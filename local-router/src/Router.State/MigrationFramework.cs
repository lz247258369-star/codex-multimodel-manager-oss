using System.Text;
using System.Text.Json;
using Router.Core.Abstractions;
using Router.Core.Errors;
using Router.Core.Support;

namespace Router.State;

/// <summary>A single versioned, idempotent JSON migration step.</summary>
public interface IRouterMigration
{
    int FromVersion { get; }

    int ToVersion { get; }

    string MigrationId { get; }

    string Apply(string sourceJson);
}

/// <summary>Reason a migration plan could not be built.</summary>
public enum MigrationPlanReason
{
    FutureVersion = 0,
    Gap = 1,
    TooLong = 2,
}

/// <summary>Thrown when no safe migration plan exists.</summary>
public sealed class MigrationPlanException : Exception
{
    public MigrationPlanException(MigrationPlanReason reason)
        : base(reason.ToString())
    {
        Reason = reason;
    }

    public MigrationPlanException()
    {
    }

    public MigrationPlanException(string message)
        : base(message)
    {
    }

    public MigrationPlanException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public MigrationPlanReason Reason { get; }
}

/// <summary>Builds an ordered migration chain to the current target version.</summary>
public sealed class MigrationPlanner
{
    public const int TargetSchemaVersion = 1;

    private const int MaxChainLength = 16;

    public static IReadOnlyList<IRouterMigration> Plan(int currentVersion, IReadOnlyList<IRouterMigration> available)
    {
        ArgumentNullException.ThrowIfNull(available);

        ArgumentOutOfRangeException.ThrowIfNegative(currentVersion);

        if (currentVersion > TargetSchemaVersion)
        {
            throw new MigrationPlanException(MigrationPlanReason.FutureVersion);
        }

        if (currentVersion == TargetSchemaVersion)
        {
            return Array.Empty<IRouterMigration>();
        }

        var chain = new List<IRouterMigration>();
        int version = currentVersion;
        while (version < TargetSchemaVersion)
        {
            IRouterMigration? next = available
                .Where(migration => migration.FromVersion == version)
                .OrderBy(migration => migration.ToVersion)
                .FirstOrDefault();

            if (next is null || next.ToVersion <= version)
            {
                throw new MigrationPlanException(MigrationPlanReason.Gap);
            }

            chain.Add(next);
            version = next.ToVersion;
            if (chain.Count > MaxChainLength)
            {
                throw new MigrationPlanException(MigrationPlanReason.TooLong);
            }
        }

        return chain;
    }
}

/// <summary>Outcome of a migration run.</summary>
public sealed record MigrationRunOutcome(bool IsNoOp, IReadOnlyList<MigrationReceipt>? Receipts, RouterError? Error)
{
    public bool IsSuccess => Error is null;

    public MigrationReceipt? RollbackReceipt
        => Receipts?.FirstOrDefault(static receipt => string.Equals(receipt.Status, "rolled_back", StringComparison.Ordinal));

    public static MigrationRunOutcome NoOp()
        => new(true, Array.Empty<MigrationReceipt>(), null);

    public static MigrationRunOutcome Success(IReadOnlyList<MigrationReceipt> receipts)
        => new(false, receipts, null);

    public static MigrationRunOutcome Failure(RouterError error)
        => new(false, null, error);
}

/// <summary>Callbacks that keep the migration machinery config-agnostic.</summary>
public sealed record MigrationRunOptions
{
    /// <summary>Validates migrated JSON; null means valid.</summary>
    public required Func<string, RouterError?> Validate { get; init; }

    public required Func<string, RouterError> CorruptSource { get; init; }

    public required Func<string, RouterError> FutureVersion { get; init; }
}

/// <summary>
/// Executes a versioned migration plan with backup, atomic replace, and
/// verified rollback. Reruns are no-ops once the target version is reached.
/// </summary>
public sealed class MigrationRunner
{
    private readonly IFileSystem _fileSystem;
    private readonly IClock _clock;
    private readonly RouterStateStore _stateStore;

    public MigrationRunner(IFileSystem fileSystem, IClock clock)
    {
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _stateStore = new RouterStateStore(fileSystem, clock);
    }

