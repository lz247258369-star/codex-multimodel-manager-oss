namespace Router.ProviderAdapters.Abstractions;

/// <summary>Request semantics an adapter can encode to its upstream.</summary>
public enum RequestSemantics
{
    NonStream,
    Stream,
    Both,
}

/// <summary>Response semantics an adapter can decode from its upstream.</summary>
public enum ResponseSemantics
{
    NonStream,
    SseStream,
    Both,
}

/// <summary>Endpoint transport requirements declared by an adapter.</summary>
public enum EndpointRequirement
{
    /// <summary>HTTPS is mandatory for production endpoints.</summary>
    HttpsRequired,

    /// <summary>HTTPS required, plus loopback HTTP is allowed only in tests.</summary>
    HttpsWithTestLoopback,
}

/// <summary>Secret requirements declared by an adapter.</summary>
public enum SecretRequirement
{
    RequiresProviderSecret,
    NoSecret,
}

/// <summary>Declared cancellation support of an adapter.</summary>
public enum CancellationSupport
{
    /// <summary>Full propagation from send through stream reads.</summary>
    Full,

    /// <summary>Transport-level cancellation only (no stream decode cancellation).</summary>
    TransportOnly,
}

/// <summary>Declared usage support of an adapter.</summary>
public enum UsageSupport
{
    /// <summary>Canonical usage records are normalized when present.</summary>
    Canonical,

    /// <summary>Usage is never produced; unknown stays null.</summary>
    NullOnly,
}
