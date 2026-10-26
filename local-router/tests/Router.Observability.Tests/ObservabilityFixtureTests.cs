using System.Text.Json;
using Xunit;

namespace Router.Observability.Tests;

public sealed class ObservabilityFixtureTests
{
    private static string FixtureRoot
        => Path.Combine(AppContext.BaseDirectory, "fixtures", "local-router", "v1", "observability");

    [Fact]
    public void Health_snapshot_fixture_contains_allowed_fields_only()
    {
        string json = File.ReadAllText(Path.Combine(FixtureRoot, "health.snapshot.allowed-fields.json"));
        using JsonDocument document = JsonDocument.Parse(json);

        Assert.Equal(1, document.RootElement.GetProperty("schema_version").GetInt32());
        Assert.Equal("HEALTHY", document.RootElement.GetProperty("routes")[0].GetProperty("state").GetString());
        Assert.Equal("healthy", document.RootElement.GetProperty("routes")[0].GetProperty("reason_code").GetString());
    }

    [Fact]
    public void Request_record_fixture_has_no_content_fields()
    {
        string json = File.ReadAllText(Path.Combine(FixtureRoot, "request-record.allowed-fields.json"));
        using JsonDocument document = JsonDocument.Parse(json);

        Assert.False(document.RootElement.TryGetProperty("prompt", out _));
        Assert.False(document.RootElement.TryGetProperty("instructions", out _));
        Assert.False(document.RootElement.TryGetProperty("tool_arguments", out _));
        Assert.False(document.RootElement.TryGetProperty("authorization", out _));
        Assert.Equal("COMPLETED", document.RootElement.GetProperty("terminal_state").GetString());
    }

    [Fact]
    public void Redaction_fixture_is_present_and_synthetic_only()
    {
        string json = File.ReadAllText(Path.Combine(FixtureRoot, "redaction.forbidden-injection.json"));
        using JsonDocument document = JsonDocument.Parse(json);

        Assert.Contains("synthetic-not-real", json, StringComparison.Ordinal);
        Assert.Equal(1, document.RootElement.GetProperty("schema_version").GetInt32());
    }
}
