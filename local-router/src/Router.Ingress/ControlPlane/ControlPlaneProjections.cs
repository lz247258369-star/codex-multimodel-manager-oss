using Router.Configuration;
using Router.Health;
using Router.Metering;
using Router.Observability;
using Router.Policies;
using Router.ThreadSelection;

namespace Router.Ingress.ControlPlane;

/// <summary>
/// Pure projection helpers for the control-plane DTOs. Only fields that exist
/// on the safe typed records are projected; prompt/output/tool/header/secret
/// content, endpoint URLs, and filesystem paths are absent by construction.
/// </summary>
public static class ControlPlaneProjections
{
    public const string CrossModelFallbackHardOff = "HARD_OFF";
    public const string ScopeBoundedRecent = "bounded_recent_records";
    public const string ScopeRouterOwnedRecent = "router_owned_durable_recent";
    public const string BillingNote = "informational_estimate_not_billing";
    public const string LifecycleControlGapCode = "LIFECYCLE_CONTROL_GAP";
    public const string HealthNotComposedCode = "HEALTH_SNAPSHOT_NOT_COMPOSED";
    public const string CircuitBreakerGapCode = "CIRCUIT_BREAKER_POLICY_CONFIGURATION_GAP";
    public const string ThreadSelectionNotComposedCode = "THREAD_SELECTION_NOT_COMPOSED";
    public const string ThreadSelectionDisabledCode = "THREAD_SELECTION_DISABLED";

    public const int ReadDefaultLimit = 20;
    public const int ReadHardLimit = 100;

    public static int ResolveLimit(string? raw)
    {
        if (!int.TryParse(raw, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out int parsed)
            || parsed < 1)
        {
            return ReadDefaultLimit;
        }

        return Math.Min(parsed, ReadHardLimit);
    }

    public static ControlPlaneUsagePayload BuildUsagePayload(
        RequestMeteringService metering,
        int limit)
    {
        IReadOnlyList<RequestMeteringRecord> records = metering.Store.Recent(limit);
        int knownUsage = 0;
        int unknownUsage = 0;
        int knownCost = 0;
        int unknownCost = 0;
        var currencyCosts = new Dictionary<string, decimal>(StringComparer.Ordinal);

        foreach (RequestMeteringRecord record in records)
        {
            if (!HasUsage(record.Usage))
            {
                unknownUsage++;
            }
            else
            {
                knownUsage++;
            }

            if (HasCost(record.CostEstimate) is false
                || string.IsNullOrEmpty(record.CostEstimate!.Currency))
            {
                unknownCost++;
            }
            else
            {
                CostEstimate estimate = record.CostEstimate!;
                decimal total = estimate.TotalCost!.Value;
                knownCost++;
                currencyCosts.TryGetValue(estimate.Currency, out decimal current);
                currencyCosts[estimate.Currency] = current + total;
            }
        }

        var codes = new List<string>();
        if (metering.LastErrorCode is { } lastError)
        {
            codes.Add(lastError);
        }

        return new ControlPlaneUsagePayload
        {
            SchemaVersionValue = 1,
            Scope = ScopeBoundedRecent,
            BillingNote = BillingNote,
            RecordCount = records.Count,
            Capacity = metering.Store.Capacity,
            KnownUsageCount = knownUsage,
            UnknownUsageCount = unknownUsage,
            KnownCostCount = knownCost,
            UnknownCostCount = unknownCost,
            InputTokensTotal = DimensionTotal(records, static usage => usage.InputTokens),
            OutputTokensTotal = DimensionTotal(records, static usage => usage.OutputTokens),
            EstimatedCostByCurrency = currencyCosts
                .Select(pair => new CurrencyCostSummaryPayload
                {
                    Currency = pair.Key,
                    TotalCost = pair.Value,
                })
                .OrderBy(static entry => entry.Currency, StringComparer.Ordinal)
                .ToArray(),
            Degraded = codes.Count > 0,
            DegradationCodes = codes,
            Records = records.Select(ToMeteringRecord).ToArray(),
        };
    }

    public static async Task<ControlPlaneRecentRequestsPayload> BuildRecentRequestsPayloadAsync(
        DurableRequestLog requestLog,
        int limit,
        CancellationToken cancellationToken)
    {
        DurableRecentReadResult result = await requestLog
            .ReadRecentAsync(limit, cancellationToken)
            .ConfigureAwait(false);
        return new ControlPlaneRecentRequestsPayload
        {
            SchemaVersionValue = 1,
            Scope = ScopeRouterOwnedRecent,
            RecordCount = result.Records.Count,
            Degraded = result.Degraded,
            DegradationCodes = result.Codes,
            Records = result.Records,
        };
    }

