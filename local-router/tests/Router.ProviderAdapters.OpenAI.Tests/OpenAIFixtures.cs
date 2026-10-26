namespace Router.ProviderAdapters.OpenAI.Tests;

/// <summary>
/// Deterministic, scrubbed, offline OpenAI API Responses fixtures. Values are
/// synthetic; no real key, prompt, project ID, user data, or Authorization
/// value is ever present. Usage shapes follow the real OpenAI Responses API
/// (nested cached/reasoning token details) using synthetic numbers only.
/// </summary>
public static class OpenAIFixtures
{
    public const string Gpt56Model = "gpt-5.6";
    public const string TerraModel = "gpt-5.6-terra";
    public const string LunaModel = "gpt-5.6-luna";

    public static string NonStreamJson(string text = "synthetic answer")
        => """
            {"id":"resp_oai_gpt56","object":"response","created_at":1752000000,"status":"completed","model":"gpt-5.6","output":[{"id":"msg_oai_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"__TEXT__","annotations":[]}]}],"usage":{"input_tokens":7,"input_tokens_details":{"cached_tokens":2},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":1},"total_tokens":12}}
            """.Replace("__TEXT__", text);

    public static string TerraStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_oai_terra","object":"response","status":"in_progress","model":"gpt-5.6-terra","output":[],"usage":null}}"""),
            "event: response.output_item.added\ndata: " + Json("""{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_oai_terra","type":"message","role":"assistant","content":[]}}"""),
            "event: response.output_text.delta\ndata: " + Json("""{"type":"response.output_text.delta","item_id":"msg_oai_terra","output_index":0,"content_index":0,"delta":"synthetic"}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_oai_terra","object":"response","status":"completed","model":"gpt-5.6-terra","output":[{"id":"msg_oai_terra","type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic","annotations":[]}]}],"usage":{"input_tokens":11,"output_tokens":4,"total_tokens":15}}}"""),
        ]) + "\n\n";

    public static string ReasoningStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_oai_reasoning","status":"in_progress","model":"gpt-5.6"}}"""),
            "event: response.reasoning_summary_text.delta\ndata: " + Json("""{"type":"response.reasoning_summary_text.delta","item_id":"reasoning_oai_1","summary_index":0,"delta":"synthetic"}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_oai_reasoning","status":"completed","model":"gpt-5.6"}}"""),
        ]) + "\n\n";

    public static string ToolCallStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_oai_tool","status":"in_progress","model":"gpt-5.6"}}"""),
            "event: response.output_item.added\ndata: " + Json("""{"type":"response.output_item.added","output_index":0,"item":{"id":"call_oai_1","type":"function_call","name":"get_weather","arguments":"{\"city\":\"shanghai\"}","call_id":"call_oai_1"}}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_oai_tool","status":"completed","model":"gpt-5.6"}}"""),
        ]) + "\n\n";

    public static string UsageJson()
        => """
            {"id":"resp_oai_usage","object":"response","created_at":1752000000,"status":"completed","model":"gpt-5.6","output":[],"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":30},"output_tokens":50,"output_tokens_details":{"reasoning_tokens":12},"total_tokens":150}}
            """;

    public static string UsageWithoutDetailsJson()
        => """
            {"id":"resp_oai_usage_flat","object":"response","created_at":1752000000,"status":"completed","model":"gpt-5.6","output":[],"usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}
            """;

    public static string ErrorEventSse()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_oai_error","status":"in_progress","model":"gpt-5.6"}}"""),
            "event: error\ndata: " + Json("""{"type":"error","code":"provider_5xx","message":"safe provider error","param":null,"request_id":null,"retryable":false}"""),
        ]) + "\n\n";

    private static string Json(string json)
        => json;
}
