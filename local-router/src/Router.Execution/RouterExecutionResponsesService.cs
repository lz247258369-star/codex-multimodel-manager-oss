using Router.CircuitBreaker;
using Router.ClientAdapters.Responses;
using Router.Core.Abstractions;
using Router.Core.Context;
using Router.Core.Errors;
using Router.Health;
using Router.Policies;
using Router.ProviderAdapters.Abstractions;
using Router.ProtocolAdapters.Abstractions;
using Router.Registries;
using Router.Routing;
using Router.Secrets;

namespace Router.Execution;

/// <summary>
/// Production <see cref="IResponsesService"/> execution boundary. One instance
/// owns one immutable registry snapshot, one provider adapter registry, one
/// protocol adapter registry, one upstream transport, and one set of policy
/// bodies. Every request flows through the real route resolver, protocol
/// compatibility gate, provider adapter registry, provider harness, and
/// upstream transport; it never synthesizes responses and never guesses
/// provider/model identity. Resolution always consumes the current dynamic
/// passive-health projection when a tracker is composed, and streamed
/// executions are finalized only at their terminal boundary.
/// </summary>
public sealed class RouterExecutionResponsesService : IResponsesService, IDisposable
{
    private readonly RouterRegistrySnapshot _snapshot;
    private readonly IRouteResolver _routeResolver;
    private readonly ProviderAdapterRegistry _providerAdapters;
    private readonly ProtocolAdapterRegistry _protocolAdapters;
    private readonly ISecretResolver _secretResolver;
    private readonly IUpstreamTransport _transport;
    private readonly IRouterExecutionEndpointSource _endpointSource;
    private readonly RouterExecutionPolicySet _policies;
    private readonly IRouterExecutionPolicySource? _policySource;
    private readonly ProviderAdapterHarness _harness;
    private readonly CircuitBreakerStateMachine _circuitBreaker;
    private readonly PassiveHealthTracker? _passiveHealth;
    private readonly IExecutionOutcomeSink? _outcomeSink;
    private readonly IClock _clock;
    private readonly IThreadModelSelectionSource? _threadModelSelection;
    private readonly IThreadAutomaticSelectionSink? _threadAutomaticSelection;
    private readonly QuotaAvailabilityTracker _quotaAvailability;
    private readonly bool _quotaFailoverEnabled;
    private bool _disposed;

    public RouterExecutionResponsesService(
        RouterRegistrySnapshot snapshot,
        IRouteResolver routeResolver,
        ProviderAdapterRegistry providerAdapters,
        ProtocolAdapterRegistry protocolAdapters,
        ISecretResolver secretResolver,
        IUpstreamTransport transport,
        IRouterExecutionEndpointSource endpointSource,
        RouterExecutionPolicySet? policies = null,
        IClock? clock = null,
        CircuitBreakerStateMachine? circuitBreaker = null,
        PassiveHealthTracker? passiveHealth = null,
        IExecutionOutcomeSink? outcomeSink = null,
        IRouterExecutionPolicySource? policySource = null,
        IThreadModelSelectionSource? threadModelSelectionSource = null,
        bool quotaFailoverEnabled = false,
        QuotaAvailabilityTracker? quotaAvailabilityTracker = null)
    {
        _snapshot = snapshot ?? throw new ArgumentNullException(nameof(snapshot));
        _routeResolver = routeResolver ?? throw new ArgumentNullException(nameof(routeResolver));
        _providerAdapters = providerAdapters ?? throw new ArgumentNullException(nameof(providerAdapters));
        _protocolAdapters = protocolAdapters ?? throw new ArgumentNullException(nameof(protocolAdapters));
        _secretResolver = secretResolver ?? throw new ArgumentNullException(nameof(secretResolver));
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _endpointSource = endpointSource ?? throw new ArgumentNullException(nameof(endpointSource));
        _policies = policies ?? RouterExecutionPolicySet.SafeDefaults;
        _policySource = policySource;
        _clock = clock ?? new SystemClock();
        _harness = new ProviderAdapterHarness(_clock);
        _circuitBreaker = circuitBreaker ?? new CircuitBreakerStateMachine(CircuitBreakerPolicy.Disabled);
        _passiveHealth = passiveHealth;
        _outcomeSink = outcomeSink;
        _threadModelSelection = threadModelSelectionSource;
        _threadAutomaticSelection = threadModelSelectionSource as IThreadAutomaticSelectionSink;
        _quotaFailoverEnabled = quotaFailoverEnabled;
        _quotaAvailability = quotaAvailabilityTracker ?? new QuotaAvailabilityTracker();
        ApprovedModelValidator = new RouterExecutionApprovedModelValidator(_snapshot);
    }

    /// <summary>Current passive-health tracker, when composed (read-only seam).</summary>
    public PassiveHealthTracker? PassiveHealth => _passiveHealth;

