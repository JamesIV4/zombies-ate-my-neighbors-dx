#!/usr/bin/env python3
"""Create/update the repo-owned ZAMN-DX bsnes-hd libretro core.

BizHawk 2.11.1 can host libretro cores, but its bridge only exposes core option
defaults to the core. This patches a deliberately chosen upstream bsnes-hd beta
DLL so the defaults match the settings required by the ZAMN-DX widescreen ROM
hack. The source DLL should also include tools/bsnes_hd_libretro_wram.patch so
BizHawk can expose SNES WRAM as mainmemory for the ZAMN-DX controller mailbox.
Release builds consume the tracked patched DLL; they do not download or
regenerate it automatically.
"""
from __future__ import annotations

import argparse
import hashlib
import pathlib
import struct


RECORD_SIZE = 2080
DEFAULT_VALUE_OFFSET = 2072
VALUES_OFFSET = 24
VALUE_RECORD_SIZE = 16

# The user requested "layers 2 and 4 always on"; the companion "1 and 4 off"
# appears to repeat layer 4, so this uses the coherent 1/3 off, 2/4 on layout.
#
# The CPU entries are a ZAMN-DX performance tweak: BizHawk's libretro bridge only
# feeds the core its option *defaults*, so a mild overclock and the Fast Math hack are
# baked in here to take pressure off sprite-heavy widescreen scenes. The value IDs come
# straight from target-libretro/libretro_core_options.h (overclock "10".."400" in 10%
# steps, default "100"; fastmath "ON"/"OFF", default "OFF").
DEFAULTS = {
    "bsnes_mode7_wsMode": "all",
    "bsnes_mode7_wsbg1": "off",
    "bsnes_mode7_wsbg2": "on",
    "bsnes_mode7_wsbg3": "off",
    "bsnes_mode7_wsbg4": "on",
    "bsnes_mode7_wsobj": "unsafe",
    "bsnes_cpu_overclock": "130",   # 130% CPU overclock (stock 100%)
    "bsnes_cpu_fastmath": "ON",     # enable CPU Fast Math (stock OFF)
}


class PeImage:
    def __init__(self, data: bytearray):
        self.data = data
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe:pe + 4] != b"PE\0\0":
            raise ValueError("not a PE image")

        coff = pe + 4
        section_count = struct.unpack_from("<H", data, coff + 2)[0]
        optional_size = struct.unpack_from("<H", data, coff + 16)[0]
        optional = coff + 20
        magic = struct.unpack_from("<H", data, optional)[0]
        if magic != 0x20B:
            raise ValueError("expected a 64-bit PE image")

        self.image_base = struct.unpack_from("<Q", data, optional + 24)[0]
        section_table = optional + optional_size
        self.sections = []
        for index in range(section_count):
            offset = section_table + index * 40
            name = data[offset:offset + 8].split(b"\0")[0].decode("ascii", "ignore")
            virtual_size, virtual_address, raw_size, raw_pointer = struct.unpack_from(
                "<IIII", data, offset + 8)
            self.sections.append((name, virtual_address, virtual_size, raw_pointer, raw_size))

    def file_offset_to_va(self, offset: int) -> int:
        for _, virtual_address, _, raw_pointer, raw_size in self.sections:
            if raw_pointer <= offset < raw_pointer + raw_size:
                return self.image_base + virtual_address + offset - raw_pointer
        raise ValueError(f"file offset 0x{offset:X} is outside PE sections")

    def va_to_file_offset(self, va: int) -> int:
        rva = va - self.image_base
        for _, virtual_address, virtual_size, raw_pointer, raw_size in self.sections:
            size = max(virtual_size, raw_size)
            if virtual_address <= rva < virtual_address + size:
                return raw_pointer + rva - virtual_address
        raise ValueError(f"VA 0x{va:X} is outside PE sections")

    def read_c_string(self, va: int) -> str:
        offset = self.va_to_file_offset(va)
        end = self.data.index(0, offset)
        return self.data[offset:end].decode("ascii")

    def string_va(self, value: str) -> int:
        needle = value.encode("ascii") + b"\0"
        hits = []
        start = 0
        while True:
            index = self.data.find(needle, start)
            if index < 0:
                break
            hits.append(index)
            start = index + 1

        # Option strings live together in .rdata; this filters out unrelated
        # short strings when values such as "on" are looked up through records.
        hits = [hit for hit in hits if 0x220000 <= hit <= 0x230000] or hits
        if len(hits) != 1:
            raise ValueError(f"expected one copy of {value!r}, found {len(hits)}")
        return self.file_offset_to_va(hits[0])

    def option_record_offset(self, key: str) -> int:
        key_pointer = struct.pack("<Q", self.string_va(key))
        candidates = []
        start = 0
        while True:
            index = self.data.find(key_pointer, start)
            if index < 0:
                break
            start = index + 1
            # The key string's VA also appears as an immediate in the var.key = "..."
            # reader code, so disambiguate structurally rather than by description text
            # (CPU options are not "Widescreen ..."): only the real v1
            # retro_core_option_definition record has its default_value pointer
            # RECORD_SIZE-8 after the key AND that default listed among its own values.
            try:
                desc = self.read_c_string(struct.unpack_from("<Q", self.data, index + 8)[0])
                values = self.option_values(index)
                current_default = self.read_c_string(
                    struct.unpack_from("<Q", self.data, index + DEFAULT_VALUE_OFFSET)[0])
            except (ValueError, UnicodeDecodeError, struct.error):
                continue
            if desc and values and current_default in values:
                candidates.append(index)

        if len(candidates) != 1:
            raise ValueError(f"expected one option record for {key}, found {len(candidates)}")
        return candidates[0]

    def option_values(self, record: int) -> dict[str, int]:
        values: dict[str, int] = {}
        for index in range(128):
            value_pointer = struct.unpack_from(
                "<Q", self.data, record + VALUES_OFFSET + index * VALUE_RECORD_SIZE)[0]
            if value_pointer == 0:
                break
            values[self.read_c_string(value_pointer)] = value_pointer
        return values


def patch_core(source: pathlib.Path, output: pathlib.Path) -> list[str]:
    data = bytearray(source.read_bytes())
    image = PeImage(data)
    report = []

    for key, desired in DEFAULTS.items():
        record = image.option_record_offset(key)
        values = image.option_values(record)
        if desired not in values:
            raise ValueError(f"{key} has no value {desired!r}; values are {sorted(values)}")

        current_pointer = struct.unpack_from("<Q", data, record + DEFAULT_VALUE_OFFSET)[0]
        current = image.read_c_string(current_pointer)
        struct.pack_into("<Q", data, record + DEFAULT_VALUE_OFFSET, values[desired])
        report.append(f"{key}: {current} -> {desired}")

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    report = patch_core(args.source, args.output)
    for line in report:
        print(line)
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest().upper()
    print(f"output: {args.output}")
    print(f"sha256: {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
