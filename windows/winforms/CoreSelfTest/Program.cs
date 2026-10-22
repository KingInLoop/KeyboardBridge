using KeyboardBridge;

var failed = 0;
void Expect(bool condition, string name)
{
    Console.WriteLine($"{(condition ? "PASS" : "FAIL")} {name}");
    if (!condition) failed++;
}

var safe = TextPlan.Create("echo a\r\nb\tc", false);
Expect(string.Concat(safe.Units) == "echo a b    c", "newline and tab safe normalization");
Expect(safe.ReplacedNewlines == 1, "newline count");
var allowed = TextPlan.Create("a\nb", true);
Expect(string.Concat(allowed.Units) == "a\nb", "allowed return preserved");
Expect(PhysicalKeyMapper.Map('a')?.VirtualKey == 0x41, "physical key mapping for a");
Expect(PhysicalKeyMapper.Map('p')?.VirtualKey == 0x50, "physical key mapping for p");
Expect(PhysicalKeyMapper.Map('A')?.Shift == true, "uppercase uses shift");
Expect(PhysicalKeyMapper.Map('.')?.VirtualKey == 0xBE, "physical key mapping for period");
Expect(PhysicalKeyMapper.Map('$')?.Shift == true, "shell symbol uses shift");

Console.WriteLine(failed == 0 ? "CORE SELF-TEST OK" : $"CORE SELF-TEST FAILED: {failed}");
return failed == 0 ? 0 : 1;