    /// <summary>Owned circuit-breaker state machine (read-only seam).</summary>
    public CircuitBreakerStateMachine CircuitBreaker => _circuitBreaker;

    /// <summary>HS-1C last-known quota state; no provider probing is performed.</summary>
    public QuotaAvailabilityTracker QuotaAvailability => _quotaAvailability;

    /// <summary>
    /// Static approved-model validator bound to this service's own immutable
    /// registry snapshot, so a thread-selection mutation is judged against
    /// exactly the registry production execution resolves against. It performs
    /// no provider request, network call, or health evaluation.
    /// </summary>
    public IApprovedModelValidator ApprovedModelValidator { get; }

    /// <inheritdoc />
    public async Task<ResponsesServiceResult> InvokeAsync(
        CanonicalResponsesRequest request,
        RequestContext context,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(context);
        cancellationToken.ThrowIfCancellationRequested();

        CapabilitySet required = RequestCapabilities(request);

        // HS-1B: the thread-scoped decision is taken exactly once, before route
        // resolution, and is never re-read for this logical request - retries,
        // failover attempts, and streamed events all keep the snapshot taken
        // here. Request truth stays request.Model; routing truth is the
        // selected model, which is why the canonical request object is never
        // rewritten by this boundary.
        ThreadModelSelectionDecision? selection = ResolveThreadSelection(request, context);
        string selectedModel = selection?.SelectedModel ?? request.Model;

        RouteRequest routeRequest = RouteRequest.Create(context.ClientId, selectedModel, required);
        RouteHealthSnapshot? health = CurrentRouteHealthSnapshot();
        RouteResolutionResult resolution = _routeResolver.Resolve(routeRequest, _snapshot, health, context);
        if (!resolution.IsResolved || resolution.Route is null)
        {
            RouterError routeError = resolution.Error ?? RouterError.RouteNotFound(context.RequestId.Value);

            // Fail closed: a thread that claimed model B is never silently
            // downgraded to A (or to any other model) when B cannot be routed.
            // The claim is preserved; only a safe failure code is recorded.
            RecordSelectionFailure(selection, routeError);
            return ResponsesServiceResult.Failure(routeError);
        }

        ExecutionSession session = new();
        // Capture the current policy view exactly once per logical request so
        // a concurrent live publication can never tear policies mid-request.
        RouterExecutionPolicySet policies = PoliciesFor(resolution.Route);
        ResponsesServiceResult result = await ExecuteResolvedRouteAsync(
            resolution.Route,
            routeRequest,
            required,
            request,
            context,
            session,
            policies,
            allowFailover: true,
            selection,
            cancellationToken).ConfigureAwait(false);

        // Non-stream results are already terminal, so their authoritative
        // metadata is emitted here exactly once. A streamed result carries the
        // same authoritative identity with CompletedAt == null, but the outcome
        // sink is NOT called while the stream is merely returned: the
        // terminal-aware stream boundary finalizes it exactly once at the real
        // terminal outcome (success, provider failure, cancellation, or
        // protocol-mapping failure).
        if (result.Execution is { } execution && result.EventStream is null)
        {
            _outcomeSink?.OnExecuted(execution);
        }

        return result;
    }

    /// <summary>Disposes the owned upstream transport.</summary>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        if (_transport is IDisposable disposable)
        {
            disposable.Dispose();
        }

