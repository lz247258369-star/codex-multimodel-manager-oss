using System.Globalization;
using System.Text;
using System.Text.Json;
using Router.Core.Abstractions;
using Router.Core.Errors;
using Router.Core.Ids;
using Router.Core.Support;

namespace Router.State;

/// <summary>Outcome of loading runtime state.</summary>
public sealed record StateLoadOutcome(RouterRuntimeState? State, RouterError? Error, QuarantineReceipt? QuarantineReceipt)
{
    public bool IsSuccess => State is not null && Error is null;

    public static StateLoadOutcome Success(RouterRuntimeState state)
        => new(state, null, null);

    public static StateLoadOutcome Failure(RouterError error, QuarantineReceipt? receipt = null)
        => new(null, error, receipt);
}

/// <summary>Outcome of restoring a file from a verified backup.</summary>
public sealed record RestoreOutcome(RouterError? Error)
{
    public bool IsSuccess => Error is null;

    public static RestoreOutcome Success()
        => new(Error: null);

    public static RestoreOutcome Failure(RouterError error)
        => new(Error: error);
}

/// <summary>
/// Atomic runtime-state persistence with backup and quarantine. Previous good
/// state is preserved on any write failure; corrupt state is quarantined, never
/// deleted, and never silently replaced.
/// </summary>
public sealed class RouterStateStore
{
    private readonly IFileSystem _fileSystem;
    private readonly IClock _clock;

    public RouterStateStore(IFileSystem fileSystem, IClock clock)
    {
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
    }

