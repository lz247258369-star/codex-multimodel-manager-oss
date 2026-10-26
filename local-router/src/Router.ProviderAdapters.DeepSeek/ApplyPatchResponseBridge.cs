using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;

namespace Router.ProviderAdapters.DeepSeek;

/// <summary>
/// DSR7-C-FIX5-B1b-2: the DeepSeek-only apply_patch response restore.
///
/// This is the return half of the B1b-1 request bridge and it lives in the
/// DeepSeek provider compatibility layer on purpose. The generic Responses codec
/// keeps decoding an upstream function_call into a canonical
/// FunctionCallResponseItem; only this provider-local step decides whether the
/// Router-owned synthetic identity is handed back to the client as a freeform
/// custom_tool_call.
///
/// The restore is non-stream only and it is never unconditional. The exact
/// reserved synthetic name is restorable only when the request that produced the
/// response actually enabled the bridge; without an active bridge the reserved
/// identity is a synthetic injection and the whole response fails closed. The
/// whole output list is validated before anything is returned, so one malformed
/// synthetic call rejects the entire response instead of leaking a partial
/// result.
///
/// The restore is pure data transformation: it never executes a patch, never
/// touches the filesystem, never starts a process, and never logs, meters or
/// diagnoses the patch text. Errors carry only a fixed, content-free message.
/// </summary>
public static class ApplyPatchResponseBridge
{
    /// <summary>The single accepted argument property of the synthetic function.</summary>
    private const string PatchPropertyName = "patch";

    /// <summary>
    /// Applies the restore (or the injection defence) to one adapter result.
    /// Errors and streamed results are returned untouched: this gate is
    /// non-stream only, and the SSE path stays exactly as it was.
    /// </summary>
    public static ProviderAdapterResult Apply(ProviderAdapterResult result, bool bridgeIsActive)
    {
        ArgumentNullException.ThrowIfNull(result);

        if (result.Response is not { } response)
        {
            return result;
        }

        Result<CanonicalResponsesResponse, RouterError> restored = Restore(response, bridgeIsActive);
        return restored.Error is { } error
            ? ProviderAdapterResult.Failed(error)
            : ProviderAdapterResult.NonStream(restored.Value!);
    }

    /// <summary>
    /// Restores every valid synthetic function call of one decoded response.
    ///
    /// The output list is walked once, in order, into a temporary list that only
    /// becomes the result when every item has been validated. Ordinary items are
    /// carried through by reference, and a response without any reserved
    /// synthetic call is returned as the same instance.
    /// </summary>
    public static Result<CanonicalResponsesResponse, RouterError> Restore(
        CanonicalResponsesResponse response,
        bool bridgeIsActive)
    {
        ArgumentNullException.ThrowIfNull(response);

        var output = new List<ResponseOutputItem>(response.Output.Count);
        int restoredCount = 0;

        foreach (ResponseOutputItem item in response.Output)
        {
            // Only a function call that carries the exact reserved synthetic name
            // is a bridge candidate. The comparison is ordinal equality: no trim,
            // no case folding, no prefix/suffix/contains/regex matching.
            if (item is not FunctionCallResponseItem call
                || !ApplyPatchBridgeContract.IsReservedSyntheticName(call.Name))
            {
                output.Add(item);
                continue;
            }

            // The reserved identity was observed. It may never be passed through to
            // the client: either it is restored by an active bridge, or the whole
            // response fails closed.
            if (!bridgeIsActive
                || !TryDecodePatch(call.Arguments, out string patch)
                || string.IsNullOrWhiteSpace(call.CallId))
            {
                return FailClosed();
            }

            output.Add(new CustomToolCallResponseItem
            {
                Type = ApplyPatchBridgeContract.ClientToolCallType,
                Id = call.Id,
                CallId = call.CallId,
                Name = ApplyPatchBridgeContract.ApplyPatchToolName,
                Input = patch,
            });
            restoredCount++;
        }

        // Response-level fields (id, object, created_at, status, model, usage,
        // error code and error message) are never touched: only the restored
        // output items differ, and only when at least one call was restored.
        return new Result<CanonicalResponsesResponse, RouterError>
        {
            Value = restoredCount == 0 ? response : response with { Output = output },
        };
    }

    /// <summary>
    /// Shared strict decode primitive for the non-stream restore and the
    /// streaming bridge, so the two halves can never drift: the arguments must be
    /// a JSON object with exactly one property named patch whose value is a
    /// string, and the decoded patch must fit the B1b-1 patch bound.
    /// </summary>
    public static bool TryDecodePatch(string arguments, out string patch)
    {
        if (!TryReadPatch(arguments, out string decoded)
            || decoded.Length > ApplyPatchRequestBridge.MaxPatchInputLength)
        {
            patch = string.Empty;
            return false;
        }

        patch = decoded;
        return true;
    }

    /// <summary>
    /// Strictly decodes the synthetic function arguments. The payload must be a
    /// JSON object with exactly one property named patch whose value is a string.
    /// The properties are enumerated - never probed with TryGetProperty - so a
    /// duplicate key is detected instead of silently resolving to one of the two
    /// values.
    /// </summary>
    private static bool TryReadPatch(string arguments, out string patch)
    {
        patch = string.Empty;
        try
        {
            using JsonDocument document = JsonDocument.Parse(arguments);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return false;
            }

            int propertyCount = 0;
            foreach (JsonProperty property in root.EnumerateObject())
            {
                propertyCount++;
                if (propertyCount > 1
                    || !string.Equals(property.Name, PatchPropertyName, StringComparison.Ordinal)
                    || property.Value.ValueKind != JsonValueKind.String)
                {
                    return false;
                }

                patch = property.Value.GetString()!;
            }

            return propertyCount == 1;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static Result<CanonicalResponsesResponse, RouterError> FailClosed()
        => new() { Error = ProviderAdapterErrors.InvalidResponse() };
}
