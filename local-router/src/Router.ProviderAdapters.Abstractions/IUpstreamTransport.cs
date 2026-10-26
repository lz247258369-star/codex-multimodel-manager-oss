using Router.Core.Errors;

namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// Unified upstream HTTP boundary. Provider adapters never create their own
/// HTTP clients; they send through this interface. The transport owns
/// connection lifecycle, redirect policy, TLS policy, timeout stages, and
/// header extraction, and normalizes every failure to a typed
/// <see cref="RouterError"/>.
/// </summary>
public interface IUpstreamTransport
{
    /// <summary>
    /// Sends one upstream request and returns a response whose headers are the
    /// safe allowlist subset. The returned body stream is owned by the caller
    /// and must be read with the provided cancellation token.
    /// </summary>
    Task<Result<UpstreamResponse, RouterError>> SendAsync(
        UpstreamRequest request,
        TimeoutBoundaries boundaries,
        CancellationToken cancellationToken);
}
