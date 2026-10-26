using Router.Core.Cancellation;
using Xunit;

namespace Router.Core.Tests.Cancellation;

public sealed class CancellationCoordinatorTests
{
    [Fact]
    public void Caller_cancellation_propagates()
    {
        using CancellationTokenSource caller = new();
        using CancellationCoordinator coordinator = new(caller.Token);

        caller.Cancel();

        Assert.True(coordinator.IsCancellationRequested);
        Assert.True(coordinator.Token.IsCancellationRequested);
    }

    [Fact]
    public void Shutdown_cancellation_propagates()
    {
        using CancellationTokenSource shutdown = new();
        using CancellationCoordinator coordinator = new(CancellationToken.None, shutdown.Token);

        shutdown.Cancel();

        Assert.True(coordinator.IsCancellationRequested);
        Assert.True(coordinator.Token.IsCancellationRequested);
    }

    [Fact]
    public void Canceling_either_source_cancels_the_coordinator()
    {
        using CancellationTokenSource caller = new();
        using CancellationTokenSource shutdown = new();
        using CancellationCoordinator coordinator = CancellationCoordinator.FromCallerAndShutdown(caller.Token, shutdown.Token);

        shutdown.Cancel();
        Assert.True(coordinator.IsCancellationRequested);

        using CancellationTokenSource caller2 = new();
        using CancellationTokenSource shutdown2 = new();
        using CancellationCoordinator coordinator2 = CancellationCoordinator.FromCallerAndShutdown(caller2.Token, shutdown2.Token);

        caller2.Cancel();
        Assert.True(coordinator2.IsCancellationRequested);
    }

    [Fact]
    public void Double_cancel_is_idempotent()
    {
        using CancellationCoordinator coordinator = new(CancellationToken.None);

        Assert.True(coordinator.TryCancel());
        Assert.False(coordinator.TryCancel());
        Assert.True(coordinator.IsCancellationRequested);
        Assert.True(coordinator.IsCancelCommitted);

        coordinator.Cancel();
        coordinator.Cancel();
    }

    [Fact]
    public void Coordinator_cancel_is_one_way_and_does_not_cancel_the_source()
    {
        using CancellationTokenSource source = new();
        using CancellationCoordinator coordinator = new(source.Token);

        coordinator.Cancel();

        Assert.False(source.IsCancellationRequested);
        Assert.True(coordinator.Token.IsCancellationRequested);
    }
}
