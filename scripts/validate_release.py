#!/usr/bin/env python3
"""Validate the committed manifest against the two built plugin archives."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tarfile
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse


EXPECTED_DIRS = ("grimmory_sync.koplugin", "grimmory.koplugin")
REQUIRED_FILES = ("_meta.lua", "main.lua")
TEXT_SUFFIXES = {".lua", ".md", ".json", ".sh", ".txt", ".yml", ".yaml"}


def fail(message: str) -> None:
    raise ValueError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_archive(path: Path, plugin_dir: str, version: str) -> None:
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        names = {member.name.rstrip("/") for member in members}
        for member in members:
            posix = PurePosixPath(member.name)
            if posix.is_absolute() or ".." in posix.parts:
                fail(f"unsafe archive path in {path.name}: {member.name}")
            if not posix.parts or posix.parts[0] != plugin_dir:
                fail(f"unexpected archive root in {path.name}: {member.name}")

        for required in REQUIRED_FILES:
            member_name = f"{plugin_dir}/{required}"
            if member_name not in names:
                fail(f"{path.name} is missing {member_name}")

        meta_member = archive.getmember(f"{plugin_dir}/_meta.lua")
        meta = archive.extractfile(meta_member)
        if meta is None:
            fail(f"cannot read _meta.lua from {path.name}")
        meta_text = meta.read().decode("utf-8", errors="strict")
        match = re.search(r"version\s*=\s*['\"]([^'\"]+)['\"]", meta_text)
        if not match or match.group(1) != version:
            fail(f"{path.name} _meta.lua version does not match {version}")

        for member in members:
            if not member.isfile() or PurePosixPath(member.name).suffix.lower() not in TEXT_SUFFIXES:
                continue
            extracted = archive.extractfile(member)
            if extracted is None:
                continue
            text = extracted.read().decode("utf-8", errors="ignore")
            if re.search(r"booklore", text, flags=re.IGNORECASE):
                fail(f"stale BookLore branding in {path.name}:{member.name}")


def validate(manifest_path: Path, build_dir: Path) -> None:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    version = manifest.get("version")
    plugins = manifest.get("plugins")
    if not isinstance(version, str) or not version:
        fail("manifest version is missing")
    if not isinstance(plugins, list) or len(plugins) != len(EXPECTED_DIRS):
        fail("manifest must contain exactly two plugins")

    entries: dict[str, dict] = {}
    for entry in plugins:
        if not isinstance(entry, dict) or not isinstance(entry.get("dir"), str):
            fail("manifest contains a malformed plugin entry")
        plugin_dir = entry["dir"]
        if plugin_dir in entries:
            fail(f"manifest contains duplicate plugin {plugin_dir}")
        entries[plugin_dir] = entry
    if set(entries) != set(EXPECTED_DIRS):
        fail("manifest plugin set does not match the managed Grimmory pair")

    expected_archives = {f"{plugin_dir}-{version}.tar.gz" for plugin_dir in EXPECTED_DIRS}
    actual_archives = {path.name for path in build_dir.glob("*.tar.gz")}
    if actual_archives != expected_archives:
        fail(f"build directory archive set is {sorted(actual_archives)}, expected {sorted(expected_archives)}")

    for plugin_dir in EXPECTED_DIRS:
        entry = entries[plugin_dir]
        archive_name = f"{plugin_dir}-{version}.tar.gz"
        archive_path = build_dir / archive_name
        if Path(urlparse(str(entry.get("url", ""))).path).name != archive_name:
            fail(f"manifest URL does not name {archive_name}")
        if entry.get("size") != archive_path.stat().st_size:
            fail(f"manifest size does not match {archive_name}")
        if str(entry.get("sha256", "")).lower() != sha256(archive_path):
            fail(f"manifest checksum does not match {archive_name}")
        validate_archive(archive_path, plugin_dir, version)

    print(f"Validated Grimmory release {version}: {', '.join(sorted(expected_archives))}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("release/manifest.json"))
    parser.add_argument("--build-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        validate(args.manifest, args.build_dir)
    except (OSError, ValueError, json.JSONDecodeError, tarfile.TarError) as exc:
        print(f"release validation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
