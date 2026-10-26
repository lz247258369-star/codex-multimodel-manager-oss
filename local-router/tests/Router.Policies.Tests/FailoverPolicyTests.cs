using System.Reflection;
using Router.Policies;
using Xunit;

namespace Router.Policies.Tests;

public sealed class FailoverPolicyTests
{
    private static readonly string[] FullCapabilities = ["text", "streaming", "reasoning", "tools", "usage"];

    [Fact]
    public void Failover_policy_defaults_to_off()
    {
        Assert.False(FailoverPolicy.Off.Enabled);
        Assert.False(FailoverPolicy.Off.AllowCrossModelFallback);
        Assert.False(FailoverPolicy.Off.AllowSameModelAlternateProvider);
    }

    [Fact]
    public void Cross_model_fallback_cannot_be_enabled()
    {
        Assert.Throws<InvalidOperationException>(() => FailoverPolicy.Create(false, false, allowCrossModelFallback: true));
    }

    [Fact]
    public void Policy_off_never_failovers()
    {
        PolicyDecision decision = FailoverPolicyEngine.Decide(FailoverPolicy.Off, Request(FailoverClass.SameModelAlternateEndpoint));

        Assert.Equal(PolicyDecisionKind.NoFailover, decision.Kind);
        Assert.Equal("failover_policy_off", decision.ReasonCode);
    }

    [Fact]
    public void Alternate_provider_requires_explicit_enablement_and_approval()
    {
        var policy = FailoverPolicy.Create(false, allowSameModelAlternateProvider: true, false);
        PolicyDecision notApproved = FailoverPolicyEngine.Decide(policy, Request(FailoverClass.SameModelAlternateProvider, approved: false));
        Assert.Equal(PolicyDecisionKind.NoFailover, notApproved.Kind);
        Assert.Equal("provider_not_explicitly_approved", notApproved.ReasonCode);

        PolicyDecision approved = FailoverPolicyEngine.Decide(policy, Request(FailoverClass.SameModelAlternateProvider, approved: true));
        Assert.Equal(PolicyDecisionKind.Failover, approved.Kind);
    }

    [Fact]
    public void Capability_and_protocol_mismatch_never_failover()
    {
        var policy = FailoverPolicy.Create(true, false, false);
        FailoverDecisionRequest request = Request(FailoverClass.SameModelAlternateEndpoint) with
        {
            CandidateProtocolId = "protocol.anthropic.messages.v1",
        };
        Assert.Equal("protocol_mismatch", FailoverPolicyEngine.Decide(policy, request).ReasonCode);

        FailoverDecisionRequest noTools = Request(FailoverClass.SameModelAlternateEndpoint) with
        {
            CandidateCapabilities = ["text"],
        };
        Assert.Equal("capability_mismatch", FailoverPolicyEngine.Decide(policy, noTools).ReasonCode);
    }

    [Fact]
    public void Post_output_failover_is_forbidden()
    {
        var policy = FailoverPolicy.Create(true, false, false);
        FailoverDecisionRequest request = Request(FailoverClass.SameModelAlternateEndpoint) with { OutputObserved = true };

        PolicyDecision decision = FailoverPolicyEngine.Decide(policy, request);

        Assert.Equal(PolicyDecisionKind.NoFailover, decision.Kind);
        Assert.Equal("post_output_failover_forbidden", decision.ReasonCode);
    }

    [Fact]
    public void Four_failover_classes_exist_from_contract()
    {
        Assert.Equal(4, Enum.GetNames<FailoverClass>().Length);
        Assert.True(Enum.IsDefined(FailoverClass.SameProviderRetry));
        Assert.True(Enum.IsDefined(FailoverClass.SameModelAlternateEndpoint));
        Assert.True(Enum.IsDefined(FailoverClass.SameModelAlternateProvider));
        Assert.True(Enum.IsDefined(FailoverClass.CrossModelFallback));
    }

    [Fact]
    public void Failover_decision_never_accepts_secret_or_content_fields()
    {
        foreach (PropertyInfo property in typeof(FailoverDecisionRequest).GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            string name = property.Name.ToLowerInvariant();
            Assert.DoesNotContain("secret", name);
            Assert.DoesNotContain("authorization", name);
            Assert.DoesNotContain("prompt", name);
        }
    }

    private static FailoverDecisionRequest Request(FailoverClass failoverClass, bool approved = false)
        => new()
        {
            CandidateClass = failoverClass,
            OutputObserved = false,
            RouteId = "route.candidate",
            OriginalProviderId = "mm_openrouter",
            CandidateProviderId = "mm_modelstudio",
            CandidateProtocolId = "protocol.openai.responses.v1",
            OriginalProtocolId = "protocol.openai.responses.v1",
            RequiredCapabilities = FullCapabilities,
            CandidateCapabilities = FullCapabilities,
            CandidateExplicitlyApproved = approved,
        };
}
