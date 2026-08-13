namespace Tolk.Web;

public sealed class AppAssetOptions
{
    public string BaseUrl { get; set; } = string.Empty;

    public string Scheme { get; set; } = string.Empty;

    public string GetUrl(string path) => path;
}
