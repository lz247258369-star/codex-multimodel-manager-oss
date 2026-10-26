namespace Router.Metering;

/// <summary>
/// Production metering recorder. One normalized usage record plus an
/// informational cost estimate per completed logical request. Missing usage is
/// never guessed; unknown prices never become zero; failures degrade to a safe
/// status and never throw into the successful response path.
/// </summary>
public sealed class RequestMeteringService
{
    private readonly RequestMeteringStore _store;
    private readonly PricingSnapshot? _pricing;
    private readonly object _sync = new();

    public RequestMeteringService(
        RequestMeteringStore? store = null,
        PricingSnapshot? pricing = null)
    {
        _store = store ?? new RequestMeteringStore();
        _pricing = pricing;
    }

    public RequestMeteringStore Store => _store;

    /// <summary>Pricing snapshot backing default production estimates, when loaded.</summary>
    public PricingSnapshot? Pricing => _pricing;

    public string? LastErrorCode
    {
        get
        {
            lock (_sync)
            {
                return _lastErrorCode;
            }
        }
    }

    private string? _lastErrorCode;

    public RequestMeteringRecord Record(RequestMeteringInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        try
        {
            if (string.IsNullOrWhiteSpace(input.ProviderId)
                || string.IsNullOrWhiteSpace(input.CatalogModelId))
            {
                RequestMeteringRecord unavailable = BuildRecord(input, null, null, RequestMeteringStatus.IdentityUnavailable);
                _store.Add(unavailable);
                return unavailable;
            }

            UsageRecord usage = UsageNormalizer.Normalize(
                input.Usage,
                input.RequestId,
                input.ProviderId,
                input.CatalogModelId,
                input.CompletedAt);

            CostEstimate? estimate = null;
            if (_pricing is not null)
            {
                estimate = CostEstimator.Estimate(
                    usage,
                    _pricing,
                    input.ProviderId,
                    input.CatalogModelId,
                    input.CompletedAt);
            }

            RequestMeteringStatus status = usage.InputTokens is null
                && usage.OutputTokens is null
                && usage.TotalTokens is null
                && usage.CachedTokens is null
                && usage.ReasoningTokens is null
                    ? RequestMeteringStatus.UsageMissing
                    : RequestMeteringStatus.Recorded;

            RequestMeteringRecord record = BuildRecord(input, usage, estimate, status);
            _store.Add(record);
            return record;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            SetLastError("metering_record_failed");
            RequestMeteringRecord degraded = BuildRecord(input, null, null, RequestMeteringStatus.MeteringDegraded);
            _store.Add(degraded);
            return degraded;
        }
    }

    private static RequestMeteringRecord BuildRecord(
        RequestMeteringInput input,
        UsageRecord? usage,
        CostEstimate? estimate,
        RequestMeteringStatus status)
        => RequestMeteringRecord.Create(
            input.RequestId,
            input.TraceId,
            input.ClientId,
            input.ConfigGeneration,
            input.ProviderId,
            input.RouteId,
            input.ModelRouteId,
            input.CatalogModelId,
            input.UpstreamModelId,
            usage,
            estimate,
            status,
            input.Stream,
            input.CompletedAt,
            input.DurationMs);

    private void SetLastError(string code)
    {
        lock (_sync)
        {
            _lastErrorCode = code;
        }
    }
}
