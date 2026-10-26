using System.Text.Json;
using Router.Core.Errors;
using Router.Core.Support;

namespace Router.ClientAdapters.Responses;

/// <summary>
/// Parses the supported subset of OpenAI Responses V1 requests into an
/// immutable canonical request. Unsupported capabilities fail closed with
/// <c>unsupported_capability</c>; unknown or unsupported behavior-changing
/// parameters fail closed with <c>unsupported_parameter</c>. Nothing is ever
/// silently ignored.
/// </summary>
public static class ResponsesRequestParser
{
    private const int MaxModelLength = 128;
    private const int MaxTextLength = 1_000_000;
    private const int MaxNameLength = 128;
    private const int MaxCallIdLength = 256;
    private const int MaxMetadataCount = 32;
    private const int MaxMetadataKeyLength = 64;
    private const int MaxMetadataValueLength = 512;
    private const int MaxToolNameLength = 64;

    private static readonly HashSet<string> SupportedRootFields = new(StringComparer.Ordinal)
    {
        "model",
        "input",
        "stream",
        "instructions",
        "reasoning",
        "tools",
        "tool_choice",
        "max_output_tokens",
        "metadata",
        "background",
        "store",
        "modalities",
        "previous_response_id",
    };

    private static readonly HashSet<string> MessageRoles = new(StringComparer.Ordinal)
    {
        "user", "system", "developer", "assistant",
    };

    private static readonly HashSet<string> MultimodalPartTypes = new(StringComparer.Ordinal)
    {
        "input_image", "output_image", "input_audio", "output_audio", "input_video",
        "output_video", "input_file", "output_file", "file",
    };

