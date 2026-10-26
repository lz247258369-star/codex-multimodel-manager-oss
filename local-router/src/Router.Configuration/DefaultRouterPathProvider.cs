namespace Router.Configuration;

/// <summary>
/// Production path provider following the existing Manager conventions:
/// codex home is <c>CODEX_HOME</c> or <c>~/.codex</c>; router files live under
/// <c>multimodel-manager/local-router/</c>; backups under
/// <c>~/.codex/backups/local-router/</c>.
/// </summary>
public sealed class DefaultRouterPathProvider : IRouterPathProvider
{
    public string DefaultsPath
        => Path.Combine(AppContext.BaseDirectory, "config", "router.defaults.json");

    public string UserConfigPath
        => Path.Combine(CodexHome, "multimodel-manager", "local-router", "router.config.json");

    public string RuntimeStatePath
        => Path.Combine(CodexHome, "multimodel-manager", "local-router", "runtime", "router.state.json");

    public string OwnerRecordPath
        => Path.Combine(CodexHome, "multimodel-manager", "local-router", "runtime", "router.pid.json");

    public string BackupRootPath
        => Path.Combine(CodexHome, "backups", "local-router");

    public string QuarantineRootPath
        => Path.Combine(CodexHome, "multimodel-manager", "local-router", "quarantine");

    public string MigrationReceiptDirectory
        => Path.Combine(CodexHome, "multimodel-manager", "local-router", "runtime");

    private static string CodexHome
    {
        get
        {
            string? custom = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (!string.IsNullOrWhiteSpace(custom))
            {
                return custom;
            }

            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        }
    }
}
