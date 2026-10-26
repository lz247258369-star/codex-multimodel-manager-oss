using System.Text.Json;
using ProviderContractKit;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.MiMo;
using Router.Secrets;
using Xunit;

namespace Router.ProviderAdapters.MiMo.Tests;

public sealed class MiMoSecretTests
{
    [Fact]
    public void Only_mimo_api_key_is_allowed_for_mm_mimo()
    {
        Assert.True(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_mimo", "MIMO_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_mimo", "OPENROUTER_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_mimo", "CODEX_DASHSCOPE_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_mimo", "CODEX_OPENAI_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_mimo", "OPENAI_API_KEY"));
    }

    [Fact]
    public void Mimo_api_key_is_rejected_for_other_provider_scopes()
    {
        var reference = new SecretReference
        {
            Resolver = "environment",
            Name = "MIMO_API_KEY",
            Scope = SecretScope.UserOrProcess,
            AllowedProviderIds = ["mm_mimo"],
            Version = 1,
        };

        Assert.Null(SecretReferenceValidator.Validate(reference));
        Assert.True(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_mimo", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openrouter", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openai_api", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_modelstudio", reference.Name));
    }

    [Fact]
    public void Adapter_declares_provider_secret_requirement()
    {
        Assert.Equal(SecretRequirement.RequiresProviderSecret, new MiMoProviderAdapter().Descriptor.SecretRequirement);
    }

    [Fact]
    public async Task Missing_secret_handle_sends_no_authorization_header()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, SseFixtureBuilder.NonStreamJson()));

        Result<UpstreamEndpoint, RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1"),
            tlsRequired: false,
            loopbackTestOnly: true);

        ProviderAdapterInvocation invocation = MiMoInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()) with
        {
            Endpoint = endpoint.Value!,
            Secret = null!,
        };

        ProviderAdapterResult result = await new MiMoProviderAdapter().InvokeAsync(invocation, CancellationToken.None);

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
