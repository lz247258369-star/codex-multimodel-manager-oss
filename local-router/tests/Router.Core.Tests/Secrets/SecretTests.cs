using System.Text.Json;
using Router.Core.Errors;
using Router.Core.Tests.Fakes;
using Router.Secrets;
using Xunit;

namespace Router.Core.Tests.Secrets;

public sealed class SecretTests
{
    [Fact]
    public async Task Valid_process_env_ref_resolves()
    {
        FakeEnvironment environment = new();
        environment.Set(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.Process, "process-value");
        EnvironmentSecretResolver resolver = new(environment);

        SecretResolutionResult result = await Resolve(resolver, Ref(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.Process), "mm_openrouter");

        Assert.True(result.IsSuccess);
        Assert.Equal("process-value", result.Handle!.ReadValue());
    }

    [Fact]
    public async Task Valid_user_env_ref_resolves()
    {
        FakeEnvironment environment = new();
        environment.Set(EnvironmentSecretAllowlist.DashScopeApiKey, SecretScope.User, "user-value");
        EnvironmentSecretResolver resolver = new(environment);

        SecretResolutionResult result = await Resolve(resolver, Ref(EnvironmentSecretAllowlist.DashScopeApiKey, SecretScope.User), "mm_modelstudio");

        Assert.True(result.IsSuccess);
        Assert.Equal("user-value", result.Handle!.ReadValue());
    }

    [Fact]
    public async Task User_or_process_precedence_is_process_first()
    {
        FakeEnvironment environment = new();
        environment.Set(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.Process, "process-value");
        environment.Set(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.User, "user-value");
        EnvironmentSecretResolver resolver = new(environment);

        SecretResolutionResult result = await Resolve(resolver, Ref(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.UserOrProcess), "mm_openrouter");

        Assert.True(result.IsSuccess);
        Assert.Equal("process-value", result.Handle!.ReadValue());
    }

    [Fact]
    public async Task User_or_process_falls_back_to_user()
    {
        FakeEnvironment environment = new();
        environment.Set(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.User, "user-value");
        EnvironmentSecretResolver resolver = new(environment);

        SecretResolutionResult result = await Resolve(resolver, Ref(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.UserOrProcess), "mm_openrouter");

        Assert.True(result.IsSuccess);
        Assert.Equal("user-value", result.Handle!.ReadValue());
    }

