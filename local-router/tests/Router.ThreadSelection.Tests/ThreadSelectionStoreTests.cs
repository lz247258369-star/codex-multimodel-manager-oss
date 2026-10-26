using Router.Core.Abstractions;
using Router.Core.Context;
using Router.ThreadSelection;
using Xunit;

namespace Router.ThreadSelection.Tests;

/// <summary>
/// HS-1B store coverage: sticky activation, auxiliary-request isolation,
/// per-thread isolation, capture-as-identity-discovery, lifecycle clearing, and
/// generation compare-and-swap.
/// </summary>
public sealed class ThreadSelectionStoreTests
{
    private const string ThreadOneId = "01a09dae-3db7-7820-8912-0d86815051a6";
    private const string ThreadTwoId = "01a09dae-3e22-7072-b928-701a84420b82";
    private const string ThreadThreeId = "01a09dae-5ec2-7e61-8590-7d8dce1b70e2";

    private static readonly DateTimeOffset Origin = DateTimeOffset.UnixEpoch.AddDays(20_000);

    [Fact]
    public void PendingSelectionBecomesActiveAndStaysSticky()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");

        Assert.Equal("hot-alpha", context.Resolve(thread, "hot-alpha").SelectedModel);

        ThreadSelectionSnapshot snapshot = context.Store.TryGet(thread.Ref)!;
        ThreadSelectionOperationResult set = context.Store.SetSelection(thread.Ref, "hot-beta", snapshot.SelectionGeneration);
        Assert.Equal(ThreadSelectionOperationStatus.Applied, set.Status);
        Assert.Equal(ThreadSelectionState.Pending, set.Snapshot!.SelectionState);

        ThreadModelSelectionDecision first = context.Resolve(thread, "hot-alpha");
        Assert.Equal("hot-beta", first.SelectedModel);
        Assert.Equal(ThreadModelSelectionDecision.SourceThreadPending, first.SelectionSource);

        ThreadModelSelectionDecision second = context.Resolve(thread, "hot-alpha");
        Assert.Equal("hot-beta", second.SelectedModel);
        Assert.Equal(ThreadModelSelectionDecision.SourceThreadActive, second.SelectionSource);