    public async Task<MigrationRunOutcome> RunAsync(
        string targetPath,
        IReadOnlyList<IRouterMigration> migrations,
        string backupRoot,
        MigrationRunOptions options,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(migrations);
        ArgumentNullException.ThrowIfNull(options);

        if (!_fileSystem.FileExists(targetPath))
        {
            return MigrationRunOutcome.NoOp();
        }

        string sourceText;
        try
        {
            sourceText = await _fileSystem.ReadAllTextAsync(targetPath, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return MigrationRunOutcome.Failure(options.CorruptSource("source_unreadable"));
        }

        int currentVersion = DetectVersion(sourceText);
        if (currentVersion < 0)
        {
            return MigrationRunOutcome.Failure(options.CorruptSource("source_json"));
        }

        IReadOnlyList<IRouterMigration> plan;
        try
        {
            plan = MigrationPlanner.Plan(currentVersion, migrations);
        }
        catch (MigrationPlanException ex) when (ex.Reason == MigrationPlanReason.FutureVersion)
        {
            return MigrationRunOutcome.Failure(options.FutureVersion("schema_version"));
        }
        catch (MigrationPlanException)
        {
            return MigrationRunOutcome.Failure(options.CorruptSource("migration_gap"));
        }

        if (plan.Count == 0)
        {
            return MigrationRunOutcome.NoOp();
        }

        string directory = Path.GetDirectoryName(targetPath)
            ?? throw new ArgumentException("Target path has no directory.", nameof(targetPath));
        CleanStaleTemps(directory);

        BackupReceipt? backup = await _stateStore.BackupAsync(targetPath, backupRoot, "migration", cancellationToken).ConfigureAwait(false);

        string currentJson = sourceText;
        foreach (IRouterMigration migration in plan)
        {
            try
            {
                currentJson = migration.Apply(currentJson);
            }
            catch (Exception)
            {
                return await RollbackAsync(targetPath, backup, options, StateErrors.MigrationFailed(migration.MigrationId), cancellationToken).ConfigureAwait(false);
            }
        }

        RouterError? validationError = options.Validate(currentJson);
        if (validationError is not null)
        {
            return await RollbackAsync(targetPath, backup, options, StateErrors.MigrationFailed(validationError.Code), cancellationToken).ConfigureAwait(false);
        }

        RouterError? writeError = await AtomicFileWriter.WriteAsync(targetPath, Encoding.UTF8.GetBytes(currentJson), _fileSystem, cancellationToken).ConfigureAwait(false);
        if (writeError is not null)
        {
            return await RollbackAsync(targetPath, backup, options, writeError, cancellationToken).ConfigureAwait(false);
        }

        MigrationReceipt completed = CreateReceipt(
            status: "completed",
            plan: plan,
            sourceJson: sourceText,
            targetJson: currentJson,
            backup: backup,
            errorCode: null);

        return MigrationRunOutcome.Success([completed]);
    }

    private async Task<MigrationRunOutcome> RollbackAsync(
        string targetPath,
        BackupReceipt? backup,
        MigrationRunOptions options,
        RouterError primaryError,
        CancellationToken cancellationToken)
    {
        if (backup is null)
        {
            return MigrationRunOutcome.Failure(primaryError);
        }

        RestoreOutcome restore = await _stateStore.RestoreAsync(backup, targetPath, cancellationToken).ConfigureAwait(false);
        if (!restore.IsSuccess)
        {
            return MigrationRunOutcome.Failure(StateErrors.MigrationRollbackFailed(restore.Error!.Code));
        }

        string restoredText;
        try
        {
            restoredText = await _fileSystem.ReadAllTextAsync(targetPath, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return MigrationRunOutcome.Failure(StateErrors.MigrationRollbackFailed("restored_unreadable"));
        }

        if (DetectVersion(restoredText) < 0)
        {
            return MigrationRunOutcome.Failure(StateErrors.MigrationRollbackFailed("restored_invalid"));
        }

        MigrationReceipt rollbackReceipt = new()
        {
            SchemaVersion = MigrationReceipt.CurrentSchemaVersion,
            MigrationId = "rollback",
            FromVersion = 0,
            ToVersion = 0,
            SourceSha256 = SafeHasher.Sha256Hex(restoredText),
            TargetSha256 = SafeHasher.Sha256Hex(restoredText),
            Status = "rolled_back",
            BackupReceiptId = backup.BackupId,
            ErrorCode = primaryError.Code,
            CompletedAt = _clock.UtcNow,
        };

        return new MigrationRunOutcome(false, [rollbackReceipt], primaryError);
    }

    private MigrationReceipt CreateReceipt(
        string status,
        IReadOnlyList<IRouterMigration> plan,
        string sourceJson,
        string targetJson,
        BackupReceipt? backup,
        string? errorCode)
        => new()
        {
            SchemaVersion = MigrationReceipt.CurrentSchemaVersion,
            MigrationId = string.Join("+", plan.Select(static migration => migration.MigrationId)),
            FromVersion = plan[0].FromVersion,
            ToVersion = plan[^1].ToVersion,
            SourceSha256 = SafeHasher.Sha256Hex(sourceJson),
            TargetSha256 = SafeHasher.Sha256Hex(targetJson),
            Status = status,
            BackupReceiptId = backup?.BackupId,
            ErrorCode = errorCode,
            CompletedAt = _clock.UtcNow,
        };

    private static int DetectVersion(string json)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("schema_version", out JsonElement versionElement)
                && versionElement.ValueKind == JsonValueKind.Number
                && versionElement.TryGetInt32(out int version))
            {
                return version;
            }

            return 0;
        }
        catch (JsonException)
        {
            return -1;
        }
    }

    private void CleanStaleTemps(string directory)
    {
        if (!_fileSystem.DirectoryExists(directory))
        {
            return;
        }

        foreach (string tempFile in _fileSystem.EnumerateFiles(directory, ".tmp-*"))
        {
            try
            {
                _fileSystem.DeleteFile(tempFile);
            }
            catch
            {
                // Interrupted temp files are best-effort cleanup only.
            }
        }
    }
}
