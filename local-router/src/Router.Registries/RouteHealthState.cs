namespace Router.Registries;

/// <summary>Route health states from the health contract.</summary>
public enum RouteHealthState
{
    Unknown,
    Healthy,
    Degraded,
    Unhealthy,
    Disabled,
}

/// <summary>Parses and normalizes the health-state enum used by config.</summary>
public static class RouteHealthStateParser
{
    public static RouteHealthState Parse(string value)
    {
        return value switch
        {
            "UNKNOWN" => RouteHealthState.Unknown,
            "HEALTHY" => RouteHealthState.Healthy,
            "DEGRADED" => RouteHealthState.Degraded,
            "UNHEALTHY" => RouteHealthState.Unhealthy,
            "DISABLED" => RouteHealthState.Disabled,
            _ => throw new ArgumentOutOfRangeException(nameof(value), value, "Unknown route health state."),
        };
    }
}
