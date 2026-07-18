namespace Acme.Text;

public sealed class ImportPipeline
{
    public decimal Sum(IEnumerable<ReadOnlyMemory<byte>> values)
    {
        decimal total = 0;
        foreach (var value in values)
        {
            if (DecimalParser.ParseLegacy(value.Span, out var parsed, out _))
            {
                total += parsed;
            }
        }

        return total;
    }
}
