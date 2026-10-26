using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.Configuration;

/// <summary>Router mode. Direct is the default and the only safe default.</summary>
public enum RouterMode
{
    Direct = 0,
    Router = 1,
}

/// <summary>Mapping between <see cref="RouterMode"/> and contract wire names.</summary>
public static class RouterModeExtensions
{
    public static string ToWireName(this RouterMode mode) => mode switch
    {
        RouterMode.Direct => "direct",
        RouterMode.Router => "router",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    public static bool TryFromWireName(string? name, out RouterMode mode)
    {
        switch (name)
        {
            case "direct":
                mode = RouterMode.Direct;
                return true;
            case "router":
                mode = RouterMode.Router;
                return true;
            default:
                mode = default;
                return false;
        }
    }
}

/// <summary>Serializes <see cref="RouterMode"/> using contract wire names.</summary>
public sealed class RouterModeJsonConverter : JsonConverter<RouterMode>
{
    public override RouterMode Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? text = reader.GetString();
        if (RouterModeExtensions.TryFromWireName(text, out RouterMode mode))
        {
            return mode;
        }

        throw new JsonException("Unknown router mode.");
    }

    public override void Write(Utf8JsonWriter writer, RouterMode value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToWireName());
}
