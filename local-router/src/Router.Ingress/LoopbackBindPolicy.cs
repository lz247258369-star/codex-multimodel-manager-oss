using Router.Configuration;
using Router.Core.Errors;

namespace Router.Ingress;

/// <summary>
/// Loopback-only binding policy. The only allowed target is IPv4 127.0.0.1 on
/// a configured port. 0.0.0.0, ::, [::], hostnames, localhost, LAN IPs, and
/// wildcard binds are rejected before any socket is opened.
/// </summary>
public static class LoopbackBindPolicy
{
    public const string LoopbackHost = "127.0.0.1";

    /// <summary>Returns a normalized error when the bind target is unsafe; otherwise null.</summary>
    public static RouterError? Validate(string host, int port)
    {
        if (!string.Equals(host, LoopbackHost, StringComparison.Ordinal))
        {
            return ConfigurationErrors.SecurityViolation("local_router.host");
        }

        if (port is < 1 or > 65535)
        {
            return ConfigurationErrors.SecurityViolation("local_router.port");
        }

        return null;
    }
}
