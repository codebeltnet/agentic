using System.Linq;
using Xunit;

namespace Codebelt.Extensions.Xunit;

public class InMemoryTestStoreTests
{
    [Fact]
    public void Query_AllowsValidZeroMatchFilters()
    {
        var store = new InMemoryTestStore<int>();
        foreach (var value in Enumerable.Range(0, 8))
        {
            store.Add(value);
        }

        Assert.Empty(store.Query(x => x < 0));
    }

    [Fact]
    public void QueryFor_ReturnsAssignableRuntimeTypesInInsertionOrder()
    {
        var store = new InMemoryTestStore<StoreItem>();
        store.Add(new Order(1, "SO-001"));
        store.Add(new Draft(2, "draft"));
        store.Add(new PriorityOrder(3, "SO-002", 5));

        var result = store.QueryFor<Order>().ToArray();

        Assert.Collection(
            result,
            item => Assert.IsType<Order>(item),
            item => Assert.IsType<PriorityOrder>(item));
    }

    public abstract record StoreItem(int Id);

    public record Order(int Id, string Number) : StoreItem(Id);

    public sealed record PriorityOrder(int Id, string Number, int Priority) : Order(Id, Number);

    public sealed record Draft(int Id, string Name) : StoreItem(Id);
}
