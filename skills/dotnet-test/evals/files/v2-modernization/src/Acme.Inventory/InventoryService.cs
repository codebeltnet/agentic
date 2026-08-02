namespace Acme.Inventory;

public sealed class InventoryService
{
    public int GetAvailableCount(IEnumerable<bool> availability)
    {
        return availability.Count(value => value);
    }
}

