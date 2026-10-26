using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Router.Core.Abstractions;
using Router.Core.Errors;
using Router.Core.Support;

namespace Router.Configuration;

/// <summary>
/// Loads checked-in defaults plus an optional user config, merges them with
/// field-level precedence, validates the effective config fail-closed, and
/// produces an immutable snapshot with a stable config_generation.
/// </summary>
public sealed class RouterConfigurationLoader
{
    private static readonly JsonSerializerOptions ParseOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private readonly IFileSystem _fileSystem;
    private readonly IClock _clock;

    public RouterConfigurationLoader(IFileSystem fileSystem, IClock clock)
    {
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
    }

    public Task<RouterConfigLoadResult> LoadDefaultsAsync(string defaultsPath, CancellationToken cancellationToken)
        => LoadAsync(defaultsPath, null, cancellationToken);

    /// <summary>
    /// Validates a full effective-config JSON document without a file round
    /// trip. Used by migration validation.
    /// </summary>
    public static RouterError? ValidateJson(string json)
    {
        try
        {
            RouterConfig config = JsonSerializer.Deserialize<RouterConfig>(json, ParseOptions) ?? throw new JsonException();
            return RouterConfigValidator.Validate(config);
        }
        catch (JsonException)
        {
            return ConfigurationErrors.Invalid("json");
        }
    }

    /// <summary>
    /// Loads and validates the effective config. A missing user file is not an
    /// error; a missing or invalid defaults file is always fail-closed.
    /// </summary>
    public async Task<RouterConfigLoadResult> LoadAsync(string defaultsPath, string? userConfigPath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (!_fileSystem.FileExists(defaultsPath))
        {
            return RouterConfigLoadResult.Failure(ConfigurationErrors.MissingRequired("defaults"));
        }

        string defaultsText;
        try
        {
            defaultsText = await _fileSystem.ReadAllTextAsync(defaultsPath, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return RouterConfigLoadResult.Failure(ConfigurationErrors.Corrupt("defaults"));
        }

        JsonObject? defaultsNode = ParseObject(defaultsText);
        if (defaultsNode is null)
        {
            return RouterConfigLoadResult.Failure(ConfigurationErrors.Corrupt("defaults"));
        }

        try
        {
            RouterConfigMerger.EnsureKnownFields(defaultsNode);
        }
        catch (ConfigMergeSecurityViolation violation)
        {
            return RouterConfigLoadResult.Failure(ConfigurationErrors.SecurityViolation(violation.PropertyPath));
        }

        string defaultsSha256 = SafeHasher.Sha256Hex(defaultsText);

        JsonObject? userNode = null;
        bool hasUserConfig = false;
        if (userConfigPath is not null && _fileSystem.FileExists(userConfigPath))
        {
            string userText;
            try
            {
                userText = await _fileSystem.ReadAllTextAsync(userConfigPath, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception)
            {
                return RouterConfigLoadResult.Failure(ConfigurationErrors.Corrupt("user"));
            }

            userNode = ParseObject(userText);
            if (userNode is null)
            {
                return RouterConfigLoadResult.Failure(ConfigurationErrors.Corrupt("user"));
            }

            hasUserConfig = true;
        }

        JsonObject merged;
        try
        {
            merged = RouterConfigMerger.Merge(defaultsNode, userNode);
        }
        catch (ConfigMergeSecurityViolation violation)
        {
            return RouterConfigLoadResult.Failure(ConfigurationErrors.SecurityViolation(violation.PropertyPath));
        }

        JsonObject normalized = RouterConfigNormalizer.Normalize(merged);
        string canonicalJson = RouterConfigNormalizer.ToJson(normalized);

        RouterConfig config;
        try
        {
            config = JsonSerializer.Deserialize<RouterConfig>(canonicalJson, ParseOptions) ?? throw new JsonException();
        }
        catch (JsonException)
        {
            return RouterConfigLoadResult.Failure(ConfigurationErrors.Invalid("json"));
        }

        RouterError? validationError = RouterConfigValidator.Validate(config);
        if (validationError is not null)
        {
            return RouterConfigLoadResult.Failure(validationError);
        }

        string generationInput = RouterConfigNormalizer.ToGenerationInput(normalized);
        string configGeneration = SafeHasher.Sha256Hex(generationInput);

        var snapshot = new EffectiveRouterConfigSnapshot
        {
            Config = config,
            ConfigGeneration = configGeneration,
            LoadedAt = _clock.UtcNow,
            Source = new ConfigSourceProvenance
            {
                DefaultsPath = defaultsPath,
                UserConfigPath = hasUserConfig ? userConfigPath : null,
                HasUserConfig = hasUserConfig,
                DefaultsSha256 = defaultsSha256,
            },
        };

        return RouterConfigLoadResult.Success(snapshot);
    }

    private static JsonObject? ParseObject(string text)
    {
        try
        {
            return JsonNode.Parse(text) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
