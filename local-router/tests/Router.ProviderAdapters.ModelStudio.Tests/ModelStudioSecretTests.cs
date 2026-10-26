using System.Text.Json;
using ProviderContractKit;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.ModelStudio;
using Router.Secrets;
using Xunit;

namespace Router.ProviderAdapters.ModelStudio.Tests;

public sealed class ModelStudioSecretTests
{
    [Fact]
    public void Only_dashscope_api_key_is_allowed_for_mm_modelstudio()
    {
        Assert.True(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_modelstudio", "CODEX_DASHSCOPE_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_modelstudio", "OPENROUTER_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_modelstudio", "MIMO_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_modelstudio", "CODEX_OPENAI_API_KEY"));
    }

    [Fact]
    public void Dashscope_key_is_rejected_for_other_provider_scopes()
    {
        var reference = new SecretReference
        {
            Resolver = "environment",
            Name = "CODEX_DASHSCOPE_API_KEY",
            Scope = SecretScope.UserOrProcess,
            AllowedProviderIds = ["mm_modelstudio"],
            Version = 1,
        };

        Assert.Null(SecretReferenceValidator.Validate(reference));
        Assert.True(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_modelstudio", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openrouter", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openai_api", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_mimo", reference.Name));
    }

    [Fact]
    public void Adapter_declares_provider_secret_requirement()
    {
        Assert.Equal(SecretRequirement.RequiresProviderSecret, new ModelStudioProviderAdapter().Descriptor.SecretRequirement);
    }

    [Fact]
    public async Task Missing_secret_handle_sends_no_authorization_header()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));

        Result<UpstreamEndpoint, RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "compatible-mode/v1"),
            tlsRequired: false,
            loopbackTestOnly: true);

        ProviderAdapterInvocation invocation = ModelStudioInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()) with
        {
            Endpoint = endpoint.Value!,
            Secret = null!,
        };

        ProviderAdapterResult result = await new ModelStudioProviderAdapter().InvokeAsync(invocation, CancellationToken.None);

        result.Validate();
        Assert.NotNull(result.Response);
        Assert.False(server.LastRequestHeaders.ContainsKey("Authorization"));
    }

    [Fact]
    public void Secret_handle_never_serializes_or_logs_the_value()
    {
        using SecretHandle handle = SecretHandle.FromValue("test-fake-secret-value-never-real");

        Assert.Equal("[secret-redacted]", handle.ToString());
        Assert.DoesNotContain("test-fake-secret-value-never-real", JsonSerializer.Serialize(handle), StringComparison.Ordinal);
        Assert.DoesNotContain("test-fake-secret-value-never-real", handle.ToString(), StringComparison.Ordinal);
    }
}
