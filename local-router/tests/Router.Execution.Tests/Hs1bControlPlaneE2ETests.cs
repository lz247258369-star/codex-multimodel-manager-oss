using System.Net;
using System.Text;
using System.Text.Json;
using Router.Configuration;
using Router.ThreadSelection;
using Xunit;

namespace Router.Execution.Tests;

/// <summary>
/// HS-1B stage 3 control-plane E2E. Every test drives the real authenticated
/// HTTP control plane over the production-shaped harness: durable config +
/// composite runtime publication + ONE shared thread-selection store + the real
/// execution path with its own approved-model validator. No test contacts a
/// real provider, and the loopback transport counts every provider attempt.
/// </summary>
public sealed class Hs1bControlPlaneE2ETests
{
    private const string FeaturePath = "/v1/router/control-plane/thread-selection-feature";
    private const string ThreadsPath = "/v1/router/control-plane/threads";
    private const string RouterFeaturePath = "/v1/router/control-plane/feature";
    private const string StatusPath = "/v1/router/control-plane/status";

    private static string RetryMutationBody(string generation, int maxAttempts)
        => "{\"schema_version\":1,\"expected_generation\":\"" + generation
            + "\",\"policy_id\":\"policy.retry-safe-default\",\"retry\":{\"schema_version\":1,\"max_attempts\":"
            + maxAttempts
            + ",\"base_delay_ms\":50,\"max_delay_ms\":500,\"jitter\":0,\"respect_retry_after\":false,\"max_retry_after_ms\":1000}}";

