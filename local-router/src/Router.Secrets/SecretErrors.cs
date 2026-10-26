using Router.Core.Errors;

namespace Router.Secrets;

/// <summary>Stable, content-free secret-related errors.</summary>
public static class SecretErrors
{
    public static RouterError ReferenceInvalid(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.SecretReferenceInvalid, "The secret reference is invalid.", param, requestId);

    public static RouterError ScopeViolation(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.SecretScopeViolation, "The secret reference is not authorized for this provider.", param, requestId);

    public static RouterError Missing(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.SecretMissing, "The referenced secret is not set.", param, requestId);
}
