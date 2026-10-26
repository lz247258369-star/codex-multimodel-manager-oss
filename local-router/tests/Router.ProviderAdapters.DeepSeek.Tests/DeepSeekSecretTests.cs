using System.Text.Json;
using ProviderContractKit;
using Router.Core.Errors;
using Router.FakeProvider;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Router.Secrets;
using Xunit;

namespace Router.ProviderAdapters.DeepSeek.Tests;

public sealed class DeepSeekSecretTests
{
    [Fact]
    public void Only_deepseek_api_key_is_allowed_for_deepseek()
    {
        Assert.True(EnvironmentSecretAllowlist.IsProviderSecretAllowed("deepseek", "DEEPSEEK_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("deepseek", "MIMO_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("deepseek", "OPENROUTER_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("deepseek", "CODEX_DASHSCOPE_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("deepseek", "CODEX_OPENAI_API_KEY"));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("deepseek", "CODEX_LOCAL_ROUTER_TOKEN"));
    }

    [Fact]
    public void Deepseek_api_key_is_rejected_for_other_provider_scopes()
    {
        var reference = new SecretReference
        {
            Resolver = "environment",
            Name = "DEEPSEEK_API_KEY",
            Scope = SecretScope.UserOrProcess,
            AllowedProviderIds = ["deepseek"],
            Version = 1,
        };

        Assert.Null(SecretReferenceValidator.Validate(reference));
        Assert.True(EnvironmentSecretAllowlist.IsProviderSecretAllowed("deepseek", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_mimo", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openrouter", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_openai_api", reference.Name));
        Assert.False(EnvironmentSecretAllowlist.IsProviderSecretAllowed("mm_modelstudio", reference.Name));
    }

    [Fact]
    public void Adapter_declares_provider_secret_requirement()
    {
        Assert.Equal(SecretRequirement.RequiresProviderSecret, new DeepSeekProviderAdapter().Descriptor.SecretRequirement);
    }

    [Fact]
    public void Adapter_never_reads_an_inline_config_bearer_token()
    {
        // The Router reads environment references only; the Direct Mode
        // experimental_bearer_token in the user's Codex config is never parsed
        // or migrated by this adapter.
        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        while (directory is not null
            && !Directory.Exists(Path.Combine(directory.FullName, "src", "Router.ProviderAdapters.DeepSeek")))
        {
            directory = directory.Parent;
        }

        Assert.NotNull(directory);
        string source = File.ReadAllText(Path.Combine(
            directory!.FullName,
            "src", "Router.ProviderAdapters.DeepSeek", "DeepSeekProviderAdapter.cs"));

        Assert.DoesNotContain("experimental_bearer_token", source, StringComparison.Ordinal);
        Assert.DoesNotContain("base_url", source, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Missing_secret_handle_sends_no_authorization_header()
    {
        await using var server = new FakeProviderServer();
        await server.StartAsync();
        server.SetScenario(FakeProviderScenario.Json(200, DeepSeekFixtures.NonStreamJson()));

        ProviderAdapterInvocation invocation = DeepSeekInvocationFactory.CreateInvocation(
            server,
            ContractRouteFactory.CreateRequest()) with
        {
            Secret = null!,
        };

        ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(invocation, CancellationToken.None);

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
    public async Task Authorization_failures_never_echo_the_secret()
    {
        foreach (int status in new[] { 401, 403 })
        {
            await using var server = new FakeProviderServer();
            await server.StartAsync();
            server.SetScenario(FakeProviderScenario.Json(status, """{"error":{"message":"denied"}}"""));

            ProviderAdapterResult result = await new DeepSeekProviderAdapter().InvokeAsync(
                DeepSeekInvocationFactory.CreateInvocation(
                    server,
                    ContractRouteFactory.CreateRequest(),
                    secretValue: "test-fake-secret-value-never-real"),
                CancellationToken.None);

            result.Validate();
            Assert.NotNull(result.Error);
            Assert.DoesNotContain("test-fake-secret-value-never-real", result.Error!.Message, StringComparison.Ordinal);
            Assert.DoesNotContain("test-fake-secret-value-never-real", result.Error.Message, StringComparison.Ordinal);
        }
    }
}
