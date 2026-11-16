#!/usr/bin/env python3
"""Non-executing verification of the intended Windows engineering binary."""
from pathlib import Path
import hashlib
import struct
import sys

p = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent.parent / "build/LightCapture.exe"
b = p.read_bytes()
def u16(offset): return struct.unpack_from("<H", b, offset)[0]
def u32(offset): return struct.unpack_from("<I", b, offset)[0]
def check(ready, description):
    if not ready:
        raise SystemExit(f"FAIL: {description}")

check(len(b) > 256 and b[:2] == b"MZ", "DOS header")
pe = u32(60)
check(pe + 160 <= len(b) and b[pe:pe + 4] == b"PE\x00\x00", "PE signature")
check(u16(pe + 4) == 0x8664, "AMD64 machine")
check(u16(pe + 24) == 0x20B, "PE32+ optional header")
check(u16(pe + 24 + 68) == 2, "Windows GUI subsystem")
check(u16(pe + 22) & 2 and not u16(pe + 22) & 0x2000, "executable, not DLL")
check(u16(pe + 24 + 70) & 0x0140 == 0x0140, "ASLR and DEP enabled")
check(u32(pe + 24 + 112 + 2 * 8) > 0, "resource directory present")
signing_table_offset = u32(pe + 24 + 112 + 4 * 8)
print(f"PE32+ / AMD64 / Windows GUI / {len(b):,} bytes")
print("SHA-256:", hashlib.sha256(b).hexdigest())
print("Certificate table:", "present (not verified)" if signing_table_offset else "absent (unsigned)")
print("This check does not run the program or exercise Windows desktop, capture or audio.")
