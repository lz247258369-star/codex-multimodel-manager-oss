using System.Text.Json;
using System.Text.Json.Serialization;

namespace Router.ClientAdapters.Responses;

/// <summary>Supported reasoning effort values (contract wire names).</summary>
public enum ReasoningEffort
{
    Low = 0,
    Medium = 1,
    High = 2,

    /// <summary>
    /// DeepSeek official Responses effort level. It is a first-class canonical
    /// value and is never rewritten to <see cref="High"/>, <c>xhigh</c> or any
    /// provider-specific spelling.
    /// </summary>
    Max = 3,
}

/// <summary>Supported reasoning summary modes (contract wire names).</summary>
public enum ReasoningSummaryMode
{
    Auto = 0,
    Enabled = 1,
    Disabled = 2,
}

/// <summary>Wire-name mapping for reasoning enums.</summary>
public static class ReasoningEnums
{
    public static bool TryParseEffort(string? name, out ReasoningEffort effort)
    {
        switch (name)
        {
            case "low":
                effort = ReasoningEffort.Low;
                return true;
            case "medium":
                effort = ReasoningEffort.Medium;
                return true;
            case "high":
                effort = ReasoningEffort.High;
                return true;
            case "max":
                effort = ReasoningEffort.Max;
                return true;
            default:
                effort = default;
                return false;
        }
    }

    public static bool TryParseSummary(string? name, out ReasoningSummaryMode summary)
    {
        switch (name)
        {
            case "auto":
                summary = ReasoningSummaryMode.Auto;
                return true;
            case "enabled":
                summary = ReasoningSummaryMode.Enabled;
                return true;
            case "disabled":
                summary = ReasoningSummaryMode.Disabled;
                return true;
            default:
                summary = default;
                return false;
        }
    }

    public static string ToWireName(this ReasoningEffort effort) => effort switch
    {
        ReasoningEffort.Low => "low",
        ReasoningEffort.Medium => "medium",
        ReasoningEffort.High => "high",
        ReasoningEffort.Max => "max",
        _ => throw new ArgumentOutOfRangeException(nameof(effort)),
    };

    public static string ToWireName(this ReasoningSummaryMode summary) => summary switch
    {
        ReasoningSummaryMode.Auto => "auto",
        ReasoningSummaryMode.Enabled => "enabled",
        ReasoningSummaryMode.Disabled => "disabled",
        _ => throw new ArgumentOutOfRangeException(nameof(summary)),
    };
}

/// <summary>
/// Supported reasoning controls. Values are preserved as data; the router
/// never interprets or executes reasoning behavior beyond representation.
/// </summary>
public sealed record ReasoningRequest
{
    [JsonConverter(typeof(ReasoningEffortConverter))]
    public ReasoningEffort? Effort { get; init; }

    [JsonConverter(typeof(ReasoningSummaryConverter))]
    public ReasoningSummaryMode? Summary { get; init; }
}

internal sealed class ReasoningEffortConverter : JsonConverter<ReasoningEffort?>
{
    public override ReasoningEffort? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? text = reader.GetString();
        return ReasoningEnums.TryParseEffort(text, out ReasoningEffort effort) ? effort : null;
    }

    public override void Write(Utf8JsonWriter writer, ReasoningEffort? value, JsonSerializerOptions options)
    {
        if (value is { } effort)
        {
            writer.WriteStringValue(effort.ToWireName());
        }
        else
        {
            writer.WriteNullValue();
        }
    }
}

internal sealed class ReasoningSummaryConverter : JsonConverter<ReasoningSummaryMode?>
{
    public override ReasoningSummaryMode? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? text = reader.GetString();
        return ReasoningEnums.TryParseSummary(text, out ReasoningSummaryMode summary) ? summary : null;
    }

    public override void Write(Utf8JsonWriter writer, ReasoningSummaryMode? value, JsonSerializerOptions options)
    {
        if (value is { } summary)
        {
            writer.WriteStringValue(summary.ToWireName());
        }
        else
        {
            writer.WriteNullValue();
        }
    }
}
