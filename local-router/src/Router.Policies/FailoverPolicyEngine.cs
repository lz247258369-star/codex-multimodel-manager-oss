namespace Router.Policies;

/// <summary>
/// Inputs for one failover decision. Contains only identity/capability facts;
/// no secret handle, prompt, or content is ever accepted.
/// </summary>
public sealed record FailoverDecisionRequest
{
    public required FailoverClass CandidateClass { get; init; }

    public required bool OutputObserved { get; init; }

    public required string RouteId { get; init; }

    public required string OriginalProviderId { get; init; }

    public required string CandidateProviderId { get; init; }

    public required string CandidateProtocolId { get; init; }

    public required string OriginalProtocolId { get; init; }

    public required IReadOnlyList<string> RequiredCapabilities { get; init; }

    public required IReadOnlyList<string> CandidateCapabilities { get; init; }

    /// <summary>True only when this candidate was explicitly approved for this request context.</summary>
    public required bool CandidateExplicitlyApproved { get; init; }
}

/// <summary>
/// Explicit failover decision engine. Failover never runs after output, never
/// crosses disabled classes, and requires capability/protocol/security
/// equivalence. Secrets are never part of the decision.
/// </summary>
public static class FailoverPolicyEngine
{
    public static PolicyDecision Decide(FailoverPolicy policy, FailoverDecisionRequest request)
    {
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(request);

        if (request.OutputObserved)
        {
            return NoFailover("post_output_failover_forbidden", request.RouteId);
        }

        if (!policy.Enabled)
        {
            return NoFailover("failover_policy_off", request.RouteId);
        }

        if (request.CandidateClass == FailoverClass.SameProviderRetry)
        {
            return NoFailover("same_provider_retry_handled_by_retry", request.RouteId);
        }

        if (request.CandidateClass == FailoverClass.CrossModelFallback)
        {
            return NoFailover("cross_model_fallback_off", request.RouteId);
        }

        if (request.CandidateClass == FailoverClass.SameModelAlternateProvider && !policy.AllowSameModelAlternateProvider)
        {
            return NoFailover("alternate_provider_off", request.RouteId);
        }

        if (request.CandidateClass == FailoverClass.SameModelAlternateEndpoint && !policy.AllowSameModelAlternateEndpoint)
        {
            return NoFailover("alternate_endpoint_off", request.RouteId);
        }

        if (!string.Equals(request.CandidateProtocolId, request.OriginalProtocolId, StringComparison.Ordinal))
        {
            return NoFailover("protocol_mismatch", request.RouteId);
        }

        foreach (string required in request.RequiredCapabilities)
        {
            if (!request.CandidateCapabilities.Contains(required, StringComparer.Ordinal))
            {
                return NoFailover("capability_mismatch", request.RouteId);
            }
        }

        if (!string.Equals(request.OriginalProviderId, request.CandidateProviderId, StringComparison.Ordinal)
            && !request.CandidateExplicitlyApproved)
        {
            return NoFailover("provider_not_explicitly_approved", request.RouteId);
        }

        return new PolicyDecision
        {
            Kind = PolicyDecisionKind.Failover,
            ReasonCode = "failover_allowed",
            RouteId = request.RouteId,
        };
    }

    private static PolicyDecision NoFailover(string reason, string routeId)
        => new()
        {
            Kind = PolicyDecisionKind.NoFailover,
            ReasonCode = reason,
            RouteId = routeId,
        };
}
