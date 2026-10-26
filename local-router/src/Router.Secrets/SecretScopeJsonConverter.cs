using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.Secrets;

/// <summary>Serializes <see cref="SecretScope"/> using contract wire names.</summary>
public sealed class SecretScopeJsonConverter : JsonConverter<SecretScope>
{
    public override SecretScope Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? text = reader.GetString();
        if (SecretScopeExtensions.TryFromWireName(text, out SecretScope scope))
        {
            return scope;
        }

        throw new JsonException("Unknown secret scope.");
    }

    public override void Write(Utf8JsonWriter writer, SecretScope value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToWireName());
}
