#!/usr/bin/env python3
"""Run an isolated, disposable Grimmory + MariaDB acceptance-test stack.

This controller owns only Docker resources whose project name and bind mounts
it created below build/grimmory-compatibility.  Books are imported by the real
Grimmory scanner and setup uses public HTTP APIs; the database is never seeded
or edited directly.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from private_epub_sources import SourceResolutionError, resolve_private_epubs


ROOT = Path(__file__).resolve().parents[1]
COMPOSE_FILE = ROOT / "tests" / "emulator" / "grimmory-real-server.compose.yml"
FIXTURE_FILE = ROOT / "tests" / "emulator" / "grimmory_library_fixture.json"
SEED_SCRIPT = ROOT / "scripts" / "seed-grimmory-real-server.py"
METADATA_CACHE_SCRIPT = ROOT / "scripts" / "grimmory-metadata-cache.py"
DEFAULT_PARENT = ROOT / "build" / "grimmory-compatibility"
DEFAULT_GRIMMORY_IMAGE = "ghcr.io/grimmory-tools/grimmory:v3.3.1"
DEFAULT_MARIADB_IMAGE = "lscr.io/linuxserver/mariadb:11.4.8"
PROJECT_PREFIX = "grimmory-compat-"
PRIVATE_STACK = "stack-private.json"
RUNTIME_FILE = "runtime.json"
NODE_PATH_ENV = "GRIMMORY_COMPAT_NODE"
NODE_VERSION_ENV = "GRIMMORY_COMPAT_NODE_VERSION"
JWT_RE = re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+")
NODE_VERSION_RE = re.compile(r"^v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
NODE_MIN_MAJOR = 20


class StackError(RuntimeError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise StackError(f"expected JSON object: {path}")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_or_link(source: Path, target: Path) -> str:
    try:
        os.link(source, target)
        return "hard-link"
    except OSError:
        shutil.copy2(source, target)
        return "copy"


def load_fixture_module():
    source = ROOT / "tests" / "emulator" / "grimmory_fixture_server.py"
    spec = importlib.util.spec_from_file_location("grimmory_fixture_server", source)
    if spec is None or spec.loader is None:
        raise StackError(f"could not load synthetic EPUB builder: {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_epub(path: Path) -> dict:
    try:
        with zipfile.ZipFile(path) as archive:
            if archive.testzip() is not None:
                raise StackError(f"EPUB has a CRC failure: {path.name}")
            if "META-INF/container.xml" not in archive.namelist():
                raise StackError(f"EPUB has no container.xml: {path.name}")
            return {
                "archiveMembers": len(archive.infolist()),
                "uncompressedBytes": sum(item.file_size for item in archive.infolist()),
            }
    except zipfile.BadZipFile as exc:
        raise StackError(f"invalid EPUB archive: {path}") from exc


def prepare_books(
    source_dir: Path,
    run_root: Path,
    *,
    metadata_cache: Path | None = None,
    private_source_map: Path | None = None,
) -> tuple[Path, list[dict]]:
    fixture = read_json(FIXTURE_FILE)
    fixture_books = fixture.get("books")
    if not isinstance(fixture_books, list) or len(fixture_books) != 8:
        raise StackError("tracked fixture must declare exactly eight private EPUB aliases")

    books_dir = run_root / "input" / "books"
    books_dir.mkdir(parents=True, exist_ok=False)
    entries: list[dict] = []

    synthetic_name = "0000. Grimmory Acceptance Field Notes.epub"
    synthetic_path = books_dir / synthetic_name
    synthetic_builder = load_fixture_module()
    synthetic_path.write_bytes(
        synthetic_builder.synthetic_epub(
            {
                "id": 9000,
                "title": "Grimmory Acceptance Field Notes",
                "authors": ["Grimmory Test Suite"],
            }
        )
    )
    synthetic_profile = validate_epub(synthetic_path)
    entries.append(
        {
            "alias": "synthetic",
            "kind": "synthetic",
            "stagedName": synthetic_name,
            "sourcePath": str(synthetic_path.resolve()),
            "sourceSha256": sha256_file(synthetic_path),
            "sourceBytes": synthetic_path.stat().st_size,
            "stagingMethod": "generated",
            "epubProfile": synthetic_profile,
        }
    )

    try:
        private_sources = resolve_private_epubs(
            fixture_books,
            source_dir,
            metadata_cache=metadata_cache,
            source_map=private_source_map,
        )
    except SourceResolutionError as exc:
        raise StackError(str(exc)) from exc

    for raw in fixture_books:
        book_id = int(raw["id"])
        source = private_sources[book_id]
        profile = validate_epub(source)
        staged = books_dir / source.name
        method = copy_or_link(source, staged)
        entries.append(
            {
                "alias": f"real-{book_id}",
                "kind": "private-real-epub",
                "fixtureBookId": book_id,
                "stagedName": staged.name,
                "sourcePath": str(source.resolve()),
                "sourceSha256": sha256_file(source),
                "sourceBytes": source.stat().st_size,
                "stagingMethod": method,
                "epubProfile": profile,
            }
        )
    return books_dir, entries


def choose_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def repository_name(image: str) -> str:
    without_digest = image.split("@", 1)[0]
    slash = without_digest.rfind("/")
    colon = without_digest.rfind(":")
    return without_digest[:colon] if colon > slash else without_digest


def run_command(
    command: list[str],
    *,
    env: dict[str, str] | None = None,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=check,
            cwd=ROOT,
            env=env,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except FileNotFoundError as exc:
        raise StackError(f"required command was not found: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        raise StackError(f"command failed ({' '.join(command)}): {detail}") from exc


def validate_node_executable(path: Path) -> dict[str, str]:
    """Resolve and execute the exact Node binary before Docker is touched."""
    if not path.is_absolute():
        raise StackError("Node.js executable must be an absolute path")
    try:
        resolved = path.expanduser().resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise StackError(f"Node.js executable does not exist: {path}") from exc
    if not resolved.is_file():
        raise StackError(f"Node.js executable is not a file: {resolved}")
    if os.name != "nt" and not os.access(resolved, os.X_OK):
        raise StackError(f"Node.js executable is not executable: {resolved}")
    if os.name != "nt" and resolved.suffix.lower() == ".exe":
        raise StackError(
            "a Linux stack controller requires native Linux Node.js, not node.exe"
        )
    result = run_command([str(resolved), "--version"], check=False)
    version = (result.stdout or "").strip()
    if result.returncode != 0 or not NODE_VERSION_RE.fullmatch(version):
        detail = (result.stderr or result.stdout or "no version output").strip()
        raise StackError(f"Node.js preflight failed for {resolved}: {detail}")
    if int(version[1:].split(".", 1)[0]) < NODE_MIN_MAJOR:
        raise StackError(
            f"Node.js {NODE_MIN_MAJOR}+ is required; {resolved} reported {version}"
        )
    return {"executable": str(resolved), "version": version}


def record_consumer_tools(runtime_path: Path, node: dict[str, str]) -> None:
    runtime = read_json(runtime_path)
    runtime["consumerTools"] = {"node": dict(node)}
    write_json(runtime_path, runtime)
    provenance_path = runtime_path.parent / "artifacts" / "provenance.json"
    provenance = read_json(provenance_path)
    provenance["consumerTools"] = {"node": dict(node)}
    write_json(provenance_path, provenance)


def image_provenance(image: str, *, pull: bool) -> dict:
    if pull:
        result = run_command(["docker", "pull", image])
        if result.stdout:
            print(result.stdout.strip())
    inspected = run_command(["docker", "image", "inspect", image])
    payload = json.loads(inspected.stdout)
    if not payload:
        raise StackError(f"Docker image is unavailable: {image}")
    info = payload[0]
    repository = repository_name(image)
    digests = [str(item) for item in info.get("RepoDigests") or []]
    matching = next((item for item in digests if item.startswith(repository + "@")), None)
    if matching is None:
        raise StackError(
            f"image {image} has no immutable repository digest; pull it before using --offline"
        )
    return {
        "configuredReference": image,
        "resolvedReference": matching,
        "imageId": info.get("Id"),
        "repoDigests": sorted(digests),
        "created": info.get("Created"),
        "architecture": info.get("Architecture"),
        "os": info.get("Os"),
    }


def docker_provenance() -> dict:
    version = run_command(["docker", "version", "--format", "{{json .}}"])
    compose = run_command(["docker", "compose", "version", "--short"])
    payload = json.loads(version.stdout)
    return {
        "clientVersion": (payload.get("Client") or {}).get("Version"),
        "serverVersion": (payload.get("Server") or {}).get("Version"),
        "serverOs": (payload.get("Server") or {}).get("Os"),
        "serverArch": (payload.get("Server") or {}).get("Arch"),
        "composeVersion": compose.stdout.strip(),
    }


def compose_environment(private: dict) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update({str(key): str(value) for key, value in private["composeEnvironment"].items()})
    return environment


def compose_command(runtime: dict, *arguments: str) -> list[str]:
    project = str(runtime.get("composeProject", ""))
    if not project.startswith(PROJECT_PREFIX):
        raise StackError(f"refusing to control unowned Compose project: {project!r}")
    compose_file = Path(str(runtime.get("composeFile", COMPOSE_FILE))).resolve()
    run_root = Path(str(runtime.get("runRoot", ROOT))).resolve()
    # Schema-1 validation runs created before per-run snapshots point at the
    # tracked file. New runs must use their own retained snapshot so teardown
    # remains reliable if the worktree changes while a test is running.
    if compose_file != COMPOSE_FILE.resolve() and compose_file.parent != run_root:
        raise StackError(f"refusing Compose file outside owned run: {compose_file}")
    return [
        "docker",
        "compose",
        "--project-name",
        project,
        "--file",
        str(compose_file),
        *arguments,
    ]


def request_json(url: str, timeout: float = 5.0) -> object:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        raw = response.read()
    return json.loads(raw) if raw else None


def redacted(text: str, secrets_to_hide: list[str]) -> str:
    output = JWT_RE.sub(r"\1<redacted-token>", text)
    for secret in sorted((value for value in secrets_to_hide if value), key=len, reverse=True):
        output = output.replace(secret, "<redacted>")
    return output


def save_logs(runtime_path: Path, runtime: dict, private: dict) -> Path:
    result = run_command(
        compose_command(runtime, "logs", "--no-color", "--timestamps"),
        env=compose_environment(private),
        check=False,
    )
    combined = (result.stdout or "") + ("\n" + result.stderr if result.stderr else "")
    hidden = [
        runtime.get("password", ""),
        *[str(value) for key, value in private["composeEnvironment"].items() if "PASSWORD" in key],
    ]
    target = runtime_path.parent / "artifacts" / "docker.log"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(redacted(combined, hidden), encoding="utf-8")
    return target


def assert_owned_run_root(run_root: Path) -> None:
    expected = DEFAULT_PARENT.resolve()
    resolved = run_root.resolve()
    try:
        resolved.relative_to(expected)
    except ValueError as exc:
        raise StackError(
            f"refusing destructive cleanup outside {expected}: {resolved}"
        ) from exc


def remove_disposable_data(run_root: Path) -> None:
    assert_owned_run_root(run_root)
    for relative in (Path("state"), Path("input") / "books"):
        target = (run_root / relative).resolve()
        target.relative_to(run_root.resolve())
        if target.exists():
            shutil.rmtree(target)


def load_stack(runtime_path: Path) -> tuple[dict, dict]:
    runtime_path = runtime_path.resolve()
    runtime = read_json(runtime_path)
    private_path = Path(str(runtime["privateStackConfig"])).resolve()
    if private_path.parent != runtime_path.parent:
        raise StackError("private stack configuration escaped its run directory")
    return runtime, read_json(private_path)


def stop_stack(runtime_path: Path, *, preserve_data: bool = False) -> None:
    runtime, private = load_stack(runtime_path)
    run_root = runtime_path.resolve().parent
    log_path = save_logs(runtime_path, runtime, private)
    result = run_command(
        compose_command(runtime, "down", "--volumes", "--remove-orphans", "--timeout", "20"),
        env=compose_environment(private),
        check=False,
    )
    if result.returncode != 0:
        raise StackError(f"Docker teardown failed; retained state and logs at {log_path}")
    if not preserve_data:
        remove_disposable_data(run_root)
    runtime["status"] = "stopped"
    runtime["stoppedAt"] = utc_now()
    runtime["dockerLog"] = str(log_path)
    runtime["disposableDataRemoved"] = not preserve_data
    write_json(runtime_path, runtime)
    print(f"stopped isolated stack {runtime['composeProject']}")


def create_run_root(output: Path | None) -> Path:
    DEFAULT_PARENT.mkdir(parents=True, exist_ok=True)
    if output is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        output = DEFAULT_PARENT / f"run-{stamp}-{secrets.token_hex(3)}"
    output = output.resolve()
    try:
        output.relative_to(DEFAULT_PARENT.resolve())
    except ValueError as exc:
        raise StackError(f"--output must be below {DEFAULT_PARENT.resolve()}") from exc
    if output.exists() and any(output.iterdir()):
        raise StackError(f"run output already exists and is not empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    return output


def start_stack(args: argparse.Namespace) -> Path:
    # Resolve every caller-relative path before the long Docker/import phase.
    # A launcher or test cleanup can invalidate its original cwd while this
    # process is waiting; no later lifecycle step should depend on getcwd().
    source_dir = args.source_dir.resolve()
    metadata_cache = (
        args.metadata_cache.resolve()
        if getattr(args, "metadata_cache", None) else None
    )
    private_source_map = (
        args.private_source_map.resolve()
        if getattr(args, "private_source_map", None) else None
    )
    run_root = create_run_root(args.output)
    runtime_path = run_root / RUNTIME_FILE
    project = PROJECT_PREFIX + secrets.token_hex(6)
    suffix = secrets.token_hex(4)
    port = choose_port()
    username = f"compat_{suffix}"
    password = secrets.token_urlsafe(24)

    private: dict = {}
    runtime: dict = {}
    try:
        books_dir, books = prepare_books(
            source_dir,
            run_root,
            metadata_cache=metadata_cache,
            private_source_map=private_source_map,
        )
        source_manifest = run_root / "source-manifest.json"
        write_json(source_manifest, {"schemaVersion": 1, "books": books})

        print("resolving immutable Docker image digests")
        grimmory = image_provenance(args.grimmory_image, pull=not args.offline)
        mariadb = image_provenance(args.mariadb_image, pull=not args.offline)
        docker_tools = docker_provenance()

        state_root = run_root / "state"
        app_data = state_root / "grimmory"
        database_data = state_root / "mariadb"
        bookdrop = state_root / "bookdrop"
        for directory in (app_data, database_data, bookdrop):
            directory.mkdir(parents=True, exist_ok=True)

        private = {
            "schemaVersion": 1,
            "composeEnvironment": {
                "GRIMMORY_IMAGE": grimmory["resolvedReference"],
                "GRIMMORY_MARIADB_IMAGE": mariadb["resolvedReference"],
                "GRIMMORY_REAL_PORT": str(port),
                "GRIMMORY_APP_DATA": str(app_data),
                "GRIMMORY_BOOKS_DIR": str(books_dir),
                "GRIMMORY_BOOKDROP_DIR": str(bookdrop),
                "GRIMMORY_MARIADB_DATA": str(database_data),
                "GRIMMORY_DATABASE_USERNAME": "grimmory",
                "GRIMMORY_DATABASE_PASSWORD": secrets.token_urlsafe(28),
                "GRIMMORY_DATABASE_ROOT_PASSWORD": secrets.token_urlsafe(28),
            },
        }
        private_path = run_root / PRIVATE_STACK
        write_json(private_path, private)
        compose_snapshot = run_root / "compose.yml"
        shutil.copy2(COMPOSE_FILE, compose_snapshot)

        runtime = {
            "schemaVersion": 1,
            "status": "starting",
            "startedAt": utc_now(),
            "runRoot": str(run_root),
            "baseUrl": f"http://127.0.0.1:{port}",
            "username": username,
            "password": password,
            "composeProject": project,
            "composeFile": str(compose_snapshot),
            "privateStackConfig": str(private_path),
            "sourceManifest": str(source_manifest),
            "books": books,
            "syntheticBook": next(book for book in books if book["kind"] == "synthetic"),
            "keepOnFailure": bool(args.keep_on_failure),
            "images": {"grimmory": grimmory, "mariadb": mariadb},
            "docker": docker_tools,
            "commands": {
                "status": [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "status",
                    "--runtime",
                    str(runtime_path),
                ],
                "down": [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "down",
                    "--runtime",
                    str(runtime_path),
                ],
            },
        }
        write_json(runtime_path, runtime)
        write_json(
            run_root / "artifacts" / "provenance.json",
            {
                "schemaVersion": 1,
                "startedAt": runtime["startedAt"],
                "composeProject": project,
                "baseUrl": runtime["baseUrl"],
                "composeSha256": sha256_file(compose_snapshot),
                "images": runtime["images"],
                "docker": docker_tools,
                "bookInputs": [
                    {
                        "alias": book["alias"],
                        "kind": book["kind"],
                        "sha256": book["sourceSha256"],
                        "bytes": book["sourceBytes"],
                        "epubProfile": book["epubProfile"],
                    }
                    for book in books
                ],
            },
        )

        print(f"starting isolated Compose project {project} on port {port}")
        result = run_command(
            compose_command(runtime, "up", "--detach", "--wait", "--wait-timeout", str(args.readiness_timeout)),
            env=compose_environment(private),
            check=False,
        )
        if result.returncode != 0:
            raise StackError((result.stderr or result.stdout or "docker compose up failed").strip())

        deadline = time.monotonic() + args.readiness_timeout
        health = None
        while time.monotonic() < deadline:
            try:
                health = request_json(runtime["baseUrl"] + "/api/v1/healthcheck")
                break
            except (OSError, ValueError, urllib.error.URLError):
                time.sleep(1)
        if health is None:
            raise StackError("Grimmory container became healthy but its HTTP API was unavailable")

        imported_path = run_root / "imported-books.json"
        seed_environment = os.environ.copy()
        seed_environment["GRIMMORY_TEST_USERNAME"] = username
        seed_environment["GRIMMORY_TEST_PASSWORD"] = password
        seed = run_command(
            [
                sys.executable,
                str(SEED_SCRIPT),
                "--url",
                runtime["baseUrl"],
                "--expected-books",
                str(len(books)),
                "--timeout",
                str(args.import_timeout),
                "--email",
                f"{username}@example.invalid",
                "--name",
                "Grimmory Compatibility Test",
                "--library-name",
                f"Compatibility Library {suffix}",
                "--source-manifest",
                str(source_manifest),
                "--output",
                str(imported_path),
            ],
            check=False,
            env=seed_environment,
        )
        if seed.stdout:
            print(redacted(seed.stdout.strip(), [password]))
        if seed.returncode != 0:
            raise StackError(redacted((seed.stderr or "seeding failed").strip(), [password]))

        imported = read_json(imported_path)
        runtime["status"] = "imported"
        runtime["importedAt"] = utc_now()
        runtime["health"] = health
        runtime["library"] = imported.get("library")
        runtime["books"] = imported.get("books", books)
        runtime["syntheticBook"] = next(
            book for book in runtime["books"] if book["kind"] == "synthetic"
        )
        write_json(runtime_path, runtime)
        if metadata_cache:
            cache_path = metadata_cache
            enriched_path = run_root / "runtime.with-metadata.json"
            replay = run_command(
                [
                    sys.executable,
                    str(METADATA_CACHE_SCRIPT),
                    "replay",
                    "--runtime",
                    str(runtime_path),
                    "--cache",
                    str(cache_path),
                    "--enriched-runtime",
                    str(enriched_path),
                ],
                check=False,
            )
            if replay.stdout:
                print(redacted(replay.stdout.strip(), [password]))
            if replay.returncode != 0:
                raise StackError(
                    "metadata cache replay failed: "
                    + redacted((replay.stderr or "unknown error").strip(), [password])
                )
            runtime = read_json(enriched_path)
            runtime["status"] = "metadata-replayed"
            write_json(runtime_path, runtime)
        runtime["syntheticBook"] = next(
            book for book in runtime["books"] if book["kind"] == "synthetic"
        )
        runtime["status"] = "ready"
        runtime["readyAt"] = utc_now()
        write_json(runtime_path, runtime)
        provenance_path = run_root / "artifacts" / "provenance.json"
        provenance = read_json(provenance_path)
        provenance.update(
            readyAt=runtime["readyAt"],
            serverHealth=health,
            library=runtime["library"],
            importedBooks=[
                {
                    "alias": book["alias"],
                    "kind": book["kind"],
                    "sha256": book["sourceSha256"],
                    "serverBookId": book.get("serverBookId"),
                }
                for book in runtime["books"]
            ],
        )
        if runtime.get("metadataCache"):
            provenance["metadataCache"] = runtime["metadataCache"]
        write_json(provenance_path, provenance)
        print(f"real Grimmory ready: {runtime['baseUrl']}")
        print(f"runtime descriptor: {runtime_path}")
        return runtime_path
    except BaseException:
        if runtime and private:
            try:
                save_logs(runtime_path, runtime, private)
            except Exception:
                pass
            if not args.keep_on_failure:
                try:
                    stop_stack(runtime_path)
                except Exception as teardown_error:
                    print(f"WARNING: teardown also failed: {teardown_error}", file=sys.stderr)
            else:
                print(f"stack retained for diagnosis: {runtime_path}", file=sys.stderr)
                print(
                    "teardown command: "
                    + subprocess.list2cmdline(runtime["commands"]["down"]),
                    file=sys.stderr,
                )
        elif not args.keep_on_failure:
            # No Docker project has been started yet, but validation or image
            # resolution may have failed after private books were staged.
            # Remove only the two disposable directories created for this run.
            remove_disposable_data(run_root)
        raise


def status_stack(runtime_path: Path) -> int:
    runtime, private = load_stack(runtime_path)
    result = run_command(
        compose_command(runtime, "ps", "--format", "json"),
        env=compose_environment(private),
        check=False,
    )
    if result.stdout:
        print(result.stdout.strip())
    if result.stderr:
        print(result.stderr.strip(), file=sys.stderr)
    print(f"runtime status: {runtime.get('status')}; URL: {runtime.get('baseUrl')}")
    return result.returncode


def capture_logs(runtime_path: Path) -> Path:
    runtime, private = load_stack(runtime_path)
    target = save_logs(runtime_path, runtime, private)
    print(f"redacted Docker log: {target}")
    return target


def run_wrapped(args: argparse.Namespace) -> int:
    raw_command = list(args.command)
    if raw_command and raw_command[0] == "--":
        raw_command = raw_command[1:]
    if not raw_command:
        raise StackError("run requires a command after --")
    node = validate_node_executable(args.node)
    runtime_path = start_stack(args)
    record_consumer_tools(runtime_path, node)
    command = [str(runtime_path) if part == "{runtime}" else part for part in raw_command]
    if command and command[0] == "--":
        command = command[1:]
    environment = os.environ.copy()
    environment["GRIMMORY_COMPAT_RUNTIME"] = str(runtime_path)
    environment[NODE_PATH_ENV] = node["executable"]
    environment[NODE_VERSION_ENV] = node["version"]
    result: subprocess.CompletedProcess[str] | None = None
    try:
        result = subprocess.run(
            command, cwd=ROOT, env=environment, check=False, text=True,
        )
        if result.returncode != 0 and args.keep_on_failure:
            print(f"test failed; stack retained: {runtime_path}", file=sys.stderr)
            return result.returncode
        return result.returncode
    finally:
        if result is None or result.returncode == 0 or not args.keep_on_failure:
            stop_stack(runtime_path)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command_name", required=True)

    def start_arguments(command: argparse.ArgumentParser) -> None:
        command.add_argument("--source-dir", type=Path, required=True)
        command.add_argument("--output", type=Path)
        command.add_argument("--grimmory-image", default=DEFAULT_GRIMMORY_IMAGE)
        command.add_argument("--mariadb-image", default=DEFAULT_MARIADB_IMAGE)
        command.add_argument("--offline", action="store_true", help="use already-pulled images")
        command.add_argument("--keep-on-failure", action="store_true")
        command.add_argument(
            "--metadata-cache",
            type=Path,
            help="replay and verify an ignored real metadata cache after scanning",
        )
        command.add_argument(
            "--private-source-map",
            type=Path,
            help="ignored mapping used before a metadata cache exists",
        )
        command.add_argument("--readiness-timeout", type=int, default=240)
        command.add_argument("--import-timeout", type=int, default=300)

    up = subparsers.add_parser("up", help="start, import, and leave one isolated stack running")
    start_arguments(up)

    run = subparsers.add_parser("run", help="run a command with the stack, then tear it down")
    start_arguments(run)
    run.add_argument(
        "--node",
        type=Path,
        required=True,
        help="absolute native Node.js executable used by browser consumers",
    )
    run.add_argument("command", nargs=argparse.REMAINDER)

    down = subparsers.add_parser("down", help="stop an owned stack and delete its database/books")
    down.add_argument("--runtime", type=Path, required=True)
    down.add_argument("--preserve-data", action="store_true", help="debugging only")

    status = subparsers.add_parser("status", help="show only an owned stack")
    status.add_argument("--runtime", type=Path, required=True)
    logs = subparsers.add_parser("logs", help="capture redacted logs without stopping")
    logs.add_argument("--runtime", type=Path, required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    if args.command_name == "up":
        start_stack(args)
        return 0
    if args.command_name == "run":
        return run_wrapped(args)
    if args.command_name == "down":
        stop_stack(args.runtime, preserve_data=args.preserve_data)
        return 0
    if args.command_name == "status":
        return status_stack(args.runtime)
    if args.command_name == "logs":
        capture_logs(args.runtime)
        return 0
    raise AssertionError(args.command_name)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (StackError, OSError, ValueError) as exc:
        print(f"grimmory-real-stack: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
