using System.Security.Cryptography;
using Router.Core.Abstractions;
using Router.Core.Concurrency;
using Router.Core.Context;

namespace Router.ThreadSelection;

/// <summary>
/// Bounded, in-memory thread-selection domain.
///
/// This store is the single owner of observed-thread metadata, per-thread model
/// selections, capture windows, and per-thread generations. It never persists
/// anything, never stores request content, and never exposes a raw canonical
/// thread identity outside the process: every projection uses
/// <see cref="ThreadRef"/>.
///
/// Model approval is deliberately not decided here; the control plane validates
/// the target model through the existing registry/resolver primitives before
/// calling <see cref="SetSelection"/>.
///
/// Every public operation observes or mutates runtime state under the shared
/// <see cref="IRouterRuntimeConsistencyGate"/>, so no operation can complete in
/// the middle of a runtime publication that is changing the published config
/// generation and this store's effective capability together.
///
/// Capture windows are globally unique: at most one
/// <see cref="ThreadCaptureStatus.Open"/> window exists per Router process,
/// because an incoming Codex turn carries no trustworthy control-plane owner
/// correlation, and a window is readable/cancellable only by the authenticated
/// control-plane client that opened it.
/// </summary>
public sealed class ThreadSelectionStore : IThreadModelSelectionSource, IThreadSelectionFailureSink, IThreadAutomaticSelectionSink, IRouterRuntimeFeatureState
{
    private readonly ThreadSelectionOptions _options;
    private readonly IClock _clock;
    private readonly IRouterRuntimeConsistencyGate _consistencyGate;
    private readonly object _sync = new();
    private readonly Dictionary<string, MutableThreadState> _threads = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _refIndex = new(StringComparer.Ordinal);
    private readonly Dictionary<string, MutableCaptureState> _captures = new(StringComparer.Ordinal);
    private bool _enabled;
    private long _evictedCount;
    private long _captureInvariantViolations;
    private long _captureSequence;

