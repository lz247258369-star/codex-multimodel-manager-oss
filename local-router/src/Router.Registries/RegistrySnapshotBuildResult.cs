using Router.Core.Errors;

namespace Router.Registries;

/// <summary>Typed registry build outcome: exactly one of a snapshot or an error.</summary>
public sealed record RegistrySnapshotBuildResult
{
    public RouterRegistrySnapshot? Snapshot { get; init; }

    public RouterError? Error { get; init; }

    public static RegistrySnapshotBuildResult Ok(RouterRegistrySnapshot snapshot)
        => new() { Snapshot = snapshot };

    public static RegistrySnapshotBuildResult Fail(RouterError error)
        => new() { Error = error };

    /// <summary>Validates the discriminated invariant.</summary>
    public void Validate()
    {
        if ((Snapshot is null) == (Error is null))
        {
            throw new InvalidOperationException("A RegistrySnapshotBuildResult must contain exactly one of snapshot or error.");
        }
    }
}
