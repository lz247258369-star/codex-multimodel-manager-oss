using Router.Core.Lifecycle;
using Xunit;

namespace Router.Core.Tests.Lifecycle;

public sealed class RequestStateMachineTests
{
    [Fact]
    public void Legal_streaming_path_completes()
    {
        RequestStateMachine machine = new();

        Assert.True(machine.TryAdvance(RequestState.Received, RequestState.Routed));
        Assert.True(machine.TryAdvance(RequestState.Routed, RequestState.UpstreamPending));
        Assert.True(machine.TryAdvance(RequestState.UpstreamPending, RequestState.Streaming));
        Assert.True(machine.TryComplete());

        Assert.Equal(RequestState.Completed, machine.State);
        Assert.True(machine.IsTerminal);
    }

    [Fact]
    public void Legal_non_streaming_path_completes()
    {
        RequestStateMachine machine = new();

        Assert.True(machine.TryAdvance(RequestState.Received, RequestState.Routed));
        Assert.True(machine.TryAdvance(RequestState.Routed, RequestState.UpstreamPending));
        Assert.True(machine.TryComplete());

        Assert.Equal(RequestState.Completed, machine.State);
    }

    [Theory]
    [InlineData(RequestState.Received, RequestState.Streaming)]
    [InlineData(RequestState.Received, RequestState.Received)]
    [InlineData(RequestState.Routed, RequestState.Received)]
    [InlineData(RequestState.Routed, RequestState.Routed)]
    [InlineData(RequestState.UpstreamPending, RequestState.Routed)]
    [InlineData(RequestState.Streaming, RequestState.Routed)]
    [InlineData(RequestState.Streaming, RequestState.UpstreamPending)]
    public void Illegal_advances_are_rejected(RequestState from, RequestState to)
    {
        RequestStateMachine machine = CreateAt(from);

        bool changed = machine.TryAdvance(from, to);

        Assert.False(changed);
        Assert.Equal(from, machine.State);
    }

    [Fact]
    public void Terminal_states_are_immutable()
    {
        RequestStateMachine machine = CreateAt(RequestState.UpstreamPending);
        Assert.True(machine.TryComplete());

        Assert.False(machine.TryFail());
        Assert.False(machine.TryCancel());
        Assert.False(machine.TryAdvance(RequestState.Completed, RequestState.Failed));
        Assert.Equal(RequestState.Completed, machine.State);
    }

    [Fact]
    public async Task Terminal_race_has_exactly_one_winner()
    {
        const int iterations = 250;

        for (int i = 0; i < iterations; i++)
        {
            RequestStateMachine machine = CreateAt(RequestState.UpstreamPending);

            Task<bool> complete = Task.Run(machine.TryComplete);
            Task<bool> fail = Task.Run(machine.TryFail);
            Task<bool> cancel = Task.Run(machine.TryCancel);

            bool[] results = await Task.WhenAll(complete, fail, cancel);

            Assert.Equal(1, results.Count(static won => won));
            Assert.True(machine.IsTerminal);
            Assert.Equal(
                results[0] ? RequestState.Completed
                : results[1] ? RequestState.Failed
                : RequestState.Cancelled,
                machine.State);
        }
    }

    [Fact]
    public async Task Cancellation_never_overrides_an_earlier_committed_completion()
    {
        for (int i = 0; i < 250; i++)
        {
            RequestStateMachine machine = CreateAt(RequestState.UpstreamPending);

            Task<bool> complete = Task.Run(machine.TryComplete);
            Task<bool> cancel = Task.Run(machine.TryCancel);

            bool[] results = await Task.WhenAll(complete, cancel);

            Assert.Equal(1, results.Count(static won => won));
            Assert.Equal(results[0] ? RequestState.Completed : RequestState.Cancelled, machine.State);
            Assert.NotEqual(RequestState.Failed, machine.State);
        }
    }

    [Theory]
    [InlineData(RequestState.Received, "RECEIVED")]
    [InlineData(RequestState.Routed, "ROUTED")]
    [InlineData(RequestState.UpstreamPending, "UPSTREAM_PENDING")]
    [InlineData(RequestState.Streaming, "STREAMING")]
    [InlineData(RequestState.Completed, "COMPLETED")]
    [InlineData(RequestState.Failed, "FAILED")]
    [InlineData(RequestState.Cancelled, "CANCELLED")]
    public void Wire_names_match_the_contract(RequestState state, string expected)
    {
        Assert.Equal(expected, state.ToWireName());
        Assert.True(RequestStateExtensions.TryFromWireName(expected, out RequestState parsed));
        Assert.Equal(state, parsed);
    }

    private static RequestStateMachine CreateAt(RequestState target)
    {
        RequestStateMachine machine = new();
        foreach ((RequestState from, RequestState to) in PathTo(target))
        {
            Assert.True(machine.TryAdvance(from, to), $"Failed to seed {from} -> {to}");
        }

        Assert.Equal(target, machine.State);
        return machine;
    }

    private static (RequestState From, RequestState To)[] PathTo(RequestState target)
        => target switch
        {
            RequestState.Received => Array.Empty<(RequestState From, RequestState To)>(),
            RequestState.Routed => new[] { (RequestState.Received, RequestState.Routed) },
            RequestState.UpstreamPending => new[]
            {
                (RequestState.Received, RequestState.Routed),
                (RequestState.Routed, RequestState.UpstreamPending),
            },
            RequestState.Streaming => new[]
            {
                (RequestState.Received, RequestState.Routed),
                (RequestState.Routed, RequestState.UpstreamPending),
                (RequestState.UpstreamPending, RequestState.Streaming),
            },
            _ => throw new ArgumentOutOfRangeException(nameof(target)),
        };
}
