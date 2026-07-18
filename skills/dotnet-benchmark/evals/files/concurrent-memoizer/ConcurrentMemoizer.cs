namespace Acme.Caching;

public sealed class ConcurrentMemoizer<TKey, TValue> where TKey : notnull
{
    private readonly object _gate = new();
    private readonly Dictionary<TKey, TValue> _values = new();

    public TValue GetOrAdd(TKey key, Func<TKey, TValue> factory)
    {
        lock (_gate)
        {
            if (_values.TryGetValue(key, out var value))
            {
                return value;
            }

            value = factory(key);
            _values.Add(key, value);
            return value;
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            _values.Clear();
        }
    }
}
