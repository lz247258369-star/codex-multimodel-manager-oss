using System.Text;
using System.Text.Json;
using Router.Core.Abstractions;
using Router.Core.Errors;

namespace Router.State.Ownership;

/// <summary>Outcome of loading the owner record.</summary>
public sealed record OwnerLoadOutcome(OwnerRecord? Record, RouterError? Error, QuarantineReceipt? QuarantineReceipt)
{
    public bool IsSuccess => Record is not null && Error is null;

    public static OwnerLoadOutcome Missing()
        => new(null, null, null);

    public static OwnerLoadOutcome Success(OwnerRecord record)
        => new(record, null, null);

    public static OwnerLoadOutcome Failure(RouterError error, QuarantineReceipt? receipt = null)
        => new(null, error, receipt);
}

/// <summary>Outcome of cleaning a stale owner record.</summary>
public sealed record CleanStaleOutcome(RouterError? Error, QuarantineReceipt? QuarantineReceipt)
{
    public bool IsSuccess => Error is null;
}

/// <summary>
/// Persists the owner record atomically with restrictive ACL protection and
/// cleans only records verified stale. Never kills or touches live processes.
/// </summary>
public sealed class OwnerRecordStore
{
    private readonly IFileSystem _fileSystem;
    private readonly IClock _clock;
    private readonly IFileSecurity _fileSecurity;
    private readonly OwnershipVerifier _verifier;
    private readonly RouterStateStore _stateStore;

    public OwnerRecordStore(IFileSystem fileSystem, IClock clock, IFileSecurity fileSecurity, OwnershipVerifier verifier)
    {
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _fileSecurity = fileSecurity ?? throw new ArgumentNullException(nameof(fileSecurity));
        _verifier = verifier ?? throw new ArgumentNullException(nameof(verifier));
        _stateStore = new RouterStateStore(fileSystem, clock);
    }

    public async Task<OwnerLoadOutcome> LoadAsync(string ownerPath, string quarantineRoot, CancellationToken cancellationToken)
    {
        if (!_fileSystem.FileExists(ownerPath))
        {
            return OwnerLoadOutcome.Missing();
        }

        string text;
        try
        {
            text = await _fileSystem.ReadAllTextAsync(ownerPath, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return await QuarantineAndFailAsync(ownerPath, quarantineRoot, "owner_unreadable", cancellationToken).ConfigureAwait(false);
        }

        OwnerRecord record;
        try
        {
            record = JsonSerializer.Deserialize<OwnerRecord>(text, StateJson.Options) ?? throw new JsonException();
        }
        catch (JsonException)
        {
            return await QuarantineAndFailAsync(ownerPath, quarantineRoot, "owner_corrupt", cancellationToken).ConfigureAwait(false);
        }

        RouterError? validationError = OwnerRecordValidator.Validate(record);
        if (validationError is not null)
        {
            return await QuarantineAndFailAsync(ownerPath, quarantineRoot, "owner_invalid", cancellationToken).ConfigureAwait(false);
        }

        return OwnerLoadOutcome.Success(record);
    }

    public async Task<RouterError?> WriteAsync(string ownerPath, OwnerRecord record, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(record);

        string json = JsonSerializer.Serialize(record, StateJson.Options);
        RouterError? writeError = await AtomicFileWriter.WriteAsync(ownerPath, Encoding.UTF8.GetBytes(json), _fileSystem, cancellationToken).ConfigureAwait(false);
        if (writeError is not null)
        {
            return writeError;
        }

        FileSecurityStatus status = _fileSecurity.ProtectForCurrentUser(ownerPath);
        return status == FileSecurityStatus.Unknown
            ? StateErrors.StateWriteFailed("file_security")
            : null;
    }

    /// <summary>
    /// Archives a stale owner record to quarantine. Refuses to touch live or
    /// foreign records and never kills a process.
    /// </summary>
    public async Task<CleanStaleOutcome> CleanStaleAsync(string ownerPath, string quarantineRoot, CancellationToken cancellationToken)
    {
        OwnerLoadOutcome load = await LoadAsync(ownerPath, quarantineRoot, cancellationToken).ConfigureAwait(false);
        if (!load.IsSuccess)
        {
            return new CleanStaleOutcome(load.Error, null);
        }

        if (load.Record is null)
        {
            return new CleanStaleOutcome(null, null);
        }

        OwnershipStatus status = _verifier.Verify(load.Record);
        if (status != OwnershipStatus.StaleOwner)
        {
            return new CleanStaleOutcome(
                status == OwnershipStatus.ForeignProcess
                    ? StateErrors.OwnershipForeignProcess(load.Record.Pid.ToString(System.Globalization.CultureInfo.InvariantCulture))
                    : StateErrors.OwnershipConflict(status.ToString()),
                null);
        }

        QuarantineReceipt receipt = await _stateStore.QuarantineAsync(ownerPath, quarantineRoot, "stale_owner", cancellationToken).ConfigureAwait(false);
        return new CleanStaleOutcome(null, receipt);
    }

    private async Task<OwnerLoadOutcome> QuarantineAndFailAsync(
        string ownerPath,
        string quarantineRoot,
        string reasonCode,
        CancellationToken cancellationToken)
    {
        try
        {
            QuarantineReceipt receipt = await _stateStore.QuarantineAsync(ownerPath, quarantineRoot, reasonCode, cancellationToken).ConfigureAwait(false);
            return OwnerLoadOutcome.Failure(StateErrors.StateCorrupt(reasonCode), receipt);
        }
        catch (Exception)
        {
            return OwnerLoadOutcome.Failure(StateErrors.StateCorrupt(reasonCode));
        }
    }
}