    /// <summary>
    /// Creates the store in the given feature state. The production Host passes
    /// the ONE process-wide runtime consistency gate; when none is supplied the
    /// store keeps a private boundary so an isolated store can never be observed
    /// half-published by its own operations.
    /// </summary>
    public ThreadSelectionStore(
        ThreadSelectionOptions options,
        IClock clock,
        bool enabled,
        IRouterRuntimeConsistencyGate? consistencyGate = null)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(clock);
        _options = options;
        _clock = clock;
        _consistencyGate = consistencyGate ?? new RouterRuntimeConsistencyGate();
        _enabled = enabled;
    }

    /// <summary>The runtime consistency boundary this store participates in.</summary>
    public IRouterRuntimeConsistencyGate ConsistencyGate => _consistencyGate;

    /// <summary>
    /// Number of capture invariant violations observed since start (safe
    /// aggregate only: never a token, owner, or thread identity).
    /// </summary>
    public long CaptureInvariantViolationCount
    {
        get
        {
            using (_consistencyGate.EnterShared())
            {
                lock (_sync)
                {
                    return _captureInvariantViolations;
                }
            }
        }
    }

    /// <summary>Current runtime enabled state.</summary>
    public bool Enabled
    {
        get
        {
            using (_consistencyGate.EnterShared())
            {
                lock (_sync)
                {
                    return _enabled;
                }
            }
        }
    }

    /// <summary>
    /// Applies a capability/feature state change inside its own exclusive
    /// runtime consistency section. Disabling always clears every selection and
    /// cancels every capture; enabling only grants the capability and never
    /// creates state.
    /// </summary>
    public void ApplyFeatureState(bool enabled, string disabledReason)
    {
        using (_consistencyGate.EnterExclusive())
        {
            ApplyPublishedState(enabled, disabledReason);
        }
    }

    /// <inheritdoc />
    public void ApplyPublishedState(bool enabled, string disabledReason)
    {
        lock (_sync)
        {
            if (!enabled)
            {
                ClearAllLocked(disabledReason);
                CancelAllCapturesLocked();
            }

            _enabled = enabled;
        }
    }

    /// <inheritdoc />
    public ThreadModelSelectionDecision Resolve(ThreadModelSelectionRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        using (_consistencyGate.EnterShared())
        {
            return ResolveCore(request);
        }
    }

    private ThreadModelSelectionDecision ResolveCore(ThreadModelSelectionRequest request)
    {
        ThreadIdentity? thread = request.Thread;
        if (thread is null)
        {
            return ThreadModelSelectionDecision.None(request, null);
        }

        lock (_sync)
        {
            DateTimeOffset now = request.ObservedAt;
            ExpireLocked(now);
            if (!_enabled)
            {
                return ThreadModelSelectionDecision.None(request, null);
            }

            MutableThreadState? state = ObserveLocked(thread, request, now);
            if (state is null)
            {
                return ThreadModelSelectionDecision.None(request, null);
            }

            if (!thread.IsEligibleTurn)
            {
                // Observation only: auxiliary requests never consume or apply a
                // selection and always keep the Codex requested model.
                state.LastSelectedModel = request.RequestedModel;
                return ThreadModelSelectionDecision.None(request, thread, state.SelectionGeneration);
            }

            TryClaimCaptureLocked(state, now);

            if (state.Selection == ThreadSelectionState.Pending && state.SelectionModel is { } pendingModel)
            {
                state.Selection = ThreadSelectionState.Active;
                state.SelectionGeneration++;
                state.LastActivatedAt = now;
                state.SelectionExpiresAt = now + _options.ActiveIdleTtl;
                state.LastSelectedModel = pendingModel;
                return new ThreadModelSelectionDecision
                {
                    RequestedModel = request.RequestedModel,
                    SelectedModel = pendingModel,
                    SelectionSource = ThreadModelSelectionDecision.SourceThreadPending,
                    OverrideGeneration = state.SelectionGeneration,
                    ThreadGeneration = state.SelectionGeneration,
                    ThreadRef = state.Ref,
                    RequestKind = thread.RequestKind,
                };
            }

            if (state.Selection == ThreadSelectionState.Active && state.SelectionModel is { } activeModel)
            {
                state.SelectionExpiresAt = now + _options.ActiveIdleTtl;
                state.LastSelectedModel = activeModel;
                return new ThreadModelSelectionDecision
                {
                    RequestedModel = request.RequestedModel,
                    SelectedModel = activeModel,
                    SelectionSource = ThreadModelSelectionDecision.SourceThreadActive,
                    OverrideGeneration = state.SelectionGeneration,
                    ThreadGeneration = state.SelectionGeneration,
                    ThreadRef = state.Ref,
                    RequestKind = thread.RequestKind,
                };
            }

            state.LastSelectedModel = request.RequestedModel;
            return ThreadModelSelectionDecision.None(request, thread, state.SelectionGeneration);
        }
    }

    /// <inheritdoc />
    public bool TryApplyAutomaticSelection(
        string? threadRef,
        string expectedCurrentModel,
        ulong? expectedThreadGeneration,
        string selectedModel,
        DateTimeOffset observedAt)
    {
        if (string.IsNullOrWhiteSpace(threadRef)
            || string.IsNullOrWhiteSpace(expectedCurrentModel)
            || string.IsNullOrWhiteSpace(selectedModel))
        {
            return false;
        }

        using (_consistencyGate.EnterExclusive())
        {
            lock (_sync)
            {
                ExpireLocked(observedAt);
                if (!_enabled
                    || !TryFindLocked(threadRef!, out MutableThreadState? state)
                    || state is null)
                {
                    return false;
                }

                // Strong CAS: ANY manual selection mutation after request start
                // increments the generation, even when the user re-selects the
                // same model. Automation must never overwrite that decision.
                if (expectedThreadGeneration is { } expected
                    && state.SelectionGeneration != expected)
                {
                    return false;
                }

                string? effectiveCurrent = state.Selection is ThreadSelectionState.Pending or ThreadSelectionState.Active
                    ? state.SelectionModel
                    : state.LastSelectedModel;
                if (!string.Equals(effectiveCurrent, expectedCurrentModel, StringComparison.Ordinal))
                {
                    return false;
                }

                state.Selection = ThreadSelectionState.Active;
                state.SelectionModel = selectedModel;
                state.SelectionGeneration++;
                state.SelectionIssuedAt = observedAt;
                state.SelectionExpiresAt = observedAt + _options.ActiveIdleTtl;
                state.LastActivatedAt = observedAt;
                state.LastSelectedModel = selectedModel;
                state.LastClearedReason = null;
                state.LastFailureCode = null;
                state.LastFailureAt = null;
                return true;
            }
        }
    }

    /// <summary>Records a fail-closed capability error for a selected thread.</summary>
    public void RecordSelectionFailure(string? threadRef, string failureCode, DateTimeOffset observedAt)
    {
        if (string.IsNullOrWhiteSpace(threadRef) || string.IsNullOrWhiteSpace(failureCode))
        {
            return;
        }

        using (_consistencyGate.EnterShared())
        {
            lock (_sync)
            {
                if (TryFindLocked(threadRef!, out MutableThreadState? state) && state is not null)
                {
                    state.LastFailureCode = failureCode;
                    state.LastFailureAt = observedAt;
                }
            }
        }
    }

    /// <summary>Returns a bounded, content-free projection of observed threads.</summary>
    public IReadOnlyList<ThreadSelectionSnapshot> List(int limit)
    {
        using (_consistencyGate.EnterShared())
        {
            lock (_sync)
            {
                ExpireLocked(_clock.UtcNow);
                int take = Math.Clamp(limit, 1, _options.MaxObservedThreads);
                return _threads.Values
                    .OrderByDescending(static state => state.LastSeen)
                    .ThenBy(static state => state.Ref, StringComparer.Ordinal)
                    .Take(take)
                    .Select(ToSnapshot)
                    .ToArray();
            }
        }
    }

    /// <summary>Returns one thread projection, or <c>null</c> when unknown.</summary>
    public ThreadSelectionSnapshot? TryGet(string? threadRef)
    {
        if (string.IsNullOrWhiteSpace(threadRef))
        {
            return null;
        }

        using (_consistencyGate.EnterShared())
        {
            lock (_sync)
            {
                ExpireLocked(_clock.UtcNow);
                return TryFindLocked(threadRef!, out MutableThreadState? state) && state is not null
                    ? ToSnapshot(state)
                    : null;
            }
        }
    }

    /// <summary>Sets a pending selection with generation compare-and-swap.</summary>
    public ThreadSelectionOperationResult SetSelection(string? threadRef, string model, ulong expectedGeneration)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(model);
        using (_consistencyGate.EnterExclusive())
        {
            return SetSelectionCore(threadRef, model, expectedGeneration);
        }
    }

    private ThreadSelectionOperationResult SetSelectionCore(string? threadRef, string model, ulong expectedGeneration)
    {
        lock (_sync)
        {
            DateTimeOffset now = _clock.UtcNow;
            ExpireLocked(now);
            if (!_enabled)
            {
                return new ThreadSelectionOperationResult { Status = ThreadSelectionOperationStatus.Disabled };
            }

            if (string.IsNullOrWhiteSpace(threadRef) || !TryFindLocked(threadRef!, out MutableThreadState? state) || state is null)
            {
                return new ThreadSelectionOperationResult { Status = ThreadSelectionOperationStatus.NotFound };
            }

            if (expectedGeneration != state.SelectionGeneration)
            {
                return new ThreadSelectionOperationResult
                {
                    Status = ThreadSelectionOperationStatus.Conflict,
                    Generation = state.SelectionGeneration,
                    Snapshot = ToSnapshot(state),
                };
            }

            state.Selection = ThreadSelectionState.Pending;
            state.SelectionModel = model;
            state.SelectionGeneration++;
            state.SelectionIssuedAt = now;
            state.SelectionExpiresAt = now + _options.PendingTtl;
            state.LastClearedReason = null;
            state.LastFailureCode = null;
            state.LastFailureAt = null;

            return new ThreadSelectionOperationResult
            {
                Status = ThreadSelectionOperationStatus.Applied,
                Generation = state.SelectionGeneration,
                Snapshot = ToSnapshot(state),
            };
        }
    }

    /// <summary>Clears one thread's selection with generation compare-and-swap.</summary>
    public ThreadSelectionOperationResult ClearSelection(string? threadRef, ulong expectedGeneration)
    {
        using (_consistencyGate.EnterExclusive())
        {
            return ClearSelectionCore(threadRef, expectedGeneration);
        }
    }

    private ThreadSelectionOperationResult ClearSelectionCore(string? threadRef, ulong expectedGeneration)
    {
        lock (_sync)
        {
            DateTimeOffset now = _clock.UtcNow;
            ExpireLocked(now);
            if (!_enabled)
            {
                return new ThreadSelectionOperationResult { Status = ThreadSelectionOperationStatus.Disabled };
            }

            if (string.IsNullOrWhiteSpace(threadRef) || !TryFindLocked(threadRef!, out MutableThreadState? state) || state is null)
            {
                return new ThreadSelectionOperationResult { Status = ThreadSelectionOperationStatus.NotFound };
            }

            if (expectedGeneration != state.SelectionGeneration)
            {
                return new ThreadSelectionOperationResult
                {
                    Status = ThreadSelectionOperationStatus.Conflict,
                    Generation = state.SelectionGeneration,
                    Snapshot = ToSnapshot(state),
                };
            }

            ApplyClear(state, "explicit_clear");
            return new ThreadSelectionOperationResult
            {
                Status = ThreadSelectionOperationStatus.Applied,
                Generation = state.SelectionGeneration,
                Snapshot = ToSnapshot(state),
            };
        }
    }

    /// <summary>Clears every selection and cancels every capture.</summary>
    public ThreadSelectionOperationResult ClearAll()
    {
        using (_consistencyGate.EnterExclusive())
        {
            return ClearAllCore();
        }
    }

    private ThreadSelectionOperationResult ClearAllCore()
    {
        lock (_sync)
        {
            ExpireLocked(_clock.UtcNow);
            int cleared = ClearAllLocked("explicit_clear_all");
            int cancelled = CancelAllCapturesLocked();
            return new ThreadSelectionOperationResult
            {
                Status = ThreadSelectionOperationStatus.Applied,
                ClearedCount = cleared,
                CancelledCaptureCount = cancelled,
            };
        }
    }

    /// <summary>
    /// Opens the process-wide capture window.
    ///
    /// At most one <see cref="ThreadCaptureStatus.Open"/> window may exist at a
    /// time: an incoming Codex turn carries no trustworthy control-plane owner
    /// correlation, so two parallel OPEN windows could never be disambiguated
    /// safely. Opening a second window therefore fails closed with
    /// <see cref="ThreadCaptureOpenStatus.Busy"/> and never cancels, replaces,
    /// or reveals the existing window - regardless of which owner opened it.
    /// </summary>
    public ThreadCaptureOpenResult OpenCapture(string ownerClientId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerClientId);
        using (_consistencyGate.EnterExclusive())
        {
            return OpenCaptureCore(ownerClientId);
        }
    }

    private ThreadCaptureOpenResult OpenCaptureCore(string ownerClientId)
    {
        lock (_sync)
        {
            DateTimeOffset now = _clock.UtcNow;
            ExpireLocked(now);
            if (!_enabled)
            {
                return ThreadCaptureOpenResult.Disabled();
            }

            int openCount = 0;
            foreach (MutableCaptureState candidate in _captures.Values)
            {
                if (candidate.Status == ThreadCaptureStatus.Open)
                {
                    openCount++;
                }
            }

            if (openCount > 0)
            {
                if (openCount > 1)
                {
                    // Defensive: more than one OPEN window must be impossible
                    // through the public surface. Record a safe, content-free
                    // invariant violation and fail closed.
                    _captureInvariantViolations++;
                }

                return ThreadCaptureOpenResult.Busy();
            }

            // The single OPEN slot is free. Retained CAPTURED results are
            // bounded: expired ones are already gone, and the oldest CAPTURED
            // result is evicted under pressure - never the live window and never
            // any thread selection state.
            EnforceRetainedCaptureCeilingLocked();

            string token = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
            MutableCaptureState capture = new()
            {
                Token = token,
                OwnerClientId = ownerClientId,
                Sequence = ++_captureSequence,
                Status = ThreadCaptureStatus.Open,
                CreatedAt = now,
                ExpiresAt = now + _options.CaptureTtl,
            };
            _captures[token] = capture;
            return ThreadCaptureOpenResult.Opened(ToCaptureSnapshot(capture));
        }
    }

    /// <summary>
    /// Returns one capture projection for its owner, or <c>null</c> when the
    /// token is unknown or belongs to a different authenticated control-plane
    /// client. A foreign token is reported exactly like an unknown token so
    /// capture existence is never disclosed.
    /// </summary>
    public ThreadCaptureSnapshot? TryGetCapture(string? token, string? ownerClientId)
    {
        if (string.IsNullOrWhiteSpace(token) || string.IsNullOrWhiteSpace(ownerClientId))
        {
            return null;
        }

        using (_consistencyGate.EnterShared())
        {
            lock (_sync)
            {
                ExpireLocked(_clock.UtcNow);
                return _captures.TryGetValue(token!, out MutableCaptureState? capture)
                    && IsOwnedBy(capture, ownerClientId!)
                        ? ToCaptureSnapshot(capture)
                        : null;
            }
        }
    }

    /// <summary>
    /// Cancels one capture window for its owner. A foreign owner cannot cancel
    /// another client's window and receives the same result as an unknown token.
    /// </summary>
    public bool CancelCapture(string? token, string? ownerClientId)
    {
        if (string.IsNullOrWhiteSpace(token) || string.IsNullOrWhiteSpace(ownerClientId))
        {
            return false;
        }

        using (_consistencyGate.EnterExclusive())
        {
            lock (_sync)
            {
                // Expiry first: an already-expired token must never be reported
                // as a successful cancellation (it becomes an unknown token).
                ExpireLocked(_clock.UtcNow);
                if (!_captures.TryGetValue(token!, out MutableCaptureState? capture)
                    || !IsOwnedBy(capture, ownerClientId!))
                {
                    return false;
                }

                capture.Status = ThreadCaptureStatus.Cancelled;
                _captures.Remove(token!);
                return true;
            }
        }
    }

    /// <summary>Safe aggregate status projection.</summary>
    public ThreadSelectionStatusSnapshot Status()
    {
        using (_consistencyGate.EnterShared())
        {
            lock (_sync)
            {
                DateTimeOffset now = _clock.UtcNow;
                ExpireLocked(now);
                int active = 0;
                int pending = 0;
                foreach (MutableThreadState state in _threads.Values)
                {
                    if (state.Selection == ThreadSelectionState.Active)
                    {
                        active++;
                    }
                    else if (state.Selection == ThreadSelectionState.Pending)
                    {
                        pending++;
                    }
                }

                return new ThreadSelectionStatusSnapshot
                {
                    Enabled = _enabled,
                    ObservedThreadCount = _threads.Count,
                    ActiveSelectionCount = active,
                    PendingSelectionCount = pending,
                    CaptureOpen = _captures.Values.Any(static capture => capture.Status == ThreadCaptureStatus.Open),
                    EvictedCount = _evictedCount,
                    SnapshotAt = now,
                };
            }
        }
    }

    private MutableThreadState? ObserveLocked(ThreadIdentity thread, ThreadModelSelectionRequest request, DateTimeOffset now)
    {
        string canonical = thread.ThreadId.Value;
        if (!_threads.TryGetValue(canonical, out MutableThreadState? state))
        {
            if (_refIndex.TryGetValue(thread.Ref, out string? existingCanonical)
                && !string.Equals(existingCanonical, canonical, StringComparison.Ordinal))
            {
                // Reference collision: never merge two distinct identities.
                return null;
            }

            if (_threads.Count >= _options.MaxObservedThreads)
            {
                // Capacity is enforced after TTL expiry; a full store of fresh
                // entries refuses new observations instead of evicting them.
                return null;
            }

            state = new MutableThreadState
            {
                Canonical = canonical,
                Ref = thread.Ref,
                FirstSeen = now,
                SelectionGeneration = 1,
            };
            _threads[canonical] = state;
            _refIndex[thread.Ref] = canonical;
        }

        state.ClientId = request.ClientId;
        state.LastSeen = now;
        state.LastRequestKind = thread.RequestKind;
        state.LastRequestedModel = request.RequestedModel;
        if (thread.WindowNumber is { } window)
        {
            state.WindowNumber = window;
        }

        return state;
    }

    /// <summary>
    /// Binds a claimable capture window to this thread. The claim is only made
    /// when exactly ONE OPEN window exists; if the invariant is ever violated
    /// the method claims nothing rather than picking an arbitrary dictionary
    /// entry, and records a safe, content-free violation instead.
    /// </summary>
    private void TryClaimCaptureLocked(MutableThreadState state, DateTimeOffset now)
    {
        MutableCaptureState? openCapture = null;
        int openCount = 0;
        foreach (MutableCaptureState capture in _captures.Values)
        {
            if (capture.Status != ThreadCaptureStatus.Open)
            {
                continue;
            }

            openCount++;
            openCapture = capture;
        }

        if (openCount == 0)
        {
            return;
        }

        if (openCount > 1)
        {
            _captureInvariantViolations++;
            return;
        }

        MutableCaptureState claimed = openCapture!;
        claimed.Status = ThreadCaptureStatus.Captured;
        claimed.CapturedAt = now;
        claimed.ThreadRef = state.Ref;
        claimed.ExpiresAt = now + ThreadSelectionOptions.CapturedRetentionTtl;
    }

    /// <summary>
    /// A capture window is readable and cancellable only by the authenticated
    /// control-plane client that opened it; every other client is treated like
    /// an unknown token.
    /// </summary>
    private static bool IsOwnedBy(MutableCaptureState capture, string ownerClientId)
        => string.Equals(capture.OwnerClientId, ownerClientId, StringComparison.Ordinal);

    /// <summary>
    /// Lazy expiry for the whole in-memory domain. It runs at read, claim, and
    /// mutation time under the store lock - never from a timer or background
    /// task - and always evaluates BOTH domains: an empty thread-expiry result
    /// can never skip capture cleanup.
    /// </summary>
    private void ExpireLocked(DateTimeOffset now)
    {
        ExpireThreadStateLocked(now);
        ExpireCaptureStateLocked(now);
    }

    /// <summary>
    /// Idle-TTL eviction for observed threads plus pending/active selection
    /// expiry. Selection lifecycle is independent of capture lifecycle.
    /// </summary>
    private void ExpireThreadStateLocked(DateTimeOffset now)
    {
        List<string>? expired = null;
        foreach (KeyValuePair<string, MutableThreadState> pair in _threads)
        {
            MutableThreadState state = pair.Value;
            if (now - state.LastSeen >= _options.EntryIdleTtl)
            {
                (expired ??= []).Add(pair.Key);
                continue;
            }

            if (state.Selection == ThreadSelectionState.Pending
                && state.SelectionExpiresAt is { } pendingExpiry
                && now >= pendingExpiry)
            {
                state.Selection = ThreadSelectionState.Expired;
                state.SelectionModel = null;
            }
            else if (state.Selection == ThreadSelectionState.Active
                && state.SelectionExpiresAt is { } activeExpiry
                && now >= activeExpiry)
            {
                state.Selection = ThreadSelectionState.Expired;
                state.SelectionModel = null;
            }
        }

        if (expired is null)
        {
            return;
        }

        foreach (string canonical in expired)
        {
            if (_threads.Remove(canonical, out MutableThreadState? removed))
            {
                _refIndex.Remove(removed.Ref);
                _evictedCount++;
            }
        }
    }

    /// <summary>
    /// Removes expired capture windows: an OPEN window whose capture TTL has
    /// elapsed, and a CAPTURED result whose retention TTL has elapsed. Both use
    /// the same boundary rule (<c>now &gt;= ExpiresAt</c>), so a token becomes
    /// indistinguishable from an unknown token the moment it expires. Capture
    /// expiry never touches observed threads or model selections.
    /// </summary>
    private void ExpireCaptureStateLocked(DateTimeOffset now)
    {
        List<string>? expired = null;
        foreach (KeyValuePair<string, MutableCaptureState> pair in _captures)
        {
            if (now >= pair.Value.ExpiresAt)
            {
                (expired ??= []).Add(pair.Key);
            }
        }

        if (expired is null)
        {
            return;
        }

        foreach (string token in expired)
        {
            _captures.Remove(token);
        }
    }

    /// <summary>
    /// Enforces the retained-capture ceiling before a new OPEN window is
    /// inserted. Expired entries are already gone, so the ceiling only ever
    /// removes the OLDEST CAPTURED result (deterministically, oldest
    /// <c>CapturedAt</c>/<c>CreatedAt</c> first, then token order). The live OPEN
    /// window is never evicted and thread selection state is never touched.
    /// </summary>
    private void EnforceRetainedCaptureCeilingLocked()
    {
        int ceiling = _options.MaxRetainedCaptures;
        while (_captures.Count >= ceiling)
        {
            string? evictToken = null;
            DateTimeOffset oldest = DateTimeOffset.MaxValue;
            long oldestSequence = long.MaxValue;
            foreach (KeyValuePair<string, MutableCaptureState> pair in _captures)
            {
                MutableCaptureState candidate = pair.Value;
                if (candidate.Status == ThreadCaptureStatus.Open)
                {
                    // The live window is never evicted under pressure.
                    continue;
                }

                DateTimeOffset stamp = candidate.CapturedAt ?? candidate.CreatedAt;
                // Deterministic order: the oldest retention stamp wins, with the
                // creation sequence as the tie-break so equal instants (and the
                // random tokens) can never decide the outcome.
                if (evictToken is null
                    || stamp < oldest
                    || (stamp == oldest && candidate.Sequence < oldestSequence))
                {
                    oldest = stamp;
                    oldestSequence = candidate.Sequence;
                    evictToken = pair.Key;
                }
            }

            if (evictToken is null)
            {
                // Only the OPEN window remains (or nothing at all): nothing may
                // be evicted, so the caller proceeds without further trimming.
                return;
            }

            _captures.Remove(evictToken);
        }
    }

    private int ClearAllLocked(string reason)
    {
        int cleared = 0;
        foreach (MutableThreadState state in _threads.Values)
        {
            if (state.Selection is ThreadSelectionState.Pending or ThreadSelectionState.Active)
            {
                ApplyClear(state, reason);
                cleared++;
            }
        }

        return cleared;
    }

    private static void ApplyClear(MutableThreadState state, string reason)
    {
        state.Selection = ThreadSelectionState.Cleared;
        state.SelectionModel = null;
        state.SelectionGeneration++;
        state.SelectionExpiresAt = null;
        state.LastClearedReason = reason;
        state.LastFailureCode = null;
        state.LastFailureAt = null;
    }

    private int CancelAllCapturesLocked()
    {
        if (_captures.Count == 0)
        {
            return 0;
        }

        int cancelled = _captures.Count;
        _captures.Clear();
        return cancelled;
    }

    private bool TryFindLocked(string threadRef, out MutableThreadState? state)
    {
        state = null;
        return _refIndex.TryGetValue(threadRef, out string? canonical)
            && _threads.TryGetValue(canonical, out state);
    }

    private static ThreadSelectionSnapshot ToSnapshot(MutableThreadState state)
        => new()
        {
            ThreadRef = state.Ref,
            ClientId = state.ClientId,
            FirstSeen = state.FirstSeen,
            LastSeen = state.LastSeen,
            LastRequestKind = state.LastRequestKind,
            LastRequestedModel = state.LastRequestedModel,
            LastSelectedModel = state.LastSelectedModel,
            WindowNumber = state.WindowNumber,
            SelectionState = state.Selection,
            SelectionModel = state.SelectionModel,
            SelectionGeneration = state.SelectionGeneration,
            SelectionIssuedAt = state.SelectionIssuedAt,
            SelectionExpiresAt = state.SelectionExpiresAt,
            LastActivatedAt = state.LastActivatedAt,
            LastFailureCode = state.LastFailureCode,
            LastFailureAt = state.LastFailureAt,
            LastClearedReason = state.LastClearedReason,
        };

    private static ThreadCaptureSnapshot ToCaptureSnapshot(MutableCaptureState capture)
        => new()
        {
            Token = capture.Token,
            OwnerClientId = capture.OwnerClientId,
            Status = capture.Status,
            CreatedAt = capture.CreatedAt,
            ExpiresAt = capture.ExpiresAt,
            CapturedAt = capture.CapturedAt,
            ThreadRef = capture.ThreadRef,
        };

    private sealed class MutableThreadState
    {
        public required string Canonical { get; init; }

        public required string Ref { get; init; }

        public string ClientId { get; set; } = string.Empty;

        public DateTimeOffset FirstSeen { get; set; }

        public DateTimeOffset LastSeen { get; set; }

        public string? LastRequestKind { get; set; }

        public string? LastRequestedModel { get; set; }

        public string? LastSelectedModel { get; set; }

        public int? WindowNumber { get; set; }

        public ThreadSelectionState Selection { get; set; } = ThreadSelectionState.None;

        public string? SelectionModel { get; set; }

        public ulong SelectionGeneration { get; set; }

        public DateTimeOffset? SelectionIssuedAt { get; set; }

        public DateTimeOffset? SelectionExpiresAt { get; set; }

        public DateTimeOffset? LastActivatedAt { get; set; }

        public string? LastFailureCode { get; set; }

        public DateTimeOffset? LastFailureAt { get; set; }

        public string? LastClearedReason { get; set; }
    }

    private sealed class MutableCaptureState
    {
        public required string Token { get; init; }

        public required string OwnerClientId { get; init; }

        /// <summary>Monotonic creation order; makes bounded eviction deterministic.</summary>
        public long Sequence { get; init; }

        public ThreadCaptureStatus Status { get; set; }

        public DateTimeOffset CreatedAt { get; init; }

        public DateTimeOffset ExpiresAt { get; set; }

        public DateTimeOffset? CapturedAt { get; set; }

        public string? ThreadRef { get; set; }
    }
}
