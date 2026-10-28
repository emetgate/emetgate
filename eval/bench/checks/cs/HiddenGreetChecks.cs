using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

public class HiddenGreetChecks : IClassFixture<WebApplicationFactory<global::Program>>
{
    private readonly HttpClient _client;

    public HiddenGreetChecks(WebApplicationFactory<global::Program> factory)
    {
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task HiddenGreetReturnsMessage()
    {
        var response = await _client.GetAsync("/api/greet/Ada");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        string? message = null;
        foreach (var p in doc.RootElement.EnumerateObject())
        {
            if (p.Name.Equals("message", System.StringComparison.OrdinalIgnoreCase))
            {
                message = p.Value.GetString();
            }
        }
        Assert.Equal("Hello, Ada!", message);
    }

    [Fact]
    public async Task HiddenGreetRejectsLongName()
    {
        var response = await _client.GetAsync("/api/greet/" + new string('x', 21));
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task HiddenGreetAcceptsTwentyChars()
    {
        var response = await _client.GetAsync("/api/greet/" + new string('y', 20));
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}
