using Router.ProviderAdapters.Abstractions;
using Xunit;

namespace Router.ProviderAdapters.Tests;

public sealed class HeaderRedactionTests
{
    [Fact]
    public void Safe_allowlist_extracts_only_declared_headers()
    {
        var headers = new Dictionary<string, IEnumerable<string>>(StringComparer.OrdinalIgnoreCase)
        {
            ["Content-Type"] = ["application/json"],
            ["X-Request-Id"] = ["req-123"],
            ["Authorization"] = ["Bearer top-secret"],
            ["Set-Cookie"] = ["session=secret"],
            ["x-api-key"] = ["secret-key"],
            ["Proxy-Authorization"] = ["Basic secret"],
            ["X-Custom-Vendor-Secret"] = ["secret"],
        };

        IReadOnlyDictionary<string, string> safe = UpstreamHeaderPolicy.ExtractSafeHeaders(headers);

        Assert.Equal(2, safe.Count);
        Assert.True(safe.ContainsKey("Content-Type"));
        Assert.True(safe.ContainsKey("X-Request-Id"));
        Assert.False(safe.ContainsKey("Authorization"));
        Assert.False(safe.ContainsKey("Set-Cookie"));
        Assert.False(safe.ContainsKey("x-api-key"));
        Assert.False(safe.ContainsKey("Proxy-Authorization"));
        Assert.False(safe.ContainsKey("X-Custom-Vendor-Secret"));
    }

    [Fact]
    public void Forbidden_header_names_are_recognized()
    {
        Assert.True(UpstreamHeaderPolicy.IsForbiddenHeader("Authorization"));
        Assert.True(UpstreamHeaderPolicy.IsForbiddenHeader("cookie"));
        Assert.True(UpstreamHeaderPolicy.IsForbiddenHeader("set-cookie"));
        Assert.True(UpstreamHeaderPolicy.IsForbiddenHeader("x-api-key"));
        Assert.True(UpstreamHeaderPolicy.IsForbiddenHeader("proxy-authorization"));
    }
}
