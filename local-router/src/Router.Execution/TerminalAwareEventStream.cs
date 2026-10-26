using System.Runtime.CompilerServices;
using System.Text.Json;
using Router.ClientAdapters.Responses;
using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;
using Router.ProviderAdapters.Responses;
using Router.ProtocolAdapters.Abstractions;
using Router.ProtocolAdapters.Responses;

namespace Router.Execution;

/// <summary>
/// Terminal-aware streaming boundary owned by the production execution
/// service. The provider event stream is only an in-flight attempt: success,
/// provider failure, cancellation, or protocol-mapping failure is committed
/// exactly once, and only when a real terminal outcome occurs (normal
/// completion, terminal provider event, unexpected EOF, idle/total stream
/// timeout, protocol mapping failure, cancellation, or abandonment). The
/// finalizer callback observes passive health, updates the circuit breaker,
/// and emits terminal execution metadata; the once-only guard prevents
/// duplicate observations. Retries and failover are structurally impossible
/// here because this wrapper runs after the attempt/retry/failover loop has
/// already returned the stream to the caller.
/// </summary>
internal sealed class TerminalAwareEventStream : IAsyncEnumerable<CanonicalEvent>
{
    private readonly IResponsesProtocolAdapter _adapter;
    private readonly IAsyncEnumerable<CanonicalEvent> _providerEvents;
    private readonly Action<AttemptOutcome, RouterError?, DateTimeOffset> _finalize;
    private readonly string _requestId;
    private readonly Func<DateTimeOffset> _now;
    private readonly CancellationToken _token;
    private readonly Once _finalized = new();

    public TerminalAwareEventStream(
        IResponsesProtocolAdapter adapter,
        IAsyncEnumerable<CanonicalEvent> providerEvents,
        Action<AttemptOutcome, RouterError?, DateTimeOffset> finalize,
        string requestId,
        Func<DateTimeOffset> now,
        CancellationToken token)
    {
        _adapter = adapter ?? throw new ArgumentNullException(nameof(adapter));
        _providerEvents = providerEvents ?? throw new ArgumentNullException(nameof(providerEvents));
        _finalize = finalize ?? throw new ArgumentNullException(nameof(finalize));
        _requestId = requestId;
        _now = now ?? throw new ArgumentNullException(nameof(now));
        _token = token;
    }

    internal bool Finalized => _finalized.IsDone;

    public IAsyncEnumerator<CanonicalEvent> GetAsyncEnumerator(CancellationToken cancellationToken = default)
    {
        CancellationTokenSource? linked = null;
        CancellationToken effective = cancellationToken;
        if (_token.CanBeCanceled && cancellationToken.CanBeCanceled && _token != cancellationToken)
        {
            linked = CancellationTokenSource.CreateLinkedTokenSource(_token, cancellationToken);
            effective = linked.Token;
        }
        else if (_token.CanBeCanceled && !cancellationToken.CanBeCanceled)
        {
            effective = _token;
        }

        return new Enumerator(this, linked, effective);
    }

    private sealed class Enumerator : IAsyncEnumerator<CanonicalEvent>
    {
        private readonly TerminalAwareEventStream _owner;
        private readonly CancellationTokenSource? _linked;
        private ConfiguredCancelableAsyncEnumerable<CanonicalEvent>.Enumerator _inner;
        private CanonicalEvent? _current;
        private bool _sawTerminal;

        public Enumerator(
            TerminalAwareEventStream owner,
            CancellationTokenSource? linked,
            CancellationToken effectiveToken)
        {
            _owner = owner;
            _linked = linked;
            _inner = owner._providerEvents.WithCancellation(effectiveToken).GetAsyncEnumerator();
        }

        /// <summary>
        /// The protocol-adapter-mapped canonical event for the current
        /// position. Consumers always observe the mapped event, never the raw
        /// inner provider event.
        /// </summary>
        public CanonicalEvent Current => _current ?? throw new InvalidOperationException("Enumeration has not started or has finished.");

