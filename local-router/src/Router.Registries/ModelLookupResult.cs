using Router.Core.Errors;

namespace Router.Registries;

/// <summary>
/// Provider-scoped model lookup outcome. A lookup never crosses provider
/// boundaries and never infers identity from names or brands.
/// </summary>
public sealed record ModelLookupResult
{
    public ModelRouteRegistryEntry? Entry { get; init; }

    public RouterError? Error { get; init; }

    public bool IsFound => Entry is not null;

    public static ModelLookupResult Found(ModelRouteRegistryEntry entry)
        => new() { Entry = entry };

    public static ModelLookupResult NotFound(RouterError error)
        => new() { Error = error };

    public static ModelLookupResult Ambiguous(RouterError error)
        => new() { Error = error };

    /// <summary>Validates the discriminated invariant.</summary>
    public void Validate()
    {
        bool hasEntry = Entry is not null;
        bool hasError = Error is not null;
        if (hasEntry == hasError)
        {
            throw new InvalidOperationException("A ModelLookupResult must contain exactly one of entry or error.");
        }
    }
}
