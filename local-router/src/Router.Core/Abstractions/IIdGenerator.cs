using Router.Core.Ids;

namespace Router.Core.Abstractions;

/// <summary>
/// Produces typed correlation IDs. Implementations must be thread-safe and
/// must never derive an ID from a secret or request content.
/// </summary>
public interface IIdGenerator
{
    /// <summary>Creates a new <see cref="RequestId"/>.</summary>
    RequestId NewRequestId();

    /// <summary>Creates a new <see cref="TraceId"/>.</summary>
    TraceId NewTraceId();

    /// <summary>Creates a new <see cref="AttemptId"/>.</summary>
    AttemptId NewAttemptId();
}
