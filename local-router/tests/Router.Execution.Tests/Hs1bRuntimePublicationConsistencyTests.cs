using System.Net.Http;
using Router.Configuration;
using Router.Core.Concurrency;
using Router.Core.Context;
using Router.ThreadSelection;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// Deterministic observable-atomicity coverage for runtime publication.
///
/// A runtime publication changes two owners - the published Router state (config
/// generation / Router feature) and the runtime effective thread-selection
/// capability - inside ONE exclusive runtime consistency section. These tests
/// pause the publisher deterministically INSIDE that section (no sleeps, no
/// race-luck) and prove that concurrent observers cannot complete on a mixed
/// pair, and that they observe the new pair once the section is released.
/// </summary>
public sealed class Hs1bRuntimePublicationConsistencyTests
{
    private const string FeaturePath = "/v1/router/control-plane/thread-selection-feature";

    [Fact]
    public async Task Enable_publication_is_observably_atomic()
    {
        var gate = new SignalingGate(new RouterRuntimeConsistencyGate());
        PausingFeatureState? pausing = null;
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(
            threadSelectionEnabled: false,
            consistencyGate: gate,
            featureStateFactory: store => pausing = new PausingFeatureState(store));
        PausingFeatureState featureState = pausing!;

        // Exactly ONE boundary exists for the process pair.
        Assert.Same(gate, harness.ConsistencyGate);
        Assert.Same(gate, harness.Store.ConsistencyGate);
        Assert.Same(gate, harness.PublicationSink.ConsistencyGate);
        Assert.False(harness.Store.Enabled);
        Assert.False(harness.CurrentState.Snapshot.ThreadSelectionEnabled);

        PublishedRouterState updated = harness.CurrentState.Snapshot with
        {
            ConfigGeneration = new string('c', 64),
            ThreadSelectionEnabled = true,
        };

        Task publisher = Task.Run(() => harness.PublicationSink.Publish(updated));
        featureState.WaitUntilEntered();

        // Inside the exclusive section the published state is already NEW while
        // the capability transition has not been applied yet. That mixed pair
        // exists only inside the section - no observer may complete on it.
        Assert.True(harness.CurrentState.Snapshot.ThreadSelectionEnabled);

        int sharedBeforeRead = gate.SharedAttempts;
        Task<HttpResponseMessage> combinedRead = harness.ControlGetAsync(FeaturePath);
        await gate.WaitForSharedAttemptsAsync(sharedBeforeRead + 1);
        Assert.False(combinedRead.IsCompleted);

        int sharedBeforeResolve = gate.SharedAttempts;
        Task<ThreadModelSelectionDecision> resolve = Task.Run(() => harness.Store.Resolve(new ThreadModelSelectionRequest
        {
            Thread = Identity(Hs1bTestThreads.One),
            ClientId = Hs1bRuntimeConfig.ClientId,
            RequestedModel = Hs1bRuntimeConfig.Beta.ClientModelId,
            ObservedAt = DateTimeOffset.UtcNow,
        }));
        await gate.WaitForSharedAttemptsAsync(sharedBeforeResolve + 1);
        Assert.False(resolve.IsCompleted);

        featureState.Release();
        await publisher.WaitAsync(TimeSpan.FromSeconds(10));

        using (HttpResponseMessage response = await combinedRead.WaitAsync(TimeSpan.FromSeconds(10)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(response);
            Assert.True(response.IsSuccessStatusCode, body);
            Assert.Contains("\"configured_enabled\":true", body, StringComparison.Ordinal);
            Assert.Contains("\"effective_enabled\":true", body, StringComparison.Ordinal);
        }

        ThreadModelSelectionDecision decision = await resolve.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.True(harness.Store.Enabled);
        Assert.True(harness.CurrentState.Snapshot.ThreadSelectionEnabled);
        // NEW + NEW: the capability is on, and it created no selection of its own.
        Assert.Equal(Hs1bRuntimeConfig.Beta.ClientModelId, decision.SelectedModel);
        Assert.Equal(ThreadModelSelectionDecision.SourceNone, decision.SelectionSource);
    }

    [Fact]
    public async Task Disable_publication_is_observably_atomic()
    {
        var gate = new SignalingGate(new RouterRuntimeConsistencyGate());
        PausingFeatureState? pausing = null;
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(
            threadSelectionEnabled: true,
            consistencyGate: gate,
            featureStateFactory: store => pausing = new PausingFeatureState(store));
        PausingFeatureState featureState = pausing!;
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        // Establish an ACTIVE hot-beta override for T1 through the real path.
        using (HttpResponseMessage observe = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(observe.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(observe));
        }

        using (HttpResponseMessage set = await harness.ControlPutAsync(
            $"/v1/router/control-plane/threads/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Beta.ClientModelId)))
        {
            Assert.True(set.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(set));
        }

        using (HttpResponseMessage active = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(active.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(active));
        }

        Assert.Equal(ThreadSelectionState.Active, harness.Store.TryGet(threadRef)!.SelectionState);
        Assert.Equal(Hs1bRuntimeConfig.Beta.UpstreamModelId, harness.Sink.Executed[^1].UpstreamModelId);

        PublishedRouterState disabled = harness.CurrentState.Snapshot with { ThreadSelectionEnabled = false };
        Task publisher = Task.Run(() => harness.PublicationSink.Publish(disabled));
        featureState.WaitUntilEntered();

        // NEW published config, capability transition still pending.
        Assert.False(harness.CurrentState.Snapshot.ThreadSelectionEnabled);

        int sharedBeforeResolve = gate.SharedAttempts;
        Task<ThreadModelSelectionDecision> resolve = Task.Run(() => harness.Store.Resolve(new ThreadModelSelectionRequest
        {
            Thread = Identity(Hs1bTestThreads.One),
            ClientId = Hs1bRuntimeConfig.ClientId,
            RequestedModel = Hs1bRuntimeConfig.Alpha.ClientModelId,
            ObservedAt = DateTimeOffset.UtcNow,
        }));
        await gate.WaitForSharedAttemptsAsync(sharedBeforeResolve + 1);
        Assert.False(resolve.IsCompleted);

        featureState.Release();
        await publisher.WaitAsync(TimeSpan.FromSeconds(10));

        ThreadModelSelectionDecision decision = await resolve.WaitAsync(TimeSpan.FromSeconds(10));

        // The disable must never be observed as "new config, old ACTIVE override".
        Assert.Equal(Hs1bRuntimeConfig.Alpha.ClientModelId, decision.SelectedModel);
        Assert.Equal(ThreadModelSelectionDecision.SourceNone, decision.SelectionSource);
        Assert.False(harness.Store.Enabled);
        Assert.False(harness.CurrentState.Snapshot.ThreadSelectionEnabled);
        Assert.Equal(ThreadSelectionState.Cleared, harness.Store.TryGet(threadRef)!.SelectionState);
    }

    private static ThreadIdentity Identity(string rawThreadId)
    {
        Assert.True(CanonicalThreadId.TryParse(rawThreadId, out CanonicalThreadId? canonical));
        return new ThreadIdentity
        {
            ThreadId = canonical!,
            Ref = ThreadRef.From(canonical!),
            RequestKind = ThreadIdentity.TurnRequestKind,
        };
    }

    /// <summary>
    /// Test-only feature state that pauses deterministically inside the
    /// exclusive publication section, after the published state was swapped and
    /// before the capability transition is applied.
    /// </summary>
    private sealed class PausingFeatureState : IRouterRuntimeFeatureState
    {
        private readonly ThreadSelectionStore _store;
        private readonly TaskCompletionSource _entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _release = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public PausingFeatureState(ThreadSelectionStore store)
        {
            _store = store;
        }

        public bool Enabled => _store.Enabled;

        public void WaitUntilEntered()
            => Assert.True(
                _entered.Task.Wait(TimeSpan.FromSeconds(10)),
                "the runtime publication never reached the capability transition");

        public void Release() => _release.TrySetResult();

        public void ApplyPublishedState(bool enabled, string disabledReason)
        {
            _entered.TrySetResult();
            Assert.True(
                _release.Task.Wait(TimeSpan.FromSeconds(30)),
                "the test never released the paused runtime publication");
            _store.ApplyPublishedState(enabled, disabledReason);
        }
    }

    /// <summary>
    /// Test-only gate wrapper that signals when a shared (observer) section is
    /// attempted, so a test can prove a reader is blocked by the publication
    /// instead of relying on timing.
    /// </summary>
    private sealed class SignalingGate : IRouterRuntimeConsistencyGate
    {
        private readonly IRouterRuntimeConsistencyGate _inner;
        private readonly object _sync = new();
        private readonly List<(int Target, TaskCompletionSource Completion)> _waiters = [];
        private int _sharedAttempts;

        public SignalingGate(IRouterRuntimeConsistencyGate inner)
        {
            _inner = inner;
        }

        public int SharedAttempts
        {
            get
            {
                lock (_sync)
                {
                    return _sharedAttempts;
                }
            }
        }

        public IDisposable EnterShared()
        {
            TaskCompletionSource? completed = null;
            lock (_sync)
            {
                _sharedAttempts++;
                for (int index = _waiters.Count - 1; index >= 0; index--)
                {
                    if (_waiters[index].Target <= _sharedAttempts)
                    {
                        completed = _waiters[index].Completion;
                        _waiters.RemoveAt(index);
                    }
                }
            }

            completed?.TrySetResult();
            return _inner.EnterShared();
        }

        public IDisposable EnterExclusive() => _inner.EnterExclusive();

        public async Task WaitForSharedAttemptsAsync(int count)
        {
            Task pending;
            lock (_sync)
            {
                if (_sharedAttempts >= count)
                {
                    return;
                }

                var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                _waiters.Add((count, completion));
                pending = completion.Task;
            }

            await pending.WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
        }
    }
}
