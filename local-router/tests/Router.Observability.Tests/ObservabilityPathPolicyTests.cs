using Router.Observability;
using Xunit;

namespace Router.Observability.Tests;

public sealed class ObservabilityPathPolicyTests
{
    [Fact]
    public void Router_owned_absolute_directory_is_allowed()
    {
        string dir = Path.Combine(Path.GetTempPath(), "codex-mm-logs", "router-observability");
        Assert.True(ObservabilityPathPolicy.IsAllowedDirectory(dir));
        Assert.NotNull(ObservabilityOptions.Defaults(dir));
    }

    [Fact]
    public void Cwd_drive_root_and_public_temp_root_are_rejected()
    {
        Assert.False(ObservabilityPathPolicy.IsAllowedDirectory(Environment.CurrentDirectory));
        Assert.False(ObservabilityPathPolicy.IsAllowedDirectory(Path.GetTempPath()));
        Assert.False(ObservabilityPathPolicy.IsAllowedDirectory(Path.GetPathRoot(Environment.CurrentDirectory)!));
        Assert.False(ObservabilityPathPolicy.IsAllowedDirectory("relative/logs"));
    }

    [Fact]
    public void Boundary_validation_rejects_invalid_options()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ObservabilityOptions.Create(
            Path.Combine(Path.GetTempPath(), "codex-mm-logs"),
            0,
            8,
            TimeSpan.FromDays(7),
            64));
    }
}
