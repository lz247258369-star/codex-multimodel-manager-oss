using System.Text.Json;
using System.Text.Json.Serialization;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.Registries;

namespace Router.ProviderAdapters.DeepSeek;

/// <summary>
/// DSR7-C-FIX5-B1b-1: the DeepSeek-only <c>apply_patch</c> request bridge.
///
/// This type is provider-local on purpose. It is the only place in the Router
/// that rewrites a canonical freeform tool into an upstream representable shape,
/// it is reachable only from <see cref="DeepSeekProviderAdapter"/>, and it is
/// gated on the explicit provider compatibility bridge capability plus the
/// route's <c>tools</c> capability. Every other provider keeps failing closed in
/// the shared adapter base.
///
/// The transform is pure and immutable: the canonical request instance handed in
/// by the caller is never mutated. A new canonical request is returned in which
/// only the freeform tool slot is cleared, the Router-owned synthetic function is
/// appended last, and the two replayed freeform input shapes are projected onto
/// the ordinary function wire shapes. Patch text is request content: it is never
/// logged, never metered, never diagnosed, and it is never executed - the bridge
/// only serializes it into the upstream function arguments.
/// </summary>
public static class ApplyPatchRequestBridge
{
    /// <summary>
    /// The route capability the bridge requires in addition to the provider's
    /// declared compatibility bridge: the synthetic function is an ordinary
    /// upstream function, so a route that cannot carry tools can never be bridged.
    /// </summary>
    public const string RequiredRouteCapability = "tools";

    /// <summary>
    /// The additional route capability a streaming request needs: the synthetic
    /// function travels inside the ordinary upstream event stream, so a route that
    /// cannot stream can never carry a bridged streaming request.
    /// </summary>
    public const string RequiredStreamingCapability = "streaming";

    /// <summary>
    /// Maximum replayed patch length accepted from the client. The bound protects
    /// the upstream serialization path; the accepted value is request content and
    /// is never logged or diagnosed.
    /// </summary>
    public const int MaxPatchInputLength = 65_536;

    /// <summary>
    /// The fixed synthetic function schema. The freeform grammar definition and
    /// the client description are deliberately never projected: only the patch
    /// string crosses the boundary.
    /// </summary>
    private const string SyntheticParametersJson =
        """{"type":"object","properties":{"patch":{"type":"string"}},"required":["patch"],"additionalProperties":false}""";

    private static readonly JsonElement SyntheticParameters = CreateSyntheticParameters();

    private static readonly JsonSerializerOptions CompactJson = new()
    {
        WriteIndented = false,
    };

    /// <summary>
    /// True only when every bridge precondition holds: the provider declares the
    /// explicit <c>apply_patch_compat_bridge</c> capability, the resolved route
    /// belongs to the direct DeepSeek provider, and the route declares every
    /// capability the requested mode needs - <c>tools</c> always, plus
    /// <c>streaming</c> for a streaming request. Anything else fails closed before
    /// any transport call.
    /// </summary>
    public static bool IsEligible(ProviderAdapterInvocation invocation, CapabilitySet declaredBridges)
    {
        ArgumentNullException.ThrowIfNull(invocation);
        ArgumentNullException.ThrowIfNull(declaredBridges);

        return declaredBridges.Contains(ApplyPatchBridgeContract.CompatBridgeCapability)
            && string.Equals(
                invocation.Route.ProviderRoute.ProviderId,
                DeepSeekProviderAdapter.ProviderId,
                StringComparison.Ordinal)
            && invocation.Route.EffectiveCapabilities.Contains(RequiredRouteCapability)
            && (!invocation.Request.Stream
                || invocation.Route.EffectiveCapabilities.Contains(RequiredStreamingCapability));
    }

