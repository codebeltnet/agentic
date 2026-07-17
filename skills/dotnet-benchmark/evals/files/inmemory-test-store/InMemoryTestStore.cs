using System;
using System.Collections.Generic;
using System.Linq;

namespace Codebelt.Extensions.Xunit;

public sealed class InMemoryTestStore<T>
{
    private readonly List<T> _items = new();

    public void Add(T item) => _items.Add(item);

    public IReadOnlyCollection<T> Query() => _items;

    public IEnumerable<T> Query(Func<T, bool> predicate) => _items.Where(predicate);

    public IEnumerable<TRequested> QueryFor<TRequested>() => _items.OfType<TRequested>();
}