        ThreadModelSelectionDecision third = context.Resolve(thread, "hot-alpha");
        Assert.Equal("hot-beta", third.SelectedModel);
        Assert.Equal("hot-alpha", third.RequestedModel);
    }

    [Fact]
    public void AuxiliaryRequestsKeepRequestedModelAndNeverConsumePending()
    {
        TestContext context = new();
        ThreadIdentity turn = Identity(ThreadOneId, "turn");
        ThreadIdentity auxiliary = Identity(ThreadOneId, "title");

        context.Resolve(turn, "hot-alpha");
        ThreadSelectionSnapshot snapshot = context.Store.TryGet(turn.Ref)!;
        _ = context.Store.SetSelection(turn.Ref, "hot-beta", snapshot.SelectionGeneration);

        ThreadModelSelectionDecision auxiliaryDecision = context.Resolve(auxiliary, "hot-alpha");
        Assert.Equal("hot-alpha", auxiliaryDecision.SelectedModel);
        Assert.Equal(ThreadModelSelectionDecision.SourceNone, auxiliaryDecision.SelectionSource);
        Assert.Equal(ThreadSelectionState.Pending, context.Store.TryGet(turn.Ref)!.SelectionState);

        ThreadModelSelectionDecision turnDecision = context.Resolve(turn, "hot-alpha");
        Assert.Equal("hot-beta", turnDecision.SelectedModel);
    }

    [Fact]
    public void MissingRequestKindNeverAppliesSelection()
    {
        TestContext context = new();
        ThreadIdentity unknownKind = Identity(ThreadOneId, null);

        context.Resolve(unknownKind, "hot-alpha");
        string threadRef = context.Store.List(10)[0].ThreadRef;
        _ = context.Store.SetSelection(threadRef, "hot-beta", 1);

        ThreadModelSelectionDecision decision = context.Resolve(unknownKind, "hot-alpha");

        Assert.Equal("hot-alpha", decision.SelectedModel);
        Assert.Equal(ThreadSelectionState.Pending, context.Store.TryGet(threadRef)!.SelectionState);
    }

    [Fact]
    public void ThreadsAreIsolatedFromEachOther()
    {
        TestContext context = new();
        ThreadIdentity one = Identity(ThreadOneId, "turn");
        ThreadIdentity two = Identity(ThreadTwoId, "turn");

        context.Resolve(one, "hot-alpha");
        context.Resolve(two, "hot-alpha");

        string refOne = context.Store.TryGet(one.Ref)!.ThreadRef;
        string refTwo = context.Store.TryGet(two.Ref)!.ThreadRef;
        _ = context.Store.SetSelection(refOne, "hot-beta", 1);
        _ = context.Store.SetSelection(refTwo, "hot-gamma", 1);

        Assert.Equal("hot-beta", context.Resolve(one, "hot-alpha").SelectedModel);
        Assert.Equal("hot-gamma", context.Resolve(two, "hot-alpha").SelectedModel);
        Assert.Equal("hot-beta", context.Resolve(one, "hot-alpha").SelectedModel);
    }

    [Fact]
    public void ClearRestoresRequestedModel()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");

        context.Resolve(thread, "hot-alpha");
        _ = context.Store.SetSelection(thread.Ref, "hot-beta", 1);
        Assert.Equal("hot-beta", context.Resolve(thread, "hot-alpha").SelectedModel);

        ThreadSelectionSnapshot snapshot = context.Store.TryGet(thread.Ref)!;
        ThreadSelectionOperationResult cleared = context.Store.ClearSelection(thread.Ref, snapshot.SelectionGeneration);

        Assert.Equal(ThreadSelectionOperationStatus.Applied, cleared.Status);
        Assert.Equal(ThreadSelectionState.Cleared, cleared.Snapshot!.SelectionState);
        Assert.Equal("explicit_clear", cleared.Snapshot.LastClearedReason);
        Assert.Equal("hot-alpha", context.Resolve(thread, "hot-alpha").SelectedModel);
    }

    [Fact]
    public void ClearAllClearsSelectionsAndCancelsCaptures()
    {
        TestContext context = new();
        ThreadIdentity one = Identity(ThreadOneId, "turn");
        ThreadIdentity two = Identity(ThreadTwoId, "turn");

        context.Resolve(one, "hot-alpha");
        context.Resolve(two, "hot-alpha");
        _ = context.Store.SetSelection(one.Ref, "hot-beta", 1);
        _ = context.Store.SetSelection(two.Ref, "hot-gamma", 1);
        ThreadCaptureSnapshot capture = context.Store.OpenCapture("client.v4").Capture!;

        ThreadSelectionOperationResult result = context.Store.ClearAll();

        Assert.Equal(2, result.ClearedCount);
        Assert.Equal(1, result.CancelledCaptureCount);
        Assert.Equal(ThreadSelectionState.Cleared, context.Store.TryGet(one.Ref)!.SelectionState);
        Assert.Equal("explicit_clear_all", context.Store.TryGet(one.Ref)!.LastClearedReason);
        Assert.Equal("hot-alpha", context.Resolve(one, "hot-alpha").SelectedModel);
        Assert.Null(context.Store.TryGetCapture(capture.Token, "client.v4"));
    }

    [Fact]
    public void CaptureDiscoversIdentityWithoutSelectingAModel()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");
        ThreadCaptureSnapshot opened = context.Store.OpenCapture("client.v4").Capture!;

        ThreadModelSelectionDecision decision = context.Resolve(thread, "hot-alpha");

        Assert.Equal("hot-alpha", decision.SelectedModel);
        ThreadCaptureSnapshot captured = context.Store.TryGetCapture(opened.Token, "client.v4")!;
        Assert.Equal(ThreadCaptureStatus.Captured, captured.Status);
        Assert.Equal(thread.Ref, captured.ThreadRef);
        Assert.Equal(ThreadSelectionState.None, context.Store.TryGet(thread.Ref)!.SelectionState);

        // The capture turn is not the switch turn: the model only changes after
        // an explicit selection.
        _ = context.Store.SetSelection(thread.Ref, "hot-beta", 1);
        Assert.Equal("hot-beta", context.Resolve(thread, "hot-alpha").SelectedModel);
    }

    [Fact]
    public void FeatureDisableClearsSelectionsAndCaptures()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");

        context.Resolve(thread, "hot-alpha");
        _ = context.Store.SetSelection(thread.Ref, "hot-beta", 1);
        ThreadCaptureSnapshot capture = context.Store.OpenCapture("client.v4").Capture!;

        context.Store.ApplyFeatureState(false, "thread_selection_feature_disabled");

        Assert.False(context.Store.Enabled);
        Assert.Equal("thread_selection_feature_disabled", context.Store.TryGet(thread.Ref)!.LastClearedReason);
        Assert.Null(context.Store.TryGetCapture(capture.Token, "client.v4"));
        Assert.Equal("hot-alpha", context.Resolve(thread, "hot-alpha").SelectedModel);
    }

    [Fact]
    public void DisabledStoreNeverObservesThreads()
    {
        TestContext context = new(enabled: false);
        ThreadIdentity thread = Identity(ThreadOneId, "turn");

        ThreadModelSelectionDecision decision = context.Resolve(thread, "hot-alpha");

        Assert.Equal("hot-alpha", decision.SelectedModel);
        Assert.Null(decision.ThreadRef);
        Assert.Empty(context.Store.List(10));
    }

    [Fact]
    public void StaleGenerationConflictsWithoutMutation()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");
        context.Resolve(thread, "hot-alpha");

        _ = context.Store.SetSelection(thread.Ref, "hot-beta", 1);
        ThreadSelectionOperationResult conflict = context.Store.SetSelection(thread.Ref, "hot-gamma", 1);

        Assert.Equal(ThreadSelectionOperationStatus.Conflict, conflict.Status);
        Assert.Equal(2UL, conflict.Generation);
        Assert.Equal("hot-beta", conflict.Snapshot!.SelectionModel);
    }

    [Fact]
    public void PendingTtlExpiryFallsBackToRequestedModel()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");

        context.Resolve(thread, "hot-alpha");
        _ = context.Store.SetSelection(thread.Ref, "hot-beta", 1);
        context.Clock.Advance(TimeSpan.FromMinutes(10));

        ThreadModelSelectionDecision decision = context.Resolve(thread, "hot-alpha");

        Assert.Equal("hot-alpha", decision.SelectedModel);
        Assert.Equal(ThreadSelectionState.Expired, context.Store.TryGet(thread.Ref)!.SelectionState);
    }

    [Fact]
    public void UnknownThreadReferenceIsNotFound()
    {
        TestContext context = new();

        Assert.Equal(ThreadSelectionOperationStatus.NotFound, context.Store.SetSelection("deadbeefdeadbeef", "hot-beta", 1).Status);
        Assert.Equal(ThreadSelectionOperationStatus.NotFound, context.Store.ClearSelection("deadbeefdeadbeef", 1).Status);
        Assert.Null(context.Store.TryGet("deadbeefdeadbeef"));
    }

    [Fact]
    public void StoreCapacityRefusesNewObservations()
    {
        TestContext context = new(new ThreadSelectionOptions { MaxObservedThreads = 2 });

        _ = context.Resolve(Identity(ThreadOneId, "turn"), "hot-alpha");
        _ = context.Resolve(Identity(ThreadTwoId, "turn"), "hot-alpha");
        _ = context.Resolve(Identity(ThreadThreeId, "turn"), "hot-alpha");

        Assert.Equal(2, context.Store.List(10).Count);
    }

    [Fact]
    public void SelectionFailureIsRecordedForObservability()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");
        context.Resolve(thread, "hot-alpha");
        _ = context.Store.SetSelection(thread.Ref, "hot-beta", 1);

        context.Store.RecordSelectionFailure(thread.Ref, "control_model_capability_mismatch", context.Clock.UtcNow);

        ThreadSelectionSnapshot snapshot = context.Store.TryGet(thread.Ref)!;
        Assert.Equal("control_model_capability_mismatch", snapshot.LastFailureCode);
        Assert.NotNull(snapshot.LastFailureAt);
    }

    [Fact]
    public void Automatic_quota_failover_becomes_active_sticky_selection()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");
        ThreadModelSelectionDecision requestStart = context.Resolve(thread, "hot-alpha");

        Assert.Equal(1UL, requestStart.ThreadGeneration);
        Assert.True(context.Store.TryApplyAutomaticSelection(
            thread.Ref,
            "hot-alpha",
            requestStart.ThreadGeneration,
            "hot-beta",
            context.Clock.UtcNow));

        ThreadSelectionSnapshot snapshot = context.Store.TryGet(thread.Ref)!;
        Assert.Equal(ThreadSelectionState.Active, snapshot.SelectionState);
        Assert.Equal("hot-beta", snapshot.SelectionModel);
        Assert.Equal(2UL, snapshot.SelectionGeneration);
        Assert.Equal("hot-beta", context.Resolve(thread, "hot-alpha").SelectedModel);
    }

    [Fact]
    public void Manual_selection_generation_always_wins_over_late_automatic_failover()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");
        ThreadModelSelectionDecision requestStart = context.Resolve(thread, "hot-alpha");

        ThreadSelectionOperationResult manual = context.Store.SetSelection(
            thread.Ref,
            "hot-gamma",
            requestStart.ThreadGeneration!.Value);
        Assert.Equal(ThreadSelectionOperationStatus.Applied, manual.Status);

        Assert.False(context.Store.TryApplyAutomaticSelection(
            thread.Ref,
            "hot-alpha",
            requestStart.ThreadGeneration,
            "hot-beta",
            context.Clock.UtcNow));

        ThreadSelectionSnapshot snapshot = context.Store.TryGet(thread.Ref)!;
        Assert.Equal(ThreadSelectionState.Pending, snapshot.SelectionState);
        Assert.Equal("hot-gamma", snapshot.SelectionModel);
        Assert.Equal(manual.Generation, snapshot.SelectionGeneration);
    }

    [Fact]
    public void OpenCaptureExpiresAtTheBoundaryAndFreesTheSlot()
    {
        TestContext context = new();
        string token = context.Store.OpenCapture("client.owner_a").Capture!.Token;

        // One tick before the capture TTL the window is still live.
        context.Clock.Advance(ThreadSelectionOptions.DefaultCaptureTtl - TimeSpan.FromTicks(1));
        Assert.Equal(ThreadCaptureStatus.Open, context.Store.TryGetCapture(token, "client.owner_a")!.Status);
        Assert.True(context.Store.Status().CaptureOpen);

        // Expiry is inclusive: at the boundary instant the window is gone.
        context.Clock.Advance(TimeSpan.FromTicks(1));
        Assert.Null(context.Store.TryGetCapture(token, "client.owner_a"));
        Assert.False(context.Store.Status().CaptureOpen);

        // The expired window must not keep the single OPEN slot locked.
        Assert.Equal(ThreadCaptureOpenStatus.Opened, context.Store.OpenCapture("client.owner_b").Status);
    }

    [Fact]
    public void OpenCaptureItselfPerformsCaptureExpiry()
    {
        TestContext context = new();
        _ = context.Store.OpenCapture("client.owner_a");
        context.Clock.Advance(ThreadSelectionOptions.DefaultCaptureTtl + TimeSpan.FromSeconds(30));

        // No read happened in between: opening must clean up by itself.
        Assert.Equal(ThreadCaptureOpenStatus.Opened, context.Store.OpenCapture("client.owner_b").Status);
        Assert.True(context.Store.Status().CaptureOpen);
    }

    [Fact]
    public void ExpiredCaptureCanNeverBeCancelled()
    {
        TestContext context = new();
        string token = context.Store.OpenCapture("client.owner_a").Capture!.Token;
        context.Clock.Advance(ThreadSelectionOptions.DefaultCaptureTtl);

        // A DELETE on an expired token is an unknown token, never a success.
        Assert.False(context.Store.CancelCapture(token, "client.owner_a"));
        Assert.Null(context.Store.TryGetCapture(token, "client.owner_a"));
    }

    [Fact]
    public void CapturedRetentionExpiresWithoutTouchingSelections()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");
        string token = context.Store.OpenCapture("client.owner_a").Capture!.Token;

        _ = context.Resolve(thread, "hot-alpha");
        ThreadCaptureSnapshot captured = context.Store.TryGetCapture(token, "client.owner_a")!;
        Assert.Equal(ThreadCaptureStatus.Captured, captured.Status);
        Assert.Equal(thread.Ref, captured.ThreadRef);

        // An explicit model selection is armed afterwards and becomes active.
        _ = context.Store.SetSelection(thread.Ref, "hot-beta", 1);
        Assert.Equal("hot-beta", context.Resolve(thread, "hot-alpha").SelectedModel);

        context.Clock.Advance(ThreadSelectionOptions.CapturedRetentionTtl - TimeSpan.FromTicks(1));
        Assert.Equal(ThreadCaptureStatus.Captured, context.Store.TryGetCapture(token, "client.owner_a")!.Status);

        context.Clock.Advance(TimeSpan.FromTicks(1));
        Assert.Null(context.Store.TryGetCapture(token, "client.owner_a"));

        // Capture lifecycle and selection lifecycle are independent.
        Assert.Equal(ThreadSelectionState.Active, context.Store.TryGet(thread.Ref)!.SelectionState);
        Assert.Equal("hot-beta", context.Resolve(thread, "hot-alpha").SelectedModel);
    }

    [Fact]
    public void CaptureWindowsExpireIndependently()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");
        string first = context.Store.OpenCapture("client.owner_a").Capture!.Token;
        _ = context.Resolve(thread, "hot-alpha");

        // Open a second window just before the captured result reaches retention
        // expiry, so the two windows have different expiry instants.
        context.Clock.Advance(ThreadSelectionOptions.CapturedRetentionTtl - TimeSpan.FromTicks(1));
        string second = context.Store.OpenCapture("client.owner_b").Capture!.Token;

        context.Clock.Advance(TimeSpan.FromTicks(1));
        _ = context.Store.Status();

        Assert.Null(context.Store.TryGetCapture(first, "client.owner_a"));
        Assert.Equal(ThreadCaptureStatus.Open, context.Store.TryGetCapture(second, "client.owner_b")!.Status);
        Assert.True(context.Store.Status().CaptureOpen);
        Assert.NotNull(context.Store.TryGet(thread.Ref));
    }

    [Fact]
    public void RetainedCapturesAreHardBoundedAndNeverEvictTheLiveWindow()
    {
        // The ceiling is derived from the registry cap, so no new user setting
        // exists; a small cap makes the pressure path observable.
        TestContext context = new(new ThreadSelectionOptions { MaxObservedThreads = 2 });
        ThreadIdentity thread = Identity(ThreadOneId, "turn");

        string first = context.Store.OpenCapture("client.owner_a").Capture!.Token;
        _ = context.Resolve(thread, "hot-alpha");
        context.Clock.Advance(TimeSpan.FromSeconds(1));
        string second = context.Store.OpenCapture("client.owner_a").Capture!.Token;
        _ = context.Resolve(thread, "hot-alpha");
        context.Clock.Advance(TimeSpan.FromSeconds(1));

        // A third window exceeds the ceiling: the OLDEST captured result goes.
        string third = context.Store.OpenCapture("client.owner_a").Capture!.Token;
        _ = context.Resolve(thread, "hot-alpha");

        Assert.Null(context.Store.TryGetCapture(first, "client.owner_a"));
        Assert.NotNull(context.Store.TryGetCapture(second, "client.owner_a"));
        Assert.NotNull(context.Store.TryGetCapture(third, "client.owner_a"));

        // Thread observation and selection state are untouched by capture pressure.
        Assert.NotNull(context.Store.TryGet(thread.Ref));
        Assert.Equal("hot-alpha", context.Resolve(thread, "hot-alpha").SelectedModel);

        // A live OPEN window is never evicted: the ceiling is only applied when a
        // new window is actually inserted.
        TestContext tight = new(new ThreadSelectionOptions { MaxObservedThreads = 1 });
        ThreadIdentity tightThread = Identity(ThreadTwoId, "turn");
        string live = tight.Store.OpenCapture("client.owner_a").Capture!.Token;
        Assert.NotNull(tight.Store.TryGetCapture(live, "client.owner_a"));
        Assert.Equal(ThreadCaptureOpenStatus.Busy, tight.Store.OpenCapture("client.owner_a").Status);
        Assert.NotNull(tight.Store.TryGetCapture(live, "client.owner_a"));

        _ = tight.Resolve(tightThread, "hot-alpha");
        string next = tight.Store.OpenCapture("client.owner_a").Capture!.Token;
        Assert.Null(tight.Store.TryGetCapture(live, "client.owner_a"));
        Assert.NotNull(tight.Store.TryGetCapture(next, "client.owner_a"));
    }

    [Fact]
    public void CaptureEvictionOrderIsDeterministicWhenTimestampsMatch()
    {
        // Every capture happens at the SAME frozen instant here, and tokens are
        // random: only the creation sequence may decide which result is evicted.
        TestContext context = new(new ThreadSelectionOptions { MaxObservedThreads = 2 });
        ThreadIdentity thread = Identity(ThreadOneId, "turn");

        string first = context.Store.OpenCapture("client.owner_a").Capture!.Token;
        _ = context.Resolve(thread, "hot-alpha");
        string second = context.Store.OpenCapture("client.owner_a").Capture!.Token;
        _ = context.Resolve(thread, "hot-alpha");
        string third = context.Store.OpenCapture("client.owner_a").Capture!.Token;
        _ = context.Resolve(thread, "hot-alpha");

        Assert.Null(context.Store.TryGetCapture(first, "client.owner_a"));
        Assert.NotNull(context.Store.TryGetCapture(second, "client.owner_a"));
        Assert.NotNull(context.Store.TryGetCapture(third, "client.owner_a"));
    }

    [Fact]
    public void SecondOpenCaptureIsBusyAndNeverReplacesTheFirst()
    {
        TestContext context = new();
        ThreadCaptureOpenResult first = context.Store.OpenCapture("client.owner_a");
        Assert.Equal(ThreadCaptureOpenStatus.Opened, first.Status);

        // A different owner, and even the same owner, may never open a second
        // window while one is OPEN - and never cancels or replaces the first.
        ThreadCaptureOpenResult foreignOwner = context.Store.OpenCapture("client.owner_b");
        Assert.Equal(ThreadCaptureOpenStatus.Busy, foreignOwner.Status);
        Assert.Null(foreignOwner.Capture);

        ThreadCaptureOpenResult sameOwner = context.Store.OpenCapture("client.owner_a");
        Assert.Equal(ThreadCaptureOpenStatus.Busy, sameOwner.Status);
        Assert.Null(sameOwner.Capture);

        ThreadCaptureSnapshot unchanged = context.Store.TryGetCapture(first.Capture!.Token, "client.owner_a")!;
        Assert.Equal(ThreadCaptureStatus.Open, unchanged.Status);
        Assert.Equal(first.Capture.Token, unchanged.Token);
        Assert.Null(unchanged.ThreadRef);
        Assert.Equal(0L, context.Store.CaptureInvariantViolationCount);
    }

    [Fact]
    public void CaptureReadAndCancelAreOwnerScoped()
    {
        TestContext context = new();
        string token = context.Store.OpenCapture("client.owner_a").Capture!.Token;

        // A foreign owner sees exactly the same thing as an unknown token, so
        // capture existence is never disclosed.
        Assert.Null(context.Store.TryGetCapture(token, "client.owner_b"));
        Assert.False(context.Store.CancelCapture(token, "client.owner_b"));
        Assert.Equal(ThreadCaptureStatus.Open, context.Store.TryGetCapture(token, "client.owner_a")!.Status);

        Assert.True(context.Store.CancelCapture(token, "client.owner_a"));
        Assert.Null(context.Store.TryGetCapture(token, "client.owner_a"));
    }

    [Fact]
    public void CapturedWindowAllowsTheNextWindowWithoutSwitchingAModel()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");
        string first = context.Store.OpenCapture("client.owner_a").Capture!.Token;

        ThreadModelSelectionDecision decision = context.Resolve(thread, "hot-alpha");

        // The capture turn is never a switch turn.
        Assert.Equal("hot-alpha", decision.SelectedModel);
        Assert.Equal(ThreadModelSelectionDecision.SourceNone, decision.SelectionSource);
        Assert.Equal(ThreadSelectionState.None, context.Store.TryGet(thread.Ref)!.SelectionState);

        ThreadCaptureSnapshot captured = context.Store.TryGetCapture(first, "client.owner_a")!;
        Assert.Equal(ThreadCaptureStatus.Captured, captured.Status);
        Assert.Equal(thread.Ref, captured.ThreadRef);

        // A CAPTURED window is not OPEN, so the next window may open - while the
        // captured result stays readable for its own owner only.
        Assert.Equal(ThreadCaptureOpenStatus.Opened, context.Store.OpenCapture("client.owner_b").Status);
        Assert.NotNull(context.Store.TryGetCapture(first, "client.owner_a"));
        Assert.Null(context.Store.TryGetCapture(first, "client.owner_b"));
    }

    [Fact]
    public async Task ConcurrentOpenCaptureHasExactlyOneWinner()
    {
        TestContext context = new();

        ThreadCaptureOpenResult[] results = await Task.WhenAll(
            Task.Run(() => context.Store.OpenCapture("client.owner_a")),
            Task.Run(() => context.Store.OpenCapture("client.owner_b")));

        Assert.Equal(1, results.Count(static result => result.Status == ThreadCaptureOpenStatus.Opened));
        Assert.Equal(1, results.Count(static result => result.Status == ThreadCaptureOpenStatus.Busy));
        Assert.True(context.Store.Status().CaptureOpen);
        Assert.Equal(0L, context.Store.CaptureInvariantViolationCount);
    }

    [Fact]
    public void AmbiguousOpenWindowsAreNeverClaimed()
    {
        TestContext context = new();
        ThreadIdentity thread = Identity(ThreadOneId, "turn");
        ThreadCaptureSnapshot legitimate = context.Store.OpenCapture("client.owner_a").Capture!;
        SeedSecondOpenCapture(context);

        // The invariant is violated (only reachable by bypassing the public
        // surface). The claim must fail closed instead of picking an arbitrary
        // dictionary entry.
        ThreadModelSelectionDecision decision = context.Resolve(thread, "hot-alpha");

        Assert.Equal("hot-alpha", decision.SelectedModel);
        Assert.Equal(1L, context.Store.CaptureInvariantViolationCount);

        ThreadCaptureSnapshot firstSnapshot = context.Store.TryGetCapture(legitimate.Token, "client.owner_a")!;
        Assert.Equal(ThreadCaptureStatus.Open, firstSnapshot.Status);
        Assert.Null(firstSnapshot.ThreadRef);

        ThreadCaptureSnapshot injectedSnapshot = context.Store.TryGetCapture(SeededCaptureToken, "client.ghost")!;
        Assert.Equal(ThreadCaptureStatus.Open, injectedSnapshot.Status);
        Assert.Null(injectedSnapshot.ThreadRef);
    }

    private const string SeededCaptureToken = "0123456789abcdef0123456789abcdef";

    /// <summary>
    /// White-box injection of a second OPEN window: the public surface cannot
    /// produce this state any more, so the defensive fail-closed branch is
    /// verified by seeding the private capture table directly.
    /// </summary>
    private static void SeedSecondOpenCapture(TestContext context)
    {
        Type captureType = typeof(ThreadSelectionStore)
            .GetNestedType("MutableCaptureState", System.Reflection.BindingFlags.NonPublic)!;
        object injected = Activator.CreateInstance(captureType, nonPublic: true)!;
        captureType.GetProperty("Token")!.SetValue(injected, SeededCaptureToken);
        captureType.GetProperty("OwnerClientId")!.SetValue(injected, "client.ghost");
        captureType.GetProperty("Status")!.SetValue(injected, ThreadCaptureStatus.Open);
        captureType.GetProperty("CreatedAt")!.SetValue(injected, context.Clock.UtcNow);
        captureType.GetProperty("ExpiresAt")!.SetValue(injected, context.Clock.UtcNow.AddMinutes(5));

        System.Reflection.FieldInfo capturesField = typeof(ThreadSelectionStore)
            .GetField("_captures", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
        var captures = (System.Collections.IDictionary)capturesField.GetValue(context.Store)!;
        captures[SeededCaptureToken] = injected;
    }

    private static ThreadIdentity Identity(string rawId, string? requestKind)
    {
        Assert.True(CanonicalThreadId.TryParse(rawId, out CanonicalThreadId? canonical));
        return new ThreadIdentity
        {
            ThreadId = canonical!,
            Ref = ThreadRef.From(canonical!),
            RequestKind = requestKind,
        };
    }

    private sealed class TestContext
    {
        public TestContext(ThreadSelectionOptions? options = null, bool enabled = true)
        {
            Clock = new MutableClock(Origin);
            Store = new ThreadSelectionStore(options ?? ThreadSelectionOptions.Create(
                ThreadSelectionOptions.DefaultMaxObservedThreads,
                ThreadSelectionOptions.DefaultEntryIdleTtl,
                ThreadSelectionOptions.DefaultPendingTtl,
                ThreadSelectionOptions.DefaultActiveIdleTtl), Clock, enabled);
        }

        public MutableClock Clock { get; }

        public ThreadSelectionStore Store { get; }

        public ThreadModelSelectionDecision Resolve(ThreadIdentity thread, string requestedModel)
            => Store.Resolve(new ThreadModelSelectionRequest
            {
                Thread = thread,
                ClientId = "client.codex_desktop",
                RequestedModel = requestedModel,
                ObservedAt = Clock.UtcNow,
            });
    }

    private sealed class MutableClock : IClock
    {
        private DateTimeOffset _now;

        public MutableClock(DateTimeOffset now)
        {
            _now = now;
        }

        public DateTimeOffset UtcNow => _now;

        public void Advance(TimeSpan delta) => _now = _now.Add(delta);
    }
}
