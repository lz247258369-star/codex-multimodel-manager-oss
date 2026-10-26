using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.Core.Errors;

/// <summary>
/// Normalized, serialization-stable error envelope. Property order, names, and
/// null behavior are fixed; raw exception text and secret-shaped content are
/// never included.
/// </summary>
public sealed record RouterError(
    string Type,
    string Code,
    string Message,
    string? Param,
    string? RequestId,
    bool Retryable)
{
    /// <summary>
    /// DSR7-C-FIX3: internal-only diagnostic classification of a rejected
    /// capability (a fixed taxonomy label such as <c>local_shell</c>).
    /// It is deliberately JSON-ignored so the HTTP error envelope stays
    /// byte-semantically unchanged: a client still sees only
    /// type/code/message/param/request_id/retryable.
    /// </summary>
    [JsonIgnore]
    public string? SafeDiagnosticClass { get; init; }

    /// <summary>
    /// DSR7-C-FIX4: internal-only FIXED identity label for a rejected custom
    /// tool (<c>apply_patch</c> or <c>unknown_custom</c>). JSON-ignored for the
    /// same reason as <see cref="SafeDiagnosticClass"/>: the wire envelope is
    /// unchanged.
    /// </summary>
    [JsonIgnore]
    public string? SafeDiagnosticIdentity { get; init; }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    /// <summary>Creates a normalized error with a stable, content-free message.</summary>
    public static RouterError Create(string code, string message, string? param = null, string? requestId = null, bool retryable = false)
        => new(RouterErrorCode.Type, code, message, param, requestId, retryable);

    public static RouterError InvalidRequest(string message, string? param = null, string? requestId = null)
        => Create(RouterErrorCode.InvalidRequest, message, param, requestId);

    public static RouterError UnsupportedParameter(string? param = null, string? requestId = null)
        => Create(RouterErrorCode.UnsupportedParameter, "A requested parameter is not supported by this route.", param, requestId);

    public static RouterError UnsupportedCapability(string? requestId = null)
        => Create(RouterErrorCode.UnsupportedCapability, "The route cannot preserve the required semantics.", null, requestId);

    /// <summary>
    /// DSR7-C-FIX1: the fail-closed capability error that also names the SAFE
    /// field path of the rejected capability (for example <c>tools[0].type</c>).
    /// Only static field names and structural indexes are ever supplied - never
    /// a request value, tool name, prompt text, URL or identifier - so the
    /// diagnostic can travel on the HTTP error envelope without leaking request
    /// content. The message, code, retryable flag and HTTP mapping are identical
    /// to <see cref="UnsupportedCapability(string?)"/>; only the diagnostic
    /// <c>param</c> differs.
    /// </summary>
    public static RouterError UnsupportedCapabilityAt(string capabilityParam, string? requestId = null)
        => Create(RouterErrorCode.UnsupportedCapability, "The route cannot preserve the required semantics.", capabilityParam, requestId);

    /// <summary>
    /// DSR7-C-FIX3: the same fail-closed capability error carrying the FIXED
    /// diagnostic class of the rejected value. The class never appears in the
    /// serialized envelope; it only travels in-process to the local diagnostic
    /// sink. The legacy two-argument call above is untouched and cannot be
    /// reinterpreted, because this helper is a distinct signature with the class
    /// in an explicit position.
    /// </summary>
    public static RouterError UnsupportedCapabilityAtClassified(
        string capabilityParam,
        string safeDiagnosticClass,
        string? requestId = null)
        => Create(RouterErrorCode.UnsupportedCapability, "The route cannot preserve the required semantics.", capabilityParam, requestId)
            with { SafeDiagnosticClass = safeDiagnosticClass };

    /// <summary>
    /// DSR7-C-FIX4: the classified capability error with an additional FIXED
    /// identity label. It is a distinct signature rather than an extra optional
    /// parameter, so the two- and three-argument FIX1/FIX3 calls keep their exact
    /// meaning and can never be reinterpreted.
    /// </summary>
    public static RouterError UnsupportedCapabilityAtClassifiedWithIdentity(
        string capabilityParam,
        string safeDiagnosticClass,
        string safeDiagnosticIdentity,
        string? requestId = null)
        => Create(RouterErrorCode.UnsupportedCapability, "The route cannot preserve the required semantics.", capabilityParam, requestId)
            with
            {
                SafeDiagnosticClass = safeDiagnosticClass,
                SafeDiagnosticIdentity = safeDiagnosticIdentity,
            };

    public static RouterError SemanticLoss(string? capability = null, string? requestId = null)
        => Create(RouterErrorCode.SemanticLoss, "The protocol mapping cannot preserve the required semantics.", capability, requestId);

    public static RouterError ProtocolUnsupported(string? param = null, string? requestId = null)
        => Create(RouterErrorCode.ProtocolUnsupported, "The protocol pair is not supported by this router.", param, requestId);

    public static RouterError RouteNotFound(string? requestId = null)
        => Create(RouterErrorCode.RouteNotFound, "No eligible route is configured for this request.", "model", requestId);

    public static RouterError RouteDisabled(string? requestId = null)
        => Create(RouterErrorCode.RouteDisabled, "The selected route is disabled.", null, requestId);

    public static RouterError Cancelled(string? requestId = null)
        => Create(RouterErrorCode.Cancelled, "The request was cancelled.", null, requestId);

    public static RouterError AuthenticationRequired(string? requestId = null)
        => Create(RouterErrorCode.AuthenticationRequired, "Authentication is required.", null, requestId);

    public static RouterError AuthenticationInvalid(string? requestId = null)
        => Create(RouterErrorCode.AuthenticationInvalid, "The supplied credentials are invalid.", null, requestId);

    public static RouterError RequestTooLarge(string? requestId = null)
        => Create(RouterErrorCode.RequestTooLarge, "The request exceeds the configured size limit.", null, requestId);

    public static RouterError RateLimited(string? requestId = null)
        => Create(RouterErrorCode.RateLimited, "The router is at its connection limit.", null, requestId);

    public static RouterError ProviderTimeout(string? requestId = null)
        => Create(RouterErrorCode.ProviderTimeout, "The upstream operation exceeded its deadline.", null, requestId);

    public static RouterError PortInUse(string? requestId = null)
        => Create(RouterErrorCode.RouterPortInUse, "The configured port is already in use.", "port", requestId);

    public static RouterError AlreadyRunning(string? requestId = null)
        => Create(RouterErrorCode.RouterAlreadyRunning, "The router is already running.", null, requestId);

    public static RouterError ScopeDenied(string? requestId = null)
        => Create(RouterErrorCode.ScopeDenied, "The client is not authorized for the required scope.", null, requestId);

    public static RouterError RouterDisabled(string? requestId = null)
        => Create(RouterErrorCode.RouterDisabled, "The Local Router is disabled.", null, requestId);

    public static RouterError OriginForbidden(string? requestId = null)
        => Create(RouterErrorCode.OriginForbidden, "The request origin is not allowed.", "origin", requestId);

    public static RouterError InternalError(string? requestId = null)
        => Create(RouterErrorCode.InternalError, "An internal error occurred.", null, requestId);

    /// <summary>
    /// Converts an arbitrary exception into a normalized internal error without
    /// leaking exception details, secret-shaped content, or request content.
    /// </summary>
    public static RouterError FromException(Exception exception, string? requestId = null)
    {
        _ = exception;
        return InternalError(requestId);
    }

    /// <summary>
    /// Serializes this error to the stable canonical JSON envelope. Null fields
    /// are always present so the schema is fixed.
    /// </summary>
    public string ToJson() => JsonSerializer.Serialize(this, JsonOptions);
}
