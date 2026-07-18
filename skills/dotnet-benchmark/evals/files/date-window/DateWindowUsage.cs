namespace Acme;

public sealed class DateWindowIndex
{
    private readonly Dictionary<DateWindow, string> _values = new();

    public bool TryGet(DateWindow window, out string? value) => _values.TryGetValue(window, out value);
}
