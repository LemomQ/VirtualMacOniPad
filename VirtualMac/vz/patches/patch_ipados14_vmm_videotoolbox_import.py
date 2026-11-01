#!/usr/bin/env python3
"""Make iPadOS 14's VMM load the bundled VideoToolbox endpoint strongly.

iPadOS 14 dyld can satisfy Ventura VMM's weak VideoToolbox dependency with
the system shared-cache image even though the on-disk compatibility framework
has a private LC_ID_DYLIB. That image lacks the Mac paravirtual host-session
exports, so the VMM later calls a null function pointer on its AVP queue.

Changing only this iPadOS 14 load command to LC_LOAD_DYLIB keeps iPadOS 15/16
on their established binaries while requiring dyld to map the matching
extracted endpoint. The dependency path and every bind remain unchanged.
"""

import pathlib
import struct
import sys

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
TARGET = b"@loader_path/../../../Frameworks/VideoToolbox.framework/VideoToolbox"


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <thin-arm64e-vmm>", file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    image = bytearray(path.read_bytes())
    if len(image) < 32 or struct.unpack_from("<I", image)[0] != 0xFEEDFACF:
        raise SystemExit(f"unsupported Mach-O: {path}")
    command_count = struct.unpack_from("<I", image, 16)[0]
    offset = 32
    matches = []
    for _ in range(command_count):
        command, command_size = struct.unpack_from("<II", image, offset)
        if command_size < 8 or offset + command_size > len(image):
            raise SystemExit(f"malformed load commands: {path}")
        if command in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            name_offset = struct.unpack_from("<I", image, offset + 8)[0]
            name_start = offset + name_offset
            name_end = image.find(b"\0", name_start, offset + command_size)
            if name_end >= 0 and image[name_start:name_end] == TARGET:
                matches.append((offset, command))
        offset += command_size
    if len(matches) != 1:
        raise SystemExit(
            f"expected one VideoToolbox dependency in {path}, found {len(matches)}"
        )
    command_offset, command = matches[0]
    if command != LC_LOAD_WEAK_DYLIB:
        raise SystemExit(
            f"expected weak VideoToolbox dependency in {path}, got 0x{command:x}"
        )
    struct.pack_into("<I", image, command_offset, LC_LOAD_DYLIB)
    path.write_bytes(image)
    print(f"patched {path}: VideoToolbox LC_LOAD_WEAK_DYLIB -> LC_LOAD_DYLIB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
