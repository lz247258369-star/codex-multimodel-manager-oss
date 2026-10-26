namespace Router.ProviderAdapters.ModelStudio.Tests;

/// <summary>
/// Deterministic, scrubbed, offline Model Studio Responses fixtures. Values are
/// synthetic; no real key, prompt, workspace secret, customer content, or
/// Authorization value is ever present. Qwen-style and DeepSeek-hosted shapes
/// are both Responses-compatible and keep model identity separate from the
/// mm_modelstudio provider identity.
/// </summary>
public static class ModelStudioFixtures
{
    public const string QwenModel = "qwen3.8-max";
    public const string DeepSeekModel = "deepseek-v4-pro";

    public static string NonStreamJson(string text = "synthetic answer")
        => """
            {"id":"resp_ms_qwen","object":"response","created_at":1752000000,"status":"completed","model":"qwen3.8-max","output":[{"id":"msg_ms_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"__TEXT__","annotations":[]}]}],"usage":{"input_tokens":7,"output_tokens":5,"total_tokens":12}}
            """.Replace("__TEXT__", text);

    public static string DeepSeekStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_ms_deepseek","object":"response","status":"in_progress","model":"deepseek-v4-pro","output":[],"usage":null}}"""),
            "event: response.output_item.added\ndata: " + Json("""{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_ms_ds","type":"message","role":"assistant","content":[]}}"""),
            "event: response.output_text.delta\ndata: " + Json("""{"type":"response.output_text.delta","item_id":"msg_ms_ds","output_index":0,"content_index":0,"delta":"synthetic"}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_ms_deepseek","object":"response","status":"completed","model":"deepseek-v4-pro","output":[{"id":"msg_ms_ds","type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic","annotations":[]}]}],"usage":{"input_tokens":11,"output_tokens":4,"total_tokens":15}}}"""),
        ]) + "\n\n";

    public static string ReasoningStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_ms_reasoning","status":"in_progress","model":"qwen3.8-max"}}"""),
            "event: response.reasoning_summary_text.delta\ndata: " + Json("""{"type":"response.reasoning_summary_text.delta","item_id":"reasoning_ms_1","summary_index":0,"delta":"synthetic"}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_ms_reasoning","status":"completed","model":"qwen3.8-max"}}"""),
        ]) + "\n\n";

    public static string ToolCallStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_ms_tool","status":"in_progress","model":"qwen3.8-max"}}"""),
            "event: response.output_item.added\ndata: " + Json("""{"type":"response.output_item.added","output_index":0,"item":{"id":"call_ms_1","type":"function_call","name":"get_weather","arguments":"{\"city\":\"shanghai\"}","call_id":"call_ms_1"}}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_ms_tool","status":"completed","model":"qwen3.8-max"}}"""),
        ]) + "\n\n";

    public static string UsageJson()
        => """
            {"id":"resp_ms_usage","object":"response","created_at":1752000000,"status":"completed","model":"deepseek-v4-pro","output":[],"usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}
            """;

    public static string ErrorEventSse()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_ms_error","status":"in_progress","model":"qwen3.8-max"}}"""),
            "event: error\ndata: " + Json("""{"type":"error","code":"provider_5xx","message":"safe provider error","param":null,"request_id":null,"retryable":false}"""),
        ]) + "\n\n";

    private static string Json(string json)
        => json;
}
