using System.Text.RegularExpressions;
using Router.Core.Errors;
using Router.Core.Lifecycle;

namespace Router.State;

/// <summary>Safe, content-free failure record.</summary>
public sealed record FailureRecord
{
    public required string Code { get; init; }

    public required string Message { get; init; }

    public required DateTimeOffset OccurredAt { get; init; }
}

/// <summary>
/// Schema-v1 router runtime control-plane state. Contains no requests,
/// content, or secret values.
/// </summary>
public sealed record RouterRuntimeState
{
    public const int CurrentSchemaVersion = 1;

    public required int SchemaVersion { get; init; }

    public required int Version { get; init; }

    public required string Lifecycle { get; init; }

    public required string ConfigGeneration { get; init; }

    public DateTimeOffset? StartedAt { get; init; }

    public required DateTimeOffset UpdatedAt { get; init; }

    public FailureRecord? LastFailure { get; init; }

    public IReadOnlyList<MigrationReceipt> MigrationReceipts { get; init; } = [];

    public LifecycleState LifecycleState
        => LifecycleStateExtensions.TryFromWireName(Lifecycle, out LifecycleState parsed)
            ? parsed
            : Router.Core.Lifecycle.LifecycleState.Stopped;

    public static RouterRuntimeState CreateDefault(DateTimeOffset updatedAt) => new()
    {
        SchemaVersion = CurrentSchemaVersion,
        Version = 1,
        Lifecycle = Router.Core.Lifecycle.LifecycleState.Stopped.ToWireName(),
        ConfigGeneration = string.Empty,
        UpdatedAt = updatedAt,
        MigrationReceipts = [],
    };
}

/// <summary>Validation for loaded runtime state (fail closed).</summary>
public static class RouterRuntimeStateValidator
{
    private static readonly Regex ConfigGenerationPattern = new("^[0-9a-f]{64}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static RouterError? Validate(RouterRuntimeState state)
    {
        if (state is null)
        {
            return StateErrors.StateCorrupt();
        }

        if (state.SchemaVersion != RouterRuntimeState.CurrentSchemaVersion)
        {
            return StateErrors.StateCorrupt("schema_version");
        }

        if (state.Version < 1)
        {
            return StateErrors.StateCorrupt("version");
        }

        if (!LifecycleStateExtensions.TryFromWireName(state.Lifecycle, out _))
        {
            return StateErrors.StateCorrupt("lifecycle");
        }

        if (!string.IsNullOrEmpty(state.ConfigGeneration) && !ConfigGenerationPattern.IsMatch(state.ConfigGeneration))
        {
            return StateErrors.StateCorrupt("config_generation");
        }

        return null;
    }
}
