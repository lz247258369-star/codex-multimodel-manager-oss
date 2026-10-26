using Router.ClientAdapters.Responses;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.Responses;
using Router.Registries;
using Router.Routing;
using Router.Secrets;

namespace ProviderContractKit;

/// <summary>Builds a minimal, valid ResolvedRoute for contract tests (fake provider).</summary>
public static class ContractRouteFactory
{
    public const string ClientId = "client.codex_cli";
    public const string RouteId = "route.fake-responses";

    public static ResolvedRoute CreateFakeRoute()
    {
        CapabilitySet full = CapabilitySet.From(
        [
            "responses", "text", "streaming", "reasoning", "tools", "usage", "cancellation",
        ]);

        var providerRoute = new ProviderRouteRegistryEntry
        {
            ProviderRouteId = "provider-route.fake",
            ProviderId = FakeResponsesProviderAdapter.ProviderId,
            AdapterId = FakeResponsesProviderAdapter.AdapterId,
            AdapterVersion = FakeResponsesProviderAdapter.AdapterVersion,
            EndpointIds = ["endpoint.fake"],
            SecretRef = new SecretReference
            {
                Resolver = "environment",
                Name = "FAKE_TEST_KEY",
                Scope = SecretScope.UserOrProcess,
                AllowedProviderIds = [FakeResponsesProviderAdapter.ProviderId],
                Version = 1,
            },
            BaseUrlRef = "provider-config:fake.base_url",
            Enabled = true,
            Capabilities = full,
            Version = 1,
            HasEligibleAdapter = true,
        };

        var protocolRoute = new ProtocolRouteRegistryEntry
        {
            ProtocolRouteId = "protocol-route.responses-pass-through",
            IngressProtocol = "protocol.openai.responses.v1",
            UpstreamProtocol = "protocol.openai.responses.v1",
            AdapterId = "adapter.protocol.responses-compatible.v1",
            AdapterVersion = "1.0",
            Capabilities = full,
            LossPolicy = "fail_closed",
            Version = 1,
            HasEligibleAdapter = true,
            IsEligibleProtocol = true,
        };

        var modelRoute = new ModelRouteRegistryEntry
        {
            ModelRouteId = "model-route.fake",
            ProviderId = FakeResponsesProviderAdapter.ProviderId,
            ClientModelId = "fake-model",
            ModelId = "fake-model",
            UpstreamModelId = "fake-model",
            Aliases = [],
            Capabilities = full,
            PricingRef = "pricing.fake.fake-model",
            IdentityVerification = "explicit_config",
            Enabled = true,
            Version = 1,
        };

        var endpoint = new EndpointRegistryEntry
        {
            EndpointId = "endpoint.fake",
            BaseUrlRef = "provider-config:fake.base_url",
            Enabled = true,
            DataBoundary = "provider-default",
            TlsRequired = true,
            Priority = 100,
            Weight = 100,
            Version = 1,
        };

        return new ResolvedRoute
        {
            ConfigGeneration = Router.Core.Support.SafeHasher.Sha256Hex("lr5-contract-route"),
            RouteId = RouteId,
            ClientId = ClientId,
            ProviderRoute = providerRoute,
            ProtocolRoute = protocolRoute,
            ModelRoute = modelRoute,
            Endpoint = endpoint,
            EffectiveCapabilities = full,
            TimeoutPolicyId = "policy.timeout-contract",
            RetryPolicyId = "policy.retry-contract",
            FailoverPolicyId = "policy.failover-contract",
            PricingSnapshotId = "pricing.fake.fake-model",
            SecretRef = providerRoute.SecretRef,
        };
    }

    public static CanonicalResponsesRequest CreateRequest(bool stream = false, string text = "hello")
        => new()
        {
            Model = "fake-model",
            Input =
            [
                new MessageInputItem
                {
                    Type = "message",
                    Role = "user",
                    Content = [new TextContentPart { Type = "input_text", Text = text }],
                },
            ],
            Stream = stream,
        };
}
