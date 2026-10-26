namespace Router.Registries;

/// <summary>
/// Immutable built-in provider identity table reusing existing Manager provider
/// IDs. Adapter IDs are placeholders only; none becomes eligible until an
/// explicit adapter registration exists (LR-5+).
/// </summary>
public static class BuiltInProviders
{
    public static IReadOnlyDictionary<string, ProviderDescriptor> All { get; } = Build();

    private static Dictionary<string, ProviderDescriptor> Build()
    {
        var table = new Dictionary<string, ProviderDescriptor>(StringComparer.Ordinal);
        Add(table, "chatgpt", ProviderAvailability.DirectOnly, "adapter.provider.chatgpt.responses.v1");
        Add(table, "mm_openai_api", ProviderAvailability.Planned, "adapter.provider.mm_openai_api.responses.v1");
        Add(table, "mm_modelstudio", ProviderAvailability.Planned, "adapter.provider.mm_modelstudio.responses.v1");
        Add(table, "mm_openrouter", ProviderAvailability.Planned, "adapter.provider.mm_openrouter.responses.v1");
        Add(table, "mm_mimo", ProviderAvailability.Planned, "adapter.provider.mm_mimo.responses.v1");
        // DSR1: the direct DeepSeek official identity. It is the same explicit
        // identity the user's Codex config already uses, and it only becomes
        // usable once RouterExecutionDefaults registers the DeepSeek adapter.
        Add(table, "deepseek", ProviderAvailability.Planned, "adapter.provider.deepseek.responses.v1");

        // Reserved future provider identities; reservation is not approval.
        Add(table, "deepseek_direct", ProviderAvailability.Placeholder, "adapter.provider.deepseek_direct.responses.v1");
        Add(table, "qwen_direct", ProviderAvailability.Placeholder, "adapter.provider.qwen_direct.responses.v1");
        Add(table, "zai", ProviderAvailability.Placeholder, "adapter.provider.zai.responses.v1");
        Add(table, "anthropic", ProviderAvailability.Placeholder, "adapter.provider.anthropic.responses.v1");
        Add(table, "minimax", ProviderAvailability.Placeholder, "adapter.provider.minimax.responses.v1");
        Add(table, "siliconflow", ProviderAvailability.Placeholder, "adapter.provider.siliconflow.responses.v1");
        Add(table, "modelscope", ProviderAvailability.Placeholder, "adapter.provider.modelscope.responses.v1");
        Add(table, "nvidia", ProviderAvailability.Placeholder, "adapter.provider.nvidia.responses.v1");
        return table;
    }

    private static void Add(Dictionary<string, ProviderDescriptor> table, string providerId, ProviderAvailability availability, string adapterId)
        => table.Add(
            providerId,
            new ProviderDescriptor
            {
                ProviderId = providerId,
                Availability = availability,
                AdapterId = adapterId,
                AdapterVersion = "1.0",
                HasEligibleAdapter = false,
                Capabilities = [],
                Version = 1,
            });
}

/// <summary>
/// Immutable built-in protocol identity table. Only
/// <c>protocol.openai.responses.v1</c> is eligible; reserved protocols are
/// placeholders and are never selectable.
/// </summary>
public static class BuiltInProtocols
{
    public const string CanonicalResponses = "protocol.openai.responses.v1";

    public static IReadOnlyDictionary<string, ProtocolDescriptor> All { get; } = Build();

    private static Dictionary<string, ProtocolDescriptor> Build()
    {
        var table = new Dictionary<string, ProtocolDescriptor>(StringComparer.Ordinal)
        {
            [CanonicalResponses] = new()
            {
                ProtocolId = CanonicalResponses,
                IsEligibleProtocol = true,
                IsPlaceholder = false,
                Capabilities =
                [
                    "text", "streaming", "reasoning", "tools", "usage", "cancellation",
                ],
                Version = 1,
            },
            ["protocol.anthropic.messages.v1"] = new()
            {
                ProtocolId = "protocol.anthropic.messages.v1",
                IsEligibleProtocol = false,
                IsPlaceholder = true,
                Capabilities = [],
                Version = 1,
            },
        };
        return table;
    }
}
