using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;

namespace Router.ProviderAdapters.DeepSeek;

/// <summary>
/// DSR7-C-FIX5-B2: the DeepSeek-only streaming half of the apply_patch bridge.
///
/// The client-facing canonical event vocabulary is frozen and has no incremental
/// freeform tool-call event, so the streaming bridge uses the minimal safe
/// strategy: every event that belongs to the Router-owned synthetic function call
/// is buffered and validated internally, and only a fully validated call is
/// released - as one <c>response.output_item.added</c> plus one
/// <c>response.output_item.done</c> carrying the restored custom_tool_call - or the
/// whole logical response fails closed. The synthetic identity and the patch text
/// can therefore never reach the client partially, never in a wrong form, and
/// never at all when the stream is unprovable.
///
/// Ordinary events keep their relative order and are yielded by reference. The
/// event vocabulary, the SSE parser, the generic provider codec and the generic
/// providers are untouched: this gate adds no shared streaming machinery and no
/// new wire event.
/// </summary>
public static class ApplyPatchStreamBridge
{
    public const string OutputItemAddedEvent = "response.output_item.added";
    public const string OutputItemDoneEvent = "response.output_item.done";
    public const string ArgumentsDeltaEvent = "response.function_call_arguments.delta";
    public const string ArgumentsDoneEvent = "response.function_call_arguments.done";
    public const string CompletedEvent = "response.completed";
    public const string ErrorEvent = "error";

    /// <summary>Maximum synthetic calls the bridge keeps state for in one response.</summary>
    public const int MaxSyntheticCallsPerResponse = 4;

    /// <summary>
    /// Length of the smallest legal synthetic arguments object (<c>{"patch":""}</c>).
    /// </summary>
    private const int ArgumentsJsonEnvelopeLength = 12;

    /// <summary>
    /// Worst-case JSON escaping of one UTF-16 code unit: a <c>\uXXXX</c> escape is
    /// six characters, which also covers surrogate pairs (two escapes for two code
    /// units).
    /// </summary>
    private const int MaxJsonEscapedCharactersPerCodeUnit = 6;

    /// <summary>
    /// Proven per-call argument buffer bound: the JSON envelope plus the worst-case
    /// escaping of the largest patch the B1b-1 request bound admits. Any longer
    /// arguments string provably cannot decode to a legal patch, so it fails closed.
    /// </summary>
    public const int MaxSyntheticArgumentsLength =
        ArgumentsJsonEnvelopeLength + (MaxJsonEscapedCharactersPerCodeUnit * ApplyPatchRequestBridge.MaxPatchInputLength);

    /// <summary>
    /// Proven total bound for one response: the maximum number of synthetic calls
    /// times the per-call bound. Neither the call count nor the buffered bytes can
    /// grow without limit.
    /// </summary>
    public const int MaxSyntheticBufferedCharacters = MaxSyntheticCallsPerResponse * MaxSyntheticArgumentsLength;

    /// <summary>Wraps one DeepSeek upstream event stream with the restore state machine.</summary>
    public static IAsyncEnumerable<CanonicalEvent> Apply(
        IAsyncEnumerable<CanonicalEvent> upstream,
        bool bridgeIsActive,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(upstream);
        return BridgeAsync(upstream, bridgeIsActive, cancellationToken);
    }

    private static async IAsyncEnumerable<CanonicalEvent> BridgeAsync(
        IAsyncEnumerable<CanonicalEvent> upstream,
        bool bridgeIsActive,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var state = new StreamState(bridgeIsActive);
        await using IAsyncEnumerator<CanonicalEvent> enumerator = upstream.GetAsyncEnumerator(cancellationToken);

        // Upstream cancellation, idle/total timeout and stream interruption
        // exceptions propagate unchanged: the bridge never releases a buffered
        // patch, never retries and never degrades to non-stream.
        while (await enumerator.MoveNextAsync().ConfigureAwait(false))
        {
            var emitted = new List<CanonicalEvent>(2);
            if (!state.TryProcess(enumerator.Current, emitted))
            {
                // Fail closed: exactly one content-free error event terminates the
                // stream, and nothing buffered is ever released.
                yield return ErrorEventForFailClosedState();
                yield break;
            }

            foreach (CanonicalEvent canonicalEvent in emitted)
            {
                yield return canonicalEvent;
            }
        }
    }

