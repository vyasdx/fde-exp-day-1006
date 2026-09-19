using System.Text.RegularExpressions;

namespace BankingApp.Tools;

/// <summary>
/// US phone-number normalizer — participant code moved into the consolidated
/// BankingApp. Pure function; also exposed as an MCP tool.
/// </summary>
public sealed partial class PhoneNormalizer
{
    /// <summary>Normalizes a US phone number to E.164-ish form: +1XXXXXXXXXX.</summary>
    public string NormalizePhone(string phone)
    {
        // Drop any extension suffix BEFORE counting digits. "555 123 0001 ext 4"
        // otherwise yields 11 digits with no leading 1, which the 11-digit branch
        // rejects — the extension is not part of the subscriber number.
        var subscriber = ExtensionSuffix().Replace(phone, "");
        var digits = new string(subscriber.Where(char.IsDigit).ToArray());
        if (digits.Length == 10)
        {
            return "+1" + digits;
        }

        if (digits.Length == 11 && digits.StartsWith('1'))
        {
            return "+" + digits;
        }

        return "INVALID: expected a 10-digit US phone number";
    }

    [GeneratedRegex(@"[^\d+]")]
    private static partial Regex NonNumericChars();

    /// <summary>Matches an extension marker and everything after it: "ext 4", "x221", "extension 9".</summary>
    [GeneratedRegex(@"\b(?:ext|extension|x)\b\.?.*$", RegexOptions.IgnoreCase)]
    private static partial Regex ExtensionSuffix();
}