using System.Globalization;
using System.Text.RegularExpressions;
using Router.Core.Errors;
using Router.Core.Support;

namespace Router.State.Ownership;

/// <summary>
/// Schema-v1 router process ownership record. Contains a PID, a process start
/// identity, and a fingerprint derived from both, so PID reuse cannot fake
/// ownership. Never contains secrets or command-line values.
/// </summary>
public sealed record OwnerRecord
{
    public const int CurrentSchemaVersion = 1;

    public required int SchemaVersion { get; init; }

    public required int Pid { get; init; }

    public required string ProcessFingerprint { get; init; }

    public required long ProcessStartTicks { get; init; }

    public required string Host { get; init; }

    public required int Port { get; init; }

    public string? OwnerUserSidHash { get; init; }

    public string? ConfigGeneration { get; init; }

    public required DateTimeOffset CreatedAt { get; init; }

    public required int Version { get; init; }
}

/// <summary>Stable process fingerprint: SHA-256 of PID and start time.</summary>
public static class ProcessFingerprint
{
    public static string Compute(int pid, DateTimeOffset startTimeUtc)
        => SafeHasher.Sha256Hex(
            pid.ToString(CultureInfo.InvariantCulture)
            + ":"
            + startTimeUtc.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture));
}

/// <summary>Validation for loaded owner records (fail closed).</summary>
public static class OwnerRecordValidator
{
    private static readonly Regex FingerprintPattern = new("^[0-9a-f]{64}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static RouterError? Validate(OwnerRecord record)
    {
        if (record is null)
        {
            return StateErrors.StateCorrupt("owner");
        }

        if (record.SchemaVersion != OwnerRecord.CurrentSchemaVersion)
        {
            return StateErrors.StateCorrupt("owner.schema_version");
        }

        if (record.Pid < 1)
        {
            return StateErrors.StateCorrupt("owner.pid");
        }

        if (!FingerprintPattern.IsMatch(record.ProcessFingerprint))
        {
            return StateErrors.StateCorrupt("owner.process_fingerprint");
        }

        if (record.ProcessStartTicks < 0)
        {
            return StateErrors.StateCorrupt("owner.process_start_ticks");
        }

        if (!string.Equals(record.Host, "127.0.0.1", StringComparison.Ordinal))
        {
            return StateErrors.StateCorrupt("owner.host");
        }

        if (record.Port is < 1 or > 65535)
        {
            return StateErrors.StateCorrupt("owner.port");
        }

        if (record.Version < 1)
        {
            return StateErrors.StateCorrupt("owner.version");
        }

        string expectedFingerprint = ProcessFingerprint.Compute(
            record.Pid,
            new DateTimeOffset(record.ProcessStartTicks, TimeSpan.Zero));
        if (!string.Equals(expectedFingerprint, record.ProcessFingerprint, StringComparison.Ordinal))
        {
            return StateErrors.StateCorrupt("owner.fingerprint_mismatch");
        }

        return null;
    }
}
