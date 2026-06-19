using System.Buffers.Binary;
using System.Text;

namespace ZamndxLauncher;

internal static class LibretroCoreOptions
{
    private const int DefaultValueOffset = 2072;
    private const int ValuesOffset = 24;
    private const int ValueRecordSize = 16;

    internal static void PatchDefaultOption(
        string sourcePath,
        string outputPath,
        string key,
        string desiredValue)
    {
        var data = File.ReadAllBytes(sourcePath);
        var image = new PeImage(data);
        var record = image.OptionRecordOffset(key);
        var values = image.OptionValues(record);
        if (!values.TryGetValue(desiredValue, out var desiredPointer))
        {
            throw new InvalidOperationException(
                $"{key} does not expose a {desiredValue} core-option value.");
        }

        BinaryPrimitives.WriteUInt64LittleEndian(
            data.AsSpan(record + DefaultValueOffset, sizeof(ulong)),
            desiredPointer);

        Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
        File.WriteAllBytes(outputPath, data);
    }

    private sealed class PeImage
    {
        private readonly byte[] _data;
        private readonly ulong _imageBase;
        private readonly List<Section> _sections = [];

        internal PeImage(byte[] data)
        {
            _data = data;
            if (data.Length < 0x40 || data[0] != (byte)'M' || data[1] != (byte)'Z')
            {
                throw new InvalidOperationException("The bsnes-hd core is not a PE image.");
            }

            var pe = ReadUInt32(0x3C);
            if (pe + 4 >= data.Length || data[(int)pe] != (byte)'P' || data[(int)pe + 1] != (byte)'E')
            {
                throw new InvalidOperationException("The bsnes-hd core is not a PE image.");
            }

            var coff = (int)pe + 4;
            var sectionCount = ReadUInt16(coff + 2);
            var optionalSize = ReadUInt16(coff + 16);
            var optional = coff + 20;
            var magic = ReadUInt16(optional);
            if (magic != 0x20B)
            {
                throw new InvalidOperationException("Expected a 64-bit bsnes-hd core.");
            }

            _imageBase = ReadUInt64(optional + 24);
            var sectionTable = optional + optionalSize;
            for (var index = 0; index < sectionCount; index++)
            {
                var offset = sectionTable + index * 40;
                var nameBytes = data[offset..(offset + 8)];
                var zero = Array.IndexOf(nameBytes, (byte)0);
                var name = Encoding.ASCII.GetString(
                    nameBytes,
                    0,
                    zero >= 0 ? zero : nameBytes.Length);
                _sections.Add(new Section(
                    name,
                    VirtualAddress: ReadUInt32(offset + 12),
                    VirtualSize: ReadUInt32(offset + 8),
                    RawPointer: ReadUInt32(offset + 20),
                    RawSize: ReadUInt32(offset + 16)));
            }
        }

        internal int OptionRecordOffset(string key)
        {
            var keyPointer = PackUInt64(StringVa(key));
            var candidates = new List<int>();
            foreach (var index in FindAll(keyPointer))
            {
                try
                {
                    var description = ReadCString(ReadUInt64(index + 8));
                    var values = OptionValues(index);
                    var current = ReadCString(ReadUInt64(index + DefaultValueOffset));
                    if (!string.IsNullOrWhiteSpace(description)
                        && values.Count > 0
                        && values.ContainsKey(current))
                    {
                        candidates.Add(index);
                    }
                }
                catch (Exception exception) when (
                    exception is ArgumentOutOfRangeException
                    || exception is InvalidOperationException
                    || exception is DecoderFallbackException)
                {
                    // The option key pointer also appears in code; only the
                    // structured retro_core_option_definition record is useful.
                }
            }

            if (candidates.Count != 1)
            {
                throw new InvalidOperationException(
                    $"Expected one bsnes-hd option record for {key}, found {candidates.Count}.");
            }

            return candidates[0];
        }

        internal Dictionary<string, ulong> OptionValues(int record)
        {
            var values = new Dictionary<string, ulong>(StringComparer.Ordinal);
            for (var index = 0; index < 128; index++)
            {
                var pointer = ReadUInt64(record + ValuesOffset + index * ValueRecordSize);
                if (pointer == 0)
                {
                    break;
                }
                values[ReadCString(pointer)] = pointer;
            }
            return values;
        }

        private ulong StringVa(string value)
        {
            var needle = Encoding.ASCII.GetBytes(value + "\0");
            var hits = FindAll(needle).ToList();
            var rdataHits = hits.Where(offset => SectionNameAtFileOffset(offset) == ".rdata").ToList();
            if (rdataHits.Count > 0)
            {
                hits = rdataHits;
            }

            if (hits.Count != 1)
            {
                throw new InvalidOperationException(
                    $"Expected one copy of {value} in the bsnes-hd core, found {hits.Count}.");
            }

            return FileOffsetToVa(hits[0]);
        }

        private string ReadCString(ulong va)
        {
            var offset = VaToFileOffset(va);
            var end = Array.IndexOf(_data, (byte)0, offset);
            if (end < 0)
            {
                throw new InvalidOperationException("Unterminated string in bsnes-hd core.");
            }
            return Encoding.ASCII.GetString(_data, offset, end - offset);
        }

        private ulong FileOffsetToVa(int offset)
        {
            foreach (var section in _sections)
            {
                if (section.RawPointer <= (uint)offset
                    && (uint)offset < section.RawPointer + section.RawSize)
                {
                    return _imageBase + section.VirtualAddress + (uint)offset - section.RawPointer;
                }
            }

            throw new InvalidOperationException(
                $"File offset 0x{offset:X} is outside the bsnes-hd core sections.");
        }

        private int VaToFileOffset(ulong va)
        {
            var rva = va - _imageBase;
            foreach (var section in _sections)
            {
                var size = Math.Max(section.VirtualSize, section.RawSize);
                if (section.VirtualAddress <= rva && rva < section.VirtualAddress + size)
                {
                    return checked((int)(section.RawPointer + rva - section.VirtualAddress));
                }
            }

            throw new InvalidOperationException(
                $"VA 0x{va:X} is outside the bsnes-hd core sections.");
        }

        private string? SectionNameAtFileOffset(int offset)
        {
            foreach (var section in _sections)
            {
                if (section.RawPointer <= (uint)offset
                    && (uint)offset < section.RawPointer + section.RawSize)
                {
                    return section.Name;
                }
            }
            return null;
        }

        private IEnumerable<int> FindAll(byte[] needle)
        {
            var start = 0;
            while (start <= _data.Length - needle.Length)
            {
                var index = _data.AsSpan(start).IndexOf(needle);
                if (index < 0)
                {
                    yield break;
                }

                var absolute = start + index;
                yield return absolute;
                start = absolute + 1;
            }
        }

        private ushort ReadUInt16(int offset) =>
            BinaryPrimitives.ReadUInt16LittleEndian(_data.AsSpan(offset, sizeof(ushort)));

        private uint ReadUInt32(int offset) =>
            BinaryPrimitives.ReadUInt32LittleEndian(_data.AsSpan(offset, sizeof(uint)));

        private ulong ReadUInt64(int offset) =>
            BinaryPrimitives.ReadUInt64LittleEndian(_data.AsSpan(offset, sizeof(ulong)));

        private static byte[] PackUInt64(ulong value)
        {
            var bytes = new byte[sizeof(ulong)];
            BinaryPrimitives.WriteUInt64LittleEndian(bytes, value);
            return bytes;
        }

        private sealed record Section(
            string Name,
            uint VirtualAddress,
            uint VirtualSize,
            uint RawPointer,
            uint RawSize);
    }
}