    private static CanonicalEvent ErrorEventForFailClosedState()
    {
        RouterError error = ProviderAdapterErrors.InvalidResponse();
        return CanonicalEvent.Create(ErrorEvent, new
        {
            type = ErrorEvent,
            code = error.Code,
            message = error.Message,
            request_id = error.RequestId,
        });
    }

    /// <summary>Per-response bridge state: one bounded entry per synthetic call.</summary>
    private sealed class StreamState
    {
        private readonly bool _bridgeIsActive;
        private readonly Dictionary<string, SyntheticCall> _open = new(StringComparer.Ordinal);
        private readonly Dictionary<string, RestoredCall> _restored = new(StringComparer.Ordinal);
        private int _restoredOrdinal;
        private int _bufferedCharacters;

        public StreamState(bool bridgeIsActive)
        {
            _bridgeIsActive = bridgeIsActive;
        }

        public bool TryProcess(CanonicalEvent canonicalEvent, List<CanonicalEvent> emitted)
        {
            ArgumentNullException.ThrowIfNull(canonicalEvent);

            switch (canonicalEvent.Type)
            {
                case OutputItemAddedEvent:
                    return TryHandleItemAdded(canonicalEvent, emitted);
                case OutputItemDoneEvent:
                    return TryHandleItemDone(canonicalEvent, emitted);
                case ArgumentsDeltaEvent:
                    return TryHandleArgumentsDelta(canonicalEvent, emitted);
                case ArgumentsDoneEvent:
                    return TryHandleArgumentsDone(canonicalEvent, emitted);
                case CompletedEvent:
                    return TryHandleCompleted(canonicalEvent, emitted);
                default:
                    // Every other event - created, in_progress, text, reasoning,
                    // failed, error, and any unknown type - is passed through
                    // unchanged; its own semantics stay exactly as before.
                    emitted.Add(canonicalEvent);
                    return true;
            }
        }

        private bool TryHandleItemAdded(CanonicalEvent canonicalEvent, List<CanonicalEvent> emitted)
        {
            if (!_bridgeIsActive)
            {
                // Outside the bridge an event is only inspected for the reserved
                // identity, so ordinary streaming behaviour cannot regress.
                return !MentionsSyntheticName(canonicalEvent.Data, "item") && Add(emitted, canonicalEvent);
            }

            if (!TryReadItemIdentity(canonicalEvent.Data, "item", out ItemIdentity identity))
            {
                return false;
            }

            if (!identity.MentionsSyntheticName)
            {
                // An ordinary item may never reuse an open synthetic identity.
                if (identity.Id is { Length: > 0 } ordinaryId
                    && (_open.ContainsKey(ordinaryId) || _restored.ContainsKey(ordinaryId)))
                {
                    return false;
                }

                emitted.Add(canonicalEvent);
                return true;
            }

            if (!string.Equals(identity.Type, "function_call", StringComparison.Ordinal)
                || string.IsNullOrEmpty(identity.Id)
                || string.IsNullOrWhiteSpace(identity.CallId)
                || _open.Count >= MaxSyntheticCallsPerResponse)
            {
                return false;
            }

            if (_open.ContainsKey(identity.Id!)
                || _open.Values.Any(call => string.Equals(call.CallId, identity.CallId, StringComparison.Ordinal))
                || _restored.ContainsKey(identity.Id!))
            {
                // A duplicate start, a reused call id, or a reused item id can
                // never be resolved into a unique call.
                return false;
            }

            _open.Add(identity.Id!, new SyntheticCall
            {
                ItemId = identity.Id!,
                CallId = identity.CallId!,
                OutputIndex = ReadOutputIndex(canonicalEvent.Data),
            });
            return true;
        }

