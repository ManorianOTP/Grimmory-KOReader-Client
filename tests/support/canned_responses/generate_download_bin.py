#!/usr/bin/env python3
"""Generate download_book.bin: 256 bytes of varied content (0x00-0xFF).
Run once: python3 tests/support/canned_responses/generate_download_bin.py
"""
import os
import struct

out = os.path.join(os.path.dirname(__file__), "download_book.bin")
with open(out, "wb") as f:
    f.write(bytes(range(256)))
print("Written:", out)
