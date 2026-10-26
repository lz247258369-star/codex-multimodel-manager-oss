using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Router.Configuration;
using Router.Core.Concurrency;
using Router.Core.Context;
using Router.Core.Errors;
using Router.Core.Lifecycle;
using Router.Ingress.ControlPlane;
using Router.ThreadSelection;

namespace Router.Ingress.Handlers;

/// <summary>
/// LR-14P authenticated control-plane HTTP surface. Every endpoint reuses the
/// existing local bearer-token boundary plus the fixed
/// <c>router:control-plane</c> scope. Responses are versioned DTOs with fixed
/// safe fields; failures use the fixed control-plane error allowlist and never
/// leak exception text, secrets, content, endpoint URLs, or filesystem paths.
/// No control-plane read or mutation ever sends a provider request.
/// </summary>
public static class ControlPlaneHandlers
{
    public const string RequiredScope = "router:control-plane";

    private const string JsonMediaType = "application/json";
    private const string ResultApplied = "applied";

    /// <summary>
    /// Hard independent size limit for control-plane mutation bodies. This is
    /// intentionally much smaller than the 16 MB Responses payload limit.
    /// </summary>
    public const long MaxControlPlaneMutationBytes = 64 * 1024;

    /// <summary>Upper bound for a selected Router model id in a mutation body.</summary>
    public const int MaxThreadSelectionModelLength = 256;

    /// <summary>Length of an opaque capture token (16 random bytes, lowercase hex).</summary>
    public const int CaptureTokenLength = 32;

    /// <summary>
    /// Immutable feature view used by status/feature reads: the published
    /// runtime state when one exists, otherwise the durable config document.
    /// </summary>
    private readonly record struct ControlPlaneFeatureView(
        string ConfigGeneration,
        bool LocalRouterEnabled,
        bool ThreadSelectionEnabled);

    public static async Task StatusAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        ControlPlaneRuntimeServices? controlPlane = services.ControlPlane;

        // The published config and the thread-selection summary are captured
        // inside ONE shared runtime consistency section, so this combined
        // projection can never mix a new published generation with an old
        // capability state (or the reverse).
        (PublishedRouterState? published, ThreadSelectionStatusSnapshot? threadSummary) = CaptureRuntimeView(services);
        ControlPlaneFeatureView? featureView = published is not null
            ? new ControlPlaneFeatureView(
                published.ConfigGeneration,
                published.LocalRouterEnabled,
                published.ThreadSelectionEnabled)
            : await TryReadFeatureViewAsync(services, context).ConfigureAwait(false);
        if (featureView is not { } features)
        {
            return;
        }

