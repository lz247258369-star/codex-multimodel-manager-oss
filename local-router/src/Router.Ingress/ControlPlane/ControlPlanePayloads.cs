using System.Text.Json.Serialization;
using Router.Observability;

namespace Router.Ingress.ControlPlane;

/// <summary>Availability descriptor used by control-plane projections.</summary>
public sealed record ControlPlaneAvailabilityPayload
{
    public required bool Available { get; init; }

    public string? ReasonCode { get; init; }
}

/// <summary>Lifecycle-control availability. LR-14P never fakes Start/Stop.</summary>
public sealed record LifecycleControlAvailabilityPayload
{
    public required bool StartStopAvailable { get; init; }

    public required string ReasonCode { get; init; }
}

/// <summary>Safe health summary from the production passive-health tracker.</summary>
public sealed record ControlPlaneHealthSummaryPayload
{
    public required bool Available { get; init; }

    public string? ReasonCode { get; init; }

    public string? GeneratedAt { get; init; }

    public int? RouteCount { get; init; }

    public int? HealthyCount { get; init; }

    public int? DegradedCount { get; init; }

    public int? UnhealthyCount { get; init; }

    public int? UnknownCount { get; init; }
}

/// <summary>
/// Truthful circuit-breaker projection. LR-14P has no route-level breaker
/// config boundary, so configured stays null, effective is disabled, and
/// mutation is unavailable with an explicit gap code.
/// </summary>
public sealed record ControlPlaneCircuitBreakerProjectionPayload
{
    public required string EffectiveState { get; init; }

    public string? Configured { get; init; }

    public required bool MutationAvailable { get; init; }

    public required string ReasonCode { get; init; }
}

/// <summary>Versioned control-plane status payload.</summary>
public sealed record ControlPlaneStatusPayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ConfigGeneration { get; init; }

    public required string Lifecycle { get; init; }

    public required bool Ready { get; init; }

    public required int InFlightCount { get; init; }

    public required bool LocalRouterEnabled { get; init; }

    public required IReadOnlyList<string> SupportedControlPlaneContracts { get; init; }

    public required ControlPlaneAvailabilityPayload MeteringAvailability { get; init; }

    public required ControlPlaneAvailabilityPayload RecentRequestAvailability { get; init; }

    public required bool PolicyMutationAvailable { get; init; }

    public required bool FeatureMutationAvailable { get; init; }

    public required ControlPlaneThreadSelectionStatusPayload ThreadSelection { get; init; }

    public required ControlPlaneHealthSummaryPayload HealthSummary { get; init; }

    public required ControlPlaneCircuitBreakerProjectionPayload CircuitBreaker { get; init; }

    public required LifecycleControlAvailabilityPayload LifecycleControl { get; init; }
}

/// <summary>
/// Safe thread-selection capability summary. Configured state comes from the
/// published config; effective state is the conjunction of the overall Router
/// feature and the runtime capability of the single thread-selection store.
/// Counts stay null when no store is composed, so "not composed" is never
/// reported as zero threads.
/// </summary>
public sealed record ControlPlaneThreadSelectionStatusPayload
{
    public required bool ConfiguredEnabled { get; init; }

    public required bool EffectiveEnabled { get; init; }

    public required bool MutationAvailable { get; init; }

    public int? ObservedThreadCount { get; init; }

    public int? ActiveSelectionCount { get; init; }

    public int? PendingSelectionCount { get; init; }

    public bool? CaptureOpen { get; init; }

    public string? SnapshotAt { get; init; }

    public string? ReasonCode { get; init; }
}

/// <summary>Safe per-record usage projection.</summary>
public sealed record UsageProjectionPayload
{
    public int? InputTokens { get; init; }

    public int? OutputTokens { get; init; }

    public int? TotalTokens { get; init; }

    public int? CachedTokens { get; init; }

    public int? ReasoningTokens { get; init; }

    public required bool Estimated { get; init; }

    public required string RecordedAt { get; init; }
}

/// <summary>Safe per-record cost projection (informational estimate only).</summary>
public sealed record CostProjectionPayload
{
    public decimal? InputCost { get; init; }