    public static ControlPlaneMeteringRecordPayload ToMeteringRecord(RequestMeteringRecord record)
        => new()
        {
            RequestId = record.RequestId,
            TraceId = record.TraceId,
            ClientId = record.ClientId,
            ConfigGeneration = record.ConfigGeneration,
            ProviderId = record.ProviderId,
            RouteId = record.RouteId,
            ModelRouteId = record.ModelRouteId,
            ModelId = record.ModelId,
            UpstreamModelId = record.UpstreamModelId,
            Usage = ToUsage(record.Usage),
            CostEstimate = ToCost(record.CostEstimate),
            MeteringStatus = MeteringStatusWire(record.Status),
            Stream = record.Stream,
            CompletedAt = record.CompletedAt.ToString("O"),
            DurationMs = record.DurationMs,
        };

    public static UsageProjectionPayload? ToUsage(UsageRecord? usage)
    {
        if (usage is null || !HasUsage(usage))
        {
            return null;
        }

        return new UsageProjectionPayload
        {
            InputTokens = usage.InputTokens,
            OutputTokens = usage.OutputTokens,
            TotalTokens = usage.TotalTokens,
            CachedTokens = usage.CachedTokens,
            ReasoningTokens = usage.ReasoningTokens,
            Estimated = usage.Estimated,
            RecordedAt = usage.RecordedAt.ToString("O"),
        };
    }

    public static CostProjectionPayload? ToCost(CostEstimate? estimate)
    {
        if (estimate is null || estimate.TotalCost is null)
        {
            return null;
        }

        return new CostProjectionPayload
        {
            InputCost = estimate.InputCost,
            OutputCost = estimate.OutputCost,
            CachedCost = estimate.CachedCost,
            ReasoningCost = estimate.ReasoningCost,
            TotalCost = estimate.TotalCost,
            Currency = estimate.Currency,
            Status = CostStatusWire(estimate.Status),
            Estimated = estimate.Estimated,
            PricingSnapshotVersion = estimate.PricingSnapshotVersion,
        };
    }

    private static bool HasUsage(UsageRecord? usage)
        => usage is not null
            && (usage.InputTokens is not null
                || usage.OutputTokens is not null
                || usage.TotalTokens is not null
                || usage.CachedTokens is not null
                || usage.ReasoningTokens is not null);

    private static bool HasCost(CostEstimate? estimate)
        => estimate is { TotalCost: not null };

    /// <summary>
    /// Bounded-scope dimension total with strict null semantics: any record
    /// whose usage (or that token dimension) is unknown makes the total null,
    /// never zero.
    /// </summary>
    private static long? DimensionTotal(
        IReadOnlyList<RequestMeteringRecord> records,
        Func<UsageRecord, int?> selector)
    {
        bool anyKnown = false;
        long total = 0;
        foreach (RequestMeteringRecord record in records)
        {
            if (record.Usage is null || !HasUsage(record.Usage))
            {
                return null;
            }

            int? value = selector(record.Usage);
            if (value is null)
            {
                return null;
            }

            anyKnown = true;
            total += value.Value;
        }

        return anyKnown ? total : null;
    }

    public static ControlPlaneHealthSummaryPayload? BuildHealthSummary(IRouterHealthSnapshotSource? source)
    {
        if (source is null)
        {
            return new ControlPlaneHealthSummaryPayload
            {
                Available = false,
                ReasonCode = HealthNotComposedCode,
            };
        }

        RouteHealthProjection projection = source.Snapshot();
        int healthy = 0;
        int degraded = 0;
        int unhealthy = 0;
        int unknown = 0;
        foreach (RouteHealthProjectionEntry entry in projection.Routes)
        {
            switch (entry.State)
            {
                case Router.Registries.RouteHealthState.Healthy:
                    healthy++;
                    break;
                case Router.Registries.RouteHealthState.Degraded:
                    degraded++;
                    break;
                case Router.Registries.RouteHealthState.Unhealthy:
                    unhealthy++;
                    break;
                default:
                    unknown++;
                    break;
            }
        }

        return new ControlPlaneHealthSummaryPayload
        {
            Available = true,
            GeneratedAt = projection.GeneratedAt.ToString("O"),
            RouteCount = projection.Routes.Count,
            HealthyCount = healthy,
            DegradedCount = degraded,
            UnhealthyCount = unhealthy,
            UnknownCount = unknown,
        };
    }