        public async ValueTask<bool> MoveNextAsync()
        {
            try
            {
                bool moved = await _inner.MoveNextAsync();
                if (!moved)
                {
                    // A clean EOF after no terminal event is an interrupted
                    // stream. Responses-compatible provider adapters already
                    // throw for this; the guard keeps the invariant for any
                    // other upstream shape.
                    if (!_sawTerminal)
                    {
                        FinalizeOnce(
                            AttemptOutcome.Failed,
                            ProviderAdapterErrors.StreamInterrupted(_owner._requestId));
                    }

                    return false;
                }

                ProtocolAdapters.Abstractions.Result<CanonicalEvent, RouterError> mapped = _owner._adapter.MapEvent(_inner.Current);
                if (mapped.Error is not null || mapped.Value is null)
                {
                    FinalizeOnce(
                        AttemptOutcome.Failed,
                        mapped.Error ?? RouterError.SemanticLoss(null, _owner._requestId));
                    throw new ProtocolEventMappingException();
                }

                CanonicalEvent canonical = mapped.Value;
                _current = canonical;
                if (canonical.IsTerminal)
                {
                    _sawTerminal = true;
                    if (string.Equals(canonical.Type, CanonicalEventVocabulary.ResponseCompleted, StringComparison.Ordinal))
                    {
                        FinalizeOnce(AttemptOutcome.Succeeded, error: null);
                    }
                    else
                    {
                        FinalizeOnce(AttemptOutcome.Failed, TerminalStreamError(canonical));
                    }
                }

                return true;
            }
            catch (OperationCanceledException) when (!_owner.Finalized)
            {
                FinalizeOnce(
                    AttemptOutcome.Cancelled,
                    RouterError.Cancelled(_owner._requestId));
                throw;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (StreamInterruptedException) when (!_owner.Finalized)
            {
                FinalizeOnce(
                    AttemptOutcome.Failed,
                    ProviderAdapterErrors.StreamInterrupted(_owner._requestId));
                throw;
            }
            catch (StreamTimeoutException exception) when (!_owner.Finalized)
            {
                RouterError timeoutError = exception.Stage == StreamTimeoutStage.Total
                    ? ProviderAdapterErrors.TimeoutTotal(_owner._requestId)
                    : ProviderAdapterErrors.TimeoutIdle(_owner._requestId);
                FinalizeOnce(AttemptOutcome.Failed, timeoutError);
                throw;
            }
            catch (Exception) when (!_owner.Finalized)
            {
                FinalizeOnce(
                    AttemptOutcome.Failed,
                    RouterError.InternalError(_owner._requestId));
                throw;
            }
        }

        public async ValueTask DisposeAsync()
        {
            // Abandoning a stream that never reached a terminal outcome is a
            // cancelled execution, never a provider failure.
            FinalizeOnce(
                AttemptOutcome.Cancelled,
                RouterError.Cancelled(_owner._requestId));
            await _inner.DisposeAsync();
            _linked?.Dispose();
        }

        private void FinalizeOnce(AttemptOutcome outcome, RouterError? error)
        {
            if (_owner._finalized.TryMark())
            {
                _owner._finalize(outcome, error, _owner._now());
            }
        }

        private RouterError TerminalStreamError(CanonicalEvent terminalEvent)
        {
            string code = "provider_error";
            if (terminalEvent.Data.ValueKind == JsonValueKind.Object
                && terminalEvent.Data.TryGetProperty("code", out JsonElement codeElement)
                && codeElement.ValueKind == JsonValueKind.String)
            {
                string? candidate = codeElement.GetString();
                if (!string.IsNullOrWhiteSpace(candidate))
                {
                    code = candidate;
                }
            }

            return RouterError.Create(code, "The provider stream failed.", null, _owner._requestId);
        }
    }

    /// <summary>Thread-safe once-only state for one streamed execution.</summary>
    private sealed class Once
    {
        private int _done;

        public bool IsDone => Volatile.Read(ref _done) == 1;

        public bool TryMark() => Interlocked.CompareExchange(ref _done, 1, 0) == 0;
    }
}