    /// <summary>
    /// Builds the provider-local clone for one bridged attempt. The same transform
    /// serves non-streaming and streaming attempts - there is no second streaming
    /// transformer - because the outbound body is identical in both modes; only
    /// the response side differs. A request without a canonical freeform tool is
    /// returned unchanged; every shape the bridge cannot preserve exactly (a
    /// foreign freeform identity, a reserved synthetic name collision, an
    /// orphan/duplicate/oversized replay, a named tool_choice that points at the
    /// replaced tool) fails closed.
    /// </summary>
    public static Result<CanonicalResponsesRequest, RouterError> CreateProviderLocalRequest(
        CanonicalResponsesRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.ApplyPatchTool is null)
        {
            return new Result<CanonicalResponsesRequest, RouterError> { Value = request };
        }

        // The accepted identity is exact, and the Router-owned synthetic identity
        // is reserved: a client-defined function may never claim it.
        if (!string.Equals(
                request.ApplyPatchTool.Name,
                ApplyPatchBridgeContract.ApplyPatchToolName,
                StringComparison.Ordinal))
        {
            return new Result<CanonicalResponsesRequest, RouterError> { Error = RouterError.UnsupportedCapability() };
        }

        if (request.Tools.Any(static tool => ApplyPatchBridgeContract.IsReservedSyntheticName(tool.Name)))
        {
            return new Result<CanonicalResponsesRequest, RouterError>
            {
                Error = RouterError.InvalidRequest(
                    "The request already uses the reserved Router synthetic tool name.",
                    "tools"),
            };
        }

        // tool_choice keeps its canonical (B1a2) semantics byte for byte. A named
        // choice that selects the replaced freeform tool cannot be preserved, so it
        // fails closed instead of being rewritten.
        if (request.ToolChoice is { Kind: ToolChoiceKind.Function } namedChoice
            && (string.Equals(namedChoice.FunctionName, ApplyPatchBridgeContract.ApplyPatchToolName, StringComparison.Ordinal)
                || ApplyPatchBridgeContract.IsReservedSyntheticName(namedChoice.FunctionName)))
        {
            return new Result<CanonicalResponsesRequest, RouterError>
            {
                Error = RouterError.UnsupportedCapabilityAt("tool_choice.name"),
            };
        }

        Result<IReadOnlyList<ResponsesInputItem>, RouterError> replayed = ReplayInput(request.Input);
        if (replayed.Error is { } replayError)
        {
            return new Result<CanonicalResponsesRequest, RouterError> { Error = replayError };
        }

        // Ordinary function tools keep their order and their semantics; the
        // synthetic function is always appended last so no client ordinal shifts.
        var tools = new List<FunctionToolDefinition>(request.Tools.Count + 1);
        tools.AddRange(request.Tools);
        tools.Add(new FunctionToolDefinition
        {
            Name = ApplyPatchBridgeContract.SyntheticFunctionName,
            Parameters = SyntheticParameters,
            Strict = false,
        });

