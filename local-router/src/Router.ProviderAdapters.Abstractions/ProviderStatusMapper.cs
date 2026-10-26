using Router.Core.Errors;

namespace Router.ProviderAdapters.Abstractions;

/// <summary>
/// Shared HTTP status normalization for Responses-compatible provider
/// adapters. 429 maps to <c>rate_limited</c>, other 4xx to
/// <c>provider_4xx</c>, 5xx to <c>provider_5xx</c>; everything else is an
/// invalid response. Messages never contain bodies, prompts, or secrets.
/// </summary>
public static class ProviderStatusMapper
{
    public static RouterError MapStatus(int statusCode, string? requestId = null)
    {
        if (statusCode == 429)
        {
            return ProviderAdapterErrors.RateLimited(requestId);
        }

        if (statusCode is >= 400 and < 500)
        {
            return ProviderAdapterErrors.Provider4xx(statusCode, requestId);
        }

        if (statusCode >= 500)
        {
            return ProviderAdapterErrors.Provider5xx(statusCode, requestId);
        }

        return ProviderAdapterErrors.InvalidResponse(requestId);
    }
}
