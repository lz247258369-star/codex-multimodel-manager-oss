namespace Router.ProtocolAdapters.Abstractions;

/// <summary>
/// Versioned semantic-loss policy for one protocol adapter. LR-8 only permits
/// lossless mapping; lossy/best-effort policies are deferred and never
/// registered.
/// </summary>
public enum ProtocolLossPolicy
{
    /// <summary>
    /// Every canonical semantic must be preserved exactly. Any mapping that
    /// cannot preserve semantics fails closed with <c>semantic_loss</c>.
    /// </summary>
    LosslessOnly,
}

/// <summary>Stable wire names for <see cref="ProtocolLossPolicy"/>.</summary>
public static class ProtocolLossPolicyNames
{
    public const string LosslessOnly = "LOSSLESS_ONLY";

    public static string ToWireName(this ProtocolLossPolicy policy)
        => policy switch
        {
            ProtocolLossPolicy.LosslessOnly => LosslessOnly,
            _ => throw new ArgumentOutOfRangeException(nameof(policy)),
        };
}