    /// <summary>
    /// Parses one request body. On failure returns a normalized error and a
    /// null request; on success returns null and a canonical request.
    /// </summary>
    public static RouterError? TryParse(string json, out CanonicalResponsesRequest? request, string? requestId = null)
    {
        request = null;
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            return TryParseCore(document.RootElement, out request, requestId);
        }
        catch (JsonException)
        {
            return RouterError.InvalidRequest("The request body is not valid JSON.", "body", requestId);
        }
    }

    private static RouterError? TryParseCore(JsonElement root, out CanonicalResponsesRequest? request, string? requestId)
    {
        request = null;
        if (root.ValueKind != JsonValueKind.Object)
        {
            return RouterError.InvalidRequest("The request body must be a JSON object.", "body", requestId);
        }

        string? model = null;
        IReadOnlyList<ResponsesInputItem>? input = null;
        bool stream = false;
        string? instructions = null;
        ReasoningRequest? reasoning = null;
        List<FunctionToolDefinition>? tools = null;
        ApplyPatchCustomToolDefinition? applyPatchTool = null;
        ToolChoice? toolChoice = null;
        int? maxOutputTokens = null;
        Dictionary<string, string>? metadata = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (JsonProperty property in root.EnumerateObject())
        {
            if (!seen.Add(property.Name))
            {
                return RouterError.InvalidRequest("The request body contains a duplicate field.", property.Name, requestId);
            }

            switch (property.Name)
            {
                case "model":
                    if (property.Value.ValueKind != JsonValueKind.String)
                    {
                        return RouterError.InvalidRequest("model must be a string.", "model", requestId);
                    }

                    model = property.Value.GetString()!;
                    if (model.Length is < 1 or > MaxModelLength)
                    {
                        return RouterError.InvalidRequest("model has an invalid length.", "model", requestId);
                    }

                    break;

                case "input":
                {
                    RouterError? inputError = ParseInput(property, out input, requestId);
                    if (inputError is not null)
                    {
                        return inputError;
                    }

                    break;
                }

                case "stream":
                    if (!IsBoolean(property.Value.ValueKind))
                    {
                        return RouterError.InvalidRequest("stream must be a boolean.", "stream", requestId);
                    }

                    stream = property.Value.GetBoolean();
                    break;

                case "instructions":
                {
                    RouterError? instructionsError = ReadString(property, out instructions, MaxTextLength, requestId);
                    if (instructionsError is not null)
                    {
                        return instructionsError;
                    }

                    break;
                }

                case "reasoning":
                {
                    RouterError? reasoningError = ParseReasoning(property, out reasoning, requestId);
                    if (reasoningError is not null)
                    {
                        return reasoningError;
                    }

                    break;
                }

                case "tools":
                {
                    RouterError? toolsError = ParseTools(property, out tools, out applyPatchTool, requestId);
                    if (toolsError is not null)
                    {
                        return toolsError;
                    }

                    break;
                }

                case "tool_choice":
                {
                    RouterError? choiceError = ParseToolChoice(property, out toolChoice, requestId);
                    if (choiceError is not null)
                    {
                        return choiceError;
                    }

                    break;
                }

                case "metadata":
                {
                    RouterError? metadataError = ParseMetadata(property, out metadata, requestId);
                    if (metadataError is not null)
                    {
                        return metadataError;
                    }

                    break;
                }

                case "max_output_tokens":
                {
                    RouterError? maxOutputTokensError = ParseMaxOutputTokens(property, out int? parsedMaxOutputTokens, requestId);
                    if (maxOutputTokensError is not null)
                    {
                        return maxOutputTokensError;
                    }

                    maxOutputTokens = parsedMaxOutputTokens;
                    break;
                }

                case "background":
                    if (!IsBoolean(property.Value.ValueKind))
                    {
                        return RouterError.InvalidRequest("background must be a boolean.", "background", requestId);
                    }

                    if (property.Value.GetBoolean())
                    {
                        // Background Responses are deferred; a request that
                        // requires them must never be silently downgraded. The
                        // diagnostic names only the static field path.
                        return RouterError.UnsupportedCapabilityAt("background", requestId);
                    }

                    break;

                case "store":
                    if (!IsBoolean(property.Value.ValueKind))
                    {
                        return RouterError.InvalidRequest("store must be a boolean.", "store", requestId);
                    }

                    if (property.Value.GetBoolean())
                    {
                        // Persistent response storage is deferred.
                        return RouterError.UnsupportedCapabilityAt("store", requestId);
                    }

                    break;

                case "modalities":
                {
                    RouterError? modalitiesError = ParseModalities(property, requestId);
                    if (modalitiesError is not null)
                    {
                        return modalitiesError;
                    }

                    break;
                }

                case "previous_response_id":
                    if (property.Value.ValueKind == JsonValueKind.Null)
                    {
                        break;
                    }

                    if (property.Value.ValueKind != JsonValueKind.String)
                    {
                        return RouterError.InvalidRequest("previous_response_id must be a string or null.", "previous_response_id", requestId);
                    }

                    // Stateful conversation semantics are not supported by LR-3.
                    return RouterError.UnsupportedCapabilityAt("previous_response_id", requestId);

                default:
                    // Unknown fields are deny-by-default: the adapter cannot
                    // prove it preserves their semantics.
                    return RouterError.UnsupportedParameter(property.Name, requestId);
            }
        }

        if (model is null)
        {
            return RouterError.InvalidRequest("model is required.", "model", requestId);
        }

        if (input is null)
        {
            return RouterError.InvalidRequest("input is required.", "input", requestId);
        }

        request = new CanonicalResponsesRequest
        {
            Model = model,
            Input = input,
            Stream = stream,
            Instructions = instructions,
            Reasoning = reasoning,
            Tools = tools ?? [],
            ApplyPatchTool = applyPatchTool,
            ToolChoice = toolChoice,
            MaxOutputTokens = maxOutputTokens,
            Metadata = metadata is null
                ? new Dictionary<string, string>(StringComparer.Ordinal)
                : new Dictionary<string, string>(metadata, StringComparer.Ordinal),
        };
        return null;
    }

    /// <summary>
    /// Parses the optional canonical <c>max_output_tokens</c> budget. Only a JSON
    /// integer greater than zero is accepted; zero, negatives, fractional
    /// numbers, strings, null, and values outside the safe Int32 range fail
    /// closed. An explicit value is passed through unchanged and a missing value
    /// stays null so no provider-specific default can be invented.
    /// </summary>
    private static RouterError? ParseMaxOutputTokens(JsonProperty property, out int? maxOutputTokens, string? requestId)
    {
        maxOutputTokens = null;
        if (property.Value.ValueKind != JsonValueKind.Number)
        {
            return RouterError.InvalidRequest("max_output_tokens must be an integer.", "max_output_tokens", requestId);
        }

        if (!property.Value.TryGetInt32(out int parsed))
        {
            // Fractional values and out-of-range values fail closed: truncating
            // or clamping the budget would silently change caller semantics.
            return RouterError.InvalidRequest("max_output_tokens must be an integer.", "max_output_tokens", requestId);
        }

        if (parsed <= 0)
        {
            return RouterError.InvalidRequest("max_output_tokens must be greater than zero.", "max_output_tokens", requestId);
        }

        maxOutputTokens = parsed;
        return null;
    }

    private static RouterError? ParseInput(JsonProperty property, out IReadOnlyList<ResponsesInputItem>? items, string? requestId)
    {
        items = null;
        JsonElement value = property.Value;
        if (value.ValueKind == JsonValueKind.String)
        {
            string text = value.GetString()!;
            if (text.Length > MaxTextLength)
            {
                return RouterError.InvalidRequest("input exceeds the maximum length.", "input", requestId);
            }

            items =
            [
                new MessageInputItem
                {
                    Type = "message",
                    Role = "user",
                    Content =
                    [
                        new TextContentPart { Type = "input_text", Text = text },
                    ],
                },
            ];
            return null;
        }

        if (value.ValueKind != JsonValueKind.Array)
        {
            return RouterError.InvalidRequest("input must be a string or an array.", "input", requestId);
        }

        var list = new List<ResponsesInputItem>();
        // DSR7-C-FIX5-A: the freeform tool-call replay is only valid when the same
        // history carries the matching custom tool call; the pairing is tracked
        // structurally, never guessed from a name later.
        var customCallIds = new HashSet<string>(StringComparer.Ordinal);
        int index = 0;
        foreach (JsonElement item in value.EnumerateArray())
        {
            RouterError? error = ParseInputItem(item, index, customCallIds, out ResponsesInputItem? parsed, requestId);
            if (error is not null)
            {
                return error;
            }

            if (parsed is CustomToolCallInputItem customCall)
            {
                customCallIds.Add(customCall.CallId);
            }

            list.Add(parsed!);
            index++;
        }

        items = list;
        return null;
    }

    private static RouterError? ParseInputItem(
        JsonElement item,
        int index,
        HashSet<string> customCallIds,
        out ResponsesInputItem? parsed,
        string? requestId)
    {
        parsed = null;
        if (item.ValueKind != JsonValueKind.Object)
        {
            return RouterError.InvalidRequest("input items must be objects.", $"input[{index}]", requestId);
        }

        if (!item.TryGetProperty("type", out JsonElement typeElement) || typeElement.ValueKind != JsonValueKind.String)
        {
            return RouterError.InvalidRequest("input items must declare a string type.", $"input[{index}].type", requestId);
        }

        string type = typeElement.GetString()!;
        return type switch
        {
            "message" => ParseMessageItem(item, index, out parsed, requestId),
            "function_call" => ParseFunctionCallItem(item, index, out parsed, requestId),
            "function_call_output" => ParseFunctionCallOutputItem(item, index, out parsed, requestId),
            "reasoning" => ParseReasoningItem(item, index, out parsed, requestId),
            // DSR7-C-FIX5-A: the two replayed freeform shapes of the apply_patch
            // compatibility bridge. Anything else stays fail-closed.
            "custom_tool_call" => ParseCustomToolCallItem(item, index, out parsed, requestId),
            "custom_tool_call_output" => ParseCustomToolCallOutputItem(item, index, customCallIds, out parsed, requestId),
            // The diagnostic names the indexed field path, never the item type
            // value that was rejected.
            "item_reference" => RouterError.UnsupportedCapabilityAt($"input[{index}].type", requestId),
            "file" or "computer_call" or "web_search_call" => RouterError.UnsupportedCapabilityAt($"input[{index}].type", requestId),
            _ => RouterError.InvalidRequest("input contains an unsupported item type.", $"input[{index}].type", requestId),
        };
    }

    /// <summary>
    /// DSR7-C-FIX5-A: strict shape validation of the accepted Codex freeform
    /// <c>custom</c> / <c>apply_patch</c> tool definition.
    ///
    /// The FIX4 diagnostic contract is preserved: when the declaration is not the
    /// exact <c>apply_patch</c> identity (unknown name, missing/duplicate/
    /// non-string name, reserved synthetic name), the request still fails closed
    /// with <c>unsupported_capability</c> and the same safe class/identity labels
    /// as before. Once the identity is exactly <c>apply_patch</c>, a malformed
    /// shape (missing or invalid format, extra fields) is an invalid request at the
    /// precise field path - the capability is accepted, the shape is not.
    ///
    /// The grammar body is held in memory only; it is never logged, metered,
    /// diagnosed or printed, and no bridge exists yet (FIX5-B).
    /// </summary>
    private static RouterError? ParseApplyPatchCustomTool(
        JsonElement tool,
        int index,
        out ApplyPatchCustomToolDefinition? parsed,
        string? requestId)
    {
        parsed = null;
        string param = $"tools[{index}]";

        if (tool.ValueKind != JsonValueKind.Object)
        {
            return RouterError.InvalidRequest("tools must be objects.", param, requestId);
        }

        // Identity first: anything that is not the exact apply_patch name keeps the
        // FIX4 fail-closed behaviour (never a pass-through, never a guess).
        string identity = SafeCustomToolDiagnostics.ClassifyRejectedCustomToolIdentity(tool);
        if (!string.Equals(identity, SafeCustomToolIdentityClassifier.ApplyPatch, StringComparison.Ordinal))
        {
            return RouterError.UnsupportedCapabilityAtClassifiedWithIdentity(
                $"{param}.type",
                SafeToolTypeClassifier.Custom,
                identity,
                requestId);
        }

        string? description = null;
        string? formatType = null;
        string? formatSyntax = null;
        string? formatDefinition = null;
        bool formatSeen = false;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (JsonProperty property in tool.EnumerateObject())
        {
            if (!seen.Add(property.Name))
            {
                return RouterError.InvalidRequest("tools must not contain duplicate fields.", $"{param}.{property.Name}", requestId);
            }

            switch (property.Name)
            {
                case "type":
                case "name":
                    break;
                case "description":
                    if (property.Value.ValueKind != JsonValueKind.String)
                    {
                        return RouterError.InvalidRequest("apply_patch description must be a string.", $"{param}.description", requestId);
                    }

                    description = property.Value.GetString();
                    if (description is { Length: > ApplyPatchBridgeContract.MaxDescriptionLength })
                    {
                        return RouterError.InvalidRequest("apply_patch description exceeds the maximum length.", $"{param}.description", requestId);
                    }

                    break;
                case "format":
                    formatSeen = true;
                    if (property.Value.ValueKind != JsonValueKind.Object)
                    {
                        return RouterError.InvalidRequest("apply_patch format must be an object.", $"{param}.format", requestId);
                    }

                    var formatSeenFields = new HashSet<string>(StringComparer.Ordinal);
                    foreach (JsonProperty formatProperty in property.Value.EnumerateObject())
                    {
                        if (!formatSeenFields.Add(formatProperty.Name))
                        {
                            return RouterError.InvalidRequest("apply_patch format must not contain duplicate fields.", $"{param}.format.{formatProperty.Name}", requestId);
                        }

                        switch (formatProperty.Name)
                        {
                            case "type":
                                if (formatProperty.Value.ValueKind != JsonValueKind.String)
                                {
                                    return RouterError.InvalidRequest("apply_patch format.type must be a string.", $"{param}.format.type", requestId);
                                }

                                formatType = formatProperty.Value.GetString();
                                break;
                            case "syntax":
                                if (formatProperty.Value.ValueKind != JsonValueKind.String)
                                {
                                    return RouterError.InvalidRequest("apply_patch format.syntax must be a string.", $"{param}.format.syntax", requestId);
                                }

                                formatSyntax = formatProperty.Value.GetString();
                                break;
                            case "definition":
                                if (formatProperty.Value.ValueKind != JsonValueKind.String)
                                {
                                    return RouterError.InvalidRequest("apply_patch format.definition must be a string.", $"{param}.format.definition", requestId);
                                }

                                formatDefinition = formatProperty.Value.GetString();
                                if (string.IsNullOrEmpty(formatDefinition))
                                {
                                    return RouterError.InvalidRequest("apply_patch format.definition must not be empty.", $"{param}.format.definition", requestId);
                                }

                                if (formatDefinition.Length > ApplyPatchBridgeContract.MaxFormatDefinitionLength)
                                {
                                    return RouterError.InvalidRequest("apply_patch format.definition exceeds the maximum length.", $"{param}.format.definition", requestId);
                                }

                                break;
                            default:
                                // Strict policy: an unproven field such as
                                // defer_loading must never be silently swallowed.
                                return RouterError.UnsupportedParameter($"{param}.format.{formatProperty.Name}", requestId);
                        }
                    }

                    break;
                default:
                    return RouterError.UnsupportedParameter($"{param}.{property.Name}", requestId);
            }
        }

        if (!formatSeen)
        {
            return RouterError.InvalidRequest("apply_patch requires a format object.", $"{param}.format", requestId);
        }

        if (!string.Equals(formatType, ApplyPatchBridgeContract.RequiredFormatType, StringComparison.Ordinal))
        {
            return RouterError.InvalidRequest("apply_patch format.type must be grammar.", $"{param}.format.type", requestId);
        }

        if (!string.Equals(formatSyntax, ApplyPatchBridgeContract.RequiredFormatSyntax, StringComparison.Ordinal))
        {
            return RouterError.InvalidRequest("apply_patch format.syntax must be lark.", $"{param}.format.syntax", requestId);
        }

        if (string.IsNullOrEmpty(formatDefinition))
        {
            return RouterError.InvalidRequest("apply_patch requires a non-empty format.definition.", $"{param}.format.definition", requestId);
        }

        parsed = new ApplyPatchCustomToolDefinition
        {
            Name = ApplyPatchBridgeContract.ApplyPatchToolName,
            Description = description,
            FormatType = ApplyPatchBridgeContract.RequiredFormatType,
            FormatSyntax = ApplyPatchBridgeContract.RequiredFormatSyntax,
            FormatDefinition = formatDefinition!,
        };
        return null;
    }

    /// <summary>
    /// DSR7-C-FIX5-A: parses a replayed Codex freeform tool call. Only the exact
    /// <c>apply_patch</c> identity is representable; every other name fails closed
    /// at the item-type path, and no field is ever silently ignored.
    /// </summary>
    private static RouterError? ParseCustomToolCallItem(JsonElement item, int index, out ResponsesInputItem? parsed, string? requestId)
    {
        parsed = null;
        string param = $"input[{index}]";
        string? id = null;
        string? callId = null;
        string? name = null;
        string? input = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (JsonProperty property in item.EnumerateObject())
        {
            if (!seen.Add(property.Name))
            {
                return RouterError.InvalidRequest("input items must not contain duplicate fields.", $"{param}.{property.Name}", requestId);
            }

            switch (property.Name)
            {
                case "type":
                    break;
                case "id":
                    if (property.Value.ValueKind != JsonValueKind.String)
                    {
                        return RouterError.InvalidRequest("custom tool call id must be a string.", $"{param}.id", requestId);
                    }

                    id = property.Value.GetString();
                    break;
                case "call_id":
                    if (property.Value.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(property.Value.GetString()))
                    {
                        return RouterError.InvalidRequest("custom tool call requires a string call_id.", $"{param}.call_id", requestId);
                    }

                    callId = property.Value.GetString();
                    break;
                case "name":
                    if (property.Value.ValueKind != JsonValueKind.String)
                    {
                        return RouterError.InvalidRequest("custom tool call name must be a string.", $"{param}.name", requestId);
                    }

                    name = property.Value.GetString();
                    break;
                case "input":
                    if (property.Value.ValueKind != JsonValueKind.String)
                    {
                        return RouterError.InvalidRequest("custom tool call input must be a string.", $"{param}.input", requestId);
                    }

                    input = property.Value.GetString();
                    break;
                default:
                    return RouterError.UnsupportedParameter(property.Name, requestId);
            }
        }

        if (callId is null || name is null || input is null)
        {
            return RouterError.InvalidRequest("custom tool call requires call_id, name and input.", param, requestId);
        }

        // Only the exact freeform apply_patch identity is representable. The
        // rejection names the indexed item path, never the supplied name.
        if (!string.Equals(name, ApplyPatchBridgeContract.ApplyPatchToolName, StringComparison.Ordinal))
        {
            return RouterError.UnsupportedCapabilityAt($"{param}.type", requestId);
        }

        parsed = new CustomToolCallInputItem
        {
            Type = ApplyPatchBridgeContract.ClientToolCallType,
            Id = id,
            CallId = callId,
            Name = ApplyPatchBridgeContract.ApplyPatchToolName,
            Input = input,
        };
        return null;
    }

    /// <summary>
    /// DSR7-C-FIX5-A: parses the client's result for a restored freeform tool call.
    /// The output is preserved as JSON data (string or structured) and an orphan
    /// output - one whose call id has no matching custom tool call earlier in the
    /// same history - fails closed. The pairing is structural, never name-guessed.
    /// </summary>
    private static RouterError? ParseCustomToolCallOutputItem(
        JsonElement item,
        int index,
        HashSet<string> customCallIds,
        out ResponsesInputItem? parsed,
        string? requestId)
    {
        parsed = null;
        string param = $"input[{index}]";
        string? callId = null;
        JsonElement? output = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (JsonProperty property in item.EnumerateObject())
        {
            if (!seen.Add(property.Name))
            {
                return RouterError.InvalidRequest("input items must not contain duplicate fields.", $"{param}.{property.Name}", requestId);
            }

            switch (property.Name)
            {
                case "type":
                    break;
                case "call_id":
                    if (property.Value.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(property.Value.GetString()))
                    {
                        return RouterError.InvalidRequest("custom tool call output requires a string call_id.", $"{param}.call_id", requestId);
                    }

                    callId = property.Value.GetString();
                    break;
                case "output":
                    output = property.Value.Clone();
                    break;
                default:
                    return RouterError.UnsupportedParameter(property.Name, requestId);
            }
        }

        if (callId is null || output is null)
        {
            return RouterError.InvalidRequest("custom tool call output requires call_id and output.", param, requestId);
        }

        if (!customCallIds.Contains(callId))
        {
            return RouterError.InvalidRequest("custom tool call output has no matching custom tool call.", $"{param}.call_id", requestId);
        }

        parsed = new CustomToolCallOutputInputItem
        {
            Type = ApplyPatchBridgeContract.ClientToolCallOutputType,
            CallId = callId,
            Output = output.Value,
        };
        return null;
    }

    private static RouterError? ParseMessageItem(JsonElement item, int index, out ResponsesInputItem? parsed, string? requestId)
    {
        parsed = null;
        string? role = null;
        string? itemId = null;
        IReadOnlyList<TextContentPart>? content = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (JsonProperty property in item.EnumerateObject())
        {
            if (!seen.Add(property.Name))
            {
                return RouterError.InvalidRequest("input items must not contain duplicate fields.", $"input[{index}].{property.Name}", requestId);
            }

            switch (property.Name)
            {
                case "type":
                    break;
                case "id":
                {
                    RouterError? idError = ReadString(property, out itemId, MaxCallIdLength, requestId);
                    if (idError is not null)
                    {
                        return idError;
                    }

                    break;
                }

                case "role":
                {
                    RouterError? roleError = ReadString(property, out role, MaxNameLength, requestId);
                    if (roleError is not null)
                    {
                        return roleError;
                    }

                    if (role is null || !MessageRoles.Contains(role))
                    {
                        return RouterError.InvalidRequest("message role is not supported.", $"input[{index}].role", requestId);
                    }

                    break;
                }

                case "content":
                {
                    RouterError? contentError = ParseMessageContent(property, index, out content, requestId);
                    if (contentError is not null)
                    {
                        return contentError;
                    }

                    break;
                }

                default:
                    return RouterError.UnsupportedParameter($"input[{index}].{property.Name}", requestId);
            }
        }

        if (role is null)
        {
            return RouterError.InvalidRequest("message role is required.", $"input[{index}].role", requestId);
        }

        if (content is null)
        {
            return RouterError.InvalidRequest("message content is required.", $"input[{index}].content", requestId);
        }

        parsed = new MessageInputItem
        {
            Type = "message",
            Role = role,
            Content = content,
        };
        return null;
    }

    private static RouterError? ParseMessageContent(JsonProperty property, int index, out IReadOnlyList<TextContentPart>? content, string? requestId)
    {
        content = null;
        JsonElement value = property.Value;
        if (value.ValueKind == JsonValueKind.String)
        {
            string text = value.GetString()!;
            if (text.Length > MaxTextLength)
            {
                return RouterError.InvalidRequest("message content exceeds the maximum length.", $"input[{index}].content", requestId);
            }

            content =
            [
                new TextContentPart { Type = "input_text", Text = text },
            ];
            return null;
        }

        if (value.ValueKind != JsonValueKind.Array)
        {
            return RouterError.InvalidRequest("message content must be a string or an array.", $"input[{index}].content", requestId);
        }

        var parts = new List<TextContentPart>();
        int partIndex = 0;
        foreach (JsonElement part in value.EnumerateArray())
        {
            RouterError? error = ParseContentPart(part, index, partIndex, out TextContentPart? parsed, requestId);
            if (error is not null)
            {
                return error;
            }

            parts.Add(parsed!);
            partIndex++;
        }

        content = parts;
        return null;
    }

    private static RouterError? ParseContentPart(JsonElement part, int itemIndex, int partIndex, out TextContentPart? parsed, string? requestId)
    {
        parsed = null;
        string param = $"input[{itemIndex}].content[{partIndex}]";
        if (part.ValueKind != JsonValueKind.Object)
        {
            return RouterError.InvalidRequest("content parts must be objects.", param, requestId);
        }

        if (!part.TryGetProperty("type", out JsonElement typeElement) || typeElement.ValueKind != JsonValueKind.String)
        {
            return RouterError.InvalidRequest("content parts must declare a string type.", $"{param}.type", requestId);
        }

        string type = typeElement.GetString()!;
        if (MultimodalPartTypes.Contains(type))
        {
            // Images/audio/video/files are deferred capabilities; never silently
            // downgrade them to text. The diagnostic names the indexed path only,
            // never the rejected part type or its source URL.
            return RouterError.UnsupportedCapabilityAt($"{param}.type", requestId);
        }

        if (type is not ("input_text" or "output_text"))
        {
            if (type == "refusal")
            {
                return RouterError.UnsupportedParameter($"{param}.type", requestId);
            }

            return RouterError.InvalidRequest("content contains an unsupported part type.", $"{param}.type", requestId);
        }

        string? text = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (JsonProperty property in part.EnumerateObject())
        {
            if (!seen.Add(property.Name))
            {
                return RouterError.InvalidRequest("content parts must not contain duplicate fields.", $"{param}.{property.Name}", requestId);
            }

            switch (property.Name)
            {
                case "type":
                    break;
                case "text":
                {
                    RouterError? textError = ReadString(property, out text, MaxTextLength, requestId);
                    if (textError is not null)
                    {
                        return textError;
                    }

                    break;
                }

                default:
                    return RouterError.UnsupportedParameter($"{param}.{property.Name}", requestId);
            }
        }

        if (text is null)
        {
            return RouterError.InvalidRequest("text content parts require text.", $"{param}.text", requestId);
        }

        parsed = new TextContentPart { Type = type, Text = text };
        return null;
    }

    private static RouterError? ParseFunctionCallItem(JsonElement item, int index, out ResponsesInputItem? parsed, string? requestId)
    {
        parsed = null;
        string? callId = null;
        string? name = null;
        string? arguments = null;
        string? itemId = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (JsonProperty property in item.EnumerateObject())
        {
            if (!seen.Add(property.Name))
            {
                return RouterError.InvalidRequest("input items must not contain duplicate fields.", $"input[{index}].{property.Name}", requestId);
            }

            switch (property.Name)
            {
                case "type":
                    break;
                case "id":
                {
                    RouterError? idError = ReadString(property, out itemId, MaxCallIdLength, requestId);
                    if (idError is not null)
                    {
                        return idError;
                    }

                    break;
                }

                case "call_id":
                {
                    RouterError? callIdError = ReadString(property, out callId, MaxCallIdLength, requestId);
                    if (callIdError is not null)
                    {
                        return callIdError;
                    }

                    break;
                }

                case "name":
                {
                    RouterError? nameError = ReadString(property, out name, MaxNameLength, requestId);
                    if (nameError is not null)
                    {
                        return nameError;
                    }

                    break;
                }

                case "arguments":
                {
                    RouterError? argumentsError = ReadString(property, out arguments, MaxTextLength, requestId);
                    if (argumentsError is not null)
                    {
                        return argumentsError;
                    }

                    break;
                }

                default:
                    return RouterError.UnsupportedParameter($"input[{index}].{property.Name}", requestId);
            }
        }

        if (callId is null || name is null || arguments is null)
        {
            return RouterError.InvalidRequest("function_call items require call_id, name, and arguments.", $"input[{index}]", requestId);
        }

        parsed = new FunctionCallInputItem
        {
            Type = "function_call",
            CallId = callId,
            Name = name,
            Arguments = arguments,
        };
        return null;
    }

    private static RouterError? ParseFunctionCallOutputItem(JsonElement item, int index, out ResponsesInputItem? parsed, string? requestId)
    {
        parsed = null;
        string? callId = null;
        string? output = null;
        string? itemId = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (JsonProperty property in item.EnumerateObject())
        {
            if (!seen.Add(property.Name))
            {
                return RouterError.InvalidRequest("input items must not contain duplicate fields.", $"input[{index}].{property.Name}", requestId);
            }

            switch (property.Name)
            {
                case "type":
                    break;
                case "id":
                {
                    RouterError? idError = ReadString(property, out itemId, MaxCallIdLength, requestId);
                    if (idError is not null)
                    {
                        return idError;
                    }

                    break;
                }

                case "call_id":
                {
                    RouterError? callIdError = ReadString(property, out callId, MaxCallIdLength, requestId);
                    if (callIdError is not null)
                    {
                        return callIdError;
                    }

                    break;
                }

                case "output":
                {
                    RouterError? outputError = ReadString(property, out output, MaxTextLength, requestId);
                    if (outputError is not null)
                    {
                        return outputError;
                    }

                    break;
                }

                default:
                    return RouterError.UnsupportedParameter($"input[{index}].{property.Name}", requestId);
            }
        }

        if (callId is null || output is null)
        {
            return RouterError.InvalidRequest("function_call_output items require call_id and output.", $"input[{index}]", requestId);
        }

        parsed = new FunctionCallOutputItem
        {
            Type = "function_call_output",
            CallId = callId,
            Output = output,
        };
        return null;
    }

    private static RouterError? ParseReasoningItem(JsonElement item, int index, out ResponsesInputItem? parsed, string? requestId)
    {
        parsed = null;
        string? itemId = null;
        IReadOnlyList<SummaryTextPart>? summary = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (JsonProperty property in item.EnumerateObject())
        {
            if (!seen.Add(property.Name))
            {
                return RouterError.InvalidRequest("input items must not contain duplicate fields.", $"input[{index}].{property.Name}", requestId);
            }

            switch (property.Name)
            {
                case "type":
                    break;
                case "id":
                {
                    RouterError? idError = ReadString(property, out itemId, MaxCallIdLength, requestId);
                    if (idError is not null)
                    {
                        return idError;
                    }

                    break;
                }

                case "summary":
                {
                    RouterError? summaryError = ParseSummary(property, $"input[{index}].summary", out summary, requestId);
                    if (summaryError is not null)
                    {
                        return summaryError;
                    }

                    break;
                }

                default:
                    return RouterError.UnsupportedParameter($"input[{index}].{property.Name}", requestId);
            }
        }

        if (summary is null)
        {
            return RouterError.InvalidRequest("reasoning items require a summary.", $"input[{index}].summary", requestId);
        }

        parsed = new ReasoningInputItem { Type = "reasoning", Summary = summary };
        return null;
    }

    private static RouterError? ParseReasoning(JsonProperty property, out ReasoningRequest? reasoning, string? requestId)
    {
        reasoning = null;
        if (property.Value.ValueKind != JsonValueKind.Object)
        {
            return RouterError.InvalidRequest("reasoning must be an object.", "reasoning", requestId);
        }

        ReasoningEffort? effort = null;
        ReasoningSummaryMode? summary = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (JsonProperty child in property.Value.EnumerateObject())
        {
            if (!seen.Add(child.Name))
            {
                return RouterError.InvalidRequest("reasoning must not contain duplicate fields.", $"reasoning.{child.Name}", requestId);
            }

            switch (child.Name)
            {
                case "effort":
                {
                    if (child.Value.ValueKind != JsonValueKind.String)
                    {
                        return RouterError.InvalidRequest("reasoning.effort must be a string.", "reasoning.effort", requestId);
                    }

                    if (!ReasoningEnums.TryParseEffort(child.Value.GetString(), out ReasoningEffort parsedEffort))
                    {
                        return RouterError.UnsupportedParameter("reasoning.effort", requestId);
                    }

                    effort = parsedEffort;
                    break;
                }

                case "summary":
                {
                    if (child.Value.ValueKind != JsonValueKind.String)
                    {
                        return RouterError.InvalidRequest("reasoning.summary must be a string.", "reasoning.summary", requestId);
                    }

                    if (!ReasoningEnums.TryParseSummary(child.Value.GetString(), out ReasoningSummaryMode parsedSummary))
                    {
                        return RouterError.UnsupportedParameter("reasoning.summary", requestId);
                    }

                    summary = parsedSummary;
                    break;
                }

                default:
                    return RouterError.UnsupportedParameter($"reasoning.{child.Name}", requestId);
            }
        }

        if (effort is null && summary is null)
        {
            return RouterError.InvalidRequest("reasoning must declare effort or summary.", "reasoning", requestId);
        }

        reasoning = new ReasoningRequest
        {
            Effort = effort,
            Summary = summary,
        };
        return null;
    }

    private static RouterError? ParseTools(
        JsonProperty property,
        out List<FunctionToolDefinition>? tools,
        out ApplyPatchCustomToolDefinition? applyPatchTool,
        string? requestId)
    {
        tools = null;
        applyPatchTool = null;
        if (property.Value.ValueKind != JsonValueKind.Array)
        {
            return RouterError.InvalidRequest("tools must be an array.", "tools", requestId);
        }

        var list = new List<FunctionToolDefinition>();
        int index = 0;
        foreach (JsonElement tool in property.Value.EnumerateArray())
        {
            RouterError? error = ParseTool(tool, index, out FunctionToolDefinition? parsed, out ApplyPatchCustomToolDefinition? parsedApplyPatch, requestId);
            if (error is not null)
            {
                return error;
            }

            if (parsedApplyPatch is not null)
            {
                // Exactly one apply_patch tool is representable: a second one is
                // ambiguous and fails closed.
                if (applyPatchTool is not null)
                {
                    return RouterError.InvalidRequest("tools must not declare apply_patch twice.", $"tools[{index}].name", requestId);
                }

                applyPatchTool = parsedApplyPatch;
            }
            else
            {
                list.Add(parsed!);
            }

            index++;
        }

        tools = list;
        return null;
    }

    private static RouterError? ParseTool(
        JsonElement tool,
        int index,
        out FunctionToolDefinition? parsed,
        out ApplyPatchCustomToolDefinition? applyPatchTool,
        string? requestId)
    {
        parsed = null;
        applyPatchTool = null;
        string param = $"tools[{index}]";
        if (tool.ValueKind != JsonValueKind.Object)
        {
            return RouterError.InvalidRequest("tools must be objects.", param, requestId);
        }

        if (!tool.TryGetProperty("type", out JsonElement typeElement) || typeElement.ValueKind != JsonValueKind.String)
        {
            return RouterError.InvalidRequest("tools must declare a string type.", $"{param}.type", requestId);
        }

        string type = typeElement.GetString()!;
        if (!string.Equals(type, "function", StringComparison.Ordinal))
        {
            // DSR7-C-FIX5-A: the single accepted custom tool is Codex's freeform
            // `apply_patch`. Its shape is validated strictly and it becomes a
            // distinct canonical type - it is never rewritten into a function
            // here and never forwarded upstream (that is FIX5-B's bridge).
            if (string.Equals(type, ApplyPatchBridgeContract.ClientToolType, StringComparison.Ordinal))
            {
                return ParseApplyPatchCustomTool(tool, index, out applyPatchTool, requestId);
            }

            // Tool-execution capabilities (web_search, file_search, computer
            // use, code interpreter, MCP, image generation, ...) require
            // behavior the router cannot preserve in LR-3. The diagnostic names
            // the indexed path only, never the rejected tool type or name;
            // DSR7-C-FIX3 additionally attaches a FIXED taxonomy label so the
            // local diagnostic can say which category was rejected.
            string safeClass = SafeToolTypeClassifier.Classify(type);
            if (string.Equals(safeClass, SafeToolTypeClassifier.Custom, StringComparison.Ordinal))
            {
                // DSR7-C-FIX4: a rejected custom tool additionally gets a FIXED
                // identity label derived from its direct name member only. The
                // custom tool is still rejected - nothing is parsed, accepted,
                // translated or forwarded.
                return RouterError.UnsupportedCapabilityAtClassifiedWithIdentity(
                    $"{param}.type",
                    safeClass,
                    SafeCustomToolDiagnostics.ClassifyRejectedCustomToolIdentity(tool),
                    requestId);
            }

            return RouterError.UnsupportedCapabilityAtClassified(
                $"{param}.type",
                safeClass,
                requestId);
        }

        string? name = null;
        string? description = null;
        JsonElement? parameters = null;
        bool strict = false;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (JsonProperty child in tool.EnumerateObject())
        {
            if (!seen.Add(child.Name))
            {
                return RouterError.InvalidRequest("tools must not contain duplicate fields.", $"{param}.{child.Name}", requestId);
            }

            switch (child.Name)
            {
                case "type":
                    break;
                case "name":
                {
                    RouterError? nameError = ReadString(child, out name, MaxToolNameLength, requestId);
                    if (nameError is not null)
                    {
                        return nameError;
                    }

                    if (name is null || !IsValidToolName(name))
                    {
                        return RouterError.InvalidRequest("tool name is not supported.", $"{param}.name", requestId);
                    }

                    break;
                }

                case "description":
                {
                    RouterError? descriptionError = ReadString(child, out description, MaxTextLength, requestId);
                    if (descriptionError is not null)
                    {
                        return descriptionError;
                    }

                    break;
                }

                case "parameters":
                    if (child.Value.ValueKind != JsonValueKind.Object)
                    {
                        return RouterError.InvalidRequest("tool parameters must be an object.", $"{param}.parameters", requestId);
                    }

                    parameters = child.Value.Clone();
                    break;

                case "strict":
                    if (!IsBoolean(child.Value.ValueKind))
                    {
                        return RouterError.InvalidRequest("tool strict must be a boolean.", $"{param}.strict", requestId);
                    }

                    strict = child.Value.GetBoolean();
                    break;

                default:
                    return RouterError.UnsupportedParameter($"{param}.{child.Name}", requestId);
            }
        }

        if (name is null)
        {
            return RouterError.InvalidRequest("function tools require a name.", $"{param}.name", requestId);
        }

        // DSR7-C-FIX5-A: the Router-owned synthetic bridge identity is reserved. A
        // client-defined function may never claim it, and there is no
        // first-wins/last-wins fallback.
        if (ApplyPatchBridgeContract.IsReservedSyntheticName(name))
        {
            return RouterError.InvalidRequest("tools must not use the reserved Router synthetic tool name.", $"{param}.name", requestId);
        }

        parsed = new FunctionToolDefinition
        {
            Name = name,
            Description = description,
            Parameters = parameters,
            Strict = strict,
        };
        return null;
    }

    private static RouterError? ParseToolChoice(JsonProperty property, out ToolChoice? choice, string? requestId)
    {
        choice = null;
        JsonElement value = property.Value;
        if (value.ValueKind == JsonValueKind.String)
        {
            string text = value.GetString()!;
            ToolChoiceKind kind = text switch
            {
                "auto" => ToolChoiceKind.Auto,
                "none" => ToolChoiceKind.None,
                "required" => ToolChoiceKind.Required,
                _ => ToolChoiceKind.Auto,
            };

            if (text is not ("auto" or "none" or "required"))
            {
                return RouterError.InvalidRequest("tool_choice string is not supported.", "tool_choice", requestId);
            }

            choice = new ToolChoice { Kind = kind };
            return null;
        }

        if (value.ValueKind != JsonValueKind.Object)
        {
            return RouterError.InvalidRequest("tool_choice must be a string or an object.", "tool_choice", requestId);
        }

        string? type = null;
        string? name = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (JsonProperty child in value.EnumerateObject())
        {
            if (!seen.Add(child.Name))
            {
                return RouterError.InvalidRequest("tool_choice must not contain duplicate fields.", $"tool_choice.{child.Name}", requestId);
            }

            switch (child.Name)
            {
                case "type":
                {
                    RouterError? typeError = ReadString(child, out type, MaxNameLength, requestId);
                    if (typeError is not null)
                    {
                        return typeError;
                    }

                    break;
                }

                case "name":
                {
                    RouterError? nameError = ReadString(child, out name, MaxNameLength, requestId);
                    if (nameError is not null)
                    {
                        return nameError;
                    }

                    break;
                }

                default:
                    return RouterError.UnsupportedParameter($"tool_choice.{child.Name}", requestId);
            }
        }

        if (!string.Equals(type, "function", StringComparison.Ordinal))
        {
            // Named selection of a non-function tool is an execution capability
            // the router cannot preserve. The diagnostic names the static field
            // path only, never the rejected choice type or name.
            return RouterError.UnsupportedCapabilityAt("tool_choice.type", requestId);
        }

        if (string.IsNullOrEmpty(name))
        {
            return RouterError.InvalidRequest("function tool_choice requires a name.", "tool_choice.name", requestId);
        }

        choice = new ToolChoice { Kind = ToolChoiceKind.Function, FunctionName = name };
        return null;
    }

    private static RouterError? ParseMetadata(JsonProperty property, out Dictionary<string, string>? metadata, string? requestId)
    {
        metadata = null;
        if (property.Value.ValueKind != JsonValueKind.Object)
        {
            return RouterError.InvalidRequest("metadata must be an object.", "metadata", requestId);
        }

        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (JsonProperty child in property.Value.EnumerateObject())
        {
            if (result.Count >= MaxMetadataCount)
            {
                return RouterError.InvalidRequest("metadata exceeds the maximum entry count.", "metadata", requestId);
            }

            if (child.Name.Length is < 1 or > MaxMetadataKeyLength)
            {
                return RouterError.InvalidRequest("metadata key has an invalid length.", "metadata", requestId);
            }

            if (child.Value.ValueKind != JsonValueKind.String)
            {
                return RouterError.InvalidRequest("metadata values must be strings.", "metadata", requestId);
            }

            string value = child.Value.GetString()!;
            if (value.Length > MaxMetadataValueLength)
            {
                return RouterError.InvalidRequest("metadata value has an invalid length.", "metadata", requestId);
            }

            result[child.Name] = value;
        }

        metadata = result;
        return null;
    }

    private static RouterError? ParseModalities(JsonProperty property, string? requestId)
    {
        if (property.Value.ValueKind != JsonValueKind.Array)
        {
            return RouterError.InvalidRequest("modalities must be an array.", "modalities", requestId);
        }

        var modalities = new List<string>();
        foreach (JsonElement element in property.Value.EnumerateArray())
        {
            if (element.ValueKind != JsonValueKind.String)
            {
                return RouterError.InvalidRequest("modalities must contain strings.", "modalities", requestId);
            }

            modalities.Add(element.GetString()!);
        }

        if (modalities.Any(static m => m is "image" or "audio" or "video"))
        {
            // Image generation / audio / video output are deferred capabilities.
            // The diagnostic names the field only, never the modality value.
            return RouterError.UnsupportedCapabilityAt("modalities", requestId);
        }

        if (modalities.Count == 1 && string.Equals(modalities[0], "text", StringComparison.Ordinal))
        {
            return null;
        }

        return RouterError.UnsupportedParameter("modalities", requestId);
    }

    private static RouterError? ParseSummary(JsonProperty property, string param, out IReadOnlyList<SummaryTextPart>? summary, string? requestId)
    {
        summary = null;
        if (property.Value.ValueKind != JsonValueKind.Array)
        {
            return RouterError.InvalidRequest("summary must be an array.", param, requestId);
        }

        var parts = new List<SummaryTextPart>();
        int index = 0;
        foreach (JsonElement element in property.Value.EnumerateArray())
        {
            if (element.ValueKind != JsonValueKind.Object)
            {
                return RouterError.InvalidRequest("summary items must be objects.", $"{param}[{index}]", requestId);
            }

            if (!element.TryGetProperty("type", out JsonElement typeElement)
                || typeElement.ValueKind != JsonValueKind.String
                || !string.Equals(typeElement.GetString(), "summary_text", StringComparison.Ordinal))
            {
                return RouterError.InvalidRequest("summary items require type summary_text.", $"{param}[{index}].type", requestId);
            }

            if (!element.TryGetProperty("text", out JsonElement textElement) || textElement.ValueKind != JsonValueKind.String)
            {
                return RouterError.InvalidRequest("summary items require text.", $"{param}[{index}].text", requestId);
            }

            string text = textElement.GetString()!;
            if (text.Length > MaxTextLength)
            {
                return RouterError.InvalidRequest("summary text exceeds the maximum length.", $"{param}[{index}].text", requestId);
            }

            parts.Add(new SummaryTextPart { Type = "summary_text", Text = text });
            index++;
        }

        summary = parts;
        return null;
    }

    private static RouterError? ReadString(JsonProperty property, out string? value, int maxLength, string? requestId)
    {
        value = null;
        if (property.Value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (property.Value.ValueKind != JsonValueKind.String)
        {
            return RouterError.InvalidRequest($"{property.Name} must be a string.", property.Name, requestId);
        }

        value = property.Value.GetString()!;
        if (value.Length > maxLength)
        {
            return RouterError.InvalidRequest($"{property.Name} exceeds the maximum length.", property.Name, requestId);
        }

        return null;
    }

    private static bool IsValidToolName(string name)
        => name.Length is >= 1 and <= MaxToolNameLength
            && name.All(static c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-');

    private static bool IsBoolean(JsonValueKind kind)
        => kind is JsonValueKind.True or JsonValueKind.False;
}
