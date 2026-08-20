# Contributing

Thanks for helping improve the Grimmory KOReader client.

## Development setup

The fast and deterministic gates are designed for Linux. On Windows, run the
shell entry points through WSL. Install LuaJIT, LuaRocks, Python 3, and the Lua
modules listed by `scripts/test.sh`; install the locked JavaScript dependencies
with:

```bash
npm ci --ignore-scripts --prefix tests/compatibility
```

The visual workflow additionally requires Pillow and the system tools checked
by `scripts/setup-koreader-emulator.sh --check`. The pinned KOReader runtime is
downloaded and checksum-verified on first use.

## Before opening a pull request

1. Run `scripts/test.sh` for the fast Lua suite.
2. Run `scripts/ci-check.sh` for the complete deterministic gate. Install the
   locked Node dependencies first with
   `npm ci --ignore-scripts --prefix tests/compatibility`.
3. For UI changes, run `bash scripts/run-koreader-visual-tests.sh` on Linux or
   through WSL. Review differences at original resolution. Reference images
   may be changed only through the explicit approval commands documented in
   `tests/visual/README.md`.
4. Keep real EPUBs, provider responses, account data, logs, and private test
   reports out of commits. The public synthetic suite must remain useful on its
   own.

Useful focused commands are documented in [tests/README.md](tests/README.md).
Use `scripts/test.sh <spec-path>` for a focused Lua run, and run the complete
gate before requesting review.

Changes to CFI conversion, annotation merging, queues, authentication, archive
handling, or update recovery should include a focused regression test and a
short explanation of the failure mode. Do not weaken the realism-policy mapping
or update a case-set fingerprint without reviewing the cases it represents.

Documentation changes should keep user-facing instructions in `README.md`,
`INSTALL.md`, and `TROUBLESHOOTING.md` consistent with the actual menu labels.
Update `CHANGELOG.md` for user-visible behavior, and update the relevant file
under `tests/` when a harness command, realism boundary, fixture, or scenario
changes. Do not update evidence dates or counts without rerunning the command
that produces them.

## Releases

Both plugins share one version. `scripts/release.sh <version>` runs the fast
Lua gate, updates both `_meta.lua` files, builds exactly two archives, generates
`manifest.json`, and validates the complete set. Review the version bump and
generated artifacts; publishing a GitHub release is a separate maintainer
action. Run `scripts/ci-check.sh` and the visual gate before cutting a release
candidate.

Report security problems privately as described in [SECURITY.md](SECURITY.md).
