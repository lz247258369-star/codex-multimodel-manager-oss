namespace Router.Core.Cancellation;

/// <summary>
/// Links caller, deadline, and shutdown cancellation sources into one token.
/// Cancellation is idempotent; <see cref="TryCancel"/> commits the terminal
/// cancellation exactly once (compare-and-set) so a late completion/failure can
/// win the race instead.
/// </summary>
public sealed class CancellationCoordinator : IDisposable
{
    private readonly CancellationTokenSource _linked = new();
    private readonly List<CancellationTokenRegistration> _registrations = [];
    private int _cancelCommitted;

    /// <summary>Links any number of existing cancellation sources.</summary>
    public CancellationCoordinator(params CancellationToken[] sources)
    {
        foreach (CancellationToken source in sources)
        {
            if (source.CanBeCanceled)
            {
                _registrations.Add(source.Register(static state => ((CancellationTokenSource)state!).Cancel(), _linked));
            }
        }
    }

    /// <summary>Creates a coordinator linked to caller and shutdown tokens.</summary>
    public static CancellationCoordinator FromCallerAndShutdown(CancellationToken caller, CancellationToken shutdown)
        => new(caller, shutdown);

    /// <summary>Gets the linked cancellation token for downstream propagation.</summary>
    public CancellationToken Token => _linked.Token;

    /// <summary>True when any linked source requested cancellation.</summary>
    public bool IsCancellationRequested => _linked.IsCancellationRequested;

    /// <summary>True when this coordinator won and committed the terminal cancel.</summary>
    public bool IsCancelCommitted => Volatile.Read(ref _cancelCommitted) == 1;

    /// <summary>Requests cancellation idempotently; returns false on double cancel.</summary>
    public bool TryCancel()
    {
        if (Interlocked.Exchange(ref _cancelCommitted, 1) == 1)
        {
            return false;
        }

        _linked.Cancel();
        return true;
    }

    /// <summary>Requests cancellation. Safe to call any number of times.</summary>
    public void Cancel() => _linked.Cancel();

    /// <inheritdoc />
    public void Dispose()
    {
        foreach (CancellationTokenRegistration registration in _registrations)
        {
            registration.Dispose();
        }

        _registrations.Clear();
        _linked.Dispose();
        GC.SuppressFinalize(this);
    }
}
