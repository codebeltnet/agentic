namespace Acme;

public readonly record struct DateWindow(DateOnly Start, DateOnly End)
{
    public override string ToString() => $"{Start:O}/{End:O}";
}
