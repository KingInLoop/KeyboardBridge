namespace KeyboardBridge;

internal sealed record TextPlan(IReadOnlyList<string> Units, int ReplacedNewlines)
{
    public static TextPlan Create(string text, bool allowReturn)
    {
        var units = new List<string>();
        var replaced = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var ch = text[i];
            if (ch == '\r' || ch == '\n')
            {
                if (ch == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                units.Add(allowReturn ? "\n" : " ");
                if (!allowReturn) replaced++;
            }
            else if (ch == '\t')
            {
                units.Add("    ");
            }
            else if (char.IsHighSurrogate(ch) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                units.Add(new string(new[] { ch, text[++i] }));
            }
            else
            {
                units.Add(ch.ToString());
            }
        }
        return new TextPlan(units, replaced);
    }
}

internal readonly record struct PhysicalKey(ushort VirtualKey, bool Shift);

internal static class PhysicalKeyMapper
{
    private static readonly IReadOnlyDictionary<char, ushort> Plain = new Dictionary<char, ushort>
    {
        [' '] = 0x20,
        ['0'] = 0x30, ['1'] = 0x31, ['2'] = 0x32, ['3'] = 0x33, ['4'] = 0x34,
        ['5'] = 0x35, ['6'] = 0x36, ['7'] = 0x37, ['8'] = 0x38, ['9'] = 0x39,
        [';'] = 0xBA, ['='] = 0xBB, [','] = 0xBC, ['-'] = 0xBD, ['.'] = 0xBE,
        ['/'] = 0xBF, ['`'] = 0xC0, ['['] = 0xDB, ['\\'] = 0xDC, [']'] = 0xDD,
        ['\''] = 0xDE
    };

    private static readonly IReadOnlyDictionary<char, ushort> Shifted = new Dictionary<char, ushort>
    {
        [')'] = 0x30, ['!'] = 0x31, ['@'] = 0x32, ['#'] = 0x33, ['$'] = 0x34,
        ['%'] = 0x35, ['^'] = 0x36, ['&'] = 0x37, ['*'] = 0x38, ['('] = 0x39,
        [':'] = 0xBA, ['+'] = 0xBB, ['<'] = 0xBC, ['_'] = 0xBD, ['>'] = 0xBE,
        ['?'] = 0xBF, ['~'] = 0xC0, ['{'] = 0xDB, ['|'] = 0xDC, ['}'] = 0xDD,
        ['"'] = 0xDE
    };

    public static PhysicalKey? Map(char character)
    {
        if (character is >= 'a' and <= 'z')
            return new PhysicalKey((ushort)char.ToUpperInvariant(character), false);
        if (character is >= 'A' and <= 'Z')
            return new PhysicalKey(character, true);
        if (Plain.TryGetValue(character, out var plain)) return new PhysicalKey(plain, false);
        if (Shifted.TryGetValue(character, out var shifted)) return new PhysicalKey(shifted, true);
        return null;
    }
}

