using Router.Core.Errors;

namespace Router.Configuration;

/// <summary>Result of loading and validating an effective config.</summary>
public sealed record RouterConfigLoadResult(EffectiveRouterConfigSnapshot? Snapshot, RouterError? Error)
{
    public bool IsSuccess => Snapshot is not null && Error is null;

    public static RouterConfigLoadResult Success(EffectiveRouterConfigSnapshot snapshot)
        => new(snapshot, null);

    public static RouterConfigLoadResult Failure(RouterError error)
        => new(null, error);
}
