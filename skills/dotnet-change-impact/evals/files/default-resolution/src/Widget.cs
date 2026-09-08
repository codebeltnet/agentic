namespace Example;

public class Widget
{
    public string Name { get; set; } = string.Empty;
    public static Widget Parse(string value) => new Widget { Name = value };
}
