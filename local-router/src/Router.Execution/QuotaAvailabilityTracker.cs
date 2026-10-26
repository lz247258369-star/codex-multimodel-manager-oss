namespace Router.Execution;

/// <summary>Last-known quota usability for an explicit Router route.</summary>
public enum QuotaAvailabilityState
{
    Unknown,
    Available,
    Exhausted,
}

/// <summary>Safe content-free last-known quota state.</summary>
public sealed record QuotaAvailabilitySnapshot
{
    public required QuotaAvailabilityState State { get; init; }
    public DateTimeOffset? ObservedAt { get; init; }
    public string? ReasonCode { get; init; }
}

/// <summary>
/// HS-1C in-memory quota knowledge. It never probes providers and never blocks
/// a direct/manual model choice. It is consulted only while choosing automatic
/// fallback candidates; a later successful manual request marks that route
/// available again.
/// </summary>
public sealed class QuotaAvailabilityTracker
{
    private readonly object _sync = new();
    private readonly Dictionary<string, QuotaAvailabilitySnapshot> _routes = new(StringComparer.Ordinal);

    public QuotaAvailabilitySnapshot Get(string routeId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(routeId);
        lock (_sync)
        {
            return _routes.TryGetValue(routeId, out QuotaAvailabilitySnapshot? value)
                ? value
                : new QuotaAvailabilitySnapshot { State = QuotaAvailabilityState.Unknown };
        }
    }

    public void RecordAvailable(string routeId, DateTimeOffset observedAt)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(routeId);
        lock (_sync)
        {
            _routes[routeId] = new QuotaAvailabilitySnapshot
            {
                State = QuotaAvailabilityState.Available,
                ObservedAt = observedAt,
            };
        }
    }

    public void RecordExhausted(string routeId, string reasonCode, DateTimeOffset observedAt)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(routeId);
        ArgumentException.ThrowIfNullOrWhiteSpace(reasonCode);
        lock (_sync)
        {
            _routes[routeId] = new QuotaAvailabilitySnapshot
            {
                State = QuotaAvailabilityState.Exhausted,
                ObservedAt = observedAt,
                ReasonCode = reasonCode,
            };
        }
    }
}
