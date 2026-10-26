using System.Text.Json;
using Router.Core.Support;

namespace Router.ClientAdapters.Responses;

/// <summary>
/// DSR7-C-FIX4: best-effort, purely diagnostic extraction of a rejected
/// <c>custom</c> tool's identity.
///
/// Only the tool object's own direct <c>name</c> member is inspected, and only
/// when it appears exactly once with a string value. Everything else - a
/// missing member, a duplicate member, a null/number/object value - collapses to
/// <see cref="SafeCustomToolIdentityClassifier.UnknownCustom"/>. The raw name is
/// never stored, returned, copied or serialized, and this helper never changes
/// the request outcome: the caller still fails closed with the same HTTP 422
/// envelope.
/// </summary>
internal static class SafeCustomToolDiagnostics
{
    /// <summary>
    /// Returns a fixed identity label for the rejected tool. Never throws and
    /// never returns request content.
    /// </summary>
    public static string ClassifyRejectedCustomToolIdentity(JsonElement tool)
    {
        if (tool.ValueKind != JsonValueKind.Object)
        {
            return SafeCustomToolIdentityClassifier.UnknownCustom;
        }

        int nameCount = 0;
        JsonValueKind nameKind = JsonValueKind.Undefined;
        string? nameValue = null;

        foreach (JsonProperty property in tool.EnumerateObject())
        {
            if (!string.Equals(property.Name, "name", StringComparison.Ordinal))
            {
                continue;
            }

            nameCount++;
            if (nameCount > 1)
            {
                // A duplicate member is ambiguous by construction: never let one
                // of the two values decide the identity.
                return SafeCustomToolIdentityClassifier.UnknownCustom;
            }

            nameKind = property.Value.ValueKind;
            if (nameKind == JsonValueKind.String)
            {
                nameValue = property.Value.GetString();
            }
        }

        if (nameCount != 1 || nameKind != JsonValueKind.String)
        {
            return SafeCustomToolIdentityClassifier.UnknownCustom;
        }

        return SafeCustomToolIdentityClassifier.Classify(nameValue);
    }
}
