using System.Globalization;
using Router.Core.Errors;

namespace Router.Configuration;

/// <summary>Stable, content-free configuration errors.</summary>
public static class ConfigurationErrors
{
    public static RouterError MissingRequired(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.ConfigMissingRequired, "A required configuration value is missing.", param, requestId);

    public static RouterError Invalid(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.ConfigInvalid, "The configuration is invalid.", param, requestId);

    public static RouterError SchemaUnsupported(string? requestId = null)
        => RouterError.Create(RouterErrorCode.ConfigSchemaUnsupported, "The configuration schema version is not supported.", "schema_version", requestId);

    public static RouterError Corrupt(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.ConfigCorrupt, "The configuration file is corrupt.", param, requestId);

    public static RouterError SecurityViolation(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.ConfigSecurityViolation, "The configuration violates a security invariant.", param, requestId);
}
