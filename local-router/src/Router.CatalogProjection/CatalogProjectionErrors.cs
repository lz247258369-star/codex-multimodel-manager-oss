using Router.Core.Errors;

namespace Router.CatalogProjection;

/// <summary>Stable, content-free catalog projection errors.</summary>
public static class CatalogProjectionErrors
{
    public static RouterError Invalid(string? param = null)
        => RouterError.Create(RouterErrorCode.CatalogInvalid, "The model catalog projection is invalid.", param);

    public static RouterError UnsupportedVersion()
        => RouterError.Create(RouterErrorCode.CatalogUnsupportedVersion, "The model catalog schema version is not supported.");

    public static RouterError UnknownProvider(string? param = null)
        => RouterError.Create(RouterErrorCode.UnknownProvider, "The model catalog provider is not mapped to a Manager provider identity.", param);

    public static RouterError DuplicateModel(string? param = null)
        => RouterError.Create(
            RouterErrorCode.DuplicateRegistryKey,
            "The model catalog contains a duplicate provider-scoped model identity.",
            param ?? "models");
}
