using System.Net;
using Router.Core.Context;
using Router.Ingress.Fakes;
using Router.Ingress.Tests.Support;
using Xunit;

namespace Router.Ingress.Tests;

/// <summary>
/// HS-1B ingress wiring: POST /v1/responses reads its two optional router-local
/// identity headers through the single shared parser, stores only the canonical
/// identity, and never turns defective identity material into an HTTP failure.
/// </summary>
public sealed class IngressThreadIdentityTests
{
    private const string ThreadOne = "01a09dae-3db7-7820-8912-0d86815051a6";
    private const string ThreadTwo = "01a09dae-3e22-7072-b928-701a84420b82";

    [Fact]
    public async Task Consistent_thread_headers_populate_the_request_context()
    {
        RequestContext context = await SendAsync(ThreadOne, Metadata(ThreadOne, "turn"));

        Assert.NotNull(context.Thread);
        Assert.Equal(ThreadOne, context.Thread!.ThreadId.Value);
        Assert.Equal(ThreadRef.From(context.Thread.ThreadId), context.Thread.Ref);
        Assert.Equal(ThreadIdentity.TurnRequestKind, context.Thread.RequestKind);
        Assert.True(context.Thread.IsEligibleTurn);
    }

    [Fact]
    public async Task Thread_id_alone_is_accepted_without_a_request_kind()
    {
        RequestContext context = await SendAsync(ThreadOne, metadata: null);

        Assert.NotNull(context.Thread);
        Assert.Null(context.Thread!.RequestKind);
        Assert.False(context.Thread.IsEligibleTurn);
    }

    [Fact]
    public async Task Turn_metadata_alone_is_accepted()
    {
        RequestContext context = await SendAsync(threadId: null, Metadata(ThreadTwo, "turn"));

        Assert.Equal(ThreadTwo, context.Thread!.ThreadId.Value);
        Assert.True(context.Thread.IsEligibleTurn);
    }

    [Fact]
    public async Task Absent_identity_owns_no_thread_state()
    {
        RequestContext context = await SendAsync(threadId: null, metadata: null);

        Assert.Null(context.Thread);
    }

    [Theory]
    [InlineData(ThreadOne, "{\"thread_id\":\"01a09dae-3e22-7072-b928-701a84420b82\",\"request_kind\":\"turn\"}")]
    [InlineData(ThreadOne, "{not-json")]
    [InlineData(ThreadOne, "\"just-a-string\"")]
    [InlineData("not a thread id", "{\"thread_id\":\"01a09dae-3e22-7072-b928-701a84420b82\",\"request_kind\":\"turn\"}")]
    public async Task Defective_identity_never_fails_the_request(string? threadId, string? metadata)
    {
        // SendAsync asserts the canonical 200 response: malformed, contradictory,
        // or unreadable identity material only means HS-1B does not apply.
        RequestContext context = await SendAsync(threadId, metadata);

        Assert.Null(context.Thread);
    }

    [Fact]
    public async Task Oversized_turn_metadata_is_ignored_not_fatal()
    {
        string oversized = "{\"thread_id\":\"" + ThreadOne + "\",\"pad\":\"" + new string('p', 4096) + "\"}";
        Assert.True(oversized.Length > ThreadIdentityParser.MaxMetadataBytes);

        RequestContext context = await SendAsync(ThreadOne, oversized);

        Assert.Null(context.Thread);
    }

    [Fact]
    public void Request_context_never_exposes_raw_identity_material()
    {
        string[] members = typeof(RequestContext)
            .GetProperties()
            .Select(static property => property.Name)
            .ToArray();

        Assert.DoesNotContain(members, static name => name.Contains("Raw", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(members, static name => name.Contains("Header", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(members, static name => name.Contains("Metadata", StringComparison.OrdinalIgnoreCase));
    }

    private static async Task<RequestContext> SendAsync(string? threadId, string? metadata)
    {
        var service = new FakeResponsesService();
        await using IngressTestServer server = await IngressTestServer.StartAsync(options => options.Service = service);

        using HttpRequestMessage request = TestHttp.JsonRequest(
            HttpMethod.Post,
            "/v1/responses",
            """{"model":"gpt-test","input":"hi"}""");
        if (threadId is not null)
        {
            request.Headers.TryAddWithoutValidation(ThreadIdentityParser.ThreadIdHeaderName, threadId);
        }

        if (metadata is not null)
        {
            request.Headers.TryAddWithoutValidation(ThreadIdentityParser.TurnMetadataHeaderName, metadata);
        }

        using HttpResponseMessage response = await server.SendAsync(request);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        return Assert.Single(service.Calls).Context;
    }

    private static string Metadata(string threadId, string requestKind)
        => "{\"thread_id\":\"" + threadId + "\",\"request_kind\":\"" + requestKind + "\"}";
}