    public decimal? OutputCost { get; init; }

    public decimal? CachedCost { get; init; }

    public decimal? ReasoningCost { get; init; }

    public decimal? TotalCost { get; init; }

    public string? Currency { get; init; }

    public required string Status { get; init; }

    public required bool Estimated { get; init; }

    public required string PricingSnapshotVersion { get; init; }
}

/// <summary>Safe metering record projection for the bounded usage read.</summary>
public sealed record ControlPlaneMeteringRecordPayload
{
    public required string RequestId { get; init; }

    public required string TraceId { get; init; }

    public string? ClientId { get; init; }

    public string? ConfigGeneration { get; init; }

    public string? ProviderId { get; init; }

    public string? RouteId { get; init; }

    public string? ModelRouteId { get; init; }

    public string? ModelId { get; init; }

    public string? UpstreamModelId { get; init; }

    public UsageProjectionPayload? Usage { get; init; }

    public CostProjectionPayload? CostEstimate { get; init; }

    public required string MeteringStatus { get; init; }

    public required bool Stream { get; init; }

    public required string CompletedAt { get; init; }

    public required long DurationMs { get; init; }
}

/// <summary>Per-currency estimated-cost total.</summary>
public sealed record CurrencyCostSummaryPayload
{
    public required string Currency { get; init; }

    public required decimal TotalCost { get; init; }
}

/// <summary>Bounded usage/cost read payload (scope: bounded recent records).</summary>
public sealed record ControlPlaneUsagePayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string Scope { get; init; }

    public required string BillingNote { get; init; }

    public required int RecordCount { get; init; }

    public required int Capacity { get; init; }

    public required int KnownUsageCount { get; init; }

    public required int UnknownUsageCount { get; init; }

    public required int KnownCostCount { get; init; }

    public required int UnknownCostCount { get; init; }

    /// <summary>Null when any record in the bounded scope has unknown input usage.</summary>
    public long? InputTokensTotal { get; init; }

    /// <summary>Null when any record in the bounded scope has unknown output usage.</summary>
    public long? OutputTokensTotal { get; init; }

    public required IReadOnlyList<CurrencyCostSummaryPayload> EstimatedCostByCurrency { get; init; }

    public required bool Degraded { get; init; }

    public required IReadOnlyList<string> DegradationCodes { get; init; }

    public required IReadOnlyList<ControlPlaneMeteringRecordPayload> Records { get; init; }
}

/// <summary>Bounded recent-request read payload (safe operational metadata).</summary>
public sealed record ControlPlaneRecentRequestsPayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string Scope { get; init; }

    public required int RecordCount { get; init; }

    public required bool Degraded { get; init; }

    public required IReadOnlyList<string> DegradationCodes { get; init; }

    public required IReadOnlyList<RedactedRequestRecord> Records { get; init; }
}

/// <summary>Versioned retry body in the control-plane contract.</summary>
public sealed record ControlPlaneRetryBodyPayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required int MaxAttempts { get; init; }

    public required long BaseDelayMs { get; init; }

    public required long MaxDelayMs { get; init; }

    public required decimal Jitter { get; init; }

    public required bool RespectRetryAfter { get; init; }

    public required long MaxRetryAfterMs { get; init; }
}

/// <summary>Versioned timeout body in the control-plane contract.</summary>
public sealed record ControlPlaneTimeoutBodyPayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required long ConnectTimeoutMs { get; init; }

    public required long FirstByteTimeoutMs { get; init; }

    public required long IdleTimeoutMs { get; init; }

    public required long AttemptTimeoutMs { get; init; }

    public required long TotalTimeoutMs { get; init; }
}

/// <summary>Versioned failover body. No cross-model field exists.</summary>
public sealed record ControlPlaneFailoverBodyPayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required bool AllowSameModelAlternateEndpoint { get; init; }

    public required bool AllowSameModelAlternateProvider { get; init; }
}

/// <summary>One policy entry: configured vs effective, explicitly distinct.</summary>
public sealed record ControlPlanePolicyEntryPayload
{
    public required string PolicyId { get; init; }