    [Fact]
    public async Task Live_feature_enable_takes_effect_without_restart()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: false);
        string generation0 = harness.Generation;

        using (HttpResponseMessage read = await harness.ControlGetAsync(FeaturePath))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(read);
            Assert.True(read.IsSuccessStatusCode, body);
            Assert.Contains("\"configured_enabled\":false", body, StringComparison.Ordinal);
            Assert.Contains("\"effective_enabled\":false", body, StringComparison.Ordinal);
            Assert.Contains("\"mutation_available\":true", body, StringComparison.Ordinal);
            Assert.Contains("\"observed_thread_count\":0", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage status = await harness.ControlGetAsync(StatusPath))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(status);
            Assert.True(status.IsSuccessStatusCode, body);
            Assert.Contains("control-plane/thread-selection/v1", body, StringComparison.Ordinal);
            Assert.Contains(
                "\"thread_selection\":{\"configured_enabled\":false,\"effective_enabled\":false,\"mutation_available\":true,\"observed_thread_count\":0,\"active_selection_count\":0,\"pending_selection_count\":0,\"capture_open\":false",
                body,
                StringComparison.Ordinal);
        }

        int providerCallsBefore = harness.Transport.Calls;
        string appliedGeneration;
        using (HttpResponseMessage enable = await harness.ControlPutAsync(
            FeaturePath,
            Hs1bControlPlaneHarness.FeatureBody(generation0, enabled: true)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(enable);
            Assert.True(enable.IsSuccessStatusCode, body);
            Assert.Contains("\"result_code\":\"applied\"", body, StringComparison.Ordinal);
            Assert.Contains("\"configured_enabled\":true", body, StringComparison.Ordinal);
            Assert.Contains("\"effective_enabled\":true", body, StringComparison.Ordinal);
            appliedGeneration = await Hs1bControlPlaneHarness.PropertyAsync(enable, "config_generation");
        }

        // A capability mutation is config-only: it never touches a provider.
        Assert.Equal(providerCallsBefore, harness.Transport.Calls);
        Assert.True(harness.Store.Enabled);
        Assert.True(harness.CurrentState.Snapshot.ThreadSelectionEnabled);
        // When the mutation reports success, the whole publication is complete:
        // the committed generation is the published generation, and the runtime
        // capability of the SAME store already matches the published feature.
        Assert.Equal(appliedGeneration, harness.Generation);
        Assert.Equal(harness.CurrentState.Snapshot.ThreadSelectionEnabled, harness.Store.Enabled);
        Assert.NotEqual(generation0, harness.Generation);

        LocalRouterConfigReadResult durable = await harness.ConfigOperator.ReadAsync(CancellationToken.None);
        Assert.True(durable.IsSuccess);
        Assert.True(durable.View!.Config.LocalRouter.ThreadSelection.Enabled);
        Assert.Equal(harness.Generation, durable.View.ConfigGeneration);

        // No restart: a real turn observes the thread, and the per-thread
        // generation is untouched by the config generation change.
        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);

        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);
        using (HttpResponseMessage selection = await harness.ControlGetAsync($"{ThreadsPath}/{threadRef}/selection"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(selection);
            Assert.True(selection.IsSuccessStatusCode, body);
            Assert.Contains("\"selection_state\":\"none\"", body, StringComparison.Ordinal);
            Assert.Contains("\"selection_generation\":1", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage set = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Beta.ClientModelId)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(set);
            Assert.True(set.IsSuccessStatusCode, body);
            Assert.Contains("\"selection_state\":\"pending\"", body, StringComparison.Ordinal);
            Assert.Contains("\"selection_generation\":2", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage switchTurn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(switchTurn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(switchTurn));
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Live_feature_disable_clears_selections_and_cancels_captures()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: true);
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        using (HttpResponseMessage observe = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(observe.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(observe));
        }

        using (HttpResponseMessage set = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Beta.ClientModelId)))
        {
            Assert.True(set.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(set));
        }

        using (HttpResponseMessage active = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(active.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(active));
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);
        Assert.Equal(ThreadSelectionState.Active, harness.Store.TryGet(threadRef)!.SelectionState);

        string captureToken;
        using (HttpResponseMessage capture = await harness.ControlPostAsync(
            $"{ThreadsPath}/capture",
            "{\"schema_version\":1}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(capture);
            Assert.True(capture.IsSuccessStatusCode, body);
            Assert.Contains("\"status\":\"open\"", body, StringComparison.Ordinal);
            captureToken = await Hs1bControlPlaneHarness.PropertyAsync(capture, "capture_token");
        }

        Assert.True(harness.Store.Status().CaptureOpen);

        int providerCallsBefore = harness.Transport.Calls;
        using (HttpResponseMessage disable = await harness.ControlPutAsync(
            FeaturePath,
            Hs1bControlPlaneHarness.FeatureBody(harness.Generation, enabled: false)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(disable);
            Assert.True(disable.IsSuccessStatusCode, body);
            Assert.Contains("\"configured_enabled\":false", body, StringComparison.Ordinal);
            Assert.Contains("\"effective_enabled\":false", body, StringComparison.Ordinal);
        }

        Assert.Equal(providerCallsBefore, harness.Transport.Calls);
        Assert.False(harness.Store.Enabled);
        Assert.False(harness.CurrentState.Snapshot.ThreadSelectionEnabled);
        Assert.False(harness.Store.Status().CaptureOpen);

        LocalRouterConfigReadResult durable = await harness.ConfigOperator.ReadAsync(CancellationToken.None);
        Assert.True(durable.IsSuccess);
        Assert.False(durable.View!.Config.LocalRouter.ThreadSelection.Enabled);

        using (HttpResponseMessage threads = await harness.ControlGetAsync(ThreadsPath))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(threads);
            Assert.True(threads.IsSuccessStatusCode, body);
            Assert.Contains("\"effective_enabled\":false", body, StringComparison.Ordinal);
            Assert.Contains("\"selection_state\":\"cleared\"", body, StringComparison.Ordinal);
            Assert.DoesNotContain("\"selection_state\":\"active\"", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage captureRead = await harness.ControlGetAsync($"{ThreadsPath}/capture/{captureToken}"))
        {
            Assert.Equal(HttpStatusCode.NotFound, captureRead.StatusCode);
            Assert.Equal("control_thread_capture_not_found", await Hs1bControlPlaneHarness.ErrorCodeAsync(captureRead));
        }

        // The next turn is back to the Codex requested model.
        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);
        Assert.DoesNotContain(Hs1bRuntimeConfig.Beta.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Overall_router_disable_clears_thread_state_and_reenable_never_resurrects_an_override()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: true);
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        using (HttpResponseMessage observe = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(observe.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(observe));
        }

        using (HttpResponseMessage set = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Beta.ClientModelId)))
        {
            Assert.True(set.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(set));
        }

        using (HttpResponseMessage active = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(active.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(active));
        }

        Assert.Equal(Hs1bRuntimeConfig.Beta.UpstreamModelId, harness.Sink.Executed[^1].UpstreamModelId);

        // The existing LR-14P Router feature endpoint disables everything.
        using (HttpResponseMessage disable = await harness.ControlPutAsync(
            RouterFeaturePath,
            Hs1bControlPlaneHarness.RouterFeatureBody(harness.Generation, enabled: false)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(disable);
            Assert.True(disable.IsSuccessStatusCode, body);
            Assert.Contains("\"local_router_enabled\":false", body, StringComparison.Ordinal);
        }

        Assert.False(harness.Store.Enabled);
        Assert.False(harness.CurrentState.Snapshot.LocalRouterEnabled);
        Assert.Equal(ThreadSelectionState.Cleared, harness.Store.TryGet(threadRef)!.SelectionState);

        // While the Router is disabled the execution boundary fails closed.
        using (HttpResponseMessage blocked = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.Equal(HttpStatusCode.ServiceUnavailable, blocked.StatusCode);
            Assert.Equal("router_disabled", await Hs1bControlPlaneHarness.ErrorCodeAsync(blocked));
        }

        using (HttpResponseMessage enable = await harness.ControlPutAsync(
            RouterFeaturePath,
            Hs1bControlPlaneHarness.RouterFeatureBody(harness.Generation, enabled: true)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(enable);
            Assert.True(enable.IsSuccessStatusCode, body);
            Assert.Contains("\"local_router_enabled\":true", body, StringComparison.Ordinal);
        }

        // Durable thread_selection.enabled was never changed, so the capability
        // is live again - but the cleared override must not come back.
        Assert.True(harness.Store.Enabled);
        Assert.True(harness.CurrentState.Snapshot.ThreadSelectionEnabled);
        Assert.Equal(ThreadSelectionState.Cleared, harness.Store.TryGet(threadRef)!.SelectionState);

        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        Assert.Equal(Hs1bRuntimeConfig.Alpha.UpstreamModelId, harness.Sink.Executed[^1].UpstreamModelId);
    }

    [Fact]
    public async Task Config_generation_and_thread_generation_stay_independent()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: false);
        string configGeneration0 = harness.Generation;
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        // FEATURE ENABLE: config generation advances, per-thread state is untouched.
        using (HttpResponseMessage enable = await harness.ControlPutAsync(
            FeaturePath,
            Hs1bControlPlaneHarness.FeatureBody(configGeneration0, enabled: true)))
        {
            Assert.True(enable.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(enable));
        }

        string configGeneration1 = harness.Generation;
        Assert.NotEqual(configGeneration0, configGeneration1);

        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        using (HttpResponseMessage observed = await harness.ControlGetAsync($"{ThreadsPath}/{threadRef}/selection"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(observed);
            Assert.Contains("\"selection_generation\":1", body, StringComparison.Ordinal);
        }

        // SET THREAD B: thread generation advances, config generation does not.
        using (HttpResponseMessage set = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Beta.ClientModelId)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(set);
            Assert.True(set.IsSuccessStatusCode, body);
            Assert.Contains("\"selection_generation\":2", body, StringComparison.Ordinal);
        }

        Assert.Equal(configGeneration1, harness.Generation);

        using (HttpResponseMessage activation = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(activation.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(activation));
        }

        // CLEAR THREAD: thread generation advances, config generation does not.
        using (HttpResponseMessage cleared = await harness.ControlDeleteAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.ClearSelectionBody(3)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(cleared);
            Assert.True(cleared.IsSuccessStatusCode, body);
            Assert.Contains("\"selection_generation\":4", body, StringComparison.Ordinal);
        }

        Assert.Equal(configGeneration1, harness.Generation);

        using (HttpResponseMessage feature = await harness.ControlGetAsync(FeaturePath))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(feature);
            Assert.Contains("\"config_generation\":\"" + configGeneration1 + "\"", body, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task Thread_selection_control_plane_lifecycle_is_complete_and_leaks_no_identity()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: true);
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);
        List<string> bodies = [];

        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        using (HttpResponseMessage threads = await harness.ControlGetAsync($"{ThreadsPath}?limit=10"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(threads);
            bodies.Add(body);
            Assert.True(threads.IsSuccessStatusCode, body);
            Assert.Contains("\"thread_count\":1", body, StringComparison.Ordinal);
            Assert.Contains("\"thread_ref\":\"" + threadRef + "\"", body, StringComparison.Ordinal);
            Assert.Contains("\"requested_model\":\"" + Hs1bRuntimeConfig.Alpha.ClientModelId + "\"", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage selection = await harness.ControlGetAsync($"{ThreadsPath}/{threadRef}/selection"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(selection);
            bodies.Add(body);
            Assert.True(selection.IsSuccessStatusCode, body);
            Assert.Contains("\"selection_state\":\"none\"", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage set = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Beta.ClientModelId)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(set);
            bodies.Add(body);
            Assert.True(set.IsSuccessStatusCode, body);
            Assert.Contains("\"thread_ref\":\"" + threadRef + "\"", body, StringComparison.Ordinal);
            Assert.Contains("\"selection_state\":\"pending\"", body, StringComparison.Ordinal);
            Assert.Contains("\"selection_model\":\"" + Hs1bRuntimeConfig.Beta.ClientModelId + "\"", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage switchTurn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(switchTurn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(switchTurn));
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);

        using (HttpResponseMessage active = await harness.ControlGetAsync($"{ThreadsPath}/{threadRef}/selection"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(active);
            bodies.Add(body);
            Assert.Contains("\"selection_state\":\"active\"", body, StringComparison.Ordinal);
            // The pending -> active transition advances the per-thread
            // generation, so the CAS basis the caller must use moves with it.
            Assert.Contains("\"selection_generation\":3", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage sticky = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(sticky.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(sticky));
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);

        using (HttpResponseMessage cleared = await harness.ControlDeleteAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.ClearSelectionBody(3)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(cleared);
            bodies.Add(body);
            Assert.True(cleared.IsSuccessStatusCode, body);
            Assert.Contains("\"selection_state\":\"cleared\"", body, StringComparison.Ordinal);
            Assert.Contains("\"selection_generation\":4", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);

        foreach (string body in bodies)
        {
            Assert.DoesNotContain(Hs1bTestThreads.One, body, StringComparison.Ordinal);
            Assert.DoesNotContain("thread_id", body, StringComparison.Ordinal);
            Assert.DoesNotContain("x-codex-turn-metadata", body, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task Stale_thread_generation_is_rejected_with_conflict()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: true);
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        using (HttpResponseMessage winner = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Beta.ClientModelId)))
        {
            Assert.True(winner.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(winner));
        }

        using (HttpResponseMessage stale = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Gamma.ClientModelId)))
        {
            Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
            Assert.Equal("control_thread_selection_conflict", await Hs1bControlPlaneHarness.ErrorCodeAsync(stale));
        }

        // No retry, no overwrite: the winning claim is exactly what remains.
        ThreadSelectionSnapshot snapshot = harness.Store.TryGet(threadRef)!;
        Assert.Equal(Hs1bRuntimeConfig.Beta.ClientModelId, snapshot.SelectionModel);
        Assert.Equal((ulong)2, snapshot.SelectionGeneration);
        Assert.Equal(ThreadSelectionState.Pending, snapshot.SelectionState);

        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Capture_discovers_identity_without_switching_models()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: true);
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        string captureToken;
        using (HttpResponseMessage capture = await harness.ControlPostAsync($"{ThreadsPath}/capture", "{\"schema_version\":1}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(capture);
            Assert.True(capture.IsSuccessStatusCode, body);
            Assert.Contains("\"status\":\"open\"", body, StringComparison.Ordinal);
            Assert.Contains("\"thread_ref\":null", body, StringComparison.Ordinal);
            Assert.DoesNotContain("model", body, StringComparison.Ordinal);
            captureToken = await Hs1bControlPlaneHarness.PropertyAsync(capture, "capture_token");
        }

        // The capture turn is an identity-discovery turn, not a switch turn.
        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);
        Assert.Equal(ThreadSelectionState.None, harness.Store.TryGet(threadRef)!.SelectionState);

        using (HttpResponseMessage captured = await harness.ControlGetAsync($"{ThreadsPath}/capture/{captureToken}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(captured);
            Assert.True(captured.IsSuccessStatusCode, body);
            Assert.Contains("\"status\":\"captured\"", body, StringComparison.Ordinal);
            Assert.Contains("\"thread_ref\":\"" + threadRef + "\"", body, StringComparison.Ordinal);
            Assert.DoesNotContain(Hs1bTestThreads.One, body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage selection = await harness.ControlGetAsync($"{ThreadsPath}/{threadRef}/selection"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(selection);
            Assert.Contains("\"selection_state\":\"none\"", body, StringComparison.Ordinal);
        }

        // Only an explicit selection switches the model.
        using (HttpResponseMessage set = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Beta.ClientModelId)))
        {
            Assert.True(set.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(set));
        }

        using (HttpResponseMessage switchTurn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(switchTurn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(switchTurn));
        }

        Assert.Contains(Hs1bRuntimeConfig.Beta.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);

        // A capture can also be cancelled explicitly.
        string cancelToken;
        using (HttpResponseMessage second = await harness.ControlPostAsync($"{ThreadsPath}/capture", "{\"schema_version\":1}"))
        {
            cancelToken = await Hs1bControlPlaneHarness.PropertyAsync(second, "capture_token");
        }

        using (HttpResponseMessage cancel = await harness.ControlDeleteAsync($"{ThreadsPath}/capture/{cancelToken}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(cancel);
            Assert.True(cancel.IsSuccessStatusCode, body);
            Assert.Contains("\"status\":\"cancelled\"", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage gone = await harness.ControlGetAsync($"{ThreadsPath}/capture/{cancelToken}"))
        {
            Assert.Equal(HttpStatusCode.NotFound, gone.StatusCode);
        }
    }

    [Fact]
    public async Task Model_approval_is_static_and_never_contacts_a_provider()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: true);
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        int providerCallsAfterTurn = harness.Transport.Calls;

        using (HttpResponseMessage approved = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Beta.ClientModelId)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(approved);
            Assert.True(approved.IsSuccessStatusCode, body);
            Assert.Contains("\"selection_state\":\"pending\"", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage unknown = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, "hot-unknown")))
        {
            Assert.Equal(HttpStatusCode.UnprocessableEntity, unknown.StatusCode);
            Assert.Equal("control_model_not_approved", await Hs1bControlPlaneHarness.ErrorCodeAsync(unknown));
        }

        // Config-mapped but structurally unusable (route disabled): same
        // static rejection, still no provider attempt.
        using (HttpResponseMessage unusable = await harness.ControlPutAsync(
            $"{ThreadsPath}/{threadRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Delta.ClientModelId)))
        {
            Assert.Equal(HttpStatusCode.UnprocessableEntity, unusable.StatusCode);
            Assert.Equal("control_model_not_approved", await Hs1bControlPlaneHarness.ErrorCodeAsync(unusable));
        }

        Assert.Equal(providerCallsAfterTurn, harness.Transport.Calls);

        // Rejected mutations changed neither the claim nor its generation.
        ThreadSelectionSnapshot snapshot = harness.Store.TryGet(threadRef)!;
        Assert.Equal(Hs1bRuntimeConfig.Beta.ClientModelId, snapshot.SelectionModel);
        Assert.Equal((ulong)2, snapshot.SelectionGeneration);
    }

    [Fact]
    public async Task Control_plane_contract_guards_reject_bad_requests()
    {
        await using Hs1bControlPlaneHarness disabled = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: false);
        string unknownRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.Two);

        using (HttpResponseMessage anonymous = await disabled.SendUnauthenticatedAsync(HttpMethod.Get, FeaturePath))
        {
            Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
            Assert.Equal("authentication_required", await Hs1bControlPlaneHarness.ErrorCodeAsync(anonymous));
        }

        using (HttpResponseMessage invalidToken = await disabled.ControlGetAsync(FeaturePath, token: "not-the-local-token"))
        {
            Assert.Equal(HttpStatusCode.Unauthorized, invalidToken.StatusCode);
            Assert.Equal("authentication_invalid", await Hs1bControlPlaneHarness.ErrorCodeAsync(invalidToken));
        }

        using (HttpResponseMessage unknownField = await disabled.ControlPutAsync(
            FeaturePath,
            "{\"schema_version\":1,\"expected_generation\":\"" + disabled.Generation + "\",\"enabled\":true,\"unexpected\":1}"))
        {
            Assert.Equal(HttpStatusCode.BadRequest, unknownField.StatusCode);
            Assert.Equal("control_invalid_request", await Hs1bControlPlaneHarness.ErrorCodeAsync(unknownField));
        }

        using (HttpResponseMessage oversized = await disabled.ControlPutAsync(
            FeaturePath,
            "{\"schema_version\":1,\"expected_generation\":\"" + disabled.Generation + "\",\"enabled\":true,\"pad\":\""
                + new string('p', 70 * 1024) + "\"}"))
        {
            Assert.Equal(HttpStatusCode.RequestEntityTooLarge, oversized.StatusCode);
            Assert.Equal("control_payload_too_large", await Hs1bControlPlaneHarness.ErrorCodeAsync(oversized));
        }

        using (HttpResponseMessage notObserved = await disabled.ControlGetAsync($"{ThreadsPath}/{unknownRef}/selection"))
        {
            Assert.Equal(HttpStatusCode.NotFound, notObserved.StatusCode);
            Assert.Equal("control_thread_not_observed", await Hs1bControlPlaneHarness.ErrorCodeAsync(notObserved));
        }

        // A raw canonical thread id is never an addressable reference.
        using (HttpResponseMessage rawIdentity = await disabled.ControlGetAsync($"{ThreadsPath}/{Hs1bTestThreads.One}/selection"))
        {
            Assert.Equal(HttpStatusCode.BadRequest, rawIdentity.StatusCode);
            Assert.Equal("control_invalid_request", await Hs1bControlPlaneHarness.ErrorCodeAsync(rawIdentity));
            Assert.DoesNotContain(Hs1bTestThreads.One, await Hs1bControlPlaneHarness.BodyAsync(rawIdentity), StringComparison.Ordinal);
        }

        using (HttpResponseMessage disabledSet = await disabled.ControlPutAsync(
            $"{ThreadsPath}/{unknownRef}/selection",
            Hs1bControlPlaneHarness.SetSelectionBody(1, Hs1bRuntimeConfig.Beta.ClientModelId)))
        {
            Assert.Equal(HttpStatusCode.ServiceUnavailable, disabledSet.StatusCode);
            Assert.Equal("control_thread_selection_disabled", await Hs1bControlPlaneHarness.ErrorCodeAsync(disabledSet));
        }

        using (HttpResponseMessage disabledCapture = await disabled.ControlPostAsync($"{ThreadsPath}/capture", "{\"schema_version\":1}"))
        {
            Assert.Equal(HttpStatusCode.ServiceUnavailable, disabledCapture.StatusCode);
            Assert.Equal("control_thread_selection_disabled", await Hs1bControlPlaneHarness.ErrorCodeAsync(disabledCapture));
        }

        using (HttpResponseMessage noConfirm = await disabled.ControlDeleteAsync($"{ThreadsPath}/selections", "{\"schema_version\":1,\"confirm\":false}"))
        {
            Assert.Equal(HttpStatusCode.BadRequest, noConfirm.StatusCode);
            Assert.Equal("control_invalid_request", await Hs1bControlPlaneHarness.ErrorCodeAsync(noConfirm));
        }

        // Clear-all is deliberately available while the capability is off: it
        // removes runtime remnants and never enables anything.
        using (HttpResponseMessage clearAll = await disabled.ControlDeleteAsync($"{ThreadsPath}/selections", "{\"schema_version\":1,\"confirm\":true}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(clearAll);
            Assert.True(clearAll.IsSuccessStatusCode, body);
            Assert.Contains("\"cleared_count\":0", body, StringComparison.Ordinal);
            Assert.Contains("\"thread_selection_enabled\":false", body, StringComparison.Ordinal);
        }

        Assert.False(disabled.Store.Enabled);
        Assert.Equal(0, disabled.Transport.Calls);
    }

    [Fact]
    public async Task Expired_open_capture_returns_not_found_and_frees_the_slot_over_http()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: true);

        string firstToken;
        using (HttpResponseMessage first = await harness.ControlPostAsync($"{ThreadsPath}/capture", "{\"schema_version\":1}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(first);
            Assert.True(first.IsSuccessStatusCode, body);
            firstToken = await Hs1bControlPlaneHarness.PropertyAsync(first, "capture_token");
        }

        harness.Clock.Advance(ThreadSelectionOptions.DefaultCaptureTtl);

        using (HttpResponseMessage expired = await harness.ControlGetAsync($"{ThreadsPath}/capture/{firstToken}"))
        {
            Assert.Equal(HttpStatusCode.NotFound, expired.StatusCode);
            Assert.Equal("control_thread_capture_not_found", await Hs1bControlPlaneHarness.ErrorCodeAsync(expired));
        }

        // An expired token is exactly as unknown as a foreign one: DELETE is 404
        // and never "revives" it as a successful cancellation.
        using (HttpResponseMessage cancelled = await harness.ControlDeleteAsync($"{ThreadsPath}/capture/{firstToken}"))
        {
            Assert.Equal(HttpStatusCode.NotFound, cancelled.StatusCode);
            Assert.Equal("control_thread_capture_not_found", await Hs1bControlPlaneHarness.ErrorCodeAsync(cancelled));
        }

        // The expired window no longer blocks the single OPEN slot.
        using (HttpResponseMessage reopened = await harness.ControlPostAsync($"{ThreadsPath}/capture", "{\"schema_version\":1}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(reopened);
            Assert.True(reopened.IsSuccessStatusCode, body);
            Assert.NotEqual(firstToken, await Hs1bControlPlaneHarness.PropertyAsync(reopened, "capture_token"));
        }

        Assert.Equal(0, harness.Transport.Calls);
    }

    [Fact]
    public async Task Captured_retention_expiry_returns_not_found_over_http()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: true);
        string threadRef = Hs1bTestThreads.RefOf(Hs1bTestThreads.One);

        string token;
        using (HttpResponseMessage capture = await harness.ControlPostAsync($"{ThreadsPath}/capture", "{\"schema_version\":1}"))
        {
            Assert.True(capture.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(capture));
            token = await Hs1bControlPlaneHarness.PropertyAsync(capture, "capture_token");
        }

        // The identity-discovery turn claims the window and keeps its own model.
        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        Assert.Contains(Hs1bRuntimeConfig.Alpha.UpstreamModelId, harness.UpstreamBody, StringComparison.Ordinal);

        using (HttpResponseMessage captured = await harness.ControlGetAsync($"{ThreadsPath}/capture/{token}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(captured);
            Assert.True(captured.IsSuccessStatusCode, body);
            Assert.Contains("\"status\":\"captured\"", body, StringComparison.Ordinal);
            Assert.Contains("\"thread_ref\":\"" + threadRef + "\"", body, StringComparison.Ordinal);
        }

        harness.Clock.Advance(ThreadSelectionOptions.CapturedRetentionTtl);

        using (HttpResponseMessage expired = await harness.ControlGetAsync($"{ThreadsPath}/capture/{token}"))
        {
            Assert.Equal(HttpStatusCode.NotFound, expired.StatusCode);
            Assert.Equal("control_thread_capture_not_found", await Hs1bControlPlaneHarness.ErrorCodeAsync(expired));
        }

        // The observed thread itself is unaffected by capture retention expiry.
        using (HttpResponseMessage selection = await harness.ControlGetAsync($"{ThreadsPath}/{threadRef}/selection"))
        {
            Assert.True(selection.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(selection));
        }
    }

    [Fact]
    public async Task Second_capture_open_is_busy_and_leaves_the_first_window_untouched()
    {
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: true);

        string firstToken;
        using (HttpResponseMessage first = await harness.ControlPostAsync($"{ThreadsPath}/capture", "{\"schema_version\":1}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(first);
            Assert.True(first.IsSuccessStatusCode, body);
            Assert.Contains("\"status\":\"open\"", body, StringComparison.Ordinal);
            firstToken = await Hs1bControlPlaneHarness.PropertyAsync(first, "capture_token");
        }

        // The HTTP handler passed the authenticated control-plane client into the
        // store, and no other owner can observe the window.
        Assert.NotNull(harness.Store.TryGetCapture(firstToken, Hs1bRuntimeConfig.ControlPlaneClientId));
        Assert.Null(harness.Store.TryGetCapture(firstToken, "client.someone_else"));

        using (HttpResponseMessage second = await harness.ControlPostAsync($"{ThreadsPath}/capture", "{\"schema_version\":1}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(second);
            Assert.Equal(HttpStatusCode.Conflict, second.StatusCode);
            Assert.Equal("control_thread_capture_busy", await Hs1bControlPlaneHarness.ErrorCodeAsync(second));
            // The busy response never discloses the existing window.
            Assert.DoesNotContain(firstToken, body, StringComparison.Ordinal);
            Assert.DoesNotContain(Hs1bRuntimeConfig.ControlPlaneClientId, body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage unchanged = await harness.ControlGetAsync($"{ThreadsPath}/capture/{firstToken}"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(unchanged);
            Assert.True(unchanged.IsSuccessStatusCode, body);
            Assert.Contains("\"status\":\"open\"", body, StringComparison.Ordinal);
            Assert.Contains("\"capture_token\":\"" + firstToken + "\"", body, StringComparison.Ordinal);
            Assert.DoesNotContain(Hs1bRuntimeConfig.ControlPlaneClientId, body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage cancelled = await harness.ControlDeleteAsync($"{ThreadsPath}/capture/{firstToken}"))
        {
            Assert.True(cancelled.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(cancelled));
        }

        // Cancelling the owner's window frees the single OPEN slot.
        using (HttpResponseMessage reopened = await harness.ControlPostAsync($"{ThreadsPath}/capture", "{\"schema_version\":1}"))
        {
            Assert.True(reopened.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(reopened));
        }

        Assert.Equal(0, harness.Transport.Calls);
    }

    [Fact]
    public async Task Composite_publication_keeps_live_policy_resolution_intact()
    {
        // The composite runtime sink must publish the SAME CurrentRouterState on
        // every mutation, so the existing live policy source keeps seeing new
        // policies - and a thread-selection capability change must not disturb
        // policy state (or the reverse).
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(threadSelectionEnabled: false);
        string generation0 = harness.Generation;

        using (HttpResponseMessage policyRead = await harness.ControlGetAsync("/v1/router/control-plane/policy"))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(policyRead);
            Assert.True(policyRead.IsSuccessStatusCode, body);
            Assert.Contains("\"effective_retry_source\":\"safe_defaults\"", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage mutation = await harness.ControlPutAsync(
            "/v1/router/control-plane/policy",
            RetryMutationBody(generation0, maxAttempts: 3)))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(mutation);
            Assert.True(mutation.IsSuccessStatusCode, body);
            Assert.Contains("\"max_attempts\":3", body, StringComparison.Ordinal);
        }

        PolicyConfig policy = harness.CurrentState.Snapshot.Policies
            .Single(candidate => candidate.PolicyId == "policy.retry-safe-default");
        Assert.Equal(3, policy.RetryBody!.MaxAttempts);
        Assert.False(harness.Store.Enabled);

        // Two injected upstream failures now still succeed: the running
        // execution boundary sees the newly published retry policy.
        harness.Transport.FailuresForNextRequest = 2;
        using (HttpResponseMessage turn = await harness.PostTurnAsync(Hs1bRuntimeConfig.Alpha.ClientModelId, Hs1bTestThreads.One))
        {
            Assert.True(turn.IsSuccessStatusCode, await Hs1bControlPlaneHarness.BodyAsync(turn));
        }

        Assert.Equal(3, harness.Sink.Executed[^1].AttemptCount);
    }

    [Fact]
    public async Task Live_mutation_requires_the_running_runtime_publication_sink()
    {
        // The operator publishes through a sink that is not this runtime's live
        // owner: a mutation must fail closed instead of writing durable config
        // and claiming the running Router applied it.
        await using Hs1bControlPlaneHarness harness = await Hs1bControlPlaneHarness.StartAsync(
            threadSelectionEnabled: false,
            bindForeignPublicationSink: true);

        string generation = harness.Generation;
        using (HttpResponseMessage status = await harness.ControlGetAsync(StatusPath))
        {
            string body = await Hs1bControlPlaneHarness.BodyAsync(status);
            Assert.Contains("\"policy_mutation_available\":false", body, StringComparison.Ordinal);
            Assert.Contains("\"feature_mutation_available\":false", body, StringComparison.Ordinal);
            Assert.Contains("\"mutation_available\":false", body, StringComparison.Ordinal);
        }

        using (HttpResponseMessage mutation = await harness.ControlPutAsync(
            FeaturePath,
            Hs1bControlPlaneHarness.FeatureBody(generation, enabled: true)))
        {
            Assert.Equal(HttpStatusCode.ServiceUnavailable, mutation.StatusCode);
            Assert.Equal("control_thread_selection_unavailable", await Hs1bControlPlaneHarness.ErrorCodeAsync(mutation));
        }

        Assert.False(harness.Store.Enabled);
        Assert.Equal(generation, harness.Generation);

        LocalRouterConfigReadResult durable = await harness.ConfigOperator.ReadAsync(CancellationToken.None);
        Assert.True(durable.IsSuccess);
        Assert.False(durable.View!.Config.LocalRouter.ThreadSelection.Enabled);
        Assert.Equal(generation, durable.View.ConfigGeneration);
    }
}
