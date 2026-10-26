namespace Router.Secrets;

/// <summary>
/// Explicit environment-variable reference allowlist per provider. New provider
/// secret mappings must be registered here; placeholders never auto-allow
/// arbitrary environment names.
/// </summary>
public static class EnvironmentSecretAllowlist
{
    public const string OpenAiApiKey = "CODEX_OPENAI_API_KEY";
    public const string DashScopeApiKey = "CODEX_DASHSCOPE_API_KEY";
    public const string OpenRouterApiKey = "OPENROUTER_API_KEY";
    public const string MimoApiKey = "MIMO_API_KEY";
    public const string DeepSeekApiKey = "DEEPSEEK_API_KEY";
    public const string LocalRouterToken = "CODEX_LOCAL_ROUTER_TOKEN";
    public const string LocalRouterProviderId = "local_router";

    private static readonly Dictionary<string, string> ProviderToEnvironmentName = new(StringComparer.Ordinal)
        {
            ["mm_openai_api"] = OpenAiApiKey,
            ["mm_modelstudio"] = DashScopeApiKey,
            ["mm_openrouter"] = OpenRouterApiKey,
            ["mm_mimo"] = MimoApiKey,
            ["deepseek"] = DeepSeekApiKey,
        };

    /// <summary>True only when the provider maps exactly to the given environment name.</summary>
    public static bool IsProviderSecretAllowed(string providerId, string environmentName)
        => ProviderToEnvironmentName.TryGetValue(providerId, out string? mapped)
            && string.Equals(mapped, environmentName, StringComparison.Ordinal);

    /// <summary>The local client token reference is fixed by the architecture.</summary>
    public static bool IsLocalRouterTokenReferenceAllowed(string environmentName)
        => string.Equals(environmentName, LocalRouterToken, StringComparison.Ordinal);

    /// <summary>Provider -> environment reference name mapping (read-only copy).</summary>
    public static IReadOnlyDictionary<string, string> ProviderMappings { get; } =
        new Dictionary<string, string>(ProviderToEnvironmentName, StringComparer.Ordinal);
}
