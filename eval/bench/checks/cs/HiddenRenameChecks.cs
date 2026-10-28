using Inventory.Core.Abstractions;
using Inventory.Core.Models;
using Inventory.Core.Services;
using Inventory.Core.Storage;
using Xunit;

namespace Inventory.HiddenChecks;

public class HiddenRenameChecks
{
    [Fact]
    public void RenamedTypeAndMethodWork()
    {
        var hammer = new Product(new Sku("HAM-0001"), "Hammer", 10m, Category.Hardware);
        InventoryItem item = new InventoryItem(hammer, 5);
        item.Reserve(1);
        Assert.Equal(4, item.Available);
        IStockRepository repo = new InMemoryStockRepository(new[] { item });
        InventoryItem? found = repo.Find(hammer.Sku);
        Assert.Same(item, found);
        var w = new Warehouse(repo);
        Quote q = w.Allocate(Order.Create("o", new OrderLine(hammer.Sku, 2)));
        Assert.Equal(20m, q.Total);
        Assert.Equal(2, w.AvailableUnits(hammer.Sku));
        InventoryItem registered = w.Register(new Product(new Sku("NAL-0002"), "Nail", 1m, Category.Hardware), 3);
        Assert.Equal(3, registered.OnHand);
    }
}
