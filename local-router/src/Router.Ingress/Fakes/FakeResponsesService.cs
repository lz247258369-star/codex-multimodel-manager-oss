using System.Runtime.CompilerServices;
using Router.ClientAdapters.Responses;
using Router.Core.Abstractions;
using Router.Core.Context;
using Router.Core.Errors;
using Router.Core.Ids;

namespace Router.Ingress.Fakes;

/// <summary>
/// Synthetic, in-process response service. It never touches a real provider,
/// reads no secrets, and makes no network calls. It is never constructed by
/// Router.Host production source; tests inject it explicitly.
/// </summary>
public sealed class FakeResponsesService : IResponsesService
{
    private readonly object _sync = new();
    private readonly List<(CanonicalResponsesRequest Request, RequestContext Context)> _calls = [];
    private readonly IClock _clock;
    private readonly IIdGenerator _idGenerator;
    private TimeSpan _delayBeforeFirstOutput;
    private bool _fragmented;
    private Func<CanonicalResponsesRequest, RequestContext, CancellationToken, Task<ResponsesServiceResult>> _handler;

    public FakeResponsesService(IClock? clock = null, IIdGenerator? idGenerator = null)
    {
        _clock = clock ?? new SystemClock();
        _idGenerator = idGenerator ?? new UuidV7IdGenerator(_clock);
        _handler = DefaultHandlerAsync;
    }

    /// <summary>All recorded calls (request + context), in order.</summary>
    public IReadOnlyList<(CanonicalResponsesRequest Request, RequestContext Context)> Calls
    {
        get
        {
            lock (_sync)
            {
                return _calls.ToArray();
            }
        }
    }

    public FakeResponsesService UseHandler(Func<CanonicalResponsesRequest, RequestContext, CancellationToken, Task<ResponsesServiceResult>> handler)
    {
        ArgumentNullException.ThrowIfNull(handler);
        lock (_sync)
        {
            _handler = handler;
        }

        return this;
    }

    public FakeResponsesService WithDelay(TimeSpan delay)
    {
        lock (_sync)
        {
            _delayBeforeFirstOutput = delay;
        }

        return this;
    }

    public FakeResponsesService WithFragmented(bool fragmented)
    {
        lock (_sync)
        {
            _fragmented = fragmented;
        }

        return this;
    }

    public FakeResponsesService WithError(RouterError error)
        => UseHandler((_, _, _) => Task.FromResult(ResponsesServiceResult.Failure(error)));

    public FakeResponsesService WithException(Exception exception)
        => UseHandler((_, _, _) => Task.FromException<ResponsesServiceResult>(exception));

    public async Task<ResponsesServiceResult> InvokeAsync(CanonicalResponsesRequest request, RequestContext context, CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            _calls.Add((request, context));
        }

        TimeSpan delay;
        Func<CanonicalResponsesRequest, RequestContext, CancellationToken, Task<ResponsesServiceResult>> handler;
        lock (_sync)
        {
            delay = _delayBeforeFirstOutput;
            handler = _handler;
        }

        if (delay > TimeSpan.Zero)
        {
            await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
        }

        return await handler(request, context, cancellationToken).ConfigureAwait(false);
    }

    private Task<ResponsesServiceResult> DefaultHandlerAsync(CanonicalResponsesRequest request, RequestContext context, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (request.Stream)
        {
            bool fragmented;
            lock (_sync)
            {
                fragmented = _fragmented;
            }

            CanonicalResponsesResponse response = BuildEchoResponse(request);
            IReadOnlyList<CanonicalEvent> events = BuildStandardStream(request, response);
            return Task.FromResult(ResponsesServiceResult.Stream(EnumerateEventsAsync(events, fragmented, cancellationToken)));
        }

        return Task.FromResult(ResponsesServiceResult.NonStream(BuildEchoResponse(request)));
    }

    private static async IAsyncEnumerable<CanonicalEvent> EnumerateEventsAsync(
        IReadOnlyList<CanonicalEvent> events,
        bool fragmented,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        foreach (CanonicalEvent evt in events)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (fragmented)
            {
                await Task.Delay(1, cancellationToken).ConfigureAwait(false);
            }

            yield return evt;
        }
    }

    private CanonicalResponsesResponse BuildEchoResponse(CanonicalResponsesRequest request)
    {
        string text = "Synthetic response for model '" + request.Model + "'.";
        return new CanonicalResponsesResponse
        {
            Id = ResponseId.FromUuid(_idGenerator.NewRequestId().Uuid.Value).Value,
            ObjectType = "response",
            CreatedAt = _clock.UtcNow.ToUnixTimeSeconds(),
            Status = "completed",
            Model = request.Model,
            Output =
            [
                new MessageOutputItem
                {
                    Type = "message",
                    Id = "msg_" + _idGenerator.NewRequestId().Uuid.Value,
                    Role = "assistant",
                    Content =
                    [
                        new OutputTextPart { Type = "output_text", Text = text, Annotations = [] },
                    ],
                },
            ],
            Usage = new UsageRecord
            {
                InputTokens = 7,
                OutputTokens = 5,
                TotalTokens = 12,
            },
        };
    }

    private static IReadOnlyList<CanonicalEvent> BuildStandardStream(CanonicalResponsesRequest request, CanonicalResponsesResponse response)
    {
        string text = "Synthetic response for model '" + request.Model + "'.";
        string itemId = "msg_" + response.Id["resp_".Length..];

        return
        [
            CanonicalEvent.Create("response.created", new { type = "response.created", response = ResponseShape(response, "in_progress") }),
            CanonicalEvent.Create("response.output_item.added", new
            {
                type = "response.output_item.added",
                output_index = 0,
                item = new { id = itemId, type = "message", role = "assistant", content = Array.Empty<object>() },
            }),
            CanonicalEvent.Create("response.output_text.delta", new
            {
                type = "response.output_text.delta",
                item_id = itemId,
                output_index = 0,
                content_index = 0,
                delta = text,
            }),
            CanonicalEvent.Create("response.output_text.done", new
            {
                type = "response.output_text.done",
                item_id = itemId,
                output_index = 0,
                content_index = 0,
                text,
            }),
            CanonicalEvent.Create("response.output_item.done", new
            {
                type = "response.output_item.done",
                output_index = 0,
                item = new
                {
                    id = itemId,
                    type = "message",
                    role = "assistant",
                    content = new object[]
                    {
                        new { type = "output_text", text, annotations = Array.Empty<object>() },
                    },
                },
            }),
            CanonicalEvent.Create("response.completed", new { type = "response.completed", response = ResponseShape(response, "completed") }),
        ];
    }

    private static object ResponseShape(CanonicalResponsesResponse response, string status) => new
    {
        id = response.Id,
        @object = "response",
        created_at = response.CreatedAt,
        status,
        model = response.Model,
        output = response.Output,
        usage = response.Usage,
    };
}