    [Fact]
    public async Task Missing_secret_returns_secret_missing()
    {
        EnvironmentSecretResolver resolver = new(new FakeEnvironment());

        SecretResolutionResult result = await Resolve(resolver, Ref(EnvironmentSecretAllowlist.MimoApiKey), "mm_mimo");

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.SecretMissing, result.Error!.Code);
    }

    [Theory]
    [InlineData("deepseek_api_key")]
    [InlineData("1ABC")]
    [InlineData("AB")]
    [InlineData("A")]
    [InlineData("A.B")]
    [InlineData("A-B")]
    [InlineData("A B")]
    [InlineData("A$B")]
    [InlineData("A{B}")]
    [InlineData("A/B")]
    [InlineData("A\\B")]
    [InlineData("A:B")]
    [InlineData("")]
    [InlineData("INLINE-TOKEN-VALUE")]
    public async Task Invalid_secret_names_are_rejected(string name)
    {
        EnvironmentSecretResolver resolver = new(new FakeEnvironment());

        SecretResolutionResult result = await Resolve(resolver, Ref(name), "mm_openrouter");

        Assert.False(result.IsSuccess);
        Assert.Equal(RouterErrorCode.SecretReferenceInvalid, result.Error!.Code);
    }

    [Fact]
    public async Task Unknown_environment_name_is_a_scope_violation()
    {
        EnvironmentSecretResolver resolver = new(new FakeEnvironment());

        SecretResolutionResult deepseek = await Resolve(resolver, Ref("DEEPSEEK_API_KEY"), "mm_modelstudio");
        SecretResolutionResult openai = await Resolve(resolver, Ref("OPENAI_API_KEY"), "mm_openai_api");

        Assert.Equal(RouterErrorCode.SecretScopeViolation, deepseek.Error!.Code);
        Assert.Equal(RouterErrorCode.SecretScopeViolation, openai.Error!.Code);
    }

    [Fact]
    public async Task Provider_mismatch_is_a_scope_violation()
    {
        EnvironmentSecretResolver resolver = new(new FakeEnvironment());

        SecretResolutionResult result = await Resolve(
            resolver,
            Ref(EnvironmentSecretAllowlist.OpenRouterApiKey, providers: ["mm_mimo"]),
            "mm_mimo");

        Assert.Equal(RouterErrorCode.SecretScopeViolation, result.Error!.Code);
    }

    [Fact]
    public async Task Chatgpt_secret_is_never_allowed()
    {
        EnvironmentSecretResolver resolver = new(new FakeEnvironment());

        SecretResolutionResult result = await Resolve(
            resolver,
            Ref(EnvironmentSecretAllowlist.OpenRouterApiKey, providers: ["chatgpt"]),
            "chatgpt");

        Assert.Equal(RouterErrorCode.SecretScopeViolation, result.Error!.Code);
    }

    [Fact]
    public async Task Rotation_is_observed_immediately()
    {
        FakeEnvironment environment = new();
        environment.Set(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.Process, "first-value");
        EnvironmentSecretResolver resolver = new(environment);

        SecretResolutionResult first = await Resolve(resolver, Ref(EnvironmentSecretAllowlist.OpenRouterApiKey), "mm_openrouter");
        environment.Set(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.Process, "second-value");
        SecretResolutionResult second = await Resolve(resolver, Ref(EnvironmentSecretAllowlist.OpenRouterApiKey), "mm_openrouter");

        Assert.Equal("first-value", first.Handle!.ReadValue());
        Assert.Equal("second-value", second.Handle!.ReadValue());
    }

    [Fact]
    public void Opaque_handle_tostring_is_redacted()
    {
        using SecretHandle handle = SecretHandle.FromValue("supersecret-value-123");

        Assert.Equal("[secret-redacted]", handle.ToString());
        Assert.Equal("supersecret-value-123", handle.ReadValue());
    }

    [Fact]
    public void Json_serialization_cannot_leak_handle_value()
    {
        using SecretHandle handle = SecretHandle.FromValue("supersecret-value-123");

        string json = JsonSerializer.Serialize(handle);

        Assert.DoesNotContain("supersecret", json);
        Assert.DoesNotContain("value-123", json);
    }

    [Fact]
    public async Task Errors_and_logs_never_contain_the_secret_value()
    {
        FakeEnvironment environment = new();
        environment.Set(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.Process, "supersecret-value-123");
        EnvironmentSecretResolver resolver = new(environment);
        SecretResolutionResult result = await Resolve(resolver, Ref(EnvironmentSecretAllowlist.OpenRouterApiKey), "mm_openrouter");

        string errorJson = JsonSerializer.Serialize(new[] { result.Error });
        string missingJson = SecretErrors.Missing(EnvironmentSecretAllowlist.OpenRouterApiKey).ToJson();

        Assert.DoesNotContain("supersecret", errorJson);
        Assert.DoesNotContain("supersecret", missingJson);
    }

    [Fact]
    public async Task Resolver_only_reads_allowlisted_names_and_never_machine_scope()
    {
        FakeEnvironment environment = new();
        environment.Set(EnvironmentSecretAllowlist.OpenRouterApiKey, SecretScope.Process, "v");
        EnvironmentSecretResolver resolver = new(environment);

        SecretReference reference = Ref(EnvironmentSecretAllowlist.OpenRouterApiKey);
        _ = await resolver.ResolveAsync(reference, "mm_openrouter", CancellationToken.None);

        Assert.All(environment.Reads, static read =>
        {
            Assert.NotEqual("auth.json", read.Name);
            Assert.DoesNotContain(".env", read.Name);
            Assert.True(read.Scope is SecretScope.Process or SecretScope.User);
        });
        Assert.DoesNotContain(Enum.GetNames<SecretScope>(), static scope => scope == "Machine");
    }

    [Fact]
    public void Disposed_handle_cannot_be_read()
    {
        SecretHandle handle = SecretHandle.FromValue("supersecret-value-123");
        handle.Dispose();

        Assert.Throws<ObjectDisposedException>(() => handle.ReadValue());
        Assert.Equal("[secret-redacted]", handle.ToString());
    }

    private static Task<SecretResolutionResult> Resolve(
        EnvironmentSecretResolver resolver,
        SecretReference reference,
        string providerId)
        => resolver.ResolveAsync(reference, providerId, CancellationToken.None);

    private static SecretReference Ref(string name, SecretScope scope = SecretScope.UserOrProcess, string[]? providers = null)
        => new()
        {
            Resolver = "environment",
            Name = name,
            Scope = scope,
            AllowedProviderIds = providers ?? ["mm_openrouter"],
            Version = 1,
        };
}
