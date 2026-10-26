namespace Router.Observability;

/// <summary>
/// Versioned, bounded observability options. Defaults are deterministic and
/// conservative; paths must be Router-owned user directories, never the
/// repository, cwd, or a public temporary directory.
/// </summary>
public sealed record ObservabilityOptions
{
    public const int SchemaVersion = 1;
    public const long DefaultMaxFileBytes = 256 * 1024;
    public const int DefaultMaxFiles = 8;

    public required string LogDirectory { get; init; }

    public required long MaxFileBytes { get; init; }

    public required int MaxFiles { get; init; }

    public required TimeSpan RetentionAge { get; init; }

    public required int MaxTraceEventsPerRequest { get; init; }

    public static ObservabilityOptions Defaults(string logDirectory)
        => Create(
            logDirectory,
            DefaultMaxFileBytes,
            DefaultMaxFiles,
            TimeSpan.FromDays(7),
            maxTraceEventsPerRequest: 64);

    public static ObservabilityOptions Create(
        string logDirectory,
        long maxFileBytes,
        int maxFiles,
        TimeSpan retentionAge,
        int maxTraceEventsPerRequest)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(maxFileBytes, 0, nameof(maxFileBytes));
        ArgumentOutOfRangeException.ThrowIfLessThan(maxFiles, 1, nameof(maxFiles));
        ArgumentOutOfRangeException.ThrowIfLessThan(retentionAge, TimeSpan.Zero, nameof(retentionAge));
        ArgumentOutOfRangeException.ThrowIfLessThan(maxTraceEventsPerRequest, 1, nameof(maxTraceEventsPerRequest));

        if (!ObservabilityPathPolicy.IsAllowedDirectory(logDirectory))
        {
            throw new ArgumentException("Observability log directory must be an allowed Router-owned path.", nameof(logDirectory));
        }

        return new ObservabilityOptions
        {
            LogDirectory = Path.GetFullPath(logDirectory),
            MaxFileBytes = maxFileBytes,
            MaxFiles = maxFiles,
            RetentionAge = retentionAge,
            MaxTraceEventsPerRequest = maxTraceEventsPerRequest,
        };
    }
}

/// <summary>
/// Path policy: logs must never target the repository root, current working
/// directory, a drive root, or a public temp directory.
/// </summary>
public static class ObservabilityPathPolicy
{
    private static readonly HashSet<string> ForbiddenRoots = new(StringComparer.OrdinalIgnoreCase)
    {
        Normalize(Path.GetPathRoot(Environment.CurrentDirectory) ?? string.Empty),
        Normalize(Environment.CurrentDirectory),
        Normalize(Path.GetTempPath()),
    };

    public static bool IsAllowedDirectory(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path))
        {
            return false;
        }

        string full = Normalize(path);
        return !ForbiddenRoots.Contains(full)
            && !string.Equals(full, Environment.CurrentDirectory, StringComparison.OrdinalIgnoreCase);
    }

    private static string Normalize(string path)
        => string.IsNullOrWhiteSpace(path)
            ? string.Empty
            : Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
}