    public static ControlPlaneCircuitBreakerProjectionPayload CircuitBreakerGap()
        => new()
        {
            EffectiveState = "disabled",
            MutationAvailable = false,
            ReasonCode = CircuitBreakerGapCode,
        };

    /// <summary>Safe observed-thread projection; only the external reference is exposed.</summary>
    public static ControlPlaneThreadEntryPayload ToThreadEntry(ThreadSelectionSnapshot snapshot)
        => new()
        {
            ThreadRef = snapshot.ThreadRef,
            ClientId = snapshot.ClientId,
            FirstSeen = snapshot.FirstSeen.ToString("O"),
            LastSeen = snapshot.LastSeen.ToString("O"),
            RequestKind = snapshot.LastRequestKind,
            WindowNumber = snapshot.WindowNumber,
            RequestedModel = snapshot.LastRequestedModel,
            SelectedModel = snapshot.LastSelectedModel,
            SelectionState = ThreadSelectionStateWire(snapshot.SelectionState),
            SelectionModel = snapshot.SelectionModel,
            SelectionGeneration = snapshot.SelectionGeneration,
            SelectionExpiresAt = snapshot.SelectionExpiresAt?.ToString("O"),
            LastFailureCode = snapshot.LastFailureCode,
            LastFailureAt = snapshot.LastFailureAt?.ToString("O"),
        };

    /// <summary>Safe single-thread selection projection.</summary>
    public static ControlPlaneThreadSelectionPayload ToThreadSelection(ThreadSelectionSnapshot snapshot)
        => new()
        {
            SchemaVersionValue = 1,
            ThreadRef = snapshot.ThreadRef,
            ClientId = snapshot.ClientId,
            SelectionState = ThreadSelectionStateWire(snapshot.SelectionState),
            SelectionModel = snapshot.SelectionModel,
            SelectionGeneration = snapshot.SelectionGeneration,
            SelectionIssuedAt = snapshot.SelectionIssuedAt?.ToString("O"),
            SelectionExpiresAt = snapshot.SelectionExpiresAt?.ToString("O"),
            RequestedModel = snapshot.LastRequestedModel,
            LastSelectedModel = snapshot.LastSelectedModel,
            LastFailureCode = snapshot.LastFailureCode,
            LastFailureAt = snapshot.LastFailureAt?.ToString("O"),
        };

    /// <summary>
    /// Safe capture projection. It never carries the capture owner or any model
    /// state: a capture window only discovers which thread a real turn belongs to.
    /// </summary>
    public static ControlPlaneThreadCapturePayload ToCapture(ThreadCaptureSnapshot capture)
        => new()
        {
            SchemaVersionValue = 1,
            CaptureToken = capture.Token,
            Status = ThreadCaptureStatusWire(capture.Status),
            CreatedAt = capture.CreatedAt.ToString("O"),
            ExpiresAt = capture.ExpiresAt.ToString("O"),
            ThreadRef = capture.ThreadRef,
            CapturedAt = capture.CapturedAt?.ToString("O"),
        };

    /// <summary>Stable wire name for a thread selection state.</summary>
    public static string ThreadSelectionStateWire(ThreadSelectionState state)
        => state switch
        {
            ThreadSelectionState.None => "none",
            ThreadSelectionState.Pending => "pending",
            ThreadSelectionState.Active => "active",
            ThreadSelectionState.Superseded => "superseded",
            ThreadSelectionState.Cleared => "cleared",
            ThreadSelectionState.Expired => "expired",
            _ => "unknown",
        };

    /// <summary>Stable wire name for a capture status.</summary>
    public static string ThreadCaptureStatusWire(ThreadCaptureStatus status)
        => status switch
        {
            ThreadCaptureStatus.Open => "open",
            ThreadCaptureStatus.Captured => "captured",
            ThreadCaptureStatus.Expired => "expired",
            ThreadCaptureStatus.Cancelled => "cancelled",
            _ => "unknown",
        };

