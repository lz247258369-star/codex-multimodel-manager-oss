using Router.Core.Lifecycle;
using Xunit;

namespace Router.Core.Tests.Lifecycle;

public sealed class RouterLifecycleTests
{
    public static TheoryData<LifecycleState, LifecycleState> LegalTransitions => new()
    {
        { LifecycleState.Stopped, LifecycleState.Starting },
        { LifecycleState.Starting, LifecycleState.Ready },
        { LifecycleState.Starting, LifecycleState.Degraded },
        { LifecycleState.Starting, LifecycleState.Stopping },
        { LifecycleState.Starting, LifecycleState.Failed },
        { LifecycleState.Ready, LifecycleState.Degraded },
        { LifecycleState.Ready, LifecycleState.Stopping },
        { LifecycleState.Ready, LifecycleState.Failed },
        { LifecycleState.Degraded, LifecycleState.Ready },
        { LifecycleState.Degraded, LifecycleState.Stopping },
        { LifecycleState.Degraded, LifecycleState.Failed },
        { LifecycleState.Stopping, LifecycleState.Stopped },
        { LifecycleState.Stopping, LifecycleState.Failed },
        { LifecycleState.Failed, LifecycleState.Stopped },
    };

    public static TheoryData<LifecycleState, LifecycleState> IllegalTransitions => new()
    {
        { LifecycleState.Stopped, LifecycleState.Ready },
        { LifecycleState.Stopped, LifecycleState.Degraded },
        { LifecycleState.Stopped, LifecycleState.Stopping },
        { LifecycleState.Stopped, LifecycleState.Failed },
        { LifecycleState.Starting, LifecycleState.Starting },
        { LifecycleState.Starting, LifecycleState.Stopped },
        { LifecycleState.Ready, LifecycleState.Starting },
        { LifecycleState.Ready, LifecycleState.Stopped },
        { LifecycleState.Degraded, LifecycleState.Starting },
        { LifecycleState.Degraded, LifecycleState.Stopped },
        { LifecycleState.Stopping, LifecycleState.Starting },
        { LifecycleState.Stopping, LifecycleState.Ready },
        { LifecycleState.Stopping, LifecycleState.Degraded },
        { LifecycleState.Failed, LifecycleState.Starting },
        { LifecycleState.Failed, LifecycleState.Ready },
        { LifecycleState.Failed, LifecycleState.Degraded },
        { LifecycleState.Failed, LifecycleState.Stopping },
    };

    [Theory]
    [MemberData(nameof(LegalTransitions))]
    public void Legal_transitions_succeed(LifecycleState from, LifecycleState to)
    {
        RouterLifecycle lifecycle = CreateAt(from);

        bool changed = lifecycle.TryTransition(from, to);

        Assert.True(changed);
        Assert.Equal(to, lifecycle.State);
    }

    [Theory]
    [MemberData(nameof(IllegalTransitions))]
    public void Illegal_transitions_are_rejected_and_state_is_unchanged(LifecycleState from, LifecycleState to)
    {
        RouterLifecycle lifecycle = CreateAt(from);

        bool changed = lifecycle.TryTransition(from, to);

        Assert.False(changed);
        Assert.Equal(from, lifecycle.State);
    }

    [Fact]
    public void Duplicate_transition_is_rejected()
    {
        RouterLifecycle lifecycle = new();

        Assert.True(lifecycle.TryTransition(LifecycleState.Stopped, LifecycleState.Starting));
        Assert.False(lifecycle.TryTransition(LifecycleState.Stopped, LifecycleState.Starting));
        Assert.Equal(LifecycleState.Starting, lifecycle.State);
    }

    [Fact]
    public void Startup_shutdown_reaches_stopped_through_stopping_and_never_skips_it()
    {
        RouterLifecycle lifecycle = CreateAt(LifecycleState.Starting);

        // STARTING -> STOPPED stays forbidden: the STOPPING checkpoint is the
        // documented place where admission stops and in-flight work drains.
        Assert.False(lifecycle.TryTransition(LifecycleState.Starting, LifecycleState.Stopped));
        Assert.Equal(LifecycleState.Starting, lifecycle.State);

        Assert.True(lifecycle.TryTransitionTo(LifecycleState.Stopping));
        Assert.Equal(LifecycleState.Stopping, lifecycle.State);

        Assert.True(lifecycle.TryTransition(LifecycleState.Stopping, LifecycleState.Stopped));
        Assert.Equal(LifecycleState.Stopped, lifecycle.State);
    }

