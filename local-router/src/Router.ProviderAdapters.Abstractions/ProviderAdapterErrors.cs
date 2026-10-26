using Router.Core.Errors;

namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// Stable, content-free provider/transport error factories. Messages never
/// contain secrets, raw headers, prompts, or payloads.
/// </summary>
public static class ProviderAdapterErrors
{
    public static RouterError ConnectionFailed(string? requestId = null)
        => RouterError.Create(RouterErrorCode.ConnectionFailed, "The upstream connection failed.", null, requestId);

    public static RouterError TimeoutConnect(string? requestId = null)
        => RouterError.Create(RouterErrorCode.TimeoutConnect, "The upstream connection timed out.", "connect", requestId);

    public static RouterError TimeoutFirstByte(string? requestId = null)
        => RouterError.Create(RouterErrorCode.TimeoutFirstByte, "The upstream did not return the first byte in time.", "first_byte", requestId);

    public static RouterError TimeoutIdle(string? requestId = null)
        => RouterError.Create(RouterErrorCode.TimeoutIdle, "The upstream stream was idle too long.", "idle", requestId);

    public static RouterError TimeoutTotal(string? requestId = null)
        => RouterError.Create(RouterErrorCode.TimeoutTotal, "The total request deadline expired.", "total", requestId);

    public static RouterError Provider4xx(int statusCode, string? requestId = null)
        => RouterError.Create(RouterErrorCode.Provider4xx, "The provider rejected the request.", "status", requestId);

    public static RouterError RateLimited(string? requestId = null)
        => RouterError.RateLimited(requestId);

    public static RouterError Provider5xx(int statusCode, string? requestId = null)
        => RouterError.Create(RouterErrorCode.Provider5xx, "The provider is temporarily unavailable.", "status", requestId);

    public static RouterError InvalidResponse(string? requestId = null)
        => RouterError.Create(RouterErrorCode.InvalidResponse, "The provider returned a malformed response.", null, requestId);

    public static RouterError StreamInterrupted(string? requestId = null)
        => RouterError.Create(RouterErrorCode.StreamInterrupted, "The provider stream ended unexpectedly.", null, requestId);

    public static RouterError RedirectRejected(string? requestId = null)
        => RouterError.Create(RouterErrorCode.RedirectRejected, "The upstream redirect was rejected.", "redirect", requestId);

    public static RouterError TlsRequired(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.TlsRequired, "HTTPS is required for this endpoint.", param ?? "endpoint", requestId);

    public static RouterError InvalidEndpoint(string? param = null, string? requestId = null)
        => RouterError.Create(RouterErrorCode.InvalidEndpointReference, "The upstream endpoint is invalid.", param ?? "endpoint", requestId);

    public static RouterError AdapterNotFound(string? requestId = null)
        => RouterError.Create(RouterErrorCode.AdapterNotFound, "No provider adapter is registered for this route.", "adapter", requestId);

    public static RouterError AdapterVersionMismatch(string? requestId = null)
        => RouterError.Create(RouterErrorCode.AdapterVersionMismatch, "The requested adapter version is not registered.", "adapter", requestId);

    public static RouterError AdapterRegistrationInvalid(string? param = null)
        => RouterError.Create(RouterErrorCode.AdapterRegistrationInvalid, "The adapter registration is invalid.", param);

    public static RouterError PlaceholderUnavailable(string? requestId = null)
        => RouterError.Create(RouterErrorCode.PlaceholderUnavailable, "A placeholder adapter cannot serve this route.", "adapter", requestId);
}
