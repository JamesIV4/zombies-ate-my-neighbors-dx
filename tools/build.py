#!/usr/bin/env python3
"""Build the Zombies Ate My Neighbors DX ROM and an IPS patch."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


EXPECTED_SHA256 = "b27e2e957fa760f4f483e2af30e03062034a6c0066984f2e284cc2cb430b2059"
DEFAULT_ROM = "Zombies Ate My Neighbors (USA).sfc"
DEFAULT_OUTPUT = "dist/Zombies Ate My Neighbors DX.sfc"
DEFAULT_IPS = "dist/zamndx.ips"

# The generic sprite-to-sprite collision routine at SNES $80:BEF1 uses
# (position delta + 8) < 16 on both axes. A radius of 12 gives a 24-pixel
# box, exactly 150% of the original 16-pixel box.
#
# The aim hook replaces the weapon-cycle test at $80:D259, immediately after
# movement updates the player's facing, with a call to unused padding at
# $81:FF48. It reads the analog aim state that Lua places at the top of WRAM,
# changes player 1's facing, and returns the original button-test result and
# processor flags.
PATCHES = (
    (0x003EF8, bytes.fromhex("08 00"), bytes.fromhex("0C 00")),
    (0x003EFB, bytes.fromhex("10 00"), bytes.fromhex("18 00")),
    (0x003F06, bytes.fromhex("08 00"), bytes.fromhex("0C 00")),
    (0x003F09, bytes.fromhex("10 00"), bytes.fromhex("18 00")),
    (
        0x005259,
        bytes.fromhex("A5 1A 29 00 80"),
        bytes.fromhex("22 48 FF 81 EA"),
    ),
    (
        0x00FF48,
        bytes.fromhex("FF " * 26),
        bytes.fromhex(
            "A5 1A "        # LDA $1A: controller input
            "29 00 80 "     # AND #$8000: B/weapon-cycle test
            "48 "           # PHA: preserve button-test result
            "7B "           # TDC
            "C9 00 01 "     # CMP #$0100: player 1 direct page
            "D0 0C "        # BNE restore
            "AF F0 FF 7F "  # LDA.l $7FFFF0: analog aim active
            "F0 06 "        # BEQ restore
            "AF F2 FF 7F "  # LDA.l $7FFFF2: aim direction
            "85 26 "        # STA $26: facing direction
            "68 "           # restore: PLA
            "6B"            # RTL
        ),
    ),
)

CHECKSUM_OFFSET = 0x007FDC


def digest(data: bytes, algorithm: str) -> str:
    return hashlib.new(algorithm, data).hexdigest()


def patch_rom(source: bytes) -> bytearray:
    actual_sha256 = digest(source, "sha256")
    if actual_sha256 != EXPECTED_SHA256:
        raise ValueError(
            "Unsupported ROM. Expected the headerless USA ROM with SHA-256 "
            f"{EXPECTED_SHA256}, got {actual_sha256}."
        )

    result = bytearray(source)
    for offset, expected, replacement in PATCHES:
        actual = bytes(result[offset : offset + len(expected)])
        if actual != expected:
            raise ValueError(
                f"Unexpected bytes at file offset 0x{offset:06X}: "
                f"expected {expected.hex(' ')}, got {actual.hex(' ')}"
            )
        result[offset : offset + len(replacement)] = replacement

    # The checksum and complement always contribute 0x1FE to the byte sum, so
    # the existing pair can remain present while calculating the replacement.
    checksum = sum(result) & 0xFFFF
    complement = checksum ^ 0xFFFF
    result[CHECKSUM_OFFSET : CHECKSUM_OFFSET + 2] = complement.to_bytes(2, "little")
    result[CHECKSUM_OFFSET + 2 : CHECKSUM_OFFSET + 4] = checksum.to_bytes(2, "little")

    if (sum(result) & 0xFFFF) != checksum:
        raise AssertionError("SNES checksum calculation did not converge")

    return result


def changed_runs(original: bytes, modified: bytes):
    offset = 0
    while offset < len(original):
        if original[offset] == modified[offset]:
            offset += 1
            continue

        start = offset
        while (
            offset < len(original)
            and original[offset] != modified[offset]
            and offset - start < 0xFFFF
        ):
            offset += 1
        yield start, modified[start:offset]


def make_ips(original: bytes, modified: bytes) -> bytes:
    output = bytearray(b"PATCH")
    for offset, replacement in changed_runs(original, modified):
        if offset > 0xFFFFFF:
            raise ValueError("IPS cannot encode an offset above 0xFFFFFF")
        output.extend(offset.to_bytes(3, "big"))
        output.extend(len(replacement).to_bytes(2, "big"))
        output.extend(replacement)
    output.extend(b"EOF")
    return bytes(output)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rom", nargs="?", default=DEFAULT_ROM, type=Path)
    parser.add_argument("--output", default=DEFAULT_OUTPUT, type=Path)
    parser.add_argument("--ips", default=DEFAULT_IPS, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source = args.rom.read_bytes()
    patched = patch_rom(source)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.ips.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(patched)
    args.ips.write_bytes(make_ips(source, patched))

    checksum = int.from_bytes(
        patched[CHECKSUM_OFFSET + 2 : CHECKSUM_OFFSET + 4], "little"
    )
    print(f"ROM: {args.output}")
    print(f"IPS: {args.ips}")
    print(f"SHA-256: {digest(patched, 'sha256')}")
    print(f"SNES checksum: {checksum:04X}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
