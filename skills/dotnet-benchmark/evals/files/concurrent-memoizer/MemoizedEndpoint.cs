namespace Acme.Caching;

public sealed class MemoizedEndpoint(ConcurrentMemoizer<int, string> memoizer)
{
    public async Task HandleBurst(IEnumerable<int> ids, CancellationToken cancellationToken)
    {
        await Parallel.ForEachAsync(ids, cancellationToken, (id, cancellation) =>
        {
            _ = memoizer.GetOrAdd(id, static key => key.ToString());
            return ValueTask.CompletedTask;
        });
    }
}
