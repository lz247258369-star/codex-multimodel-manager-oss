using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Router.ClientAdapters.Responses;
using Router.Core.Cancellation;
using Router.Core.Context;
using Router.Core.Errors;
using Router.Core.Lifecycle;
using Router.Core.Support;

namespace Router.Ingress.Handlers;

/// <summary>
/// POST /v1/responses handler: authenticates the responses:invoke scope,
/// enforces content/body limits before parsing, parses the canonical request,
/// invokes the fake-only response service, and writes JSON or SSE.
/// </summary>
public static class ResponsesHandler
{
    public const string RequiredScope = "responses:invoke";
    public const int MaxIdempotencyKeyLength = 255;

    public static async Task HandleAsync(HttpContext context)
    {
        IngressServices services = context.RequestServices.GetRequiredService<IngressServices>();
        DateTimeOffset receivedAt = services.Clock.UtcNow;
        string requestId = RequestPipeline.RequestIdValue(context);
        RequestStateMachine machine = new();

        if (!services.ScopeRegistry.TryResolve(RequiredScope, out string clientId))
        {
            await DenyAsync(context, services, clientId, RouterError.ScopeDenied(requestId), receivedAt).ConfigureAwait(false);
            return;
        }

        if (!IsJsonContentType(context.Request.ContentType))
        {
            RouterError error = RouterError.InvalidRequest("Content-Type must be application/json.", "content_type", requestId);
            await FailAsync(context, services, clientId, error, receivedAt).ConfigureAwait(false);
            return;
        }

        string? idempotencyKeyHash = null;
        string? rawIdempotencyKey = context.Request.Headers["Idempotency-Key"];
        if (!string.IsNullOrEmpty(rawIdempotencyKey))
        {
            if (rawIdempotencyKey.Length > MaxIdempotencyKeyLength)
            {
                RouterError error = RouterError.InvalidRequest("Idempotency-Key exceeds the maximum length.", "idempotency_key", requestId);
                await FailAsync(context, services, clientId, error, receivedAt, idempotencyKeyHash: null).ConfigureAwait(false);
                return;
            }

            idempotencyKeyHash = SafeHasher.Sha256Hex(rawIdempotencyKey);
        }

        int maxBytes = Math.Min(services.Options.Limits.MaxRequestBytes, Router.Configuration.ConfigLimitCeilings.MaxRequestBytesCeiling);
        byte[] body;
        try
        {
            body = await ReadBodyAsync(context.Request.Body, maxBytes, context.RequestAborted).ConfigureAwait(false);
        }
        catch (RequestTooLargeException)
        {
            RouterError error = RouterError.RequestTooLarge(requestId);
            await FailAsync(context, services, clientId, error, receivedAt, idempotencyKeyHash).ConfigureAwait(false);
            return;
        }
        catch (OperationCanceledException)
        {
            await CancelAsync(context, services, clientId, receivedAt, idempotencyKeyHash, stream: false).ConfigureAwait(false);
            return;
        }

        string json = Encoding.UTF8.GetString(body);
        RouterError? parseError = ResponsesRequestParser.TryParse(json, out CanonicalResponsesRequest? canonical, requestId);
        if (parseError is not null)
        {
            await FailAsync(context, services, clientId, parseError, receivedAt, idempotencyKeyHash).ConfigureAwait(false);
            return;
        }

        CanonicalResponsesRequest parsedRequest = canonical!;

        using CancellationTokenSource deadlineCts = new();
        if (services.Options.RequestTimeout is { } timeout)
        {
            deadlineCts.CancelAfter(timeout);
        }

        using CancellationCoordinator coordinator = new(context.RequestAborted, services.ShutdownCts.Token, deadlineCts.Token);
        CancellationToken cancellationToken = coordinator.Token;
        RequestContext requestContext = RequestPipeline.CreateContext(
            context,
            services,
            clientId,
            RequiredScope,
            idempotencyKeyHash,
            receivedAt,
            cancellationToken);

        machine.TryAdvance(RequestState.Received, RequestState.UpstreamPending);
        DateTimeOffset executionStartedAt = services.Clock.UtcNow;
        OutputCheckpoint checkpoint = new();
        TimeSpan? ttft = null;

        ResponsesServiceResult result;
        try
        {
            result = await services.Service.InvokeAsync(parsedRequest, requestContext, cancellationToken).ConfigureAwait(false);
            result.Validate();
        }
        catch (OperationCanceledException)
        {
            machine.TryCancel();
            RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Cancelled, 0, RouterErrorCode.Cancelled, idempotencyKeyHash, null, receivedAt, parsedRequest.Stream));
            return;
        }
        catch (Exception)
        {
            RouterError error = RouterError.InternalError(requestId);
            machine.TryFail();
            await FailAsync(context, services, clientId, error, receivedAt, idempotencyKeyHash).ConfigureAwait(false);
            return;
        }

        if (result.Error is not null)
        {
            if (string.Equals(result.Error.Code, RouterErrorCode.Cancelled, StringComparison.Ordinal))
            {
                machine.TryCancel();
                RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Cancelled, 0, RouterErrorCode.Cancelled, idempotencyKeyHash, null, receivedAt, parsedRequest.Stream));
                return;
            }

            machine.TryFail();
            await FailAsync(context, services, clientId, result.Error, receivedAt, idempotencyKeyHash).ConfigureAwait(false);
            return;
        }

        if (parsedRequest.Stream)
        {
            if (result.EventStream is null)
            {
                RouterError error = RouterError.InternalError(requestId);
                machine.TryFail();
                await FailAsync(context, services, clientId, error, receivedAt, idempotencyKeyHash).ConfigureAwait(false);
                return;
            }

            await WriteStreamAsync(
                context,
                services,
                result.EventStream,
                result.Execution,
                machine,
                checkpoint,
                executionStartedAt,
                ttft,
                receivedAt,
                clientId,
                idempotencyKeyHash,
                parsedRequest,
                cancellationToken).ConfigureAwait(false);
            return;
        }

        if (result.Response is null)
        {
            RouterError error = RouterError.InternalError(requestId);
            machine.TryFail();
            await FailAsync(context, services, clientId, error, receivedAt, idempotencyKeyHash).ConfigureAwait(false);
            return;
        }

        if (checkpoint.TryMarkOutputStarted())
        {
            ttft = services.Clock.UtcNow - executionStartedAt;
        }

        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.ContentType = "application/json";
        await context.Response
            .WriteAsync(JsonSerializer.Serialize(result.Response, ResponsesJson.Options), cancellationToken)
            .ConfigureAwait(false);

        machine.TryComplete();
        RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Completed, StatusCodes.Status200OK, null, idempotencyKeyHash, ttft, receivedAt, stream: false));
        await RecordUsageCompletionAsync(
            context,
            services,
            clientId,
            parsedRequest,
            result.Response?.Usage,
            result.Execution,
            receivedAt,
            stream: false).ConfigureAwait(false);
    }

    private static async Task WriteStreamAsync(
        HttpContext context,
        IngressServices services,
        IAsyncEnumerable<CanonicalEvent> events,
        ResponsesExecutionMetadata? execution,
        RequestStateMachine machine,
        OutputCheckpoint checkpoint,
        DateTimeOffset executionStartedAt,
        TimeSpan? ttft,
        DateTimeOffset receivedAt,
        string clientId,
        string? idempotencyKeyHash,
        CanonicalResponsesRequest request,
        CancellationToken cancellationToken)
    {
        string requestId = RequestPipeline.RequestIdValue(context);
        context.Response.StatusCode = StatusCodes.Status200OK;
        context.Response.ContentType = "text/event-stream";
        context.Response.Headers.CacheControl = "no-cache";

        int terminalWritten = 0;
        bool completedTerminal = false;
        Router.ClientAdapters.Responses.UsageRecord? terminalUsage = null;
        try
        {
            await foreach (CanonicalEvent evt in events.WithCancellation(cancellationToken).ConfigureAwait(false))
            {
                if (SseWriter.IsTerminalEvent(evt) && Interlocked.Exchange(ref terminalWritten, 1) == 1)
                {
                    // A terminal event is emitted at most once; stop consuming.
                    break;
                }

                if (string.Equals(evt.Type, "response.completed", StringComparison.Ordinal))
                {
                    completedTerminal = true;
                    terminalUsage = TryReadTerminalUsage(evt.Data);
                }

                if (checkpoint.TryMarkOutputStarted())
                {
                    ttft = services.Clock.UtcNow - executionStartedAt;
                    machine.TryAdvance(RequestState.UpstreamPending, RequestState.Streaming);
                }

                await SseWriter.WriteEventAsync(context.Response.Body, evt, cancellationToken).ConfigureAwait(false);
            }

            if (cancellationToken.IsCancellationRequested)
            {
                machine.TryCancel();
                RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Cancelled, 0, RouterErrorCode.Cancelled, idempotencyKeyHash, ttft, receivedAt, stream: true));
                return;
            }

            machine.TryComplete();
            RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Completed, StatusCodes.Status200OK, null, idempotencyKeyHash, ttft, receivedAt, stream: true));
            if (completedTerminal)
            {
                await RecordUsageCompletionAsync(
                    context,
                    services,
                    clientId,
                    request,
                    terminalUsage,
                    execution,
                    receivedAt,
                    stream: true).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            machine.TryCancel();
            RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Cancelled, 0, RouterErrorCode.Cancelled, idempotencyKeyHash, ttft, receivedAt, stream: true));
        }
        catch (Exception)
        {
            machine.TryFail();
            if (Volatile.Read(ref terminalWritten) == 0)
            {
                try
                {
                    RouterError safeError = RouterError.InternalError(requestId);
                    await SseWriter.WriteErrorEventAsync(context.Response.Body, safeError, CancellationToken.None).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // Client is gone; nothing else can be written.
                }
            }

            RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Failed, 200, RouterErrorCode.InternalError, idempotencyKeyHash, ttft, receivedAt, stream: true));
        }
    }

    private static async Task DenyAsync(HttpContext context, IngressServices services, string clientId, RouterError error, DateTimeOffset receivedAt)
    {
        await ErrorEnvelopeWriter
            .WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted)
            .ConfigureAwait(false);
        RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Failed, HttpStatusMapper.ToStatusCode(error), error.Code, null, null, receivedAt, stream: false));
    }

    private static async Task FailAsync(
        HttpContext context,
        IngressServices services,
        string clientId,
        RouterError error,
        DateTimeOffset receivedAt,
        string? idempotencyKeyHash = null)
    {
        await ErrorEnvelopeWriter
            .WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted)
            .ConfigureAwait(false);
        // DSR7-C-FIX2: only the failure path carries the safe capability field
        // path. Deny/cancel/success paths never synthesize one.
        RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Failed, HttpStatusMapper.ToStatusCode(error), error.Code, idempotencyKeyHash, null, receivedAt, stream: false, errorParam: error.Param, errorDiagnosticClass: error.SafeDiagnosticClass, errorDiagnosticIdentity: error.SafeDiagnosticIdentity));
    }

    private static async Task CancelAsync(
        HttpContext context,
        IngressServices services,
        string clientId,
        DateTimeOffset receivedAt,
        string? idempotencyKeyHash,
        bool stream)
    {
        RequestPipeline.Record(services, RequestPipeline.Result(context, services, clientId, RequiredScope, RequestState.Cancelled, 0, RouterErrorCode.Cancelled, idempotencyKeyHash, null, receivedAt, stream));
        await Task.CompletedTask.ConfigureAwait(false);
    }

    private static async Task<byte[]> ReadBodyAsync(Stream body, int maxBytes, CancellationToken cancellationToken)
    {
        using MemoryStream buffer = new();
        byte[] chunk = new byte[81_920];
        int total = 0;
        while (true)
        {
            int read = await body.ReadAsync(chunk.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            total += read;
            if (total > maxBytes)
            {
                throw new RequestTooLargeException();
            }

            await buffer.WriteAsync(chunk.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
        }

        return buffer.ToArray();
    }

    private static async Task RecordUsageCompletionAsync(
        HttpContext context,
        IngressServices services,
        string clientId,
        CanonicalResponsesRequest request,
        Router.ClientAdapters.Responses.UsageRecord? usage,
        ResponsesExecutionMetadata? execution,
        DateTimeOffset receivedAt,
        bool stream)
    {
        if (services.Observer is null)
        {
            return;
        }

        // Authoritative identity is carried by the execution result. Ingress
        // never looks up configuration, model names, or provider brands; when
        // the execution result carries no metadata the identity stays null so
        // metering records IdentityUnavailable instead of guessing.
        RequestUsageIdentity? identity = ToIdentity(execution);
        DateTimeOffset completedAt = services.Clock.UtcNow;
        long durationMs = (long)Math.Round((completedAt - receivedAt).TotalMilliseconds, MidpointRounding.AwayFromZero);
        RequestUsageCompletion completion = new()
        {
            RequestId = RequestPipeline.RequestIdValue(context),
            TraceId = RequestPipeline.TraceIdValue(context),
            ClientId = clientId,
            ConfigGeneration = services.Options.ConfigGeneration,
            ModelId = request.Model,
            Identity = identity,
            Usage = usage,
            Stream = stream,
            CompletedAt = completedAt,
            DurationMs = durationMs,
        };

        // Metering is an informational subsystem: it is recorded after the
        // response has been flushed. The observer enqueues into a bounded
        // completion queue and returns immediately; no per-request background
        // task is created and disk I/O never happens on this path.
        try
        {
            await services.Observer
                .OnUsageCompletedAsync(completion, CancellationToken.None)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Client cancellation after terminal output; no usage can be trusted.
        }
        catch (Exception)
        {
            // Degraded metering only; response semantics stay successful.
        }
    }

    private static RequestUsageIdentity? ToIdentity(ResponsesExecutionMetadata? execution)
    {
        if (execution is null)
        {
            return null;
        }

        return new RequestUsageIdentity
        {
            ProviderId = execution.ProviderId,
            RouteId = execution.RouteId,
            ModelRouteId = execution.ModelRouteId,
            CatalogModelId = execution.CatalogModelId,
            UpstreamModelId = execution.UpstreamModelId,
        };
    }

    private static Router.ClientAdapters.Responses.UsageRecord? TryReadTerminalUsage(JsonElement data)
    {
        if (data.ValueKind != JsonValueKind.Object
            || !data.TryGetProperty("response", out JsonElement response)
            || response.ValueKind != JsonValueKind.Object
            || !response.TryGetProperty("usage", out JsonElement usage))
        {
            return null;
        }

        try
        {
            return JsonSerializer.Deserialize<Router.ClientAdapters.Responses.UsageRecord>(
                usage.GetRawText(),
                ResponsesJson.Options);
        }
        catch (JsonException)
        {
            return null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static bool IsJsonContentType(string? contentType)
        => !string.IsNullOrEmpty(contentType)
            && (string.Equals(contentType, "application/json", StringComparison.OrdinalIgnoreCase)
                || contentType.StartsWith("application/json;", StringComparison.OrdinalIgnoreCase));
}
