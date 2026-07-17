namespace Acme.Text.Tests;

public class DecimalParserTests
{
    // Import values include typical integers/decimals, decimal boundaries, and rejected content.
    private static readonly string[] Cases = ["42", "1234.56", "-79228162514264337593543950335", "not-a-number", "123.45 trailing"];
}
