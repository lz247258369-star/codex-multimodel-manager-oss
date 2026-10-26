using Router.Core.Errors;

namespace Router.State;

/// <summary>Stable, content-free state/migration/ownership errors.</summary>
public static class StateErrors
{
    public static RouterError StateCorrupt(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.StateCorrupt, "The router runtime state is corrupt.", param, requestId);

    public static RouterError StateWriteFailed(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.StateWriteFailed, "The router runtime state could not be written.", param, requestId);

    public static RouterError StateRecoveryFailed(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.StateRecoveryFailed, "The router runtime state could not be recovered.", param, requestId);

    public static RouterError MigrationFailed(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.MigrationFailed, "The configuration migration failed.", param, requestId);

    public static RouterError MigrationRollbackFailed(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.MigrationRollbackFailed, "The configuration migration rollback failed.", param, requestId);

    public static RouterError OwnershipConflict(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.OwnershipConflict, "A router process ownership conflict was detected.", param, requestId);

    public static RouterError OwnershipForeignProcess(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.OwnershipForeignProcess, "The owner record belongs to a foreign process.", param, requestId);

    public static RouterError OwnershipStale(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.OwnershipStale, "The router owner record is stale.", param, requestId);
}