    public required int Version { get; init; }

    public ControlPlaneRetryBodyPayload? ConfiguredRetry { get; init; }

    public ControlPlaneTimeoutBodyPayload? ConfiguredTimeout { get; init; }

    public ControlPlaneFailoverBodyPayload? ConfiguredFailover { get; init; }

    public required ControlPlaneRetryBodyPayload EffectiveRetry { get; init; }

    public required ControlPlaneTimeoutBodyPayload EffectiveTimeout { get; init; }

    public required ControlPlaneFailoverBodyPayload EffectiveFailover { get; init; }

    public required string EffectiveRetrySource { get; init; }

    public required string EffectiveTimeoutSource { get; init; }

    public required string EffectiveFailoverSource { get; init; }
}

/// <summary>Route → policy-id reference (safe operational metadata only).</summary>
public sealed record ControlPlaneRoutePolicyReferencePayload
{
    public required string RouteId { get; init; }

    public required string TimeoutPolicyId { get; init; }

    public required string RetryPolicyId { get; init; }

    public required string FailoverPolicyId { get; init; }
}

/// <summary>Versioned policy read payload.</summary>
public sealed record ControlPlanePolicySnapshotPayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ConfigGeneration { get; init; }

    public required string CrossModelFallback { get; init; }

    public required IReadOnlyList<ControlPlanePolicyEntryPayload> Policies { get; init; }

    public required IReadOnlyList<ControlPlaneRoutePolicyReferencePayload> Routes { get; init; }

    public required ControlPlaneCircuitBreakerProjectionPayload CircuitBreaker { get; init; }
}

/// <summary>Strict policy mutation request (exactly one body kind present).</summary>
public sealed record ControlPlanePolicyMutationRequest
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ExpectedGeneration { get; init; }

    public required string PolicyId { get; init; }

    public ControlPlaneRetryBodyPayload? Retry { get; init; }

    public ControlPlaneTimeoutBodyPayload? Timeout { get; init; }

    public ControlPlaneFailoverBodyPayload? Failover { get; init; }
}

/// <summary>Policy mutation response: applied snapshot + new generation.</summary>
public sealed record ControlPlanePolicyMutationResponsePayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ResultCode { get; init; }

    public required string PolicyId { get; init; }

    public required string ConfigGeneration { get; init; }

    public required string CrossModelFallback { get; init; }

    public required ControlPlanePolicyEntryPayload Policy { get; init; }
}

/// <summary>Strict feature mutation request.</summary>
public sealed record ControlPlaneFeatureMutationRequest
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ExpectedGeneration { get; init; }

    public required bool Enabled { get; init; }
}

/// <summary>Feature mutation response. Enable never claims Running.</summary>
public sealed record ControlPlaneFeatureMutationResponsePayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ResultCode { get; init; }

    public required bool LocalRouterEnabled { get; init; }

    public required string ConfigGeneration { get; init; }

    public required bool StartStopAvailable { get; init; }

    public required string LifecycleReasonCode { get; init; }
}

/// <summary>Versioned thread-selection capability read (HS-1B).</summary>
public sealed record ControlPlaneThreadSelectionFeaturePayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ConfigGeneration { get; init; }

    public required bool ConfiguredEnabled { get; init; }

    public required bool EffectiveEnabled { get; init; }

    public required bool MutationAvailable { get; init; }

    public required int ObservedThreadCount { get; init; }

    public required int ActiveSelectionCount { get; init; }

    public required int PendingSelectionCount { get; init; }

    public required bool CaptureOpen { get; init; }

    public required string SnapshotAt { get; init; }
}

/// <summary>Strict thread-selection capability mutation request (config generation CAS).</summary>
public sealed record ControlPlaneThreadSelectionFeatureMutationRequest
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ExpectedGeneration { get; init; }

    public required bool Enabled { get; init; }
}

/// <summary>Thread-selection capability mutation response.</summary>
public sealed record ControlPlaneThreadSelectionFeatureMutationResponsePayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ResultCode { get; init; }

    public required string ConfigGeneration { get; init; }

    public required bool ConfiguredEnabled { get; init; }

    public required bool EffectiveEnabled { get; init; }
}