        private bool TryHandleItemDone(CanonicalEvent canonicalEvent, List<CanonicalEvent> emitted)
        {
            if (!_bridgeIsActive)
            {
                return !MentionsSyntheticName(canonicalEvent.Data, "item") && Add(emitted, canonicalEvent);
            }

            if (!TryReadItemIdentity(canonicalEvent.Data, "item", out ItemIdentity identity))
            {
                return false;
            }

            SyntheticCall? call = FindOpen(identity);
            if (call is null)
            {
                // A reserved identity that matches no open call is a late, unknown
                // or duplicated completion; an ordinary item passes through.
                if (identity.MentionsSyntheticName)
                {
                    return false;
                }

                emitted.Add(canonicalEvent);
                return true;
            }

            if (!string.Equals(identity.Type, "function_call", StringComparison.Ordinal)
                || !string.Equals(identity.Name, ApplyPatchBridgeContract.SyntheticFunctionName, StringComparison.Ordinal)
                || !string.Equals(identity.Id, call.ItemId, StringComparison.Ordinal)
                || !string.Equals(identity.CallId, call.CallId, StringComparison.Ordinal)
                || call.Completed)
            {
                // Identity mutation, a mismatched call id or a duplicate completion.
                return false;
            }

            if (!TryResolveArguments(call, identity.Arguments, out string arguments)
                || !ApplyPatchResponseBridge.TryDecodePatch(arguments, out string patch))
            {
                return false;
            }

            Restore(call, patch, emitted);
            return true;
        }

        private bool TryHandleArgumentsDelta(CanonicalEvent canonicalEvent, List<CanonicalEvent> emitted)
        {
            if (!_bridgeIsActive)
            {
                return Add(emitted, canonicalEvent);
            }

            SyntheticCall? call = FindByEventReference(canonicalEvent.Data);
            if (call is null)
            {
                // Not ours: ordinary function-call argument events keep their
                // existing (pre-B2) behaviour.
                return Add(emitted, canonicalEvent);
            }

            if (call.Completed || !TryReadString(canonicalEvent.Data, "delta", out string? delta))
            {
                return false;
            }

            if (call.Deltas.Length + delta!.Length > MaxSyntheticArgumentsLength
                || _bufferedCharacters + delta.Length > MaxSyntheticBufferedCharacters)
            {
                return false;
            }

            call.Deltas.Append(delta);
            _bufferedCharacters += delta.Length;
            return true;
        }

        private bool TryHandleArgumentsDone(CanonicalEvent canonicalEvent, List<CanonicalEvent> emitted)
        {
            if (!_bridgeIsActive)
            {
                return Add(emitted, canonicalEvent);
            }

            SyntheticCall? call = FindByEventReference(canonicalEvent.Data);
            if (call is null)
            {
                return Add(emitted, canonicalEvent);
            }

            if (call.Completed
                || call.ArgumentsDone is not null
                || !TryReadString(canonicalEvent.Data, "arguments", out string? arguments)
                || arguments!.Length > MaxSyntheticArgumentsLength)
            {
                return false;
            }

            call.ArgumentsDone = arguments;
            return true;
        }

        private bool TryHandleCompleted(CanonicalEvent canonicalEvent, List<CanonicalEvent> emitted)
        {
            if (!_bridgeIsActive)
            {
                // Injection defence: a reserved identity in the terminal body may
                // never be handed to the client.
                return !TerminalMentionsSyntheticName(canonicalEvent.Data) && Add(emitted, canonicalEvent);
            }

            // Terminal synthetic items are resolved before anything is emitted, so
            // a malformed terminal can never leave a partial result behind.
            if (!TryReadTerminalItems(canonicalEvent.Data, out List<TerminalItem> terminalItems))
            {
                return false;
            }

            // Every call that the stream started must be provably completed by the
            // terminal body; otherwise its lifecycle is incomplete.
            foreach (SyntheticCall call in _open.Values.Where(static call => !call.Completed).ToArray())
            {
                TerminalItem? terminal = terminalItems.FirstOrDefault(
                    item => string.Equals(item.ItemId, call.ItemId, StringComparison.Ordinal));
                if (terminal is null)
                {
                    return false;
                }

                if (!string.Equals(terminal.CallId, call.CallId, StringComparison.Ordinal)
                    || !TryResolveArguments(call, terminal.Arguments, out string arguments)
                    || !ApplyPatchResponseBridge.TryDecodePatch(arguments, out string patch))
                {
                    return false;
                }

                Restore(call, patch, emitted);
            }

            // The streamed restore and the terminal body must agree on identity and
            // patch; neither is simply trusted over the other.
            var replacements = new Dictionary<string, CustomToolCallResponseItem>(StringComparer.Ordinal);
            foreach (TerminalItem terminal in terminalItems)
            {
                if (!_restored.TryGetValue(terminal.ItemId, out RestoredCall? restored)
                    || !string.Equals(restored.CallId, terminal.CallId, StringComparison.Ordinal)
                    || !ApplyPatchResponseBridge.TryDecodePatch(terminal.Arguments ?? string.Empty, out string terminalPatch)
                    || !string.Equals(restored.Patch, terminalPatch, StringComparison.Ordinal))
                {
                    return false;
                }

                replacements[terminal.ItemId] = restored.Item;
            }

            emitted.Add(replacements.Count == 0
                ? canonicalEvent
                : RewriteCompleted(canonicalEvent, replacements));
            return true;
        }

