using Router.Core.Errors;

namespace Router.ProtocolAdapters.Abstractions;

/// <summary>
/// Stable, content-free protocol-adapter error factories. Messages never
/// contain secrets, headers, prompts, or payloads.
/// </summary>
public static class ProtocolAdapterErrors
{
    public static RouterError RegistrationInvalid(string? param = null)
        => RouterError.Create(RouterErrorCode.AdapterRegistrationInvalid, "The protocol adapter registration is invalid.", param);

    public static RouterError NotFound(string? requestId = null)
        => RouterError.Create(RouterErrorCode.AdapterNotFound, "No protocol adapter is registered for this protocol pair.", "protocol", requestId);

    public static RouterError VersionMismatch(string? requestId = null)
        => RouterError.Create(RouterErrorCode.AdapterVersionMismatch, "The requested protocol adapter version is not registered.", "protocol", requestId);

    public static RouterError PlaceholderUnavailable(string? requestId = null)
        => RouterError.Create(RouterErrorCode.PlaceholderUnavailable, "A placeholder protocol adapter cannot serve this route.", "protocol", requestId);

    public static RouterError SemanticLoss(string? capability = null, string? requestId = null)
        => RouterError.SemanticLoss(capability, requestId);

    public static RouterError ProtocolUnsupported(string? param = null, string? requestId = null)
        => RouterError.ProtocolUnsupported(param, requestId);
}
