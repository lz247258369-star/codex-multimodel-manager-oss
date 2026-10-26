namespace Router.Metering;

/// <summary>
/// Operational status of one metered logical request. Absence of usage or
/// identity is explicit and never fabricated as zero.
/// </summary>
public enum RequestMeteringStatus
{
    Recorded,
    UsageMissing,
    IdentityUnavailable,
    MeteringDegraded,
}