        private void Restore(SyntheticCall call, string patch, List<CanonicalEvent> emitted)
        {
            var item = new CustomToolCallResponseItem
            {
                Type = ApplyPatchBridgeContract.ClientToolCallType,
                Id = call.ItemId,
                CallId = call.CallId,
                Name = ApplyPatchBridgeContract.ApplyPatchToolName,
                Input = patch,
            };

            int outputIndex = call.OutputIndex ?? _restoredOrdinal;
            call.Completed = true;
            _restored[call.ItemId] = new RestoredCall(call.ItemId, call.CallId, patch, item);
            _restoredOrdinal++;

            // One complete item, released only now that every field is proven.
            emitted.Add(OutputItemEvent(OutputItemAddedEvent, outputIndex, item));
            emitted.Add(OutputItemEvent(OutputItemDoneEvent, outputIndex, item));
        }

        private static CanonicalEvent OutputItemEvent(string eventType, int outputIndex, CustomToolCallResponseItem item)
            => CanonicalEvent.Create(eventType, new OutputItemPayload
            {
                Type = eventType,
                OutputIndex = outputIndex,
                Item = item,
            });

        private static CanonicalEvent RewriteCompleted(
            CanonicalEvent canonicalEvent,
            IReadOnlyDictionary<string, CustomToolCallResponseItem> replacements)
        {
            using var buffer = new MemoryStream();
            using (var writer = new Utf8JsonWriter(buffer))
            {
                writer.WriteStartObject();
                foreach (JsonProperty property in canonicalEvent.Data.EnumerateObject())
                {
                    if (property.NameEquals("response") && property.Value.ValueKind == JsonValueKind.Object)
                    {
                        writer.WritePropertyName(property.Name);
                        WriteRewrittenResponse(writer, property.Value, replacements);
                        continue;
                    }

                    property.WriteTo(writer);
                }

                writer.WriteEndObject();
            }

            using JsonDocument document = JsonDocument.Parse(buffer.ToArray());
            return CanonicalEvent.Create(CompletedEvent, document.RootElement.Clone());
        }

        private static void WriteRewrittenResponse(
            Utf8JsonWriter writer,
            JsonElement responseBody,
            IReadOnlyDictionary<string, CustomToolCallResponseItem> replacements)
        {
            writer.WriteStartObject();
            foreach (JsonProperty property in responseBody.EnumerateObject())
            {
                if (property.NameEquals("output") && property.Value.ValueKind == JsonValueKind.Array)
                {
                    writer.WritePropertyName(property.Name);
                    writer.WriteStartArray();
                    foreach (JsonElement item in property.Value.EnumerateArray())
                    {
                        string? itemId = item.ValueKind == JsonValueKind.Object && item.TryGetProperty("id", out JsonElement id)
                            && id.ValueKind == JsonValueKind.String
                                ? id.GetString()
                                : null;
                        if (itemId is not null && replacements.TryGetValue(itemId, out CustomToolCallResponseItem? replacement))
                        {
                            JsonSerializer.Serialize(writer, replacement, ResponsesJson.Options);
                            continue;
                        }

                        item.WriteTo(writer);
                    }

                    writer.WriteEndArray();
                    continue;
                }

                property.WriteTo(writer);
            }

            writer.WriteEndObject();
        }

        private SyntheticCall? FindOpen(ItemIdentity identity)
        {
            if (identity.Id is { Length: > 0 } id && _open.TryGetValue(id, out SyntheticCall? byId))
            {
                return byId;
            }

            return identity.CallId is { Length: > 0 } callId
                ? _open.Values.FirstOrDefault(call => string.Equals(call.CallId, callId, StringComparison.Ordinal))
                : null;
        }

