using System.Text;

namespace ProviderContractKit;

/// <summary>Builds deterministic canonical SSE fixtures for the fake upstream.</summary>
public static class SseFixtureBuilder
{
    public static string BasicStream(string text = "synthetic", string model = "fake-model")
    {
        string sse = string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_test_stream","object":"response","status":"in_progress","model":"fake-model","output":[],"usage":null}}"""),
            "event: response.output_item.added\ndata: " + Json("""{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_test_stream","type":"message","role":"assistant","content":[]}}"""),
            "event: response.output_text.delta\ndata: " + Json("""{"type":"response.output_text.delta","item_id":"msg_test_stream","output_index":0,"content_index":0,"delta":"{{text}}"}"""),
            "event: response.output_text.done\ndata: " + Json("""{"type":"response.output_text.done","item_id":"msg_test_stream","output_index":0,"content_index":0,"text":"{{text}}"}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_test_stream","object":"response","status":"completed","model":"fake-model","output":[{"id":"msg_test_stream","type":"message","role":"assistant","content":[{"type":"output_text","text":"{{text}}","annotations":[]}]}],"usage":{"input_tokens":7,"output_tokens":5,"total_tokens":12}}}"""),
        ]) + "\n\n";
        return sse.Replace("{{text}}", text);
    }

    public static string ReasoningStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_reasoning","status":"in_progress","model":"fake-model"}}"""),
            "event: response.reasoning_summary_text.delta\ndata: " + Json("""{"type":"response.reasoning_summary_text.delta","item_id":"reasoning_1","summary_index":0,"delta":"think"}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_reasoning","status":"completed","model":"fake-model"}}"""),
        ]) + "\n\n";

    public static string ToolCallStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_tool","status":"in_progress","model":"fake-model"}}"""),
            "event: response.output_item.added\ndata: " + Json("""{"type":"response.output_item.added","output_index":0,"item":{"id":"call_1","type":"function_call","name":"get_weather","arguments":"{\"city\":\"shanghai\"}","call_id":"call_1"}}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_tool","status":"completed","model":"fake-model"}}"""),
        ]) + "\n\n";

    public static string UsageStream()
        => string.Join("\n\n",
        [
            "event: response.created\ndata: " + Json("""{"type":"response.created","response":{"id":"resp_usage","status":"in_progress","model":"fake-model"}}"""),
            "event: response.completed\ndata: " + Json("""{"type":"response.completed","response":{"id":"resp_usage","status":"completed","model":"fake-model","usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}}"""),
        ]) + "\n\n";

    public static string NonStreamJson(string text = "synthetic")
    {
        string json = """
            {"id":"resp_test_nonstream","object":"response","created_at":1752000000,"status":"completed","model":"fake-model","output":[{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"{{text}}","annotations":[]}]}],"usage":{"input_tokens":7,"output_tokens":5,"total_tokens":12}}
            """;
        return json.Replace("{{text}}", text);
    }

    public static string ReasoningJson()
        => """
            {"id":"resp_reasoning","object":"response","created_at":1752000000,"status":"completed","model":"fake-model","output":[{"id":"reasoning_1","type":"reasoning","summary":[{"type":"summary_text","text":"think"}]},{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"answer","annotations":[]}]}],"usage":null}
            """;

    public static string ToolCallJson()
        => """
            {"id":"resp_tool","object":"response","created_at":1752000000,"status":"completed","model":"fake-model","output":[{"id":"call_1","type":"function_call","name":"get_weather","arguments":"{\"city\":\"shanghai\"}","call_id":"call_1"}],"usage":null}
            """;

    public static string UsageJson()
        => """
            {"id":"resp_usage","object":"response","created_at":1752000000,"status":"completed","model":"fake-model","output":[],"usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}
            """;

    public static string ProviderErrorJson()
        => """
            {"error":{"type":"provider_error","code":"provider_boom","message":"safe provider error","param":null,"request_id":null,"retryable":false}}
            """;

    private static string Json(string json)
        => json;
}
