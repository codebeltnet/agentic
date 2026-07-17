using System.Buffers.Text;
using System.Globalization;
using System.Text;

namespace Acme.Text;

public static class DecimalParser
{
    public static bool ParseLegacy(ReadOnlySpan<byte> utf8, out decimal value, out int consumed)
    {
        var text = Encoding.UTF8.GetString(utf8);
        var success = decimal.TryParse(text, NumberStyles.Number, CultureInfo.InvariantCulture, out value);
        consumed = success ? utf8.Length : 0;
        return success;
    }

    public static bool TryParseSpan(ReadOnlySpan<byte> utf8, out decimal value, out int consumed)
    {
        if (Utf8Parser.TryParse(utf8, out value, out var parsedBytes, 'G') && parsedBytes == utf8.Length)
        {
            consumed = parsedBytes;
            return true;
        }

        value = default;
        consumed = 0;
        return false;
    }
}
