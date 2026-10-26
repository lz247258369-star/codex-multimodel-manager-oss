namespace Router.ProviderAdapters.MiMo.Tests;

/// <summary>
/// Deterministic, scrubbed, offline Xiaomi MiMo Responses fixtures. Values are
/// synthetic; no real key, prompt, customer content, or Authorization value is
/// ever present. Model strings stay synthetic (<c>mimo-v2.5-pro</c> /
/// <c>mimo-v2.5</c>) and never select or rewrite a provider route.
/// </summary>
public static class MiMoFixtures
{
    public const string ProModel = "mimo-v2.5-pro";
    public const string StandardModel = "mimo-v2.5";

    public static string NonStreamJson(string text = "synthetic answer")
        => """
            {"id":"resp_mimo_nonstream","object":"response","created_at":1752000000,"status":"completed","model":"mimo-v2.5-pro","output":[{"id":"msg_mimo_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"__TEXT__","annotations":[]}]}],"usage":{"input_tokens":7,"output_tokens":5,"total_tokens":12}}
            """.Replace("__TEXT__", text);

    public static string StandardStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_mimo_stream","object":"response","status":"in_progress","model":"mimo-v2.5-pro","output":[],"usage":null}}"""),
            "event: response.output_item.added\ndata: " + Json("""{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_mimo_stream","type":"message","role":"assistant","content":[]}}"""),
            "event: response.output_text.delta\ndata: " + Json("""{"type":"response.output_text.delta","item_id":"msg_mimo_stream","output_index":0,"content_index":0,"delta":"synthetic"}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_mimo_stream","object":"response","status":"completed","model":"mimo-v2.5-pro","output":[{"id":"msg_mimo_stream","type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic","annotations":[]}]}],"usage":{"input_tokens":11,"output_tokens":4,"total_tokens":15}}}"""),
        ]) + "\n\n";

    public static string ReasoningStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_mimo_reasoning","status":"in_progress","model":"mimo-v2.5-pro"}}"""),
            "event: response.reasoning_summary_text.delta\ndata: " + Json("""{"type":"response.reasoning_summary_text.delta","item_id":"reasoning_mimo_1","summary_index":0,"delta":"synthetic"}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_mimo_reasoning","status":"completed","model":"mimo-v2.5-pro"}}"""),
        ]) + "\n\n";

    public static string ToolCallStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_mimo_tool","status":"in_progress","model":"mimo-v2.5-pro"}}"""),
            "event: response.output_item.added\ndata: " + Json("""{"type":"response.output_item.added","output_index":0,"item":{"id":"call_mimo_1","type":"function_call","name":"get_weather","arguments":"{\"city\":\"shanghai\"}","call_id":"call_mimo_1"}}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_mimo_tool","status":"completed","model":"mimo-v2.5-pro"}}"""),
        ]) + "\n\n";

    public static string UsageJson()
        => """
            {"id":"resp_mimo_usage","object":"response","created_at":1752000000,"status":"completed","model":"mimo-v2.5-pro","output":[],"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":30},"output_tokens":50,"output_tokens_details":{"reasoning_tokens":12},"total_tokens":150}}
            """;

    public static string UsageWithoutDetailsJson()
        => """
            {"id":"resp_mimo_usage_flat","object":"response","created_at":1752000000,"status":"completed","model":"mimo-v2.5-pro","output":[],"usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}
            """;

    public static string ErrorEventSse()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_mimo_error","status":"in_progress","model":"mimo-v2.5-pro"}}"""),
            "event: error\ndata: " + Json("""{"type":"error","code":"provider_5xx","message":"safe provider error","param":null,"request_id":null,"retryable":false}"""),
        ]) + "\n\n";

    private static string Json(string json)
        => json;
}
