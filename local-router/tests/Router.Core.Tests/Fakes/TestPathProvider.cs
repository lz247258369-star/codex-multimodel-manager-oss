using Router.Configuration;

namespace Router.Core.Tests.Fakes;

/// <summary>Sandbox path provider for tests; never resolves a real user home.</summary>
public sealed class TestPathProvider : IRouterPathProvider
{
    public TestPathProvider(string root, string? defaultsPath = null)
    {
        Root = root;
        DefaultsPath = defaultsPath ?? Path.Combine(root, "config", "router.defaults.json");
        UserConfigPath = Path.Combine(root, "user", "router.config.json");
        RuntimeStatePath = Path.Combine(root, "runtime", "router.state.json");
        OwnerRecordPath = Path.Combine(root, "runtime", "router.pid.json");
        BackupRootPath = Path.Combine(root, "backups", "local-router");
        QuarantineRootPath = Path.Combine(root, "quarantine");
        MigrationReceiptDirectory = Path.Combine(root, "runtime");
    }

    public string Root { get; }

    public string DefaultsPath { get; }

    public string UserConfigPath { get; }

    public string RuntimeStatePath { get; }

    public string OwnerRecordPath { get; }

    public string BackupRootPath { get; }

    public string QuarantineRootPath { get; }

    public string MigrationReceiptDirectory { get; }
}