    [Fact]
    public void Failed_is_terminal_except_explicit_recovery_to_stopped()
    {
        RouterLifecycle lifecycle = CreateAt(LifecycleState.Failed);

        Assert.True(lifecycle.IsFailed);
        Assert.False(lifecycle.TryTransition(LifecycleState.Failed, LifecycleState.Ready));
        Assert.False(lifecycle.TryTransition(LifecycleState.Failed, LifecycleState.Stopping));
        Assert.False(lifecycle.TryTransition(LifecycleState.Failed, LifecycleState.Starting));

        Assert.True(lifecycle.TryTransition(LifecycleState.Failed, LifecycleState.Stopped));
        Assert.Equal(LifecycleState.Stopped, lifecycle.State);
        Assert.True(lifecycle.TryTransition(LifecycleState.Stopped, LifecycleState.Starting));
    }

    [Fact]
    public async Task Concurrent_transition_has_exactly_one_winner()
    {
        const int contenders = 32;
        RouterLifecycle lifecycle = CreateAt(LifecycleState.Starting);

        Task<bool>[] tasks = Enumerable.Range(0, contenders)
            .Select(_ => Task.Run(() => lifecycle.TryTransition(LifecycleState.Starting, LifecycleState.Ready)))
            .ToArray();

        bool[] results = await Task.WhenAll(tasks);

        Assert.Equal(1, results.Count(static won => won));
        Assert.Equal(LifecycleState.Ready, lifecycle.State);
    }

    [Theory]
    [InlineData(LifecycleState.Stopped, "STOPPED")]
    [InlineData(LifecycleState.Starting, "STARTING")]
    [InlineData(LifecycleState.Ready, "READY")]
    [InlineData(LifecycleState.Degraded, "DEGRADED")]
    [InlineData(LifecycleState.Stopping, "STOPPING")]
    [InlineData(LifecycleState.Failed, "FAILED")]
    public void Wire_names_match_the_contract(LifecycleState state, string expected)
    {
        Assert.Equal(expected, state.ToWireName());
        Assert.True(LifecycleStateExtensions.TryFromWireName(expected, out LifecycleState parsed));
        Assert.Equal(state, parsed);
    }

    private static RouterLifecycle CreateAt(LifecycleState target)
    {
        RouterLifecycle lifecycle = new();
        foreach ((LifecycleState from, LifecycleState to) in PathTo(target))
        {
            Assert.True(lifecycle.TryTransition(from, to), $"Failed to seed {from} -> {to}");
        }

        Assert.Equal(target, lifecycle.State);
        return lifecycle;
    }

    private static (LifecycleState From, LifecycleState To)[] PathTo(LifecycleState target)
        => target switch
        {
            LifecycleState.Stopped => Array.Empty<(LifecycleState From, LifecycleState To)>(),
            LifecycleState.Starting => new[] { (LifecycleState.Stopped, LifecycleState.Starting) },
            LifecycleState.Ready => new[]
            {
                (LifecycleState.Stopped, LifecycleState.Starting),
                (LifecycleState.Starting, LifecycleState.Ready),
            },
            LifecycleState.Degraded => new[]
            {
                (LifecycleState.Stopped, LifecycleState.Starting),
                (LifecycleState.Starting, LifecycleState.Degraded),
            },
            LifecycleState.Stopping => new[]
            {
                (LifecycleState.Stopped, LifecycleState.Starting),
                (LifecycleState.Starting, LifecycleState.Ready),
                (LifecycleState.Ready, LifecycleState.Stopping),
            },
            LifecycleState.Failed => new[]
            {
                (LifecycleState.Stopped, LifecycleState.Starting),
                (LifecycleState.Starting, LifecycleState.Failed),
            },
            _ => throw new ArgumentOutOfRangeException(nameof(target)),
        };
}
