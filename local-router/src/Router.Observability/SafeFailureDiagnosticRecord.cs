using System.Text.Json;
using Router.Core.Support;

namespace Router.Observability;

/// <summary>
/// Minimal local failure diagnostic. It exists because a client surface can
/// swallow the HTTP error envelope's <c>param</c> field, so the Router also
/// records the safe capability field path locally.
///
/// The record is deliberately the smallest shape that answers "which capability
/// gate rejected this request": schema version, request id, error code, safe
/// field path and completion time. It never carries prompt, instructions, body,
/// headers, tool values, URLs, identifiers from the request, or secrets.
/// </summary>
public sealed record SafeFailureDiagnosticRecord
{
    /// <summary>Schema v1: the five-field diagnostic (no classification).</summary>
    public const int CurrentSchemaVersion = 1;

    /// <summary>
    /// Schema v2: DSR7-C-FIX3 adds exactly one field, the FIXED tool-type
    /// taxonomy label. The version is implied by the presence of
    /// <see cref="SafeClass"/>, so a v1 file on disk stays valid and is never
    /// migrated or rewritten.
    /// </summary>
    public const int ClassifiedSchemaVersion = 2;

    /// <summary>
    /// Schema v3: DSR7-C-FIX4 adds the FIXED custom-tool identity next to the
    /// class. It is used only for a rejected <c>custom</c> tool whose identity was
    /// classified, so v2 records stay v2 and v1 records stay v1.
    /// </summary>
    public const int ClassifiedIdentitySchemaVersion = 3;

    /// <summary>The only error code this diagnostic is allowed to describe.</summary>
    public const string UnsupportedCapabilityCode = "unsupported_capability";

    public const int MaxRequestIdLength = 128;

    public required int SchemaVersion { get; init; }

    public required string RequestId { get; init; }

    public required string ErrorCode { get; init; }

    public required string SafeParam { get; init; }

    /// <summary>
    /// Fixed classifier label for a rejected tool type. Null for schema v1
    /// diagnostics (and then omitted from JSON), so a non-tool-type failure can
    /// never carry a fabricated class.
    /// </summary>
    public string? SafeClass { get; init; }

    /// <summary>
    /// Fixed identity label for a rejected custom tool (<c>apply_patch</c> or
    /// <c>unknown_custom</c>). Null for v1/v2 diagnostics and then omitted from
    /// JSON.
    /// </summary>
    public string? SafeIdentity { get; init; }

    public required string CompletedAt { get; init; }

    /// <summary>
    /// Builds a diagnostic only when every input passes the fail-closed
    /// contract; returns null (drop the diagnostic) otherwise.
    /// </summary>
    public static SafeFailureDiagnosticRecord? TryCreate(
        string? requestId,
        string? errorCode,
        string? safeParam,
        DateTimeOffset completedAt)
        => TryCreateCore(requestId, errorCode, safeParam, safeClass: null, completedAt);

    /// <summary>
    /// DSR7-C-FIX3: builds a schema-v2 diagnostic. Both the safe path and the
    /// fixed class are re-validated here, and the class is only accepted for the
    /// tool-type path shape; anything else drops the diagnostic entirely.
    /// </summary>
    public static SafeFailureDiagnosticRecord? TryCreateClassified(
        string? requestId,
        string? errorCode,
        string? safeParam,
        string? safeClass,
        DateTimeOffset completedAt)
    {
        if (!SafeFailureDiagnosticPath.IsToolTypePath(safeParam)
            || !SafeToolTypeClassifier.IsKnownLabel(safeClass))
        {
            return null;
        }

        return TryCreateCore(requestId, errorCode, safeParam, safeClass, completedAt);
    }

    /// <summary>
    /// DSR7-C-FIX4: builds a schema-v3 diagnostic for a rejected custom tool.
    /// The path must be the tool-type shape, the class must be exactly
    /// <c>custom</c>, and the identity must be a fixed known label; anything else
    /// drops the diagnostic instead of falling back to a raw value.
    /// </summary>
    public static SafeFailureDiagnosticRecord? TryCreateIdentified(
        string? requestId,
        string? errorCode,
        string? safeParam,
        string? safeClass,
        string? safeIdentity,
        DateTimeOffset completedAt)
    {
        if (!SafeFailureDiagnosticPath.IsToolTypePath(safeParam)
            || !string.Equals(safeClass, SafeToolTypeClassifier.Custom, StringComparison.Ordinal)
            || !SafeCustomToolIdentityClassifier.IsKnownIdentity(safeIdentity))
        {
            return null;
        }

        return TryCreateCore(requestId, errorCode, safeParam, safeClass, completedAt, safeIdentity);
    }

    private static SafeFailureDiagnosticRecord? TryCreateCore(
        string? requestId,
        string? errorCode,
        string? safeParam,
        string? safeClass,
        DateTimeOffset completedAt,
        string? safeIdentity = null)
    {
        if (string.IsNullOrWhiteSpace(requestId)
            || requestId.Length > MaxRequestIdLength
            || !string.Equals(errorCode, UnsupportedCapabilityCode, StringComparison.Ordinal)
            || !SafeFailureDiagnosticPath.IsSafe(safeParam))
        {
            return null;
        }

        return new SafeFailureDiagnosticRecord
        {
            SchemaVersion = safeIdentity is not null
                ? ClassifiedIdentitySchemaVersion
                : safeClass is null ? CurrentSchemaVersion : ClassifiedSchemaVersion,
            RequestId = requestId,
            ErrorCode = UnsupportedCapabilityCode,
            SafeParam = safeParam!,
            SafeClass = safeClass,
            SafeIdentity = safeIdentity,
            CompletedAt = completedAt.ToUniversalTime().ToString("o", System.Globalization.CultureInfo.InvariantCulture),
        };
    }

    /// <summary>Canonical JSON for the five allowed fields only.</summary>
    public byte[] ToJsonBytes() => JsonSerializer.SerializeToUtf8Bytes(this, ObservabilityJson.Options);
}
