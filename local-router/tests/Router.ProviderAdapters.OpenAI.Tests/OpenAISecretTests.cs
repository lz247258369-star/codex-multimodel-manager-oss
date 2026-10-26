using System.Text.Json;
using ProviderContractKit;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.OpenAI;
using Router.Secrets;
using Xunit;

namespace Router.ProviderAdapters.OpenAI.Tests;

public sealed class OpenAISecretTests
{
    [Fact]
    public void Only_codex_openai_api_key_is_allowed_for_mm_openai_api()
    {
        Assert.True(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openai_api", "CODEX_OPENAI_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openai_api", "OPENROUTER_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openai_api", "CODEX_DASHSCOPE_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openai_api", "MIMO_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openai_api", "OPENAI_API_KEY"));
    }

    [Fact]
    public void Openai_api_key_is_rejected_for_other_provider_scopes()
    {
        var reference = new SecretReference
        {
            Resolver = "environment",
            Name = "CODEX_OPENAI_API_KEY",
            Scope = SecretScope.UserOrProcess,
            AllowedProviderIds = ["mm_openai_api"],
            Version = 1,
        };

        Assert.Null(SecretReferenceValidator.Validate(reference));
        Assert.True(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openai_api", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openrouter", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_modelstudio", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_mimo", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("chatgpt", reference.Name));
    }

    [Fact]
    public void Adapter_declares_provider_secret_requirement()
    {
        Assert.Equal(SecretRequirement.RequiresProviderSecret, new OpenAIProviderAdapter().Descriptor.SecretRequirement);
    }

    [Fact]
    public async Task Missing_secret_handle_sends_no_authorization_header()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, OpenAIFixtures.NonStreamJson()));

        Result<UpstreamEndpoint, RouterError> endpoint = UpstreamEndpoint.Create(
            new Uri(server.BaseUri, "v1"),
            tlsRequired: false,
            loopbackTestOnly: true);

        ProviderAdapterInvocation invocation = OpenAIInvocationFactory.CreateInvocation(server, ContractRouteFactory.CreateRequest()) with
        {
            Endpoint = endpoint.Value!,
            Secret = null!,
        };

        ProviderAdapterResult result = await new OpenAIProviderAdapter().InvokeAsync(invocation, CancellationToken.None);

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

    [Fact]
    public async Task ChatGPT_provider_scope_cannot_resolve_the_openai_api_key()
    {
        var reference = new SecretReference
        {
            Resolver = "environment",
            Name = "CODEX_OPENAI_API_KEY",
            Scope = SecretScope.UserOrProcess,
            AllowedProviderIds = ["chatgpt"],
            Version = 1,
        };

        var environment = new FakeEnvironment();
        var resolver = new EnvironmentSecretResolver(environment);

        SecretResolutionResult chatgptResult = await resolver.ResolveAsync(reference, "chatgpt", CancellationToken.None);
        Assert.False(chatgptResult.IsSuccess);
        Assert.Equal(RouterErrorCode.SecretScopeViolation, chatgptResult.Error!.Code);

        SecretReference apiReference = reference with { AllowedProviderIds = ["mm_openai_api"] };
        SecretResolutionResult apiResult = await resolver.ResolveAsync(apiReference, "mm_openai_api", CancellationToken.None);
        Assert.True(apiResult.IsSuccess);
        Assert.Equal("synthetic-test-key-not-real", apiResult.Handle!.ReadValue());
        apiResult.Handle.Dispose();
    }

    private sealed class FakeEnvironment : IEnvironment
    {
        public string? GetVariable(string name, SecretScope scope)
            => string.Equals(name, "CODEX_OPENAI_API_KEY", StringComparison.Ordinal)
                ? "synthetic-test-key-not-real"
                : null;
    }
}