    public static ControlPlanePolicyEntryPayload ToPolicyEntry(PolicyConfig policy)
    {
        bool retryConfigured = policy.RetryBody is not null;
        bool timeoutConfigured = policy.TimeoutBody is not null;
        bool failoverConfigured = policy.FailoverBody is not null;
        RetryPolicy effectiveRetry = retryConfigured ? FromRetryConfig(policy.RetryBody!) : RetryPolicy.Default;
        TimeoutPolicy effectiveTimeout = timeoutConfigured ? FromTimeoutConfig(policy.TimeoutBody!) : TimeoutPolicy.Default;
        FailoverPolicy effectiveFailover = failoverConfigured ? FromFailoverConfig(policy.FailoverBody!) : FailoverPolicy.Off;

        return new ControlPlanePolicyEntryPayload
        {
            PolicyId = policy.PolicyId,
            Version = policy.Version,
            ConfiguredRetry = policy.RetryBody is null ? null : ToRetryWire(policy.RetryBody),
            ConfiguredTimeout = policy.TimeoutBody is null ? null : ToTimeoutWire(policy.TimeoutBody),
            ConfiguredFailover = policy.FailoverBody is null ? null : ToFailoverWire(policy.FailoverBody),
            EffectiveRetry = ToRetryWire(effectiveRetry),
            EffectiveTimeout = ToTimeoutWire(effectiveTimeout),
            EffectiveFailover = ToFailoverWire(effectiveFailover),
            EffectiveRetrySource = retryConfigured ? "configured" : "safe_defaults",
            EffectiveTimeoutSource = timeoutConfigured ? "configured" : "safe_defaults",
            EffectiveFailoverSource = failoverConfigured ? "configured" : "safe_defaults",
        };
    }

    public static ControlPlanePolicyEntryPayload ToPolicyEntry(RouterConfig config, string policyId)
    {
        PolicyConfig? policy = config.Policies.FirstOrDefault(
            candidate => string.Equals(candidate.PolicyId, policyId, StringComparison.Ordinal));
        if (policy is null)
        {
            throw new InvalidOperationException("Applied policy must exist in the reloaded config.");
        }

        return ToPolicyEntry(policy);
    }

    public static PolicyRetryBodyConfig ToRetryConfig(ControlPlaneRetryBodyPayload payload)
        => new()
        {
            SchemaVersionValue = payload.SchemaVersionValue,
            MaxAttempts = payload.MaxAttempts,
            BaseDelayMs = payload.BaseDelayMs,
            MaxDelayMs = payload.MaxDelayMs,
            Jitter = payload.Jitter,
            RespectRetryAfter = payload.RespectRetryAfter,
            MaxRetryAfterMs = payload.MaxRetryAfterMs,
        };

    public static PolicyTimeoutBodyConfig ToTimeoutConfig(ControlPlaneTimeoutBodyPayload payload)
        => new()
        {
            SchemaVersionValue = payload.SchemaVersionValue,
            ConnectTimeoutMs = payload.ConnectTimeoutMs,
            FirstByteTimeoutMs = payload.FirstByteTimeoutMs,
            IdleTimeoutMs = payload.IdleTimeoutMs,
            AttemptTimeoutMs = payload.AttemptTimeoutMs,
            TotalTimeoutMs = payload.TotalTimeoutMs,
        };

    public static PolicyFailoverBodyConfig ToFailoverConfig(ControlPlaneFailoverBodyPayload payload)
        => new()
        {
            SchemaVersionValue = payload.SchemaVersionValue,
            AllowSameModelAlternateEndpoint = payload.AllowSameModelAlternateEndpoint,
            AllowSameModelAlternateProvider = payload.AllowSameModelAlternateProvider,
        };

    private static ControlPlaneRetryBodyPayload ToRetryWire(PolicyRetryBodyConfig body)
        => new()
        {
            SchemaVersionValue = body.SchemaVersionValue,
            MaxAttempts = body.MaxAttempts,
            BaseDelayMs = body.BaseDelayMs,
            MaxDelayMs = body.MaxDelayMs,
            Jitter = body.Jitter,
            RespectRetryAfter = body.RespectRetryAfter,
            MaxRetryAfterMs = body.MaxRetryAfterMs,
        };

    private static ControlPlaneTimeoutBodyPayload ToTimeoutWire(PolicyTimeoutBodyConfig body)
        => new()
        {
            SchemaVersionValue = body.SchemaVersionValue,
            ConnectTimeoutMs = body.ConnectTimeoutMs,
            FirstByteTimeoutMs = body.FirstByteTimeoutMs,
            IdleTimeoutMs = body.IdleTimeoutMs,
            AttemptTimeoutMs = body.AttemptTimeoutMs,
            TotalTimeoutMs = body.TotalTimeoutMs,
        };

