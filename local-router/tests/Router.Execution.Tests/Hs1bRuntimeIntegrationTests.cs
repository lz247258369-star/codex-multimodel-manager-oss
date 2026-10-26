using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Context;
using Router.ThreadSelection;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// HS-1B stage 2 runtime wiring. Every test drives the real production path:
/// HTTP ingress -> RequestContext (thread identity) -> ThreadSelectionStore ->
/// RouterExecutionResponsesService -> existing RouteResolver -> provider
/// harness -> loopback fake upstream. No real provider, key, or network target
/// is ever used, and no provider adapter is modified by this stage.
///
/// The control-plane thread endpoints are exercised separately by
/// <see cref="Hs1bControlPlaneE2ETests"/>; these tests set the selection
/// directly on the same store instance production execution receives, which is
/// exactly the seam the control plane publishes through.
/// </summary>
public sealed class Hs1bRuntimeIntegrationTests
{
    [Fact]
    public async Task Golden_thread_selection_switches_and_sticks_across_turns()
    {
        await using Hs1bRouterContext context = await Hs1bRouterContext.StartAsync();
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        // Turn 1: Codex requests hot-alpha and no selection exists yet.
        using (HttpResponseMessage first = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(first.IsSuccessStatusCode, await first.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);
        ThreadSelectionSnapshot observed = context.Store.TryGet(threadRef)!;
        Assert.Equal(ThreadSelectionState.None, observed.SelectionState);
        Assert.Equal(Hs1bRuntimeConfig.Alpha.ClientModelId, observed.LastRequestedModel);

        ThreadSelectionOperationResult set = context.Store.SetSelection(
            threadRef,
            Hs1bRuntimeConfig.Beta.ClientModelId,
            observed.SelectionGeneration);
        Assert.Equal(ThreadSelectionOperationStatus.Applied, set.Status);
        Assert.Equal(ThreadSelectionState.Pending, set.Snapshot!.SelectionState);

        // Turn 2: Codex still requests hot-alpha; the router resolves hot-beta.
        using (HttpResponseMessage second = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(second.IsSuccessStatusCode, await second.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);
        Assert.DoesNotContain(Hs1bRuntimeConfig.Alpha.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);

        // Turn 3: sticky - the same thread keeps resolving hot-beta.
        using (HttpResponseMessage third = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(third.IsSuccessStatusCode, await third.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);

        ThreadSelectionSnapshot active = context.Store.TryGet(threadRef)!;
        Assert.Equal(ThreadSelectionState.Active, active.SelectionState);
        Assert.Equal(Hs1bRuntimeConfig.Beta.ClientModelId, active.SelectionModel);
        Assert.Equal(Hs1bRuntimeConfig.Alpha.ClientModelId, active.LastRequestedModel);

        ResponsesExecutionMetadata metadata = context.Sink.Executed[^1];
        Assert.Equal(Hs1bRuntimeConfig.Beta.ClientModelId, metadata.ClientModelId);
        Assert.Equal(Hs1bRuntimeConfig.Beta.UpstreamModelId, metadata.UpstreamModelId);
        Assert.Equal(Hs1bRuntimeConfig.Beta.RouteId, metadata.RouteId);
    }

    [Fact]
    public async Task Execution_never_rewrites_the_canonical_requested_model()
    {
        await using Hs1bRouterContext context = await Hs1bRouterContext.StartAsync();
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        CanonicalResponsesRequest warmUp = new() { Model = Hs1bRuntimeConfig.Alpha.ClientModelId, Input = [], Stream = false };
        _ = await context.Service.InvokeAsync(warmUp, context.CreateRequestContext(Hs1bTestThreads.One), CancellationToken.None);

        ThreadSelectionSnapshot snapshot = context.Store.TryGet(threadRef)!;
        _ = context.Store.SetSelection(threadRef, Hs1bRuntimeConfig.Beta.ClientModelId, snapshot.SelectionGeneration);

        CanonicalResponsesRequest request = new()
        {
            Model = Hs1bRuntimeConfig.Alpha.ClientModelId,
            Input = [],
            Stream = false,
        };

        ResponsesServiceResult result = await context.Service.InvokeAsync(
            request,
            context.CreateRequestContext(Hs1bTestThreads.One),
            CancellationToken.None);

        Assert.Null(result.Error);

        // Request truth stays A while the router resolved B.
        Assert.Equal(Hs1bRuntimeConfig.Alpha.ClientModelId, request.Model);
        Assert.Equal(Hs1bRuntimeConfig.Beta.ClientModelId, result.Execution!.ClientModelId);
        Assert.Equal(Hs1bRuntimeConfig.Beta.UpstreamModelId, result.Execution.UpstreamModelId);
        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Auxiliary_request_keeps_the_requested_model_and_the_active_selection()
    {
        await using Hs1bRouterContext context = await Hs1bRouterContext.StartAsync();
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        await ActivateSelectionAsync(context, Hs1bTestThreads.One, Hs1bRuntimeConfig.Beta.ClientModelId);
        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);

        // A title-style request is never eligible for the thread override.
        using (HttpResponseMessage auxiliary = await context.PostTurnAsync(
            Hs1bRuntimeConfig.Alpha.ClientModelId,
            Hs1bTestThreads.One,
            requestKind: "title"))
        {
            Assert.True(auxiliary.IsSuccessStatusCode, await auxiliary.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);

        ThreadSelectionSnapshot afterAuxiliary = context.Store.TryGet(threadRef)!;
        Assert.Equal(ThreadSelectionState.Active, afterAuxiliary.SelectionState);
        Assert.Equal(Hs1bRuntimeConfig.Beta.ClientModelId, afterAuxiliary.SelectionModel);

        using (HttpResponseMessage turn = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await turn.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Contradictory_or_malformed_identity_keeps_the_requested_model()
    {
        await using Hs1bRouterContext context = await Hs1bRouterContext.StartAsync();
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        await ActivateSelectionAsync(context, Hs1bTestThreads.One, Hs1bRuntimeConfig.Beta.ClientModelId);

        // SOURCE A presents T1 while SOURCE B presents T2: fail closed.
        using (HttpResponseMessage mismatch = await context.PostAsync(
            Hs1bRouterContext.RequestBody(Hs1bRuntimeConfig.Alpha.ClientModelId),
            Hs1bTestThreads.One,
            Hs1bRouterContext.Metadata(Hs1bTestThreads.Two, "turn")))
        {
            Assert.True(mismatch.IsSuccessStatusCode, await mismatch.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);
        Assert.Null(context.Store.TryGet(Hs1bTestThreads.RefOf(Hs1bTestThreads.Two)));

        // Malformed metadata is equally not an identity.
        using (HttpResponseMessage malformed = await context.PostAsync(
            Hs1bRouterContext.RequestBody(Hs1bRuntimeConfig.Alpha.ClientModelId),
            Hs1bTestThreads.One,
            """{"thread_id":"01a09dae-3db7-7820-8912-0d86815051a6","""))
        {
            Assert.True(malformed.IsSuccessStatusCode, await malformed.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);

        // The active selection was neither consumed nor modified.
        ThreadSelectionSnapshot after = context.Store.TryGet(threadRef)!;
        Assert.Equal(ThreadSelectionState.Active, after.SelectionState);
        Assert.Equal(Hs1bRuntimeConfig.Beta.ClientModelId, after.SelectionModel);

        using (HttpResponseMessage turn = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await turn.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Two_threads_resolve_their_own_selections()
    {
        await using Hs1bRouterContext context = await Hs1bRouterContext.StartAsync();

        await ActivateSelectionAsync(context, Hs1bTestThreads.One, Hs1bRuntimeConfig.Beta.ClientModelId);
        await ActivateSelectionAsync(context, Hs1bTestThreads.Two, Hs1bRuntimeConfig.Gamma.ClientModelId);

        using (HttpResponseMessage one = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(one.IsSuccessStatusCode, await one.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);

        using (HttpResponseMessage two = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.Two))
        {
            Assert.True(two.IsSuccessStatusCode, await two.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Gamma.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Disabled_feature_never_observes_or_applies_a_thread_selection()
    {
        await using Hs1bRouterContext context = await Hs1bRouterContext.StartAsync(threadSelectionEnabled: false);

        using (HttpResponseMessage turn = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await turn.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);
        Assert.False(context.Store.Enabled);
        Assert.Empty(context.Store.List(10));
        Assert.Equal(
            ThreadSelectionOperationStatus.Disabled,
            context.Store.SetSelection(Hs1bTestThreads.RefOf(Hs1bTestThreads.One), Hs1bRuntimeConfig.Beta.ClientModelId, 1).Status);
    }

    [Fact]
    public async Task Feature_state_changes_on_the_shared_store_govern_production_execution()
    {
        // The production composition keeps exactly one store: the same instance
        // handed to execution is the instance a live publication drives.
        await using Hs1bRouterContext context = await Hs1bRouterContext.StartAsync();

        await ActivateSelectionAsync(context, Hs1bTestThreads.One, Hs1bRuntimeConfig.Beta.ClientModelId);
        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);

        context.Store.ApplyFeatureState(enabled: false, disabledReason: "router_disabled");

        using (HttpResponseMessage disabled = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(disabled.IsSuccessStatusCode, await disabled.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);
        Assert.DoesNotContain(
            context.Store.List(10),
            static thread => thread.SelectionState == ThreadSelectionState.Active);

        context.Store.ApplyFeatureState(enabled: true, disabledReason: string.Empty);

        using (HttpResponseMessage reEnabled = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(reEnabled.IsSuccessStatusCode, await reEnabled.Content.ReadAsStringAsync());
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);

        await ActivateSelectionAsync(context, Hs1bTestThreads.One, Hs1bRuntimeConfig.Beta.ClientModelId);
        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, context.UpstreamBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Unroutable_selection_fails_closed_without_silent_fallback()
    {
        await using Hs1bRouterContext context = await Hs1bRouterContext.StartAsync();
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        using (HttpResponseMessage observed = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(observed.IsSuccessStatusCode, await observed.Content.ReadAsStringAsync());
        }

        string beforeFailClosed = context.UpstreamBody;
        ThreadSelectionSnapshot snapshot = context.Store.TryGet(threadRef)!;
        _ = context.Store.SetSelection(threadRef, "hot-nonexistent", snapshot.SelectionGeneration);

        using HttpResponseMessage failed = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One);
        string failedBody = await failed.Content.ReadAsStringAsync();

        Assert.False(failed.IsSuccessStatusCode);
        using JsonDocument document = JsonDocument.Parse(failedBody);
        string errorCode = document.RootElement.GetProperty("error").GetProperty("code").GetString()!;
        Assert.Equal("unknown_model", errorCode);

        // Fail closed: no provider attempt happens and the claim is preserved.
        Assert.Equal(beforeFailClosed, context.UpstreamBody);

        ThreadSelectionSnapshot after = context.Store.TryGet(threadRef)!;
        Assert.Equal(ThreadSelectionState.Active, after.SelectionState);
        Assert.Equal("hot-nonexistent", after.SelectionModel);
        Assert.Equal(errorCode, after.LastFailureCode);
        Assert.NotNull(after.LastFailureAt);
    }

    [Fact]
    public async Task Control_metadata_and_the_local_token_never_reach_the_upstream()
    {
        await using Hs1bRouterContext context = await Hs1bRouterContext.StartAsync();

        await ActivateSelectionAsync(context, Hs1bTestThreads.One, Hs1bRuntimeConfig.Beta.ClientModelId);

        IReadOnlyDictionary<string, string> headers = context.Server.LastRequestHeaders;
        Assert.False(headers.ContainsKey(ThreadIdentityParser.ThreadIdHeaderName));
        Assert.False(headers.ContainsKey(ThreadIdentityParser.TurnMetadataHeaderName));
        string authorization = headers["Authorization"];
        Assert.DoesNotContain(Hs1bRouterContext.LocalToken, authorization, StringComparison.Ordinal);
    }

    private static async Task ActivateSelectionAsync(Hs1bRouterContext context, string threadId, string model)
    {
        string threadRef = Hs1bTestThreads.RefOf(threadId);
        if (context.Store.TryGet(threadRef) is null)
        {
            using HttpResponseMessage observe = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, threadId);
            Assert.True(observe.IsSuccessStatusCode, await observe.Content.ReadAsStringAsync());
        }

        ThreadSelectionSnapshot snapshot = context.Store.TryGet(threadRef)!;
        ThreadSelectionOperationResult set = context.Store.SetSelection(threadRef, model, snapshot.SelectionGeneration);
        Assert.Equal(ThreadSelectionOperationStatus.Applied, set.Status);

        using HttpResponseMessage activation = await context.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, threadId);
        Assert.True(activation.IsSuccessStatusCode, await activation.Content.ReadAsStringAsync());
    }
}
