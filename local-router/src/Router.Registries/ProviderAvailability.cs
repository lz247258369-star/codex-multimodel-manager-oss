namespace Router.Registries;

/// <summary>
/// Registry disposition of a Manager provider identity. Reservation is not
/// approval: only an explicit, eligible adapter registration makes a provider
/// usable for routing.
/// </summary>
public enum ProviderAvailability
{
    /// <summary>ChatGPT account path stays inside Direct Mode; never routed.</summary>
    DirectOnly,

    /// <summary>Reserved for a future provider adapter slice; not usable yet.</summary>
    Planned,

    /// <summary>Reserved future provider; descriptor only, never usable.</summary>
    Placeholder,

    /// <summary>An eligible adapter registration exists and may serve routes.</summary>
    Eligible,
}
