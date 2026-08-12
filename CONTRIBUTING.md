# Contributing

Thanks for helping improve the Grimmory KOReader client.

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

Changes to CFI conversion, annotation merging, queues, authentication, archive
handling, or update recovery should include a focused regression test and a
short explanation of the failure mode. Do not weaken the realism-policy mapping
or update a case-set fingerprint without reviewing the cases it represents.

Report security problems privately as described in [SECURITY.md](SECURITY.md).
