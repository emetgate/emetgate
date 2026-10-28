using Inventory.Core.Models;
using Inventory.Core.Services;
using Inventory.Core.Storage;
using Xunit;

namespace Inventory.HiddenChecks;

public class HiddenLowStockChecks
{
    private static Warehouse Build()
    {
        var w = new Warehouse(new InMemoryStockRepository());
        w.Register(new Product(new Sku("BBB-0002"), "Bolt", 1m, Category.Hardware), 3);
        w.Register(new Product(new Sku("AAA-0001"), "Anchor", 2m, Category.Hardware), 3);
        w.Register(new Product(new Sku("CCC-0003"), "Cable", 3m, Category.Electronics), 10);
        w.Register(new Product(new Sku("DDD-0004"), "Dowel", 4m, Category.Garden), 0);
        w.Register(new Product(new Sku("EEE-0005"), "Easel", 5m, Category.Office), 6);
        return w;
    }

    [Fact]
    public void ReturnsItemsStrictlyBelowThresholdSorted()
    {
        var w = Build();
        IReadOnlyList<LowStockEntry> low = w.GetLowStock(5);
        Assert.Equal(new[] { "DDD-0004", "AAA-0001", "BBB-0002" }, low.Select(e => e.Sku.Value).ToArray());
        Assert.Equal(new[] { 0, 3, 3 }, low.Select(e => e.Available).ToArray());
        Assert.Equal("Anchor", low[1].Name);
    }

    [Fact]
    public void UsesAvailableNotOnHand()
    {
        var w = Build();
        w.Reserve(Order.Create("x", new OrderLine(new Sku("CCC-0003"), 8)));
        var low = w.GetLowStock(3);
        Assert.Equal(new[] { "DDD-0004", "CCC-0003" }, low.Select(e => e.Sku.Value).ToArray());
        Assert.Equal(2, low[1].Available);
    }

    [Fact]
    public void ThresholdBoundaries()
    {
        var w = Build();
        Assert.Empty(w.GetLowStock(0));
        Assert.Equal(5, w.GetLowStock(11).Count);
        Assert.Single(w.GetLowStock(1));
        Assert.Throws<ArgumentOutOfRangeException>(() => w.GetLowStock(-1));
    }

    [Fact]
    public void EntryIsValueRecord()
    {
        var a = new LowStockEntry(new Sku("AAA-0001"), "Anchor", 3);
        var b = new LowStockEntry(new Sku("AAA-0001"), "Anchor", 3);
        Assert.Equal(a, b);
        Assert.Equal(3, a.Available);
    }
}