        _disposed = true;
        GC.SuppressFinalize(this);
    }

    private async Task<ResponsesServiceResult> ExecuteResolvedRouteAsync(
        ResolvedRoute route,
        RouteRequest routeRequest,
        CapabilitySet requiredCapabilities,
        CanonicalResponsesRequest request,
        RequestContext context,
        ExecutionSession session,
        RouterExecutionPolicySet policies,
        bool allowFailover,
        ThreadModelSelectionDecision? selection,
        CancellationToken cancellationToken)
    {
        // Protocol compatibility gate (LR-8): canonical request semantics must
        // survive losslessly before any provider attempt exists.
        ProtocolAdapterResolveResult protocolResolve = _protocolAdapters.Resolve(
            route.ProtocolRoute.IngressProtocol,
            route.ProtocolRoute.UpstreamProtocol,
            route.ProtocolRoute.AdapterVersion);
        if (!protocolResolve.IsResolved || protocolResolve.Adapter is null || protocolResolve.Descriptor is null)
        {
            return ResponsesServiceResult.Failure(
                protocolResolve.Error ?? ProtocolAdapterErrors.NotFound(context.RequestId.Value));
        }

        ProtocolAdapters.Abstractions.Result<CanonicalResponsesRequest, RouterError> mappedRequestResult =
            protocolResolve.Adapter.MapRequest(request);
        if (mappedRequestResult.Error is not null)
        {
            return ResponsesServiceResult.Failure(mappedRequestResult.Error);
        }

        CanonicalResponsesRequest mappedRequest = mappedRequestResult.Value!;

        AdapterResolveResult adapterResolve = _providerAdapters.Resolve(
            route.ProviderRoute.AdapterId,
            route.ProviderRoute.AdapterVersion,
            route.ProviderRoute.ProviderId,
            route.ProtocolRoute.IngressProtocol);
        if (!adapterResolve.IsResolved || adapterResolve.Adapter is null)
        {
            return ResponsesServiceResult.Failure(
                adapterResolve.Error ?? ProviderAdapterErrors.AdapterNotFound(context.RequestId.Value));
        }

        ProviderAdapters.Abstractions.Result<ProviderAdapters.Abstractions.UpstreamEndpoint, RouterError> endpointResult =
            _endpointSource.Resolve(route.Endpoint);
        if (endpointResult.Error is not null)
        {
            return ResponsesServiceResult.Failure(endpointResult.Error);
        }

        ProviderAdapters.Abstractions.UpstreamEndpoint endpoint = endpointResult.Value!;

        if (route.SecretRef is not { } secretReference)
        {
            return ResponsesServiceResult.Failure(SecretErrors.Missing(route.ProviderRoute.ProviderId, context.RequestId.Value));
        }

        SecretResolutionResult secret = await _secretResolver
            .ResolveAsync(secretReference, route.ProviderRoute.ProviderId, cancellationToken)
            .ConfigureAwait(false);
        if (!secret.IsSuccess || secret.Handle is null)
        {
            secret.Handle?.Dispose();
            return ResponsesServiceResult.Failure(
                secret.Error ?? SecretErrors.Missing(route.ProviderRoute.ProviderId, context.RequestId.Value));
        }

        try
        {
            int attemptNumber = 1;
            DateTimeOffset deadline = EffectiveDeadline(context, _clock.UtcNow, policies.Timeout);
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                DateTimeOffset now = _clock.UtcNow;
                if (deadline <= now)
                {
                    return ResponsesServiceResult.Failure(ProviderAdapterErrors.TimeoutTotal(context.RequestId.Value));
                }

                CircuitBreakerKey breakerKey = CircuitBreakerKey.Create(
                    route.ProviderRoute.ProviderRouteId,
                    route.Endpoint.EndpointId,
                    route.ModelRoute.ModelRouteId);
                BreakerDecision admission = _circuitBreaker.CanAttempt(breakerKey, now);
                if (!admission.Admitted)
                {
                    return ResponsesServiceResult.Failure(
                        RouterError.Create(
                            RouterErrorCode.RouteIneligible,
                            "The route is not eligible for an upstream attempt.",
                            admission.ReasonCode,
                            context.RequestId.Value));
                }

                TimeSpan attemptBudget = deadline - now;
                TimeoutBoundaries boundaries = TimeoutPolicyEngine.Boundaries(policies.Timeout, attemptBudget);

                // HS-1C: only while quota failover is enabled, observe explicit
                // quota evidence for this one attempt. Disabled, the shared
                // transport is used directly and nothing about the attempt changes.
                QuotaEvidenceTransport? quotaEvidence = _quotaFailoverEnabled
                    ? new QuotaEvidenceTransport(_transport, route.ProviderRoute.ProviderId)
                    : null;
                AttemptExecutionResult attempt = await _harness
                    .ExecuteOnceAsync(
                        adapterResolve.Adapter,
                        route,
                        endpoint,
                        mappedRequest,
                        secret.Handle,
                        (IUpstreamTransport?)quotaEvidence ?? _transport,
                        boundaries,
                        context,
                        attemptNumber,
                        cancellationToken)
                    .ConfigureAwait(false);

                // Explicit quota evidence replaces the adapter's status-only error
                // (rate_limited / provider_4xx) for this attempt; anything else,
                // including cancellation, keeps the adapter's own outcome.
                if (quotaEvidence?.Evidence is { } quotaError
                    && attempt.Result.Error is not null
                    && attempt.Record.Outcome == AttemptOutcome.Failed)
                {
                    attempt = attempt with
                    {
                        Result = ProviderAdapterResult.Failed(quotaError),
                        Record = attempt.Record with { NormalizedError = quotaError },
                    };
                }

                session.Attempts.Add(attempt.Record);

                // Streaming executions are NOT finalized here. The harness has
                // only established that a stream was returned; success,
                // provider failure, or cancellation can be determined only
                // when the stream reaches a terminal boundary. Health,
                // circuit-breaker, and terminal metadata are finalized exactly
                // once by the terminal-aware stream wrapper below.
                if (attempt.Result.EventStream is not null)
                {
                    RecordQuotaAvailable(route, _clock.UtcNow);
                    return ResponsesServiceResult.Stream(
                        ExecuteTerminalStreamAsync(
                            protocolResolve.Adapter,
                            route,
                            attempt.Record,
                            attempt.Result.EventStream,
                            session,
                            cancellationToken),
                        CreateInFlightMetadata(route, session));
                }

                DateTimeOffset finalizedAt = _clock.UtcNow;
                if (attempt.Result.Error is { } attemptError)
                {
                    if (IsQuotaExhaustion(attemptError))
                    {
                        _quotaAvailability.RecordExhausted(route.RouteId, attemptError.Code, finalizedAt);
                    }

                    Observe(attempt.Record, route, finalizedAt);
                    if (attempt.Record.Outcome == AttemptOutcome.Cancelled)
                    {
                        return ResponsesServiceResult.Failure(attemptError, CreateMetadata(route, session, finalizedAt));
                    }

                    if (attemptNumber < policies.Retry.MaxAttempts)
                    {
                        // The retry decision and its delay are bounded by the
                        // deadline that actually remains AFTER the attempt,
                        // never by the budget that existed before it.
                        TimeSpan actualRemaining = deadline - finalizedAt;
                        PolicyDecision retryDecision = RetryPolicyEngine.Decide(
                            policies.Retry,
                            attemptNumber,
                            outputObserved: false,
                            remainingDeadline: actualRemaining <= TimeSpan.Zero ? TimeSpan.Zero : actualRemaining,
                            errorCode: attemptError.Code);
                        if (retryDecision.Kind == PolicyDecisionKind.Retry)
                        {
                            attemptNumber = retryDecision.AttemptNumber ?? attemptNumber + 1;
                            if (retryDecision.Delay is { } delay
                                && delay > TimeSpan.Zero
                                && actualRemaining > TimeSpan.Zero)
                            {
                                TimeSpan boundedDelay = delay > actualRemaining ? actualRemaining : delay;
                                await Task.Delay(boundedDelay, cancellationToken).ConfigureAwait(false);
                            }

                            continue;
                        }
                    }

                    bool quotaFailoverEntered = false;
                    if (allowFailover && _quotaFailoverEnabled && IsQuotaExhaustion(attemptError))
                    {
                        quotaFailoverEntered = IsQuotaFailoverEligible(route, context, selection);
                        ResponsesServiceResult? quotaFailover = await TryQuotaFailoverAsync(
                            route,
                            requiredCapabilities,
                            request,
                            context,
                            session,
                            selection,
                            cancellationToken).ConfigureAwait(false);
                        if (quotaFailover is not null)
                        {
                            return quotaFailover;
                        }
                    }

                    if (allowFailover)
                    {
                        ResponsesServiceResult? failover = await TryFailoverAsync(
                            route,
                            routeRequest,
                            requiredCapabilities,
                            request,
                            context,
                            session,
                            policies,
                            selection,
                            cancellationToken).ConfigureAwait(false);
                        if (failover is not null)
                        {
                            return failover;
                        }
                    }

                    if (quotaFailoverEntered)
                    {
                        // G-6: every approved fallback was tried once (or skipped as
                        // known-exhausted / ineligible) without success. Stop here
                        // with an explicit, content-free reason; nothing loops.
                        return ResponsesServiceResult.Failure(
                            QuotaErrors.QuotaFallbacksExhausted(context.RequestId.Value),
                            CreateMetadata(route, session, _clock.UtcNow));
                    }

                    return ResponsesServiceResult.Failure(attemptError, CreateMetadata(route, session, finalizedAt));
                }

                if (attempt.Result.Response is { } nonStream)
                {
                    ProtocolAdapters.Abstractions.Result<CanonicalResponsesResponse, RouterError> mapped =
                        protocolResolve.Adapter.MapResponse(nonStream);
                    if (mapped.Error is not null)
                    {
                        RouterError mappingError = mapped.Error;
                        Observe(WithTerminalOutcome(attempt.Record, AttemptOutcome.Failed, mappingError, finalizedAt), route, finalizedAt);
                        return ResponsesServiceResult.Failure(mappingError, CreateMetadata(route, session, finalizedAt));
                    }

                    RecordQuotaAvailable(route, finalizedAt);
                    Observe(attempt.Record, route, finalizedAt);
                    return ResponsesServiceResult.NonStream(mapped.Value!, CreateMetadata(route, session, finalizedAt));
                }

                RouterError internalError = RouterError.InternalError(context.RequestId.Value);
                Observe(WithTerminalOutcome(attempt.Record, AttemptOutcome.Failed, internalError, finalizedAt), route, finalizedAt);
                return ResponsesServiceResult.Failure(
                    internalError,
                    CreateMetadata(route, session, finalizedAt));
            }
        }
        finally
        {
            secret.Handle.Dispose();
        }
    }

    private async Task<ResponsesServiceResult?> TryQuotaFailoverAsync(
        ResolvedRoute original,
        CapabilitySet requiredCapabilities,
        CanonicalResponsesRequest request,
        RequestContext context,
        ExecutionSession session,
        ThreadModelSelectionDecision? selection,
        CancellationToken cancellationToken)
    {
        // HS-1C is thread-scoped by construction. If HS-1B is unavailable,
        // the Router never performs an automatic cross-model transition.
        if (_threadAutomaticSelection is null
            || selection?.ThreadRef is null
            || !IsQuotaFailoverEligible(original, context, selection)
            || !_snapshot.Routes.TryGetValue(original.RouteId, out RouterRouteRegistryEntry? originalRoute))
        {
            return null;
        }

        // Explicit fallback_route_ids are the ONLY candidate source. Known
        // AVAILABLE routes are tried before UNKNOWN routes; known EXHAUSTED
        // routes are skipped. Config order remains the tie-breaker.
        var candidates = originalRoute.FallbackRouteIds
            .Select((routeId, index) => new
            {
                RouteId = routeId,
                Index = index,
                State = _quotaAvailability.Get(routeId).State,
            })
            .Where(static candidate => candidate.State != QuotaAvailabilityState.Exhausted)
            .OrderBy(static candidate => candidate.State == QuotaAvailabilityState.Available ? 0 : 1)
            .ThenBy(static candidate => candidate.Index)
            .ToArray();

        foreach (var candidate in candidates)
        {
            cancellationToken.ThrowIfCancellationRequested();

            if (!_snapshot.Routes.TryGetValue(candidate.RouteId, out RouterRouteRegistryEntry? candidateEntry)
                || _snapshot.TryGetModelRoute(candidateEntry.ModelRouteId) is not { } candidateModel)
            {
                continue;
            }

            RouteRequest candidateRequest = RouteRequest.Create(
                context.ClientId,
                candidateModel.ClientModelId,
                requiredCapabilities,
                candidateEntry.RouteId);

            RouteResolutionResult candidateResolution = _routeResolver.Resolve(
                candidateRequest,
                _snapshot,
                CurrentRouteHealthSnapshot(),
                context);
            if (!candidateResolution.IsResolved || candidateResolution.Route is null)
            {
                continue;
            }

            // V1 is Responses-only, but keep protocol equivalence explicit so a
            // future protocol adapter can never become an implicit quota bridge.
            if (!string.Equals(
                    candidateResolution.Route.ProtocolRoute.UpstreamProtocol,
                    original.ProtocolRoute.UpstreamProtocol,
                    StringComparison.Ordinal))
            {
                continue;
            }

            RouterExecutionPolicySet candidatePolicies = PoliciesFor(candidateResolution.Route);
            ResponsesServiceResult candidateResult = await ExecuteResolvedRouteAsync(
                candidateResolution.Route,
                candidateRequest,
                requiredCapabilities,
                request,
                context,
                session,
                candidatePolicies,
                allowFailover: false,
                selection,
                cancellationToken).ConfigureAwait(false);

            if (candidateResult.Error is not null)
            {
                if (string.Equals(candidateResult.Error.Code, RouterErrorCode.Cancelled, StringComparison.Ordinal))
                {
                    return candidateResult;
                }

                // Candidate never produced output. It is safe to keep walking
                // the explicit recovery chain; no sticky mutation has happened.
                continue;
            }

            // The candidate produced a response or an accepted stream. Make it
            // sticky only if the thread generation still matches request start.
            // A concurrent/manual selection increments the generation and wins.
            _threadAutomaticSelection.TryApplyAutomaticSelection(
                selection.ThreadRef,
                selection.SelectedModel,
                selection.ThreadGeneration,
                candidateResolution.Route.ModelRoute.ClientModelId,
                _clock.UtcNow);

            return candidateResult;
        }

        return null;
    }

    private async Task<ResponsesServiceResult?> TryFailoverAsync(
        ResolvedRoute original,
        RouteRequest routeRequest,
        CapabilitySet requiredCapabilities,
        CanonicalResponsesRequest request,
        RequestContext context,
        ExecutionSession session,
        RouterExecutionPolicySet policies,
        ThreadModelSelectionDecision? selection,
        CancellationToken cancellationToken)
    {
        if (session.Attempts.Count == 0 || policies.Failover.Enabled is false)
        {
            return null;
        }

        // Failover resolution consumes the CURRENT dynamic passive-health
        // projection at failover time, never a stale request-start snapshot.
        RouteHealthSnapshot? health = CurrentRouteHealthSnapshot();
        RouterRouteRegistryEntry[] siblings = FindSameModelAlternateRoutes(original);
        foreach (RouterRouteRegistryEntry candidate in siblings)
        {
            if (_snapshot.TryGetProviderRoute(candidate.ProviderRouteId) is not { } candidateProviderRoute
                || _snapshot.TryGetProtocolRoute(candidate.ProtocolRouteId) is not { } candidateProtocolRoute
                || _snapshot.TryGetModelRoute(candidate.ModelRouteId) is not { } candidateModelRoute
                || _snapshot.TryGetClient(original.ClientId) is not { } client)
            {
                continue;
            }

            FailoverClass failoverClass = string.Equals(
                candidateProviderRoute.ProviderId,
                original.ProviderRoute.ProviderId,
                StringComparison.Ordinal)
                    ? FailoverClass.SameModelAlternateEndpoint
                    : FailoverClass.SameModelAlternateProvider;

            CapabilitySet candidateCapabilities = EffectiveCapabilities(
                _snapshot,
                candidateProviderRoute,
                candidateProtocolRoute,
                candidateModelRoute,
                client);

            FailoverDecisionRequest decisionRequest = new()
            {
                CandidateClass = failoverClass,
                OutputObserved = false,
                RouteId = candidate.RouteId,
                OriginalProviderId = original.ProviderRoute.ProviderId,
                CandidateProviderId = candidateProviderRoute.ProviderId,
                CandidateProtocolId = candidateProtocolRoute.UpstreamProtocol,
                OriginalProtocolId = original.ProtocolRoute.UpstreamProtocol,
                RequiredCapabilities = requiredCapabilities.Values.ToArray(),
                CandidateCapabilities = candidateCapabilities.Values.ToArray(),
                CandidateExplicitlyApproved = policies.Failover.AllowSameModelAlternateProvider,
            };

            PolicyDecision decision = FailoverPolicyEngine.Decide(policies.Failover, decisionRequest);
            if (decision.Kind != PolicyDecisionKind.Failover)
            {
                continue;
            }

            RouteRequest candidateRequest = routeRequest with { ExplicitRoutePreference = candidate.RouteId };
            RouteResolutionResult candidateResolution = _routeResolver.Resolve(
                candidateRequest,
                _snapshot,
                health,
                context);
            if (!candidateResolution.IsResolved || candidateResolution.Route is null)
            {
                return ResponsesServiceResult.Failure(
                    candidateResolution.Error ?? RouterError.RouteNotFound(context.RequestId.Value));
            }

            // A same-provider candidate is a genuine alternate endpoint only
            // when the resolved candidate executes a different endpoint than
            // the exhausted attempt. Re-running the same endpoint is
            // same-route retry territory, never an alternate-endpoint
            // failover, so such a candidate is skipped rather than mislabeled.
            if (failoverClass == FailoverClass.SameModelAlternateEndpoint
                && string.Equals(
                    candidateResolution.Route.Endpoint.EndpointId,
                    original.Endpoint.EndpointId,
                    StringComparison.Ordinal))
            {
                continue;
            }

            return await ExecuteResolvedRouteAsync(
                candidateResolution.Route,
                candidateRequest,
                requiredCapabilities,
                request,
                context,
                session,
                policies,
                allowFailover: false,
                selection,
                cancellationToken).ConfigureAwait(false);
        }

        return null;
    }

    private RouterRouteRegistryEntry[] FindSameModelAlternateRoutes(ResolvedRoute original)
    {
        List<RouterRouteRegistryEntry> matches = [];
        foreach (RouterRouteRegistryEntry route in _snapshot.Routes.Values)
        {
            if (string.Equals(route.RouteId, original.RouteId, StringComparison.Ordinal)
                || !route.Enabled
                || !route.ClientIds.Contains(original.ClientId, StringComparer.Ordinal))
            {
                continue;
            }

            if (_snapshot.TryGetModelRoute(route.ModelRouteId) is not { } modelRoute)
            {
                continue;
            }

            ModelLookupResult lookup = _snapshot.TryResolveModel(modelRoute.ProviderId, original.ModelRoute.ClientModelId);
            if (lookup.IsFound
                && lookup.Entry is not null
                && string.Equals(lookup.Entry.ModelRouteId, route.ModelRouteId, StringComparison.Ordinal))
            {
                matches.Add(route);
            }
        }

        return matches
            .OrderBy(static route => route.RouteId, StringComparer.Ordinal)
            .ToArray();
    }

    private void Observe(AttemptRecord record, ResolvedRoute route, DateTimeOffset now)
    {
        // Quota/credit exhaustion is an account-capacity state, not evidence
        // that the provider endpoint or model route is technically unhealthy.
        // HS-1C owns that state separately so a later manual retry is never
        // blocked by a stale passive-health or circuit-breaker penalty.
        bool quotaExhausted = record.NormalizedError is { } normalized
            && IsQuotaExhaustion(normalized);

        if (_passiveHealth is not null && !quotaExhausted)
        {
            _passiveHealth.Record(new PassiveOutcomeObservation
            {
                Key = HealthKey.Create(
                    route.ProviderRoute.ProviderRouteId,
                    route.Endpoint.EndpointId,
                    route.ModelRoute.ModelRouteId),
                Route = RouteHealthKey.Create(route.RouteId),
                Outcome = record.Outcome,
                ErrorCode = record.NormalizedError?.Code,
                ObservedAt = record.CompletedAt,
            });
        }

        if (quotaExhausted)
        {
            return;
        }

        CircuitBreakerKey key = CircuitBreakerKey.Create(
            route.ProviderRoute.ProviderRouteId,
            route.Endpoint.EndpointId,
            route.ModelRoute.ModelRouteId);
        if (record.Outcome == AttemptOutcome.Succeeded)
        {
            _circuitBreaker.RecordSuccess(key);
        }
        else
        {
            _circuitBreaker.RecordFailure(key, now, record.NormalizedError?.Code);
        }
    }

    /// <summary>
    /// Builds the terminal view of an attempt record. Streaming attempts are
    /// finalized by the terminal-aware boundary, so the outcome and completion
    /// time are never decided while the stream is merely being returned.
    /// </summary>
    private static AttemptRecord WithTerminalOutcome(
        AttemptRecord attempt,
        AttemptOutcome outcome,
        RouterError? error,
        DateTimeOffset completedAt)
        => attempt with
        {
            Outcome = outcome,
            NormalizedError = error,
            CompletedAt = completedAt,
            FinalCheckpoint = RetryCheckpointState.Terminal,
            CancellationReason = outcome == AttemptOutcome.Cancelled
                ? CancellationReason.ClientDisconnect
                : CancellationReason.None,
        };

    private RouterExecutionPolicySet PoliciesFor(ResolvedRoute route)
        => _policySource is null ? _policies : _policySource.Resolve(route);

    /// <summary>
    /// Resolves the thread-scoped model selection for one request. When no
    /// selection source is composed the requested model is used unchanged, so a
    /// Router without HS-1B behaves exactly as before.
    /// </summary>
    private ThreadModelSelectionDecision? ResolveThreadSelection(CanonicalResponsesRequest request, RequestContext context)
        => _threadModelSelection?.Resolve(new ThreadModelSelectionRequest
        {
            Thread = context.Thread,
            ClientId = context.ClientId,
            RequestedModel = request.Model,
            ObservedAt = context.ReceivedAt,
        });

    /// <summary>
    /// Records a fail-closed capability error when a thread override was in
    /// force for this request. The selection state itself is never changed,
    /// cleared, or migrated here.
    /// </summary>
    private void RecordSelectionFailure(ThreadModelSelectionDecision? selection, RouterError routeError)
    {
        if (selection is null
            || _threadModelSelection is not IThreadSelectionFailureSink sink
            || string.Equals(selection.SelectedModel, selection.RequestedModel, StringComparison.Ordinal))
        {
            return;
        }

        sink.RecordSelectionFailure(selection.ThreadRef, routeError.Code, _clock.UtcNow);
    }

    /// <summary>
    /// True when an exhausted route would enter HS-1C: an HS-1B thread turn with
    /// automatic selection available and at least one explicit fallback route.
    /// </summary>
    private bool IsQuotaFailoverEligible(ResolvedRoute route, RequestContext context, ThreadModelSelectionDecision? selection)
        => _threadAutomaticSelection is not null
            && selection?.ThreadRef is not null
            && context.Thread?.IsEligibleTurn == true
            && _snapshot.Routes.TryGetValue(route.RouteId, out RouterRouteRegistryEntry? entry)
            && entry.FallbackRouteIds.Count > 0;

    private void RecordQuotaAvailable(ResolvedRoute route, DateTimeOffset observedAt)
    {
        if (_quotaFailoverEnabled)
        {
            _quotaAvailability.RecordAvailable(route.RouteId, observedAt);
        }
    }

    private static bool IsQuotaExhaustion(RouterError error)
        => string.Equals(error.Code, RouterErrorCode.QuotaExhausted, StringComparison.Ordinal)
            || string.Equals(error.Code, RouterErrorCode.CreditExhausted, StringComparison.Ordinal);

    private static DateTimeOffset EffectiveDeadline(RequestContext context, DateTimeOffset now, TimeoutPolicy timeout)
    {
        DateTimeOffset policyDeadline = now + timeout.TotalTimeout;
        return context.DeadlineAt is { } deadline && deadline < policyDeadline ? deadline : policyDeadline;
    }

    /// <summary>
    /// Authoritative identity snapshot for a streamed execution that has been
    /// returned to the caller but has not yet reached its terminal boundary.
    /// Every identity field and <see cref="ResponsesExecutionMetadata.ExecutionStartedAt"/>
    /// are already fixed by route resolution plus the first provider attempt;
    /// <see cref="ResponsesExecutionMetadata.CompletedAt"/> is intentionally
    /// null and is finalized later by the terminal-aware stream boundary.
    /// </summary>
    private ResponsesExecutionMetadata CreateInFlightMetadata(ResolvedRoute route, ExecutionSession session)
        => CreateMetadata(route, session, _clock.UtcNow) with { CompletedAt = null };

    private static ResponsesExecutionMetadata CreateMetadata(
        ResolvedRoute route,
        ExecutionSession session,
        DateTimeOffset completedAt)
    {
        DateTimeOffset startedAt = session.Attempts.Count > 0
            ? session.Attempts[0].StartedAt
            : completedAt;
        return new()
        {
            ConfigGeneration = route.ConfigGeneration,
            ClientId = route.ClientId,
            RouteId = route.RouteId,
            ProviderId = route.ProviderRoute.ProviderId,
            ProviderRouteId = route.ProviderRoute.ProviderRouteId,
            ModelRouteId = route.ModelRoute.ModelRouteId,
            ClientModelId = route.ModelRoute.ClientModelId,
            CatalogModelId = route.ModelRoute.CatalogMetadata?.ModelId ?? route.ModelRoute.ModelId,
            UpstreamModelId = route.ModelRoute.UpstreamModelId,
            EndpointId = route.Endpoint.EndpointId,
            AttemptCount = session.Attempts.Count,
            ExecutionStartedAt = startedAt,
            CompletedAt = completedAt,
        };
    }

    /// <summary>
    /// Current route-level dynamic health consumed by every resolver call.
    /// When no passive tracker is composed, resolution keeps the existing
    /// configured-health semantics; the tracker's projection is passed through
    /// unchanged, never recomputed by a second health algorithm.
    /// </summary>
    private RouteHealthSnapshot? CurrentRouteHealthSnapshot()
        => _passiveHealth is null
            ? null
            : ToResolverHealthSnapshot(_passiveHealth.ProjectRoutes(_clock.UtcNow));

    private static RouteHealthSnapshot ToResolverHealthSnapshot(RouteHealthProjection projection)
    {
        var states = new Dictionary<string, RouteHealthState>(StringComparer.Ordinal);
        foreach (RouteHealthProjectionEntry entry in projection.Routes)
        {
            states[entry.RouteId] = entry.State;
        }

        return new RouteHealthSnapshot
        {
            ObservedAt = projection.GeneratedAt,
            States = states,
        };
    }

    /// <summary>
    /// Terminal-aware stream boundary. Health, circuit-breaker, and terminal
    /// metadata are finalized exactly once, and only when one of these
    /// terminal outcomes actually occurs:
    /// normal completion, terminal provider error event, unexpected EOF,
    /// idle/total stream timeout, protocol mapping failure, or cancellation.
    /// Because this boundary runs outside the attempt/retry/failover loop,
    /// once any output event has been observed there is structurally no
    /// retry and no failover.
    /// </summary>
    private TerminalAwareEventStream ExecuteTerminalStreamAsync(
        IResponsesProtocolAdapter adapter,
        ResolvedRoute route,
        AttemptRecord attempt,
        IAsyncEnumerable<CanonicalEvent> providerEvents,
        ExecutionSession session,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(adapter);
        ArgumentNullException.ThrowIfNull(providerEvents);

        return new TerminalAwareEventStream(
            adapter,
            providerEvents,
            (outcome, error, completedAt) => FinalizeStream(route, attempt, session, outcome, error, completedAt),
            attempt.RequestId,
            () => _clock.UtcNow,
            cancellationToken);
    }

    private void FinalizeStream(
        ResolvedRoute route,
        AttemptRecord attempt,
        ExecutionSession session,
        AttemptOutcome outcome,
        RouterError? error,
        DateTimeOffset completedAt)
    {
        AttemptRecord terminal = WithTerminalOutcome(attempt, outcome, error, completedAt);
        Observe(terminal, route, completedAt);
        _outcomeSink?.OnExecuted(CreateMetadata(route, session, completedAt));
    }

    private static CapabilitySet RequestCapabilities(CanonicalResponsesRequest request)
    {
        var capabilities = new List<string> { "text" };
        if (request.Stream)
        {
            capabilities.Add("streaming");
        }

        if (request.Reasoning is not null)
        {
            capabilities.Add("reasoning");
        }

        if (request.Tools.Count > 0 || request.ToolChoice is not null)
        {
            capabilities.Add("tools");
        }

        return CapabilitySet.From(capabilities);
    }

    private static CapabilitySet EffectiveCapabilities(
        RouterRegistrySnapshot snapshot,
        ProviderRouteRegistryEntry providerRoute,
        ProtocolRouteRegistryEntry protocolRoute,
        ModelRouteRegistryEntry modelRoute,
        ClientRegistryEntry client)
        => CanonicalIngressCapabilities.V1
            .Intersect(client.Capabilities)
            .Intersect(protocolRoute.Capabilities)
            .Intersect(providerRoute.Capabilities)
            .Intersect(modelRoute.Capabilities);

    /// <summary>Mutable per-request attempt accumulation.</summary>
    private sealed class ExecutionSession
    {
        public List<AttemptRecord> Attempts { get; } = [];
    }
}

/// <summary>Internal failure when a canonical event cannot be mapped losslessly.</summary>
public sealed class ProtocolEventMappingException : Exception
{
    public ProtocolEventMappingException()
        : base("A canonical event could not be mapped without semantic loss.")
    {
    }
}
