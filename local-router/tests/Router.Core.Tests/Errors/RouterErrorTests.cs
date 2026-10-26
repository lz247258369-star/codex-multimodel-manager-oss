using Router.Core.Errors;
using Xunit;

namespace Router.Core.Tests.Errors;

public sealed class RouterErrorTests
{
    [Fact]
    public void Route_not_found_matches_the_golden_envelope()
    {
        const string requestId = "req_018f0000-0000-7000-8000-000000000000";

        string json = RouterError.RouteNotFound(requestId).ToJson();

        Assert.Equal(
            "{\"type\":\"router_error\",\"code\":\"route_not_found\","
            + "\"message\":\"No eligible route is configured for this request.\","
            + "\"param\":\"model\",\"request_id\":\"req_018f0000-0000-7000-8000-000000000000\","
            + "\"retryable\":false}",
            json);
    }

    [Fact]
    public void Serialization_is_stable_for_identical_errors()
    {
        RouterError first = RouterError.UnsupportedCapability("req_a");
        RouterError second = RouterError.UnsupportedCapability("req_a");

        Assert.Equal(first.ToJson(), second.ToJson());
        Assert.Equal(first.ToJson(), first.ToJson());
    }

    [Fact]
    public void Different_errors_serialize_differently()
    {
        Assert.NotEqual(
            RouterError.RouteNotFound().ToJson(),
            RouterError.RouteDisabled().ToJson());
    }

    // DSR7-C-FIX1 CASE A: the legacy single-argument call keeps param = null, so
    // every existing caller stays byte/semantically compatible.
    [Fact]
    public void Legacy_unsupported_capability_keeps_a_null_param()
    {
        RouterError error = RouterError.UnsupportedCapability("req_123");

        Assert.Equal(RouterErrorCode.UnsupportedCapability, error.Code);
        Assert.Equal("The route cannot preserve the required semantics.", error.Message);
        Assert.Null(error.Param);
        Assert.Equal("req_123", error.RequestId);
        Assert.False(error.Retryable);
        Assert.Contains("\"param\":null", error.ToJson(), StringComparison.Ordinal);
    }

    // DSR7-C-FIX1 CASE B: the diagnostic helper names only the safe field path
    // and keeps every other part of the envelope identical.
    [Fact]
    public void Diagnostic_unsupported_capability_names_a_safe_field_path()
    {
        RouterError error = RouterError.UnsupportedCapabilityAt("tools[0].type", "req_456");

        Assert.Equal(RouterErrorCode.UnsupportedCapability, error.Code);
        Assert.Equal("The route cannot preserve the required semantics.", error.Message);
        Assert.Equal("tools[0].type", error.Param);
        Assert.Equal("req_456", error.RequestId);
        Assert.False(error.Retryable);
    }

    // DSR7-C-FIX1 CASE C: serialization emits the exact safe path and adds no
    // new envelope fields.
    [Fact]
    public void Diagnostic_unsupported_capability_serializes_the_exact_param()
    {
        string json = RouterError.UnsupportedCapabilityAt("tools[0].type", "req_456").ToJson();

        Assert.Equal(
            "{\"type\":\"router_error\",\"code\":\"unsupported_capability\","
            + "\"message\":\"The route cannot preserve the required semantics.\","
            + "\"param\":\"tools[0].type\",\"request_id\":\"req_456\","
            + "\"retryable\":false}",
            json);
        Assert.Equal(
            json.Replace("\"param\":\"tools[0].type\"", "\"param\":null", StringComparison.Ordinal),
            RouterError.UnsupportedCapability("req_456").ToJson());
    }

