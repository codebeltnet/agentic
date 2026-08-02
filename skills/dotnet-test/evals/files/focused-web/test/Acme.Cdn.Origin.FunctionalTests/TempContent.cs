namespace Acme.Cdn.Origin;

public sealed class TempContent : IDisposable
{
    public TempContent()
    {
        Root = Path.Combine(Path.GetTempPath(), "acme-cdn-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Root);
    }

    public string Root { get; }

    public void Dispose()
    {
        if (Directory.Exists(Root)) { Directory.Delete(Root, true); }
    }
}

