namespace Router.State.Ownership;

/// <summary>Ownership verdict for an owner record.</summary>
public enum OwnershipStatus
{
    Missing = 0,
    LiveOwner = 1,
    StaleOwner = 2,
    ForeignProcess = 3,
}

/// <summary>
/// Verifies ownership using PID + process start identity + fingerprint. PID
/// reuse or fingerprint mismatch is a foreign-process conflict; a missing
/// process is stale. Never kills or mutates any process.
/// </summary>
public sealed class OwnershipVerifier
{
    private readonly IProcessInspector _inspector;

    public OwnershipVerifier(IProcessInspector inspector)
    {
        _inspector = inspector ?? throw new ArgumentNullException(nameof(inspector));
    }

    public OwnershipStatus Verify(OwnerRecord? record)
    {
        if (record is null)
        {
            return OwnershipStatus.Missing;
        }

        ProcessInfo? process = _inspector.TryGetProcess(record.Pid);
        if (process is null)
        {
            return OwnershipStatus.StaleOwner;
        }

        if (process.StartTimeUtc is not { } startTime)
        {
            return OwnershipStatus.ForeignProcess;
        }

        bool identityMatches = process.Pid == record.Pid
            && startTime.ToUniversalTime().Ticks == record.ProcessStartTicks
            && string.Equals(
                ProcessFingerprint.Compute(record.Pid, startTime),
                record.ProcessFingerprint,
                StringComparison.Ordinal);

        return identityMatches ? OwnershipStatus.LiveOwner : OwnershipStatus.ForeignProcess;
    }
}
