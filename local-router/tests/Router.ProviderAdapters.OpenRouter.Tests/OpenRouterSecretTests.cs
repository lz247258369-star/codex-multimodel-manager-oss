using ProviderContractKit;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenRouter;
using Router.Secrets;
using Xunit;

namespace Router.ProviderAdapters.OpenRouter.Tests;

public sealed class OpenRouterSecretTests
{
    [Fact]
    public void Only_openrouter_api_key_is_allowed_for_mm_openrouter()
    {
        Assert.True(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openrouter", "OPENROUTER_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openrouter", "MIMO_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openrouter", "CODEX_DASHSCOPE_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openrouter", "OPENAI_API_KEY"));
    }

    [Fact]
    public void Wrong_provider_secret_scope_is_rejected()
    {
        var reference = new SecretReference
        {
            Resolver = "environment",
            Name = "OPENROUTER_API_KEY",
            Scope = SecretScope.UserOrProcess,
            AllowedProviderIds = ["mm_openrouter"],
            Version = 1,
        };

        Assert.Null(SecretReferenceValidator.Validate(reference));
        Assert.True(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openrouter", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_mimo", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_modelstudio", reference.Name));
    }

    [Fact]
    public void Adapter_declares_provider_secret_requirement()
    {
        Assert.Equal(SecretRequirement.RequiresProviderSecret, new OpenRouterProviderAdapter().Descriptor.SecretRequirement);
    }

    [Fact]
    public async Task Missing_secret_handle_sends_no_authorization_header()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));

        Result<UpstreamEndpoint, RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1/responses"),
            tlsRequired: false,
            loopbackTestOnly: true);

        ProviderAdapterInvocation invocation = OpenRouterInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()) with
        {
            Endpoint = endpoint.Value!,
            Secret = null!,
        };

        ProviderAdapterResult result = await new OpenRouterProviderAdapter().InvokeAsync(invocation, CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.False(server.LastRequestHeaders.ContainsKey("Authorization"));
    }
}