    public async Task<StateLoadOutcome> LoadAsync(string statePath, string quarantineRoot, CancellationToken cancellationToken)
    {
        if (!_fileSystem.FileExists(statePath))
        {
            return StateLoadOutcome.Success(RouterRuntimeState.CreateDefault(_clock.UtcNow));
        }

        string text;
        try
        {
            text = await _fileSystem.ReadAllTextAsync(statePath, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return await QuarantineAndFailAsync(statePath, quarantineRoot, "state_unreadable", cancellationToken).ConfigureAwait(false);
        }

        RouterRuntimeState state;
        try
        {
            state = JsonSerializer.Deserialize<RouterRuntimeState>(text, StateJson.Options) ?? throw new JsonException();
        }
        catch (JsonException)
        {
            return await QuarantineAndFailAsync(statePath, quarantineRoot, "state_corrupt", cancellationToken).ConfigureAwait(false);
        }

        RouterError? validationError = RouterRuntimeStateValidator.Validate(state);
        if (validationError is not null)
        {
            return await QuarantineAndFailAsync(statePath, quarantineRoot, "state_invalid", cancellationToken).ConfigureAwait(false);
        }

        return StateLoadOutcome.Success(state);
    }

    public async Task<RouterError?> SaveAsync(string statePath, RouterRuntimeState state, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(state);

        string json = JsonSerializer.Serialize(state, StateJson.Options);
        return await AtomicFileWriter.WriteAsync(statePath, Encoding.UTF8.GetBytes(json), _fileSystem, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Creates a verified backup of a file before destructive changes.</summary>
    public async Task<BackupReceipt?> BackupAsync(
        string sourcePath,
        string backupRoot,
        string reasonCode,
        CancellationToken cancellationToken)
    {
        if (!_fileSystem.FileExists(sourcePath))
        {
            return null;
        }

        byte[] content = await _fileSystem.ReadAllBytesAsync(sourcePath, cancellationToken).ConfigureAwait(false);
        string backupId = NewId("bkp_");
        string stamp = _clock.UtcNow.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        string backupDirectory = Path.Combine(backupRoot, $"{stamp}-{backupId[4..]}");
        _fileSystem.CreateDirectory(backupDirectory);
        string backupPath = Path.Combine(backupDirectory, Path.GetFileName(sourcePath));
        _fileSystem.CopyFile(sourcePath, backupPath, overwrite: false);

        return new BackupReceipt
        {
            SchemaVersion = BackupReceipt.CurrentSchemaVersion,
            BackupId = backupId,
            TargetPath = sourcePath,
            BackupPath = backupPath,
            SourceSha256 = SafeHasher.Sha256Hex(content),
            ReasonCode = reasonCode,
            CreatedAt = _clock.UtcNow,
        };
    }

    /// <summary>Moves a corrupt file to quarantine with a safe receipt. Never deletes it.</summary>
    public async Task<QuarantineReceipt> QuarantineAsync(
        string sourcePath,
        string quarantineRoot,
        string reasonCode,
        CancellationToken cancellationToken)
    {
        StatePersistenceOperation operation = StatePersistenceOperation.ReadAllBytes;
        try
        {
            byte[] content = await _fileSystem.ReadAllBytesAsync(sourcePath, cancellationToken).ConfigureAwait(false);
            string quarantineId = NewId("qrn_");
            string stamp = _clock.UtcNow.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            string quarantineDirectory = Path.Combine(quarantineRoot, $"{stamp}-{quarantineId[4..]}");
            operation = StatePersistenceOperation.CreateDirectory;
            _fileSystem.CreateDirectory(quarantineDirectory);
            string quarantinePath = Path.Combine(quarantineDirectory, Path.GetFileName(sourcePath));
            operation = StatePersistenceOperation.CopyFile;
            _fileSystem.CopyFile(sourcePath, quarantinePath, overwrite: false);
            operation = StatePersistenceOperation.DeleteFile;
            _fileSystem.DeleteFile(sourcePath);

            return new QuarantineReceipt
            {
                SchemaVersion = QuarantineReceipt.CurrentSchemaVersion,
                QuarantineId = quarantineId,
                OriginalPath = sourcePath,
                QuarantinePath = quarantinePath,
                ReasonCode = reasonCode,
                Sha256 = SafeHasher.Sha256Hex(content),
                QuarantinedAt = _clock.UtcNow,
            };
        }
        catch (Exception error)
        {
            StatePersistenceDiagnostic.Report(sourcePath, operation, error);
            throw;
        }
    }

    /// <summary>
    /// Restores a target from a verified backup. The backup hash must match the
    /// receipt; the restored content is written atomically.
    /// </summary>
    public async Task<RestoreOutcome> RestoreAsync(BackupReceipt receipt, string targetPath, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(receipt);

        if (!_fileSystem.FileExists(receipt.BackupPath))
        {
            return RestoreOutcome.Failure(StateErrors.StateRecoveryFailed("backup_missing"));
        }

        byte[] backupContent;
        try
        {
            backupContent = await _fileSystem.ReadAllBytesAsync(receipt.BackupPath, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return RestoreOutcome.Failure(StateErrors.StateRecoveryFailed("backup_unreadable"));
        }

        string actualHash = SafeHasher.Sha256Hex(backupContent);
        if (!string.Equals(actualHash, receipt.SourceSha256, StringComparison.Ordinal))
        {
            return RestoreOutcome.Failure(StateErrors.StateRecoveryFailed("backup_hash_mismatch"));
        }

        RouterError? writeError = await AtomicFileWriter.WriteAsync(targetPath, backupContent, _fileSystem, cancellationToken).ConfigureAwait(false);
        return writeError is null ? RestoreOutcome.Success() : RestoreOutcome.Failure(writeError);
    }

    /// <summary>Appends a migration receipt to the persisted runtime state.</summary>
    public async Task<RouterError?> AppendMigrationReceiptAsync(
        string statePath,
        string quarantineRoot,
        MigrationReceipt receipt,
        CancellationToken cancellationToken)
    {
        StateLoadOutcome load = await LoadAsync(statePath, quarantineRoot, cancellationToken).ConfigureAwait(false);
        if (!load.IsSuccess)
        {
            return load.Error;
        }

        RouterRuntimeState updated = load.State! with
        {
            MigrationReceipts = load.State!.MigrationReceipts.Append(receipt).ToArray(),
            UpdatedAt = _clock.UtcNow,
            Version = load.State.Version + 1,
        };

        return await SaveAsync(statePath, updated, cancellationToken).ConfigureAwait(false);
    }

    private async Task<StateLoadOutcome> QuarantineAndFailAsync(
        string statePath,
        string quarantineRoot,
        string reasonCode,
        CancellationToken cancellationToken)
    {
        try
        {
            QuarantineReceipt receipt = await QuarantineAsync(statePath, quarantineRoot, reasonCode, cancellationToken).ConfigureAwait(false);
            return StateLoadOutcome.Failure(StateErrors.StateCorrupt(reasonCode), receipt);
        }
        catch (Exception)
        {
            return StateLoadOutcome.Failure(StateErrors.StateCorrupt(reasonCode));
        }
    }

    private string NewId(string prefix)
        => prefix + new UuidV7IdGenerator(_clock).NewUuidV7().Value;
}
