using Router.ProtocolAdapters.Abstractions;
using Router.ProtocolAdapters.Responses;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.DeepSeek;
using Router.ProviderAdapters.MiMo;
using Router.ProviderAdapters.ModelStudio;
using Router.ProviderAdapters.OpenAI;
using Router.ProviderAdapters.OpenRouter;
using ProviderResult = Router.ProviderAdapters.Abstractions.Result<Router.ProviderAdapters.Abstractions.ProviderAdapterRegistry, Router.Core.Errors.RouterError>;
using ProtocolResult = Router.ProtocolAdapters.Abstractions.Result<Router.ProtocolAdapters.Abstractions.ProtocolAdapterRegistry, Router.Core.Errors.RouterError>;

namespace Router.Execution;

/// <summary>
/// Exact adapter registration tables shared by the registry snapshot and the
/// runtime provider/protocol registries. chatgpt is never registered here;
/// only the existing Router providers are eligible.
/// </summary>
public static class RouterExecutionDefaults
{
    /// <summary>Explicit provider adapter instances for the existing Router providers.</summary>
    public static IReadOnlyList<IProviderAdapter> ProviderAdapters { get; } =
    [
        new OpenRouterProviderAdapter(),
        new ModelStudioProviderAdapter(),
        new OpenAIProviderAdapter(),
        new MiMoProviderAdapter(),
        new DeepSeekProviderAdapter(),
    ];

    /// <summary>Explicit Responses-to-Responses protocol adapter instance.</summary>
    public static IResponsesProtocolAdapter ProtocolAdapter { get; } = new ResponsesProtocolAdapter();

    /// <summary>
    /// Adapter registrations fed into the immutable registry snapshot builder.
    /// chatgpt and placeholder providers never receive a registration.
    /// </summary>
    public static IReadOnlyList<Router.Registries.AdapterRegistration> RegistryRegistrations { get; } = BuildRegistrations();

    /// <summary>Builds the immutable runtime provider adapter registry.</summary>
    public static ProviderAdapterRegistry CreateProviderAdapterRegistry()
    {
        ProviderAdapterRegistration[] registrations = ProviderAdapters
            .Select(static adapter => ProviderAdapterRegistration.Create(adapter.Descriptor, adapter))
            .ToArray();
        ProviderResult created = ProviderAdapterRegistry.Create(registrations);
        if (created.Error is not null)
        {
            throw new InvalidOperationException("Provider adapter registrations are invalid.");
        }

        return created.Value!;
    }

    /// <summary>Builds the immutable runtime protocol adapter registry.</summary>
    public static ProtocolAdapterRegistry CreateProtocolAdapterRegistry()
    {
        ProtocolAdapterRegistration registration = ProtocolAdapterRegistration.Create(ProtocolAdapter.Descriptor, ProtocolAdapter);
        ProtocolResult created = ProtocolAdapterRegistry.Create([registration]);
        if (created.Error is not null)
        {
            throw new InvalidOperationException("Protocol adapter registrations are invalid.");
        }

        return created.Value!;
    }

    private static Router.Registries.AdapterRegistration[] BuildRegistrations()
    {
        var registrations = new List<Router.Registries.AdapterRegistration>
        {
            Router.Registries.AdapterRegistration.Protocol(
                ProtocolAdapter.Descriptor.AdapterId,
                ProtocolAdapter.Descriptor.UpstreamProtocolId,
                ProtocolAdapter.Descriptor.Capabilities.Values),
        };

        foreach (IProviderAdapter adapter in ProviderAdapters)
        {
            registrations.Add(Router.Registries.AdapterRegistration.Provider(
                adapter.Descriptor.AdapterId,
                adapter.Descriptor.ProviderId,
                adapter.Descriptor.Capabilities.Values));
        }

        return registrations.ToArray();
    }
}