        bool liveMutationAvailable = IsLiveMutationAvailable(services);
        ThreadSelectionStore? threadSelection = controlPlane?.ThreadSelection;
        LifecycleState state = services.Lifecycle.State;
        ControlPlaneStatusPayload payload = new()
        {
            SchemaVersionValue = 1,
            ConfigGeneration = features.ConfigGeneration,
            Lifecycle = state.ToWireName(),
            Ready = state == LifecycleState.Ready,
            InFlightCount = services.Limiter.InFlightCount,
            LocalRouterEnabled = features.LocalRouterEnabled,
            SupportedControlPlaneContracts =
            [
                "control-plane/status/v1",
                "control-plane/usage/v1",
                "control-plane/recent-requests/v1",
                "control-plane/policy/v1",
                "control-plane/feature/v1",
                "control-plane/thread-selection/v1",
            ],
            MeteringAvailability = new ControlPlaneAvailabilityPayload
            {
                Available = controlPlane!.Metering is not null,
                ReasonCode = controlPlane.Metering is null ? "metering_not_composed" : null,
            },
            RecentRequestAvailability = new ControlPlaneAvailabilityPayload
            {
                Available = controlPlane.RequestLog is not null,
                ReasonCode = controlPlane.RequestLog is null ? "recent_log_not_composed" : null,
            },
            PolicyMutationAvailable = liveMutationAvailable,
            FeatureMutationAvailable = liveMutationAvailable,
            ThreadSelection = new ControlPlaneThreadSelectionStatusPayload
            {
                ConfiguredEnabled = features.ThreadSelectionEnabled,
                EffectiveEnabled = threadSelection is not null && features.LocalRouterEnabled && threadSummary?.Enabled == true,
                MutationAvailable = liveMutationAvailable && threadSelection is not null,
                ObservedThreadCount = threadSummary?.ObservedThreadCount,
                ActiveSelectionCount = threadSummary?.ActiveSelectionCount,
                PendingSelectionCount = threadSummary?.PendingSelectionCount,
                CaptureOpen = threadSummary?.CaptureOpen,
                SnapshotAt = threadSummary?.SnapshotAt.ToString("O"),
                ReasonCode = threadSelection is null
                    ? ControlPlaneProjections.ThreadSelectionNotComposedCode
                    : threadSummary?.Enabled == true ? null : ControlPlaneProjections.ThreadSelectionDisabledCode,
            },
            HealthSummary = ControlPlaneProjections.BuildHealthSummary(controlPlane!.Health)!,
            CircuitBreaker = ControlPlaneProjections.CircuitBreakerGap(),
            LifecycleControl = new LifecycleControlAvailabilityPayload
            {
                StartStopAvailable = false,
                ReasonCode = ControlPlaneProjections.LifecycleControlGapCode,
            },
        };

        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.ContentType = JsonMediaType;
        await WriteJsonAsync(context, payload).ConfigureAwait(false);
    }

    /// <summary>
    /// GET /v1/router/control-plane/thread-selection-feature
    ///
    /// Configured state is durable config; effective state requires the overall
    /// Router feature to be on as well. Counts come from the single store's own
    /// aggregate snapshot, never from a second counting path.
    /// </summary>
    public static async Task ThreadSelectionFeatureReadAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        ThreadSelectionStore? store = services.ControlPlane?.ThreadSelection;
        if (store is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionUnavailable("thread_selection")).ConfigureAwait(false);
            return;
        }

        // Same single shared section as the status projection: the published
        // generation and the capability summary are one consistent pair.
        (PublishedRouterState? published, ThreadSelectionStatusSnapshot? capturedSummary) = CaptureRuntimeView(services);
        ControlPlaneFeatureView? featureView = published is not null
            ? new ControlPlaneFeatureView(
                published.ConfigGeneration,
                published.LocalRouterEnabled,
                published.ThreadSelectionEnabled)
            : await TryReadFeatureViewAsync(services, context).ConfigureAwait(false);
        if (featureView is not { } features)
        {
            return;
        }

        ThreadSelectionStatusSnapshot summary = capturedSummary ?? store.Status();
        ControlPlaneThreadSelectionFeaturePayload payload = new()
        {
            SchemaVersionValue = 1,
            ConfigGeneration = features.ConfigGeneration,
            ConfiguredEnabled = features.ThreadSelectionEnabled,
            EffectiveEnabled = features.LocalRouterEnabled && summary.Enabled,
            MutationAvailable = IsLiveMutationAvailable(services),
            ObservedThreadCount = summary.ObservedThreadCount,
            ActiveSelectionCount = summary.ActiveSelectionCount,
            PendingSelectionCount = summary.PendingSelectionCount,
            CaptureOpen = summary.CaptureOpen,
            SnapshotAt = summary.SnapshotAt.ToString("O"),
        };
        await WriteJsonOkAsync(context, payload).ConfigureAwait(false);
    }

    /// <summary>
    /// PUT /v1/router/control-plane/thread-selection-feature
    ///
    /// The mutation is owned by the existing config operator, which publishes
    /// through the composite runtime sink inside its mutation gate. The handler
    /// therefore never applies feature state a second time: the SAME store the
    /// execution path uses is already in the committed generation when the
    /// operator returns.
    /// </summary>
    public static async Task ThreadSelectionFeatureMutateAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        if (!IsJsonContentType(context))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("content_type")).ConfigureAwait(false);
            return;
        }

        ControlPlaneThreadSelectionFeatureMutationRequest? request =
            await ReadJsonAsync<ControlPlaneThreadSelectionFeatureMutationRequest>(context).ConfigureAwait(false);
        if (request is null)
        {
            return;
        }

        if (request.SchemaVersionValue != 1)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("schema_version")).ConfigureAwait(false);
            return;
        }

        if (string.IsNullOrWhiteSpace(request.ExpectedGeneration))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("expected_generation")).ConfigureAwait(false);
            return;
        }

        ControlPlaneRuntimeServices? controlPlane = services.ControlPlane;
        if (controlPlane?.ThreadSelection is null || controlPlane.ConfigOperator is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionUnavailable("thread_selection")).ConfigureAwait(false);
            return;
        }

        if (!IsLiveMutationAvailable(services))
        {
            // Writing the durable config without a live publication boundary
            // would claim a capability change the running Router never applied.
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionUnavailable("live_publication")).ConfigureAwait(false);
            return;
        }

        LocalRouterConfigMutationResult result = await controlPlane.ConfigOperator
            .SetThreadSelectionEnabledAsync(request.ExpectedGeneration, request.Enabled, context.RequestAborted)
            .ConfigureAwait(false);
        if (!result.IsSuccess || result.View is null)
        {
            RouterError error = result.Error ?? ControlPlaneErrors.ThreadSelectionFeatureUpdateFailed("thread_selection.enabled");
            if (IsConfigFailure(error))
            {
                error = ControlPlaneErrors.ThreadSelectionFeatureUpdateFailed(error.Param);
            }

            await WriteErrorAsync(context, error).ConfigureAwait(false);
            return;
        }

        ControlPlaneThreadSelectionFeatureMutationResponsePayload payload = new()
        {
            SchemaVersionValue = 1,
            ResultCode = ResultApplied,
            ConfigGeneration = result.View.ConfigGeneration,
            ConfiguredEnabled = result.View.Config.LocalRouter.ThreadSelection.Enabled,
            // Read the applied pair from the same boundary the publication used.
            EffectiveEnabled = CaptureEffectiveFeatureState(services),
        };
        await WriteJsonOkAsync(context, payload).ConfigureAwait(false);
    }

    /// <summary>
    /// GET /v1/router/control-plane/threads?limit=N
    ///
    /// Bounded read of observed threads. Only the external thread reference is
    /// exposed; canonical thread ids, raw metadata, and content never appear.
    /// </summary>
    public static async Task ThreadsAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        ThreadSelectionStore? store = services.ControlPlane?.ThreadSelection;
        if (store is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionUnavailable("thread_selection")).ConfigureAwait(false);
            return;
        }

        int limit = ControlPlaneProjections.ResolveLimit(context.Request.Query["limit"]);
        ThreadSelectionStatusSnapshot summary = store.Status();
        IReadOnlyList<ThreadSelectionSnapshot> threads = store.List(limit);
        ControlPlaneThreadsPayload payload = new()
        {
            SchemaVersionValue = 1,
            SnapshotAt = summary.SnapshotAt.ToString("O"),
            EffectiveEnabled = store.Enabled,
            ObservedThreadCount = summary.ObservedThreadCount,
            ThreadCount = threads.Count,
            Threads = threads.Select(ControlPlaneProjections.ToThreadEntry).ToArray(),
        };
        await WriteJsonOkAsync(context, payload).ConfigureAwait(false);
    }

    /// <summary>GET /v1/router/control-plane/threads/{threadRef}/selection</summary>
    public static async Task ThreadSelectionReadAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        ThreadSelectionStore? store = services.ControlPlane?.ThreadSelection;
        if (store is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionUnavailable("thread_selection")).ConfigureAwait(false);
            return;
        }

        if (!TryReadThreadRef(context, out string threadRef))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("thread_ref")).ConfigureAwait(false);
            return;
        }

        ThreadSelectionSnapshot? snapshot = store.TryGet(threadRef);
        if (snapshot is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadNotObserved("thread_ref")).ConfigureAwait(false);
            return;
        }

        await WriteJsonOkAsync(context, ControlPlaneProjections.ToThreadSelection(snapshot)).ConfigureAwait(false);
    }

    /// <summary>
    /// PUT /v1/router/control-plane/threads/{threadRef}/selection
    ///
    /// Replaces the thread's selection with a PENDING claim on a statically
    /// approved model, using the per-thread generation compare-and-set. The
    /// claim becomes active only on the next eligible turn; this mutation never
    /// changes a model by itself and never contacts a provider.
    /// </summary>
    public static async Task ThreadSelectionMutateAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        if (!IsJsonContentType(context))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("content_type")).ConfigureAwait(false);
            return;
        }

        ControlPlaneThreadSelectionMutationRequest? request =
            await ReadJsonAsync<ControlPlaneThreadSelectionMutationRequest>(context).ConfigureAwait(false);
        if (request is null)
        {
            return;
        }

        if (request.SchemaVersionValue != 1)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("schema_version")).ConfigureAwait(false);
            return;
        }

        ThreadSelectionStore? store = services.ControlPlane?.ThreadSelection;
        if (store is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionUnavailable("thread_selection")).ConfigureAwait(false);
            return;
        }

        if (!store.Enabled)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionDisabled()).ConfigureAwait(false);
            return;
        }

        IApprovedModelValidator? validator = services.ControlPlane?.ApprovedModelValidator;
        if (validator is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionUnavailable("approved_model_validator")).ConfigureAwait(false);
            return;
        }

        if (!TryReadThreadRef(context, out string threadRef))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("thread_ref")).ConfigureAwait(false);
            return;
        }

        if (!IsAcceptableModelId(request.Model))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("model")).ConfigureAwait(false);
            return;
        }

        ThreadSelectionSnapshot? observed = store.TryGet(threadRef);
        if (observed is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadNotObserved("thread_ref")).ConfigureAwait(false);
            return;
        }

        // Static approval only: the existing registry/resolver eligibility
        // primitives bound to the production snapshot decide. No provider call,
        // no network, no second catalog.
        if (!validator.IsApprovedForClient(observed.ClientId, request.Model))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ModelNotApproved("model")).ConfigureAwait(false);
            return;
        }

        ThreadSelectionOperationResult result = store.SetSelection(threadRef, request.Model, request.ExpectedGeneration);
        if (result.Status != ThreadSelectionOperationStatus.Applied || result.Snapshot is null)
        {
            await WriteErrorAsync(context, ThreadSelectionMutationError(result.Status)).ConfigureAwait(false);
            return;
        }

        ControlPlaneThreadSelectionMutationResponsePayload payload = new()
        {
            SchemaVersionValue = 1,
            ResultCode = ResultApplied,
            ThreadRef = result.Snapshot.ThreadRef,
            SelectionState = ControlPlaneProjections.ThreadSelectionStateWire(result.Snapshot.SelectionState),
            SelectionModel = result.Snapshot.SelectionModel,
            SelectionGeneration = result.Snapshot.SelectionGeneration,
            ExpiresAt = result.Snapshot.SelectionExpiresAt?.ToString("O"),
        };
        await WriteJsonOkAsync(context, payload).ConfigureAwait(false);
    }

    /// <summary>
    /// DELETE /v1/router/control-plane/threads/{threadRef}/selection
    ///
    /// Restores the Codex requested model for this thread from the next
    /// eligible turn. The per-thread generation CAS is carried in the body.
    /// </summary>
    public static async Task ThreadSelectionClearAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        if (!IsJsonContentType(context))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("content_type")).ConfigureAwait(false);
            return;
        }

        ControlPlaneThreadSelectionClearRequest? request =
            await ReadJsonAsync<ControlPlaneThreadSelectionClearRequest>(context).ConfigureAwait(false);
        if (request is null)
        {
            return;
        }

        if (request.SchemaVersionValue != 1)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("schema_version")).ConfigureAwait(false);
            return;
        }

        ThreadSelectionStore? store = services.ControlPlane?.ThreadSelection;
        if (store is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionUnavailable("thread_selection")).ConfigureAwait(false);
            return;
        }

        if (!store.Enabled)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionDisabled()).ConfigureAwait(false);
            return;
        }

        if (!TryReadThreadRef(context, out string threadRef))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("thread_ref")).ConfigureAwait(false);
            return;
        }

        ThreadSelectionOperationResult result = store.ClearSelection(threadRef, request.ExpectedGeneration);
        if (result.Status != ThreadSelectionOperationStatus.Applied || result.Snapshot is null)
        {
            await WriteErrorAsync(context, ThreadSelectionMutationError(result.Status)).ConfigureAwait(false);
            return;
        }

        ControlPlaneThreadSelectionMutationResponsePayload payload = new()
        {
            SchemaVersionValue = 1,
            ResultCode = ResultApplied,
            ThreadRef = result.Snapshot.ThreadRef,
            SelectionState = ControlPlaneProjections.ThreadSelectionStateWire(result.Snapshot.SelectionState),
            SelectionModel = result.Snapshot.SelectionModel,
            SelectionGeneration = result.Snapshot.SelectionGeneration,
            ExpiresAt = result.Snapshot.SelectionExpiresAt?.ToString("O"),
        };
        await WriteJsonOkAsync(context, payload).ConfigureAwait(false);
    }

    /// <summary>
    /// DELETE /v1/router/control-plane/threads/selections
    ///
    /// Explicit confirmed clear-all of runtime thread state. It never changes
    /// local_router.enabled, thread_selection.enabled, the config generation,
    /// routes, or policies, and it never calls a provider.
    /// </summary>
    public static async Task ThreadSelectionsClearAllAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        if (!IsJsonContentType(context))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("content_type")).ConfigureAwait(false);
            return;
        }

        ControlPlaneThreadSelectionsClearAllRequest? request =
            await ReadJsonAsync<ControlPlaneThreadSelectionsClearAllRequest>(context).ConfigureAwait(false);
        if (request is null)
        {
            return;
        }

        if (request.SchemaVersionValue != 1)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("schema_version")).ConfigureAwait(false);
            return;
        }

        if (!request.Confirm)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("confirm")).ConfigureAwait(false);
            return;
        }

        ThreadSelectionStore? store = services.ControlPlane?.ThreadSelection;
        if (store is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionUnavailable("thread_selection")).ConfigureAwait(false);
            return;
        }

        // Clear-all is intentionally not gated by the capability flag: removing
        // runtime remnants never enables the capability, and a live publication
        // already clears them when the capability or the Router is disabled.
        ThreadSelectionOperationResult result = store.ClearAll();
        ControlPlaneThreadSelectionsClearAllResponsePayload payload = new()
        {
            SchemaVersionValue = 1,
            ResultCode = ResultApplied,
            ClearedCount = result.ClearedCount,
            CancelledCaptureCount = result.CancelledCaptureCount,
            ThreadSelectionEnabled = store.Enabled,
        };
        await WriteJsonOkAsync(context, payload).ConfigureAwait(false);
    }

    /// <summary>
    /// POST /v1/router/control-plane/threads/capture
    ///
    /// Opens an identity-discovery window owned by the authenticated control
    /// client. A capture carries no target model, creates no selection, changes
    /// no turn's model, and calls no provider.
    /// </summary>
    public static async Task ThreadCaptureOpenAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        (bool authorized, string ownerClientId) = await AuthorizeWithClientAsync(services, context).ConfigureAwait(false);
        if (!authorized)
        {
            return;
        }

        if (!IsJsonContentType(context))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("content_type")).ConfigureAwait(false);
            return;
        }

        ControlPlaneThreadCaptureRequest? request =
            await ReadJsonAsync<ControlPlaneThreadCaptureRequest>(context).ConfigureAwait(false);
        if (request is null)
        {
            return;
        }

        if (request.SchemaVersionValue != 1)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("schema_version")).ConfigureAwait(false);
            return;
        }

        ThreadSelectionStore? store = services.ControlPlane?.ThreadSelection;
        if (store is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadCaptureUnavailable("thread_selection")).ConfigureAwait(false);
            return;
        }

        // A second OPEN window is never created, never replaces, and never
        // cancels an existing one - not even for the same owner. The typed
        // result keeps "capability disabled" and "a window is already open"
        // distinct, and Busy carries no projection of the existing window.
        ThreadCaptureOpenResult result = store.OpenCapture(ownerClientId);
        switch (result.Status)
        {
            case ThreadCaptureOpenStatus.Opened:
                await WriteJsonOkAsync(context, ControlPlaneProjections.ToCapture(result.Capture!)).ConfigureAwait(false);
                return;

            case ThreadCaptureOpenStatus.Busy:
                await WriteErrorAsync(context, ControlPlaneErrors.ThreadCaptureBusy("capture")).ConfigureAwait(false);
                return;

            default:
                await WriteErrorAsync(context, ControlPlaneErrors.ThreadSelectionDisabled()).ConfigureAwait(false);
                return;
        }
    }

    /// <summary>
    /// GET /v1/router/control-plane/threads/capture/{token}
    ///
    /// The authenticated control client is passed to the store: a capture is
    /// readable only by the client that opened it, and a foreign token is
    /// reported exactly like an unknown one.
    /// </summary>
    public static async Task ThreadCaptureReadAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        (bool authorized, string ownerClientId) = await AuthorizeWithClientAsync(services, context).ConfigureAwait(false);
        if (!authorized)
        {
            return;
        }

        ThreadSelectionStore? store = services.ControlPlane?.ThreadSelection;
        if (store is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadCaptureUnavailable("thread_selection")).ConfigureAwait(false);
            return;
        }

        if (!TryReadCaptureToken(context, out string token))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("capture_token")).ConfigureAwait(false);
            return;
        }

        ThreadCaptureSnapshot? capture = store.TryGetCapture(token, ownerClientId);
        if (capture is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadCaptureNotFound("capture_token")).ConfigureAwait(false);
            return;
        }

        await WriteJsonOkAsync(context, ControlPlaneProjections.ToCapture(capture)).ConfigureAwait(false);
    }

    /// <summary>
    /// DELETE /v1/router/control-plane/threads/capture/{token}
    ///
    /// Only the owning authenticated control client may cancel its window; a
    /// foreign owner receives the same result as an unknown token.
    /// </summary>
    public static async Task ThreadCaptureCancelAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        (bool authorized, string ownerClientId) = await AuthorizeWithClientAsync(services, context).ConfigureAwait(false);
        if (!authorized)
        {
            return;
        }

        ThreadSelectionStore? store = services.ControlPlane?.ThreadSelection;
        if (store is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadCaptureUnavailable("thread_selection")).ConfigureAwait(false);
            return;
        }

        if (!TryReadCaptureToken(context, out string token))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("capture_token")).ConfigureAwait(false);
            return;
        }

        if (!store.CancelCapture(token, ownerClientId))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ThreadCaptureNotFound("capture_token")).ConfigureAwait(false);
            return;
        }

        ControlPlaneThreadCaptureCancelPayload payload = new()
        {
            SchemaVersionValue = 1,
            ResultCode = ResultApplied,
            CaptureToken = token,
            Status = ControlPlaneProjections.ThreadCaptureStatusWire(ThreadCaptureStatus.Cancelled),
        };
        await WriteJsonOkAsync(context, payload).ConfigureAwait(false);
    }

    public static async Task UsageAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        ControlPlaneRuntimeServices? controlPlane = services.ControlPlane;
        if (controlPlane?.Metering is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ReadUnavailable("metering")).ConfigureAwait(false);
            return;
        }

        int limit = ControlPlaneProjections.ResolveLimit(context.Request.Query["limit"]);
        ControlPlaneUsagePayload payload = ControlPlaneProjections.BuildUsagePayload(controlPlane.Metering, limit);
        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.ContentType = JsonMediaType;
        await WriteJsonAsync(context, payload).ConfigureAwait(false);
    }

    public static async Task RecentRequestsAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        ControlPlaneRuntimeServices? controlPlane = services.ControlPlane;
        if (controlPlane?.RequestLog is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ReadUnavailable("recent_requests")).ConfigureAwait(false);
            return;
        }

        int limit = ControlPlaneProjections.ResolveLimit(context.Request.Query["limit"]);
        ControlPlaneRecentRequestsPayload payload = await ControlPlaneProjections
            .BuildRecentRequestsPayloadAsync(controlPlane.RequestLog, limit, context.RequestAborted)
            .ConfigureAwait(false);
        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.ContentType = JsonMediaType;
        await WriteJsonAsync(context, payload).ConfigureAwait(false);
    }

    public static async Task PolicyReadAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        ControlPlaneRuntimeServices? controlPlane = services.ControlPlane;
        PublishedRouterState? published = controlPlane?.CurrentState?.Snapshot;
        string configGeneration;
        IReadOnlyList<PolicyConfig> policies;
        IReadOnlyList<RouterRouteConfig> routes;
        if (published is not null)
        {
            configGeneration = published.ConfigGeneration;
            policies = published.Policies;
            routes = published.Routes;
        }
        else
        {
            LocalRouterConfigReadResult read = await ReadConfigAsync(services, context).ConfigureAwait(false);
            if (!read.IsSuccess || read.View is null)
            {
                return;
            }

            configGeneration = read.View.ConfigGeneration;
            policies = read.View.Config.Policies;
            routes = read.View.Config.Routes;
        }

        ControlPlanePolicySnapshotPayload payload = new()
        {
            SchemaVersionValue = 1,
            ConfigGeneration = configGeneration,
            CrossModelFallback = ControlPlaneProjections.CrossModelFallbackHardOff,
            Policies = policies.Select(ControlPlaneProjections.ToPolicyEntry).ToArray(),
            Routes = routes.Select(route => new ControlPlaneRoutePolicyReferencePayload
            {
                RouteId = route.RouteId,
                TimeoutPolicyId = route.TimeoutPolicyId,
                RetryPolicyId = route.RetryPolicyId,
                FailoverPolicyId = route.FailoverPolicyId,
            }).ToArray(),
            CircuitBreaker = ControlPlaneProjections.CircuitBreakerGap(),
        };

        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.ContentType = JsonMediaType;
        await WriteJsonAsync(context, payload).ConfigureAwait(false);
    }

    public static async Task PolicyMutateAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        if (services.ControlPlane?.ConfigOperator is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ReadUnavailable("config_operator")).ConfigureAwait(false);
            return;
        }

        if (!IsJsonContentType(context))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("content_type")).ConfigureAwait(false);
            return;
        }

        ControlPlanePolicyMutationRequest? request = await ReadJsonAsync<ControlPlanePolicyMutationRequest>(context).ConfigureAwait(false);
        if (request is null)
        {
            return;
        }

        if (request.SchemaVersionValue != 1)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("schema_version")).ConfigureAwait(false);
            return;
        }

        int bodyKinds = (request.Retry is not null ? 1 : 0)
            + (request.Timeout is not null ? 1 : 0)
            + (request.Failover is not null ? 1 : 0);
        if (bodyKinds != 1)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("body")).ConfigureAwait(false);
            return;
        }

        LocalRouterConfigMutationResult result;
        if (request.Retry is { } retry)
        {
            if (retry.SchemaVersionValue != 1)
            {
                await WriteErrorAsync(context, ControlPlaneErrors.PolicyInvalid("retry.schema_version")).ConfigureAwait(false);
                return;
            }

            result = await services.ControlPlane!.ConfigOperator!
                .SetPolicyRetryBodyAsync(
                    request.ExpectedGeneration,
                    request.PolicyId,
                    ControlPlaneProjections.ToRetryConfig(retry),
                    context.RequestAborted)
                .ConfigureAwait(false);
        }
        else if (request.Timeout is { } timeout)
        {
            if (timeout.SchemaVersionValue != 1)
            {
                await WriteErrorAsync(context, ControlPlaneErrors.PolicyInvalid("timeout.schema_version")).ConfigureAwait(false);
                return;
            }

            result = await services.ControlPlane!.ConfigOperator!
                .SetPolicyTimeoutBodyAsync(
                    request.ExpectedGeneration,
                    request.PolicyId,
                    ControlPlaneProjections.ToTimeoutConfig(timeout),
                    context.RequestAborted)
                .ConfigureAwait(false);
        }
        else
        {
            ControlPlaneFailoverBodyPayload failover = request.Failover!;
            if (failover.SchemaVersionValue != 1)
            {
                await WriteErrorAsync(context, ControlPlaneErrors.PolicyInvalid("failover.schema_version")).ConfigureAwait(false);
                return;
            }

            result = await services.ControlPlane!.ConfigOperator!
                .SetPolicyFailoverBodyAsync(
                    request.ExpectedGeneration,
                    request.PolicyId,
                    ControlPlaneProjections.ToFailoverConfig(failover),
                    context.RequestAborted)
                .ConfigureAwait(false);
        }

        if (!result.IsSuccess || result.View is null)
        {
            RouterError error = result.Error ?? ControlPlaneErrors.MutationFailed("policy");
            if (IsConfigFailure(error))
            {
                error = ControlPlaneErrors.PolicyInvalid(error.Param);
            }

            await WriteErrorAsync(context, error).ConfigureAwait(false);
            return;
        }

        ControlPlanePolicyMutationResponsePayload payload = new()
        {
            SchemaVersionValue = 1,
            ResultCode = ResultApplied,
            PolicyId = request.PolicyId,
            ConfigGeneration = result.View.ConfigGeneration,
            CrossModelFallback = ControlPlaneProjections.CrossModelFallbackHardOff,
            Policy = ControlPlaneProjections.ToPolicyEntry(result.View.Config, request.PolicyId),
        };
        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.ContentType = JsonMediaType;
        await WriteJsonAsync(context, payload).ConfigureAwait(false);
    }

    public static async Task FeatureAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        if (!await AuthorizeAsync(services, context).ConfigureAwait(false))
        {
            return;
        }

        if (!IsJsonContentType(context))
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("content_type")).ConfigureAwait(false);
            return;
        }

        ControlPlaneFeatureMutationRequest? request = await ReadJsonAsync<ControlPlaneFeatureMutationRequest>(context).ConfigureAwait(false);
        if (request is null)
        {
            return;
        }

        if (request.SchemaVersionValue != 1)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("schema_version")).ConfigureAwait(false);
            return;
        }

        if (services.ControlPlane?.ConfigOperator is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ReadUnavailable("config_operator")).ConfigureAwait(false);
            return;
        }

        LocalRouterConfigMutationResult result = await services.ControlPlane!.ConfigOperator!
            .SetFeatureEnabledAsync(request.ExpectedGeneration, request.Enabled, context.RequestAborted)
            .ConfigureAwait(false);
        if (!result.IsSuccess || result.View is null)
        {
            RouterError error = result.Error ?? ControlPlaneErrors.FeatureUpdateFailed("local_router.enabled");
            if (IsConfigFailure(error))
            {
                error = ControlPlaneErrors.FeatureUpdateFailed(error.Param);
            }

            await WriteErrorAsync(context, error).ConfigureAwait(false);
            return;
        }

        ControlPlaneFeatureMutationResponsePayload payload = new()
        {
            SchemaVersionValue = 1,
            ResultCode = ResultApplied,
            LocalRouterEnabled = result.View.Config.LocalRouter.Enabled,
            ConfigGeneration = result.View.ConfigGeneration,
            StartStopAvailable = false,
            LifecycleReasonCode = ControlPlaneProjections.LifecycleControlGapCode,
        };
        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.ContentType = JsonMediaType;
        await WriteJsonAsync(context, payload).ConfigureAwait(false);
    }

    private static async Task<bool> AuthorizeAsync(IngressServices services, HttpContext context)
        => (await AuthorizeWithClientAsync(services, context).ConfigureAwait(false)).Authorized;

    /// <summary>
    /// Captures the runtime pair - published config state and thread-selection
    /// summary - inside ONE shared runtime consistency section. A combined
    /// projection therefore never mixes a new published generation with an old
    /// capability state (or the reverse).
    /// </summary>
    private static (PublishedRouterState? Published, ThreadSelectionStatusSnapshot? Summary) CaptureRuntimeView(
        IngressServices services)
    {
        ControlPlaneRuntimeServices? controlPlane = services.ControlPlane;
        if (controlPlane?.RuntimeConsistencyGate is not { } gate)
        {
            // No live runtime publication boundary is composed (offline or
            // legacy composition): there is no runtime pair to serialize.
            return (controlPlane?.CurrentState?.Snapshot, controlPlane?.ThreadSelection?.Status());
        }

        using (gate.EnterShared())
        {
            return (controlPlane.CurrentState?.Snapshot, controlPlane.ThreadSelection?.Status());
        }
    }

    /// <summary>
    /// Effective capability state immediately after a successful live mutation,
    /// read from the same boundary the config operator published under.
    /// </summary>
    private static bool CaptureEffectiveFeatureState(IngressServices services)
    {
        (PublishedRouterState? published, ThreadSelectionStatusSnapshot? summary) = CaptureRuntimeView(services);
        bool localRouterEnabled = published?.LocalRouterEnabled
            ?? services.ControlPlane?.ThreadSelection?.Enabled == true;
        return localRouterEnabled && summary?.Enabled == true;
    }

    /// <summary>
    /// Authorizes the fixed control-plane scope and resolves the authenticated
    /// control client identity. Only the identity is exposed; the bearer token
    /// itself never leaves the authentication boundary. Denials are written
    /// exactly like every other control-plane endpoint's denial.
    /// </summary>
    private static async Task<(bool Authorized, string ClientId)> AuthorizeWithClientAsync(
        IngressServices services,
        HttpContext context)
    {
        if (services.ScopeRegistry.TryResolve(RequiredScope, out string clientId))
        {
            return (true, clientId);
        }

        await WriteErrorAsync(
                context,
                RouterError.ScopeDenied(Router.Ingress.Handlers.RequestPipeline.RequestIdValue(context)))
            .ConfigureAwait(false);
        return (false, string.Empty);
    }

    /// <summary>
    /// True only when the ConfigOperator actually publishes into THIS running
    /// runtime. The composite runtime sink (when composed) is the live owner;
    /// a legacy operator bound directly to the published current state keeps
    /// working, and an offline operator is never treated as live.
    /// </summary>
    private static bool IsLiveMutationAvailable(IngressServices services)
    {
        ControlPlaneRuntimeServices? controlPlane = services.ControlPlane;
        LocalRouterConfigOperator? configOperator = controlPlane?.ConfigOperator;
        if (configOperator?.SupportsLivePublication is not true)
        {
            return false;
        }

        if (controlPlane!.RuntimePublicationSink is { } runtimeSink)
        {
            return ReferenceEquals(configOperator.PublicationSink, runtimeSink);
        }

        return controlPlane.CurrentState is not null
            && ReferenceEquals(configOperator.PublicationSink, controlPlane.CurrentState);
    }

    /// <summary>
    /// Live feature view: the published state when a runtime publishes one,
    /// otherwise the durable config document read through the same operator.
    /// </summary>
    private static async Task<ControlPlaneFeatureView?> TryReadFeatureViewAsync(IngressServices services, HttpContext context)
    {
        PublishedRouterState? published = services.ControlPlane?.CurrentState?.Snapshot;
        if (published is not null)
        {
            return new ControlPlaneFeatureView(
                published.ConfigGeneration,
                published.LocalRouterEnabled,
                published.ThreadSelectionEnabled);
        }

        LocalRouterConfigReadResult read = await ReadConfigAsync(services, context).ConfigureAwait(false);
        if (!read.IsSuccess || read.View is null)
        {
            return null;
        }

        return new ControlPlaneFeatureView(
            read.View.ConfigGeneration,
            read.View.Config.LocalRouter.Enabled,
            read.View.Config.LocalRouter.ThreadSelection.Enabled);
    }

    private static async Task<LocalRouterConfigReadResult> ReadConfigAsync(IngressServices services, HttpContext context)
    {
        ControlPlaneRuntimeServices? controlPlane = services.ControlPlane;
        if (controlPlane?.ConfigOperator is null)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.ReadUnavailable("config_operator")).ConfigureAwait(false);
            return new LocalRouterConfigReadResult();
        }

        LocalRouterConfigReadResult read = await controlPlane
            .ConfigOperator.ReadAsync(context.RequestAborted)
            .ConfigureAwait(false);
        if (!read.IsSuccess || read.View is null)
        {
            await WriteErrorAsync(context, read.Error ?? ControlPlaneErrors.ReadUnavailable("config")).ConfigureAwait(false);
        }

        return read;
    }

    private static bool IsJsonContentType(HttpContext context)
    {
        string? contentType = context.Request.ContentType;
        return !string.IsNullOrWhiteSpace(contentType)
            && contentType.Contains(JsonMediaType, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Reads and validates the thread reference path value. Only the external
    /// reference form is accepted; a raw canonical thread id is rejected here
    /// and can never address runtime state.
    /// </summary>
    private static bool TryReadThreadRef(HttpContext context, out string threadRef)
    {
        threadRef = context.Request.RouteValues["threadRef"] as string ?? string.Empty;
        return ThreadRef.IsValid(threadRef);
    }

    /// <summary>Reads and validates the opaque capture token path value.</summary>
    private static bool TryReadCaptureToken(HttpContext context, out string token)
    {
        token = context.Request.RouteValues["token"] as string ?? string.Empty;
        if (token.Length != CaptureTokenLength)
        {
            return false;
        }

        foreach (char c in token)
        {
            if (c is not (>= '0' and <= '9' or >= 'a' and <= 'f'))
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsAcceptableModelId(string? model)
        => !string.IsNullOrWhiteSpace(model)
            && model.Length <= MaxThreadSelectionModelLength;

    private static RouterError ThreadSelectionMutationError(ThreadSelectionOperationStatus status)
        => status switch
        {
            ThreadSelectionOperationStatus.Conflict => ControlPlaneErrors.ThreadSelectionConflict(),
            ThreadSelectionOperationStatus.NotFound => ControlPlaneErrors.ThreadNotObserved("thread_ref"),
            _ => ControlPlaneErrors.ThreadSelectionDisabled(),
        };

    private static bool IsConfigFailure(RouterError error)
        => error.Code is RouterErrorCode.ConfigInvalid
            or RouterErrorCode.ConfigCorrupt
            or RouterErrorCode.ConfigSecurityViolation
            or RouterErrorCode.ConfigMissingRequired
            or RouterErrorCode.ConfigSchemaUnsupported;

    private static Task WriteJsonOkAsync<T>(HttpContext context, T payload)
    {
        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.ContentType = JsonMediaType;
        return WriteJsonAsync(context, payload);
    }

    private static async Task<T?> ReadJsonAsync<T>(HttpContext context)
        where T : class
    {
        if (context.Request.ContentLength is { } knownLength && knownLength > MaxControlPlaneMutationBytes)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.PayloadTooLarge("content_length")).ConfigureAwait(false);
            return null;
        }

        byte[] buffer = new byte[MaxControlPlaneMutationBytes + 1];
        int total = 0;
        while (total <= MaxControlPlaneMutationBytes)
        {
            int read = await context.Request.Body
                .ReadAsync(buffer.AsMemory(total, buffer.Length - total), context.RequestAborted)
                .ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            total += read;
        }

        if (total > MaxControlPlaneMutationBytes)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.PayloadTooLarge("body")).ConfigureAwait(false);
            return null;
        }

        string body = Encoding.UTF8.GetString(buffer, 0, total);
        try
        {
            T? value = JsonSerializer.Deserialize<T>(body, ControlPlaneJson.RequestOptions);
            if (value is null)
            {
                await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("body")).ConfigureAwait(false);
            }

            return value;
        }
        catch (JsonException)
        {
            await WriteErrorAsync(context, ControlPlaneErrors.InvalidRequest("body")).ConfigureAwait(false);
            return null;
        }
    }

    private static Task WriteJsonAsync<T>(HttpContext context, T payload)
        => context.Response.WriteAsync(
            JsonSerializer.Serialize(payload, ControlPlaneJson.WriteOptions),
            context.RequestAborted);

    private static Task WriteErrorAsync(HttpContext context, RouterError error)
        => ErrorEnvelopeWriter.WriteAsync(
            context.Response,
            error,
            HttpStatusMapper.ToStatusCode(error),
            context.RequestAborted);
}