        return new Result<CanonicalResponsesRequest, RouterError>
        {
            Value = request with
            {
                Input = replayed.Value!,
                Tools = tools,
                ApplyPatchTool = null,
            },
        };
    }

    /// <summary>
    /// Projects the two replayed freeform input shapes onto the ordinary function
    /// wire shapes. Pairing is structural and ordering-sensitive: an output must
    /// follow exactly one earlier matching call, and a call id may never be reused
    /// or answered twice.
    /// </summary>
    private static Result<IReadOnlyList<ResponsesInputItem>, RouterError> ReplayInput(
        IReadOnlyList<ResponsesInputItem> input)
    {
        var replayed = new List<ResponsesInputItem>(input.Count);
        var pendingCalls = new HashSet<string>(StringComparer.Ordinal);
        var answeredCalls = new HashSet<string>(StringComparer.Ordinal);
        int index = 0;

        foreach (ResponsesInputItem item in input)
        {
            switch (item)
            {
                case CustomToolCallInputItem call:
                {
                    if (!string.Equals(call.Name, ApplyPatchBridgeContract.ApplyPatchToolName, StringComparison.Ordinal))
                    {
                        // Unknown freeform tool: it is never translated.
                        return new Result<IReadOnlyList<ResponsesInputItem>, RouterError>
                        {
                            Error = RouterError.UnsupportedCapabilityAt($"input[{index}].type"),
                        };
                    }

                    if (call.CallId.Length == 0 || !pendingCalls.Add(call.CallId))
                    {
                        // Malformed or duplicated call id: the pairing can no longer
                        // be proven, so nothing is translated.
                        return new Result<IReadOnlyList<ResponsesInputItem>, RouterError>
                        {
                            Error = RouterError.InvalidRequest(
                                "A replayed custom tool call must use a unique call id.",
                                $"input[{index}].call_id"),
                        };
                    }

                    if (call.Input.Length > MaxPatchInputLength)
                    {
                        return new Result<IReadOnlyList<ResponsesInputItem>, RouterError>
                        {
                            Error = RouterError.InvalidRequest(
                                "A replayed patch exceeds the maximum length.",
                                $"input[{index}].input"),
                        };
                    }

                    replayed.Add(new FunctionCallInputItem
                    {
                        Type = "function_call",
                        CallId = call.CallId,
                        Name = ApplyPatchBridgeContract.SyntheticFunctionName,
                        Arguments = SerializeArguments(call.Input),
                    });
                    break;
                }

                case CustomToolCallOutputInputItem output:
                {
                    if (output.Output.ValueKind == JsonValueKind.Undefined)
                    {
                        return new Result<IReadOnlyList<ResponsesInputItem>, RouterError>
                        {
                            Error = RouterError.InvalidRequest(
                                "A replayed custom tool call output must carry a value.",
                                $"input[{index}].output"),
                        };
                    }

                    if (!pendingCalls.Contains(output.CallId) || !answeredCalls.Add(output.CallId))
                    {
                        // Orphan output, or a second answer for the same call.
                        return new Result<IReadOnlyList<ResponsesInputItem>, RouterError>
                        {
                            Error = RouterError.InvalidRequest(
                                "A replayed custom tool call output must match exactly one earlier custom tool call.",
                                $"input[{index}].call_id"),
                        };
                    }

                    replayed.Add(new FunctionCallOutputItem
                    {
                        Type = "function_call_output",
                        CallId = output.CallId,
                        Output = SerializeOutput(output.Output),
                    });
                    break;
                }

                case FunctionCallInputItem forgedCall
                    when ApplyPatchBridgeContract.IsReservedSyntheticName(forgedCall.Name):
                    // A client may never replay the Router-owned synthetic identity.
                    return new Result<IReadOnlyList<ResponsesInputItem>, RouterError>
                    {
                        Error = RouterError.InvalidRequest(
                            "The reserved Router synthetic tool name may not be replayed by a client.",
                            $"input[{index}].name"),
                    };

                default:
                    // Ordinary messages, function calls, function call results and
                    // reasoning items are carried through untouched.
                    replayed.Add(item);
                    break;
            }

            index++;
        }

        return new Result<IReadOnlyList<ResponsesInputItem>, RouterError> { Value = replayed };
    }

    /// <summary>
    /// Serializes the patch into the synthetic function arguments. The argument
    /// object is produced by the JSON serializer so escaping is never hand-rolled.
    /// </summary>
    private static string SerializeArguments(string patch)
        => JsonSerializer.Serialize(new SyntheticArguments { Patch = patch }, CompactJson);

    /// <summary>
    /// Projects one replayed output value onto the function-call-output string. A
    /// string stays a string; every structured value becomes compact JSON.
    /// </summary>
    private static string SerializeOutput(JsonElement output)
        => output.ValueKind == JsonValueKind.String
            ? output.GetString()!
            : JsonSerializer.Serialize(output, CompactJson);

    private static JsonElement CreateSyntheticParameters()
    {
        using JsonDocument document = JsonDocument.Parse(SyntheticParametersJson);
        return document.RootElement.Clone();
    }

    /// <summary>The synthetic argument object; the property name is fixed.</summary>
    private sealed record SyntheticArguments
    {
        [JsonPropertyName("patch")]
        public required string Patch { get; init; }
    }
}