    // DSR7-C-FIX3: the internal classification must never reach the wire. The
    // envelope keeps exactly the six original fields.
    [Fact]
    public void Internal_diagnostic_class_is_never_serialized()
    {
        RouterError error = RouterError.UnsupportedCapabilityAtClassified("tools[6].type", "local_shell", "req_789");

        Assert.Equal("local_shell", error.SafeDiagnosticClass);
        Assert.Equal("tools[6].type", error.Param);
        Assert.Equal("req_789", error.RequestId);
        Assert.Equal(RouterErrorCode.UnsupportedCapability, error.Code);
        Assert.False(error.Retryable);

        string json = error.ToJson();
        Assert.Equal(
            "{\"type\":\"router_error\",\"code\":\"unsupported_capability\","
            + "\"message\":\"The route cannot preserve the required semantics.\","
            + "\"param\":\"tools[6].type\",\"request_id\":\"req_789\","
            + "\"retryable\":false}",
            json);
        Assert.DoesNotContain("safe_class", json, StringComparison.Ordinal);
        Assert.DoesNotContain("safe_diagnostic_class", json, StringComparison.Ordinal);
        Assert.DoesNotContain("local_shell", json, StringComparison.Ordinal);
    }

    // The legacy two-argument helper keeps its exact semantics and carries no class.
    [Fact]
    public void Legacy_diagnostic_helper_stays_unclassified()
    {
        RouterError error = RouterError.UnsupportedCapabilityAt("tools[0].type", "req_456");

        Assert.Null(error.SafeDiagnosticClass);
        Assert.Equal("tools[0].type", error.Param);
        Assert.Equal("req_456", error.RequestId);
    }

    [Fact]
    public void Code_constants_match_the_contract_table()
    {
        Assert.Equal("invalid_request", RouterErrorCode.InvalidRequest);
        Assert.Equal("unsupported_parameter", RouterErrorCode.UnsupportedParameter);
        Assert.Equal("unsupported_capability", RouterErrorCode.UnsupportedCapability);
        Assert.Equal("route_not_found", RouterErrorCode.RouteNotFound);
        Assert.Equal("route_disabled", RouterErrorCode.RouteDisabled);
        Assert.Equal("cancelled", RouterErrorCode.Cancelled);
        Assert.Equal("internal_error", RouterErrorCode.InternalError);
    }

    [Theory]
    [InlineData("invalid_request")]
    [InlineData("unsupported_parameter")]
    [InlineData("unsupported_capability")]
    [InlineData("route_not_found")]
    [InlineData("route_disabled")]
    [InlineData("cancelled")]
    [InlineData("internal_error")]
    public void Factory_codes_match_the_contract_table(string expected)
    {
        RouterError error = expected switch
        {
            "invalid_request" => RouterError.InvalidRequest("message"),
            "unsupported_parameter" => RouterError.UnsupportedParameter(),
            "unsupported_capability" => RouterError.UnsupportedCapability(),
            "route_not_found" => RouterError.RouteNotFound(),
            "route_disabled" => RouterError.RouteDisabled(),
            "cancelled" => RouterError.Cancelled(),
            "internal_error" => RouterError.InternalError(),
            _ => throw new ArgumentOutOfRangeException(nameof(expected)),
        };

        Assert.Equal(expected, error.Code);
    }

    [Fact]
    public void Exception_details_and_secret_shaped_content_never_leak()
    {
        var exception = new InvalidOperationException("boom sk-abcdefghijklmnopqrstuvwxyz0123456789 payload");

        string json = RouterError.FromException(exception, "req_a").ToJson();

        Assert.DoesNotContain("boom", json);
        Assert.DoesNotContain("sk-abcdef", json);
        Assert.DoesNotContain("payload", json);
        Assert.Contains("\"code\":\"internal_error\"", json);
        Assert.Contains("An internal error occurred.", json);
        Assert.Contains("\"request_id\":\"req_a\"", json);
    }

    [Fact]
    public void Cancellation_is_not_retryable()
    {
        RouterError error = RouterError.Cancelled("req_a");

        Assert.Equal("cancelled", error.Code);
        Assert.Equal("The request was cancelled.", error.Message);
        Assert.False(error.Retryable);
        Assert.Contains("\"retryable\":false", error.ToJson());
    }

    [Fact]
    public void Null_fields_are_always_present_in_json()
    {
        string json = RouterError.InternalError().ToJson();

        Assert.Contains("\"param\":null", json);
        Assert.Contains("\"request_id\":null", json);
    }
}
