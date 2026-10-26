namespace Router.Configuration;

/// <summary>
/// Hard implementation ceilings for security limits. Defaults inherit the
/// contract values; these ceilings can never be weakened by configuration.
/// </summary>
public static class ConfigLimitCeilings
{
    public const int MaxRequestBytesCeiling = 268_435_456;
    public const int MaxHeaderBytesCeiling = 1_048_576;
    public const int MaxConnectionsCeiling = 1_024;
    public const int MaxShutdownGraceMsCeiling = 120_000;
}
