# Recorded Fixtures Lane

`tests/fixtures/recorded/` is gitignored and contains local-only real-book
fixtures for realism testing.

Use a neutral directory name rather than a title or author. The directory,
unpacked EPUB, `samples.json`, and any source logs are private local evidence;
verify `git status --ignored` before assuming a new path is excluded.

## How to populate

1. Open a Grimmory book on the Kindle and capture an XPointer and corresponding
   CFI from the device logs (`/mnt/us/koreader/crash.log`).
2. SCP the EPUB file to your development machine and unzip it into
   `tests/fixtures/recorded/<book-id>/`.
3. Create `tests/fixtures/recorded/<book-id>/samples.json`:

```json
{
  "xpointers": [
    { "xp": "/body/DocFragment[1]/body/p[2].42", "cfi": "epubcfi(/6/2[chapter1]!/4/2/6:21)" }
  ]
}
```

4. Run `scripts/test.sh`. The recorded lane discovers every book directory,
   initializes the unpacked EPUB, and checks both conversions for every saved
   pair: XPointer to CFI and CFI back to XPointer. A present but empty or
   malformed recorded directory fails instead of silently passing.

## Policy

This lane is **local-only realism**, not CI-required. The synthetic fixtures in
`tests/fixtures/synthetic/` keep individual pathologies diagnosable in CI. The
private real-EPUB ReaderUI companion is the behavior gate for ordinary messy
books; this recorded lane is the exact-pair regression gate for CFIs captured
from a device.

Recorded fixtures may contain licensed book content; do not commit them. The
repository `.gitignore` excludes this directory. Redact usernames, server URLs,
book metadata, and unrelated log lines when copying an XPointer/CFI pair into
`samples.json`.