        private SyntheticCall? FindByEventReference(JsonElement data)
        {
            if (TryReadString(data, "item_id", out string? itemId)
                && itemId is { Length: > 0 }
                && _open.TryGetValue(itemId, out SyntheticCall? byItemId))
            {
                return byItemId;
            }

            if (TryReadString(data, "call_id", out string? callId) && callId is { Length: > 0 })
            {
                return _open.Values.FirstOrDefault(call => string.Equals(call.CallId, callId, StringComparison.Ordinal));
            }

            return null;
        }

        /// <summary>
        /// Every available argument source must agree; the call is only provable
        /// when at least one source exists. Disagreement is interleaving corruption.
        /// </summary>
        private static bool TryResolveArguments(SyntheticCall call, string? itemArguments, out string arguments)
        {
            arguments = string.Empty;
            string? resolved = null;

            foreach (string? candidate in new[] { call.ArgumentsDone, call.Deltas.Length > 0 ? call.Deltas.ToString() : null, itemArguments })
            {
                if (candidate is null)
                {
                    continue;
                }

                if (resolved is not null && !string.Equals(resolved, candidate, StringComparison.Ordinal))
                {
                    return false;
                }

                resolved = candidate;
            }

            if (resolved is null || resolved.Length > MaxSyntheticArgumentsLength)
            {
                return false;
            }

            arguments = resolved;
            return true;
        }

        private static bool TryReadTerminalItems(JsonElement data, out List<TerminalItem> items)
        {
            items = [];
            if (data.ValueKind != JsonValueKind.Object
                || !data.TryGetProperty("response", out JsonElement responseBody)
                || responseBody.ValueKind != JsonValueKind.Object
                || !responseBody.TryGetProperty("output", out JsonElement output)
                || output.ValueKind != JsonValueKind.Array)
            {
                return true;
            }

            foreach (JsonElement element in output.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.Object
                    || !TryReadItemIdentity(element, null, out ItemIdentity identity))
                {
                    return false;
                }

                if (!identity.MentionsSyntheticName)
                {
                    continue;
                }

                if (!string.Equals(identity.Type, "function_call", StringComparison.Ordinal)
                    || string.IsNullOrEmpty(identity.Id)
                    || items.Any(item => string.Equals(item.ItemId, identity.Id, StringComparison.Ordinal)))
                {
                    return false;
                }

                items.Add(new TerminalItem(identity.Id!, identity.CallId, identity.Arguments));
            }

            return true;
        }

        /// <summary>
        /// Reads one output item identity. Duplicated identity fields make the item
        /// ambiguous - the Router can never prove which value the upstream meant -
        /// and fail closed.
        /// </summary>
        private static bool TryReadItemIdentity(JsonElement data, string? containerName, out ItemIdentity identity)
        {
            identity = default;
            JsonElement item = data;
            if (containerName is not null)
            {
                if (data.ValueKind != JsonValueKind.Object
                    || !data.TryGetProperty(containerName, out item)
                    || item.ValueKind != JsonValueKind.Object)
                {
                    return false;
                }
            }

            if (item.ValueKind != JsonValueKind.Object)
            {
                return false;
            }

            string? itemType = null;
            string? itemId = null;
            string? itemCallId = null;
            string? itemName = null;
            string? itemArguments = null;
            foreach (JsonProperty property in item.EnumerateObject())
            {
                string propertyName = property.Name;
                if (propertyName is not ("type" or "id" or "call_id" or "name" or "arguments"))
                {
                    continue;
                }

                if (property.Value.ValueKind is not (JsonValueKind.String or JsonValueKind.Null))
                {
                    return false;
                }

                string? value = property.Value.ValueKind == JsonValueKind.String ? property.Value.GetString() : null;
                switch (propertyName)
                {
                    case "type":
                        if (itemType is not null)
                        {
                            return false;
                        }

                        itemType = value;
                        break;
                    case "id":
                        if (itemId is not null)
                        {
                            return false;
                        }

                        itemId = value;
                        break;
                    case "call_id":
                        if (itemCallId is not null)
                        {
                            return false;
                        }

                        itemCallId = value;
                        break;
                    case "name":
                        if (itemName is not null)
                        {
                            // A duplicated identity field is ambiguous, never last-wins.
                            return false;
                        }

                        itemName = value;
                        break;
                    default:
                        if (itemArguments is not null)
                        {
                            return false;
                        }

                        itemArguments = value;
                        break;
                }
            }

            identity = new ItemIdentity(itemType, itemId, itemCallId, itemName, itemArguments);
            return true;
        }

