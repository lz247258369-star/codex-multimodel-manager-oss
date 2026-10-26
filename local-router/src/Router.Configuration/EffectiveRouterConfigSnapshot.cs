namespace Router.Configuration;

/// <summary>Provenance of an effective config snapshot (paths and hashes only).</summary>
public sealed record ConfigSourceProvenance
{
    public required string DefaultsPath { get; init; }

    public string? UserConfigPath { get; init; }

    public required bool HasUserConfig { get; init; }

    public required string DefaultsSha256 { get; init; }
}

/// <summary>
/// Immutable effective config snapshot with a stable lowercase SHA-256
/// config_generation over the normalized config.
/// </summary>
public sealed record EffectiveRouterConfigSnapshot
{
    public required RouterConfig Config { get; init; }

    public int SchemaVersion => Config.SchemaVersion;

    public int Version => Config.Version;

    public required string ConfigGeneration { get; init; }

    public required DateTimeOffset LoadedAt { get; init; }

    public required ConfigSourceProvenance Source { get; init; }
}
