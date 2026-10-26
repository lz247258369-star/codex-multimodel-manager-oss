using System.Text.Json.Serialization;

namespace Router.Secrets;

/// <summary>
/// Schema-v1 secret reference. Contains a reference name only; never a value,
/// path, or inline token.
/// </summary>
public sealed record SecretReference
{
    public required string Resolver { get; init; }

    public required string Name { get; init; }

    [JsonConverter(typeof(SecretScopeJsonConverter))]
    public required SecretScope Scope { get; init; }

    public IReadOnlyList<string> AllowedProviderIds { get; init; } = [];

    public required int Version { get; init; }
}
