namespace Router.State;

/// <summary>Backup receipt: safe metadata and hashes only.</summary>
public sealed record BackupReceipt
{
    public const int CurrentSchemaVersion = 1;

    public required int SchemaVersion { get; init; }

    public required string BackupId { get; init; }

    public required string TargetPath { get; init; }

    public required string BackupPath { get; init; }

    public required string SourceSha256 { get; init; }

    public required string ReasonCode { get; init; }

    public required DateTimeOffset CreatedAt { get; init; }
}

/// <summary>Quarantine receipt: original file is preserved, never deleted without a copy.</summary>
public sealed record QuarantineReceipt
{
    public const int CurrentSchemaVersion = 1;

    public required int SchemaVersion { get; init; }

    public required string QuarantineId { get; init; }

    public required string OriginalPath { get; init; }

    public required string QuarantinePath { get; init; }

    public required string ReasonCode { get; init; }

    public required string Sha256 { get; init; }

    public required DateTimeOffset QuarantinedAt { get; init; }
}

/// <summary>Migration receipt persisted in runtime state.</summary>
public sealed record MigrationReceipt
{
    public const int CurrentSchemaVersion = 1;

    public required int SchemaVersion { get; init; }

    public required string MigrationId { get; init; }

    public required int FromVersion { get; init; }

    public required int ToVersion { get; init; }

    public required string SourceSha256 { get; init; }

    public required string TargetSha256 { get; init; }

    public required string Status { get; init; }

    public string? BackupReceiptId { get; init; }

    public string? RollbackReceiptId { get; init; }

    public string? ErrorCode { get; init; }

    public required DateTimeOffset CompletedAt { get; init; }
}