/// <summary>One bounded observed-thread projection; only a ThreadRef is exposed.</summary>
public sealed record ControlPlaneThreadEntryPayload
{
    public required string ThreadRef { get; init; }

    public required string ClientId { get; init; }

    public required string FirstSeen { get; init; }

    public required string LastSeen { get; init; }

    public string? RequestKind { get; init; }

    public int? WindowNumber { get; init; }

    public string? RequestedModel { get; init; }

    public string? SelectedModel { get; init; }

    public required string SelectionState { get; init; }

    public string? SelectionModel { get; init; }

    public required ulong SelectionGeneration { get; init; }

    public string? SelectionExpiresAt { get; init; }

    public string? LastFailureCode { get; init; }

    public string? LastFailureAt { get; init; }
}

/// <summary>Bounded observed-thread list read.</summary>
public sealed record ControlPlaneThreadsPayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string SnapshotAt { get; init; }

    public required bool EffectiveEnabled { get; init; }

    public required int ObservedThreadCount { get; init; }

    public required int ThreadCount { get; init; }

    public required IReadOnlyList<ControlPlaneThreadEntryPayload> Threads { get; init; }
}

/// <summary>Read projection of one observed thread's selection state.</summary>
public sealed record ControlPlaneThreadSelectionPayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ThreadRef { get; init; }

    public required string ClientId { get; init; }

    public required string SelectionState { get; init; }

    public string? SelectionModel { get; init; }

    public required ulong SelectionGeneration { get; init; }

    public string? SelectionIssuedAt { get; init; }

    public string? SelectionExpiresAt { get; init; }

    public string? RequestedModel { get; init; }

    public string? LastSelectedModel { get; init; }

    public string? LastFailureCode { get; init; }

    public string? LastFailureAt { get; init; }
}

/// <summary>Strict thread-selection mutation request (per-thread generation CAS).</summary>
public sealed record ControlPlaneThreadSelectionMutationRequest
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required ulong ExpectedGeneration { get; init; }

    public required string Model { get; init; }
}

/// <summary>Strict thread-selection clear request (per-thread generation CAS).</summary>
public sealed record ControlPlaneThreadSelectionClearRequest
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required ulong ExpectedGeneration { get; init; }
}

/// <summary>Thread-selection mutation response (never carries a raw identity).</summary>
public sealed record ControlPlaneThreadSelectionMutationResponsePayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ResultCode { get; init; }

    public required string ThreadRef { get; init; }

    public required string SelectionState { get; init; }

    public string? SelectionModel { get; init; }

    public required ulong SelectionGeneration { get; init; }

    public string? ExpiresAt { get; init; }
}

/// <summary>Explicit clear-all confirmation body.</summary>
public sealed record ControlPlaneThreadSelectionsClearAllRequest
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required bool Confirm { get; init; }
}

/// <summary>Clear-all result: runtime remnants removed, feature state untouched.</summary>
public sealed record ControlPlaneThreadSelectionsClearAllResponsePayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ResultCode { get; init; }

    public required int ClearedCount { get; init; }

    public required int CancelledCaptureCount { get; init; }

    public required bool ThreadSelectionEnabled { get; init; }
}

/// <summary>Strict capture-open request. A capture never carries a target model.</summary>
public sealed record ControlPlaneThreadCaptureRequest
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }
}

/// <summary>Safe capture projection: identity discovery only, no model state.</summary>
public sealed record ControlPlaneThreadCapturePayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string CaptureToken { get; init; }

    public required string Status { get; init; }

    public required string CreatedAt { get; init; }

    public required string ExpiresAt { get; init; }

    public string? ThreadRef { get; init; }

    public string? CapturedAt { get; init; }
}

/// <summary>Capture cancel result.</summary>
public sealed record ControlPlaneThreadCaptureCancelPayload
{
    [JsonPropertyName("schema_version")]
    public required int SchemaVersionValue { get; init; }

    public required string ResultCode { get; init; }

    public required string CaptureToken { get; init; }

    public required string Status { get; init; }
}
