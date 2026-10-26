using System.Reflection;
using Router.Core.Context;
using Router.Core.Ids;
using Router.Core.Tests.Fakes;
using Xunit;

namespace Router.Core.Tests.Context;

public sealed class RequestContextTests
{
    private readonly UuidV7IdGenerator _ids = new(new FakeClock(1_752_000_000_000));
    private readonly DateTimeOffset _receivedAt = DateTimeOffset.FromUnixTimeMilliseconds(1_752_000_000_000);

    [Fact]
    public void Create_populates_all_fields()
    {
        RequestId requestId = _ids.NewRequestId();
        TraceId traceId = _ids.NewTraceId();
        using CancellationTokenSource cts = new();

        RequestContext context = RequestContext.Create(
            requestId,
            traceId,
            "client.codex_cli",
            _receivedAt,
            "responses:invoke",
            deadlineAt: _receivedAt.AddSeconds(30),
            configGeneration: "abc",
            contentLogging: false,
            cancellationToken: cts.Token);

        Assert.Equal(requestId, context.RequestId);
        Assert.Equal(traceId, context.TraceId);
        Assert.Equal("client.codex_cli", context.ClientId);
        Assert.Equal(_receivedAt, context.ReceivedAt);
        Assert.Equal(_receivedAt.AddSeconds(30), context.DeadlineAt);
        Assert.Equal("abc", context.ConfigGeneration);
        Assert.Equal("responses:invoke", context.AuthScope);
        Assert.False(context.ContentLogging);
        Assert.Equal(cts.Token, context.CancellationToken);
    }

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData(null)]
    public void Empty_client_id_is_rejected(string? clientId)
    {
        Assert.Throws<ArgumentException>(() => Create(clientId: clientId));
    }

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData(null)]
    public void Empty_auth_scope_is_rejected(string? authScope)
    {
        Assert.Throws<ArgumentException>(() => Create(authScope: authScope));
    }

    [Fact]
    public void Deadline_before_received_time_is_rejected()
    {
        Assert.Throws<ArgumentException>(() => Create(deadlineAt: _receivedAt.AddSeconds(-1)));
    }

    [Fact]
    public void Deadline_equal_to_received_time_is_allowed()
    {
        RequestContext context = Create(deadlineAt: _receivedAt);

        Assert.Equal(_receivedAt, context.DeadlineAt);
    }

    [Fact]
    public void Context_never_exposes_a_token_or_secret_property()
    {
        string[] forbiddenNames =
        {
            "token",
            "authorization",
            "bearer",
            "secret",
            "apikey",
            "api_key",
            "password",
            "credential",
        };

        foreach (PropertyInfo property in typeof(RequestContext).GetProperties())
        {
            Assert.DoesNotContain(property.Name, forbiddenNames, StringComparer.OrdinalIgnoreCase);
        }
    }

    private RequestContext Create(
        string? clientId = "client.codex_cli",
        string? authScope = "responses:invoke",
        DateTimeOffset? deadlineAt = null)
        => RequestContext.Create(
            _ids.NewRequestId(),
            _ids.NewTraceId(),
            clientId!,
            _receivedAt,
            authScope!,
            deadlineAt: deadlineAt);
}
