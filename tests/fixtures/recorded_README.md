# Recorded Fixtures Lane

`tests/fixtures/recorded/` is gitignored and contains local-only real-book fixtures for realism testing.

## How to populate

1. Open a Grimmory book on the Kindle and capture an XPointer and corresponding CFI from the device logs (`/mnt/us/koreader/crash.log`).
2. SCP the EPUB file to your dev machine and unzip it into `tests/fixtures/recorded/<book-id>/`.
3. Create `tests/fixtures/recorded/<book-id>/samples.json`:

```json
{
  "xpointers": [
    { "xp": "/body/DocFragment[1]/body/p[2].42", "cfi": "epubcfi(/6/2[chapter1]!/4/2/6:21)" }
  ]
}
```

4. Run `scripts/test.sh` — the recorded describe block in `cfi_spec.lua` will automatically pick up the samples.

## Policy

This lane is **local-only realism**, not CI-required. The synthetic fixtures in `tests/fixtures/synthetic/` cover every documented CFI pitfall and are the CI gate.

Recorded fixtures may contain licensed book content — do not commit them. The `.gitignore` in `tests/` excludes this directory.
