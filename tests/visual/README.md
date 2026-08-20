# Visual reference tests

This workflow turns a reviewed KOReader screenshot into an exact test contract.
The normal command runs every named screen in the pinned KOReader release, in
portrait and landscape, then performs a pixel-exact comparison:

```sh
bash scripts/run-koreader-visual-tests.sh --output build/visual/local
```

The first run downloads and checksum-verifies KOReader; later runs reuse the
external cache. The command prints the capture, JSON, log, and HTML-report
locations. The chosen output directory must be new or empty. On Windows, run it
through WSL.

For a focused, non-approving capture while developing one screen:

```sh
bash scripts/run-koreader-visual-tests.sh \
  --scenario connection_pending \
  --orientation portrait \
  --capture-only \
  --output build/visual/connection-pending
```

Use `--list` to print the executable scenario catalogue. A focused run does not
replace the full portrait-and-landscape matrix required for UI review.

Every run fingerprints the exact production-plugin and visual-driver source
trees used to create it. The fingerprint is recorded in every scenario JSON
and in the run's `provenance.json`. After capture, the runner recomputes it and
fails if sources changed mid-run or if stale/mixed JSON and PNG artifacts are
present.

The comparison and approval tool can also be used separately. It does **not**
capture KOReader itself; the emulator runner writes the named PNG files it
reads.

Approved references contain only the fictional public fixture. Private covers,
titles, screenshots, and companion reports must remain in ignored build output
and must never be bootstrapped into `tests/visual/references/`.

Pillow is the only Python dependency:

```sh
python -m pip install Pillow
```

Compare every capture with its approved reference (pixel-exact by default):

```sh
python3 scripts/visual_regression.py compare \
  --current build/visual/current \
  --references tests/visual/references \
  --artifacts build/visual/report
```

The command fails for changed pixels, changed dimensions, missing captures, or missing references. It never changes a reference. The artifact directory contains:

- `gallery.html`, the quickest way to inspect every current screen at once;
- `index.html`, the reference/current/difference review report;
- `report.json`, the machine-readable result; and
- `before.png`, `current.png`, and `diff.png` for each case.

Start with `gallery.html` for a whole-application visual pass. Click any image
to inspect the original pixels, then use `index.html` to investigate any
highlighted mismatch against its approved reference.

After reviewing a brand-new capture, register it explicitly:

```sh
python3 scripts/visual_regression.py bootstrap \
  --current build/visual/current \
  --references tests/visual/references \
  --case portrait/wifi_badge_1
```

`bootstrap` refuses to overwrite an existing reference. After an intentional design change, review the report and explicitly approve the selected replacement:

```sh
python3 scripts/visual_regression.py approve \
  --current build/visual/current \
  --references tests/visual/references \
  --case portrait/wifi_badge_1
```

Both commands also accept `--all`, but a selection is always required. Each
reference is staged, validated, and replaced atomically. References are never
silently added or updated.

Before bootstrapping or approving a screenshot, inspect it at its original
resolution. Check balance and spacing as well as content: text must not clip or
overlap, long titles must truncate deliberately, badges must sit cleanly within
their icon area, and portrait/landscape layouts must both look intentional.

Small rendering variance can be opted into with `--channel-tolerance`, `--max-changed-pixels`, or `--max-changed-ratio`. Their hard caps are deliberately narrow; exact comparison should remain the normal choice. If both pixel count and ratio are supplied, both limits must pass.

Run the workflow tests with:

```sh
python -B -m unittest discover -s tests/visual -p "test_*.py"
```
