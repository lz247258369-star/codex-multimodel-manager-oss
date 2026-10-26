namespace Router.ProviderAdapters.DeepSeek.Tests;

/// <summary>
/// Deterministic, scrubbed, offline DeepSeek official Responses fixtures. Values
/// are synthetic; no real key, prompt, customer content, or Authorization value
/// is ever present. Model strings are the official upstream IDs
/// (<c>deepseek-v4-pro</c> / <c>deepseek-flash</c>) and never select or rewrite a
/// provider route; the adapter applies no client-slug aliasing of its own.
/// </summary>
public static class DeepSeekFixtures
{
    public const string ProModel = "deepseek-v4-pro";
    public const string FlashModel = "deepseek-flash";

    public static string NonStreamJson(string text = "synthetic answer")
        => """
            {"id":"resp_deepseek_nonstream","object":"response","created_at":1752000000,"status":"completed","model":"deepseek-v4-pro","output":[{"id":"msg_deepseek_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"__TEXT__","annotations":[]}]}],"usage":{"input_tokens":7,"output_tokens":5,"total_tokens":12}}
            """.Replace("__TEXT__", text);

    public static string StandardStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + """{"type":"response.created","response":{"id":"resp_deepseek_stream","object":"response","status":"in_progress","model":"deepseek-v4-pro","output":[],"usage":null}}""",
            "event: response.output_item.added\ndata: " + """{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_deepseek_stream","type":"message","role":"assistant","content":[]}}""",
            "event: response.output_text.delta\ndata: " + """{"type":"response.output_text.delta","item_id":"msg_deepseek_stream","output_index":0,"content_index":0,"delta":"synthetic"}""",
            "event: response.completed\ndata: " + """{"type":"response.completed","response":{"id":"resp_deepseek_stream","object":"response","status":"completed","model":"deepseek-v4-pro","output":[{"id":"msg_deepseek_stream","type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic","annotations":[]}]}],"usage":{"input_tokens":11,"output_tokens":4,"total_tokens":15}}}""",
        ]) + "\n\n";

    public static string FlashStream()
        => StandardStream()
            .Replace("deepseek-v4-pro", FlashModel, StringComparison.Ordinal)
            .Replace("resp_deepseek_stream", "resp_deepseek_flash_stream", StringComparison.Ordinal)
            .Replace("msg_deepseek_stream", "msg_deepseek_flash_stream", StringComparison.Ordinal);

    public static string ReasoningStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + """{"type":"response.created","response":{"id":"resp_deepseek_reasoning","status":"in_progress","model":"deepseek-v4-pro"}}""",
            "event: response.reasoning_summary_text.delta\ndata: " + """{"type":"response.reasoning_summary_text.delta","item_id":"reasoning_deepseek_1","summary_index":0,"delta":"synthetic"}""",
            "event: response.completed\ndata: " + """{"type":"response.completed","response":{"id":"resp_deepseek_reasoning","status":"completed","model":"deepseek-v4-pro"}}""",
        ]) + "\n\n";

    public static string ToolCallStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + """{"type":"response.created","response":{"id":"resp_deepseek_tool","status":"in_progress","model":"deepseek-v4-pro"}}""",
            "event: response.output_item.added\ndata: " + """{"type":"response.output_item.added","output_index":0,"item":{"id":"call_deepseek_1","type":"function_call","name":"get_weather","arguments":"{\"city\":\"shanghai\"}","call_id":"call_deepseek_1"}}""",
            "event: response.function_call_arguments.delta\ndata: " + """{"type":"response.function_call_arguments.delta","item_id":"call_deepseek_1","output_index":0,"delta":"{\"city\":"}""",
            "event: response.completed\ndata: " + """{"type":"response.completed","response":{"id":"resp_deepseek_tool","status":"completed","model":"deepseek-v4-pro"}}""",
        ]) + "\n\n";

    public static string IncompleteStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + """{"type":"response.created","response":{"id":"resp_deepseek_incomplete","status":"in_progress","model":"deepseek-v4-pro"}}""",
            "event: response.incomplete\ndata: " + """{"type":"response.incomplete","response":{"id":"resp_deepseek_incomplete","status":"incomplete","model":"deepseek-v4-pro"}}""",
        ]) + "\n\n";

    public static string FailedStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + """{"type":"response.created","response":{"id":"resp_deepseek_failed","status":"in_progress","model":"deepseek-v4-pro"}}""",
            "event: response.failed\ndata: " + """{"type":"response.failed","response":{"id":"resp_deepseek_failed","status":"failed","model":"deepseek-v4-pro","error":{"code":"server_error","message":"synthetic failure"}}}""",
        ]) + "\n\n";

    public static string UsageJson()
        => """
            {"id":"resp_deepseek_usage","object":"response","created_at":1752000000,"status":"completed","model":"deepseek-v4-pro","output":[],"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":30},"output_tokens":50,"output_tokens_details":{"reasoning_tokens":12},"total_tokens":150}}
            """;

    public static string UsageWithoutDetailsJson()
        => """
            {"id":"resp_deepseek_usage_flat","object":"response","created_at":1752000000,"status":"completed","model":"deepseek-v4-pro","output":[],"usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}
            """;

    public static string ErrorEventSse()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + """{"type":"response.created","response":{"id":"resp_deepseek_error","status":"in_progress","model":"deepseek-v4-pro"}}""",
            "event: error\ndata: " + """{"type":"error","code":"provider_5xx","message":"safe provider error","param":null,"request_id":null,"retryable":false}""",
        ]) + "\n\n";
}