    private static ControlPlaneFailoverBodyPayload ToFailoverWire(PolicyFailoverBodyConfig body)
        => new()
        {
            SchemaVersionValue = body.SchemaVersionValue,
            AllowSameModelAlternateEndpoint = body.AllowSameModelAlternateEndpoint,
            AllowSameModelAlternateProvider = body.AllowSameModelAlternateProvider,
        };

    private static ControlPlaneRetryBodyPayload ToRetryWire(RetryPolicy policy)
        => new()
        {
            SchemaVersionValue = 1,
            MaxAttempts = policy.MaxAttempts,
            BaseDelayMs = (long)policy.BaseDelay.TotalMilliseconds,
            MaxDelayMs = (long)policy.MaxDelay.TotalMilliseconds,
            Jitter = policy.Jitter,
            RespectRetryAfter = policy.RespectRetryAfter,
            MaxRetryAfterMs = (long)policy.MaxRetryAfter.TotalMilliseconds,
        };

    private static ControlPlaneTimeoutBodyPayload ToTimeoutWire(TimeoutPolicy policy)
        => new()
        {
            SchemaVersionValue = 1,
            ConnectTimeoutMs = (long)policy.ConnectTimeout.TotalMilliseconds,
            FirstByteTimeoutMs = (long)policy.FirstByteTimeout.TotalMilliseconds,
            IdleTimeoutMs = (long)policy.IdleTimeout.TotalMilliseconds,
            AttemptTimeoutMs = (long)policy.AttemptTimeout.TotalMilliseconds,
            TotalTimeoutMs = (long)policy.TotalTimeout.TotalMilliseconds,
        };

    private static ControlPlaneFailoverBodyPayload ToFailoverWire(FailoverPolicy policy)
        => new()
        {
            SchemaVersionValue = 1,
            AllowSameModelAlternateEndpoint = policy.AllowSameModelAlternateEndpoint,
            AllowSameModelAlternateProvider = policy.AllowSameModelAlternateProvider,
        };

    private static RetryPolicy FromRetryConfig(PolicyRetryBodyConfig body)
        => RetryPolicy.Create(
            body.MaxAttempts,
            TimeSpan.FromMilliseconds(body.BaseDelayMs),
            TimeSpan.FromMilliseconds(body.MaxDelayMs),
            body.Jitter,
            body.RespectRetryAfter,
            TimeSpan.FromMilliseconds(body.MaxRetryAfterMs));

    private static TimeoutPolicy FromTimeoutConfig(PolicyTimeoutBodyConfig body)
        => TimeoutPolicy.Create(
            TimeSpan.FromMilliseconds(body.ConnectTimeoutMs),
            TimeSpan.FromMilliseconds(body.FirstByteTimeoutMs),
            TimeSpan.FromMilliseconds(body.IdleTimeoutMs),
            TimeSpan.FromMilliseconds(body.AttemptTimeoutMs),
            TimeSpan.FromMilliseconds(body.TotalTimeoutMs));

    private static FailoverPolicy FromFailoverConfig(PolicyFailoverBodyConfig body)
        => FailoverPolicy.Create(
            body.AllowSameModelAlternateEndpoint,
            body.AllowSameModelAlternateProvider,
            allowCrossModelFallback: false);

    private static string MeteringStatusWire(RequestMeteringStatus status)
        => status switch
        {
            RequestMeteringStatus.Recorded => "recorded",
            RequestMeteringStatus.UsageMissing => "usage_missing",
            RequestMeteringStatus.IdentityUnavailable => "identity_unavailable",
            RequestMeteringStatus.MeteringDegraded => "metering_degraded",
            _ => "unknown",
        };

    private static string CostStatusWire(CostEstimateStatus status)
        => status switch
        {
            CostEstimateStatus.Complete => "complete",
            CostEstimateStatus.PartialUsage => "partial_usage",
            CostEstimateStatus.UnknownPrice => "unknown_price",
            CostEstimateStatus.StalePrice => "stale_price",
            CostEstimateStatus.UnsupportedCurrency => "unsupported_currency",
            CostEstimateStatus.Unavailable => "unavailable",
            _ => "unknown",
        };
}