        /// <summary>
        /// Injection scan used when the bridge is not active: true when any name
        /// field of the item - including a duplicated one - is the exact reserved
        /// identity. Nothing else about the event is inspected, so ordinary
        /// streaming semantics stay exactly as they were.
        /// </summary>
        private static bool MentionsSyntheticName(JsonElement data, string containerName)
        {
            if (data.ValueKind != JsonValueKind.Object
                || !data.TryGetProperty(containerName, out JsonElement item)
                || item.ValueKind != JsonValueKind.Object)
            {
                return false;
            }

            foreach (JsonProperty property in item.EnumerateObject())
            {
                if (property.NameEquals("name")
                    && property.Value.ValueKind == JsonValueKind.String
                    && ApplyPatchBridgeContract.IsReservedSyntheticName(property.Value.GetString()))
                {
                    return true;
                }
            }

            return false;
        }

        private static bool TerminalMentionsSyntheticName(JsonElement data)
        {
            if (data.ValueKind != JsonValueKind.Object
                || !data.TryGetProperty("response", out JsonElement responseBody)
                || responseBody.ValueKind != JsonValueKind.Object
                || !responseBody.TryGetProperty("output", out JsonElement output)
                || output.ValueKind != JsonValueKind.Array)
            {
                return false;
            }

            foreach (JsonElement item in output.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                foreach (JsonProperty property in item.EnumerateObject())
                {
                    if (property.NameEquals("name")
                        && property.Value.ValueKind == JsonValueKind.String
                        && ApplyPatchBridgeContract.IsReservedSyntheticName(property.Value.GetString()))
                    {
                        return true;
                    }
                }
            }

            return false;
        }

        private static bool Add(List<CanonicalEvent> emitted, CanonicalEvent canonicalEvent)
        {
            emitted.Add(canonicalEvent);
            return true;
        }

        private static bool TryReadString(JsonElement data, string name, out string? value)
        {
            value = null;
            if (data.ValueKind != JsonValueKind.Object || !data.TryGetProperty(name, out JsonElement element))
            {
                return false;
            }

            if (element.ValueKind != JsonValueKind.String)
            {
                return false;
            }

            value = element.GetString();
            return true;
        }

        private static int? ReadOutputIndex(JsonElement data)
            => data.ValueKind == JsonValueKind.Object
                && data.TryGetProperty("output_index", out JsonElement element)
                && element.ValueKind == JsonValueKind.Number
                && element.TryGetInt32(out int value)
                    ? value
                    : null;
    }

    /// <summary>One synthetic call the bridge is currently buffering.</summary>
    private sealed class SyntheticCall
    {
        public required string ItemId { get; init; }

        public required string CallId { get; init; }

        public int? OutputIndex { get; init; }

        public StringBuilder Deltas { get; } = new();

        public string? ArgumentsDone { get; set; }

        public bool Completed { get; set; }
    }

    /// <summary>One restored call, kept for terminal consistency validation.</summary>
    private sealed record RestoredCall(string ItemId, string CallId, string Patch, CustomToolCallResponseItem Item);

    /// <summary>One synthetic item carried by the terminal response body.</summary>
    private sealed record TerminalItem(string ItemId, string? CallId, string? Arguments);

    /// <summary>Identity fields of one output item; duplicates fail closed.</summary>
    private readonly record struct ItemIdentity(
        string? Type,
        string? Id,
        string? CallId,
        string? Name,
        string? Arguments)
    {
        public bool MentionsSyntheticName
            => string.Equals(Name, ApplyPatchBridgeContract.SyntheticFunctionName, StringComparison.Ordinal);
    }

    /// <summary>The client-facing output-item event payload.</summary>
    private sealed record OutputItemPayload
    {
        public required string Type { get; init; }

        [JsonPropertyName("output_index")]
        public required int OutputIndex { get; init; }

        public required CustomToolCallResponseItem Item { get; init; }
    }
}
