using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Router.Core.Abstractions;
using Router.Core.Errors;

namespace Router.Configuration;

/// <summary>
/// Host-independent operator over the persisted Router config document. Every
/// mutation is generation-aware (compare-and-set against the current
/// normalized generation), validated before write, and written atomically so a
/// failed mutation preserves the previous valid config. The operator never
/// requires the Router HTTP server to be alive and never touches provider
/// secrets, routes, clients, or any field outside the requested mutation.
/// </summary>
public sealed class LocalRouterConfigOperator
{
    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = false,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private readonly IFileSystem _fileSystem;
    private readonly IClock _clock;
    private readonly string _defaultsPath;
    private readonly string _userConfigPath;
    private readonly IRouterConfigPublicationSink? _publicationSink;

    public LocalRouterConfigOperator(
        IFileSystem fileSystem,
        IClock clock,
        string defaultsPath,
        string userConfigPath,
        IRouterConfigPublicationSink? publicationSink = null)
    {
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _defaultsPath = defaultsPath ?? throw new ArgumentNullException(nameof(defaultsPath));
        _userConfigPath = userConfigPath ?? throw new ArgumentNullException(nameof(userConfigPath));
        _publicationSink = publicationSink;
    }

    public string UserConfigPath => _userConfigPath;

    public bool SupportsLivePublication => _publicationSink is not null;

    public IRouterConfigPublicationSink? PublicationSink => _publicationSink;

    /// <summary>
    /// Returns an operator over the same durable config paths whose mutation
    /// critical section publishes to the supplied live runtime state.
    /// </summary>
    public LocalRouterConfigOperator WithPublicationSink(IRouterConfigPublicationSink publicationSink)
        => new(
            _fileSystem,
            _clock,
            _defaultsPath,
            _userConfigPath,
            publicationSink ?? throw new ArgumentNullException(nameof(publicationSink)));

    /// <summary>Reads the current validated effective config view.</summary>
    public async Task<LocalRouterConfigReadResult> ReadAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        RouterConfigurationLoader loader = new(_fileSystem, _clock);
        RouterConfigLoadResult result = await loader
            .LoadAsync(_defaultsPath, _userConfigPath, cancellationToken)
            .ConfigureAwait(false);
        if (!result.IsSuccess || result.Snapshot is null)
        {
            return LocalRouterConfigReadResult.Failure(
                result.Error ?? ConfigurationErrors.Corrupt("user"));
        }

        return LocalRouterConfigReadResult.Success(new LocalRouterConfigView
        {
            Config = result.Snapshot.Config,
            ConfigGeneration = result.Snapshot.ConfigGeneration,
            LoadedAt = result.Snapshot.LoadedAt,
            HasUserConfig = result.Snapshot.Source.HasUserConfig,
        });
    }

    /// <summary>
    /// Atomically changes the minimum schema-coupled feature state:
    /// <c>local_router.enabled</c> plus the <c>mode</c> marker required by the
    /// schema-v1 invariant. No other config field is ever modified.
    /// </summary>
    public Task<LocalRouterConfigMutationResult> SetFeatureEnabledAsync(
        string expectedGeneration,
        bool enabled,
        CancellationToken cancellationToken)
        => MutateAsync(
            expectedGeneration,
            config => config with
            {
                // Schema v1 couples mode to local_router.enabled (validator
                // requires mode=router whenever the router is enabled and the
                // canonical disabled state is mode=direct). The operator keeps
                // that invariant while changing nothing else.
                Mode = enabled ? RouterMode.Router : RouterMode.Direct,
                LocalRouter = config.LocalRouter with { Enabled = enabled },
            },
            ControlPlaneErrors.FeatureUpdateFailed,
            cancellationToken);

    /// <summary>
    /// Atomically enables or disables the HS-1B thread-scoped model selection
    /// capability. This is a global Router configuration mutation: it uses the
    /// Router config generation (never a per-thread selection generation) and
    /// never changes the overall <c>local_router.enabled</c> feature state.
    /// </summary>
    public Task<LocalRouterConfigMutationResult> SetThreadSelectionEnabledAsync(
        string expectedGeneration,
        bool enabled,
        CancellationToken cancellationToken)
        => MutateAsync(
            expectedGeneration,
            config => config with
            {
                LocalRouter = config.LocalRouter with
                {
                    ThreadSelection = config.LocalRouter.ThreadSelection with { Enabled = enabled },
                },
            },
            ControlPlaneErrors.ThreadSelectionFeatureUpdateFailed,
            cancellationToken);

    /// <summary>Atomically replaces the retry body of an existing policy.</summary>
    public Task<LocalRouterConfigMutationResult> SetPolicyRetryBodyAsync(
        string expectedGeneration,
        string policyId,
        PolicyRetryBodyConfig body,
        CancellationToken cancellationToken)
        => MutatePolicyCoreAsync(
            expectedGeneration,
            policyId,
            policy => policy with { RetryBody = body },
            ControlPlaneErrors.PolicyInvalid,
            cancellationToken);

    /// <summary>Atomically replaces the timeout body of an existing policy.</summary>
    public Task<LocalRouterConfigMutationResult> SetPolicyTimeoutBodyAsync(
        string expectedGeneration,
        string policyId,
        PolicyTimeoutBodyConfig body,
        CancellationToken cancellationToken)
        => MutatePolicyCoreAsync(
            expectedGeneration,
            policyId,
            policy => policy with { TimeoutBody = body },
            ControlPlaneErrors.PolicyInvalid,
            cancellationToken);

    /// <summary>Atomically replaces the failover body of an existing policy.</summary>
    public Task<LocalRouterConfigMutationResult> SetPolicyFailoverBodyAsync(
        string expectedGeneration,
        string policyId,
        PolicyFailoverBodyConfig body,
        CancellationToken cancellationToken)
        => MutatePolicyCoreAsync(
            expectedGeneration,
            policyId,
            policy => policy with { FailoverBody = body },
            ControlPlaneErrors.PolicyInvalid,
            cancellationToken);

    private async Task<LocalRouterConfigMutationResult> MutatePolicyCoreAsync(
        string expectedGeneration,
        string policyId,
        Func<PolicyConfig, PolicyConfig> apply,
        Func<string?, string?, RouterError> errorFactory,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(policyId);

        return await MutateAsync(
            expectedGeneration,
            config =>
            {
                PolicyConfig? existing = null;
                foreach (PolicyConfig policy in config.Policies)
                {
                    if (string.Equals(policy.PolicyId, policyId, StringComparison.Ordinal))
                    {
                        existing = policy;
                        break;
                    }
                }

                if (existing is null)
                {
                    throw new PolicyNotFoundMutationException(policyId);
                }

                PolicyConfig[] policies = config.Policies
                    .Select(policy => string.Equals(policy.PolicyId, policyId, StringComparison.Ordinal)
                        ? apply(policy)
                        : policy)
                    .ToArray();
                return config with { Policies = policies };
            },
            errorFactory,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<LocalRouterConfigMutationResult> MutateAsync(
        string expectedGeneration,
        Func<RouterConfig, RouterConfig> mutate,
        Func<string?, string?, RouterError> errorFactory,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedGeneration);

        ConfigMutationGate gate;
        try
        {
            gate = ConfigMutationGate.Acquire(_userConfigPath, cancellationToken: cancellationToken);
        }
        catch (ConfigMutationTimeoutException)
        {
            return LocalRouterConfigMutationResult.Failure(ControlPlaneErrors.MutationBusy());
        }
        catch (OperationCanceledException)
        {
            throw;
        }

        using (gate)
        {
            try
            {
                // The final CAS compare MUST occur after the gate is held and
                // the current config is re-read from durable storage. A value
                // read before acquiring the gate is never used as the CAS
                // basis.
                LocalRouterConfigReadResult read = await ReadAsync(cancellationToken).ConfigureAwait(false);
                if (!read.IsSuccess || read.View is null)
                {
                    return LocalRouterConfigMutationResult.Failure(
                        read.Error ?? errorFactory("user_config", null));
                }

                if (!string.Equals(read.View.ConfigGeneration, expectedGeneration, StringComparison.Ordinal))
                {
                    return LocalRouterConfigMutationResult.Failure(ControlPlaneErrors.GenerationConflict());
                }

                RouterConfig updated;
                try
                {
                    updated = mutate(read.View.Config);
                }
                catch (PolicyNotFoundMutationException notFound)
                {
                    return LocalRouterConfigMutationResult.Failure(
                        ControlPlaneErrors.PolicyNotFound(notFound.PolicyId));
                }

                updated = updated with { UpdatedAt = _clock.UtcNow };

                RouterError? validationError = RouterConfigValidator.Validate(updated);
                if (validationError is not null)
                {
                    return LocalRouterConfigMutationResult.Failure(validationError);
                }

                string json = JsonSerializer.Serialize(updated, WriteOptions);
                RouterError? roundTripError = RouterConfigurationLoader.ValidateJson(json);
                if (roundTripError is not null)
                {
                    return LocalRouterConfigMutationResult.Failure(roundTripError);
                }

                // Compute the next generation using the exact loader algorithm
                // (defaults + user merge → normalize) BEFORE the commit point so
                // nothing failure-prone remains after the atomic replace.
                string nextGeneration = await ComputeGenerationAsync(json, cancellationToken).ConfigureAwait(false);
                RouterError? writeError = await WriteAtomicallyAsync(json, cancellationToken).ConfigureAwait(false);
                if (writeError is not null)
                {
                    return LocalRouterConfigMutationResult.Failure(writeError);
                }

                // The commit point is the durable atomic replace above. After
                // it, no cancellable or failure-prone work remains: the next
                // generation was already computed from the validated document
                // before the write, and publication is a non-throwing atomic
                // reference swap performed INSIDE the mutation gate. Request
                // cancellation therefore can never leave disk newer than the
                // running runtime state.
                LocalRouterConfigView committed = new()
                {
                    Config = updated,
                    ConfigGeneration = nextGeneration,
                    LoadedAt = _clock.UtcNow,
                    HasUserConfig = true,
                };

                _publicationSink?.Publish(
                    PublishedRouterState.From(committed.Config, committed.ConfigGeneration));
                return LocalRouterConfigMutationResult.Success(committed);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception)
            {
                return LocalRouterConfigMutationResult.Failure(errorFactory("user_config", null));
            }
        }
    }

    private async Task<RouterError?> WriteAtomicallyAsync(string json, CancellationToken cancellationToken)
    {
        string directory = Path.GetDirectoryName(_userConfigPath)
            ?? throw new InvalidOperationException("User config path has no directory.");
        try
        {
            _fileSystem.CreateDirectory(directory);
            string tempPath = _fileSystem.CreateTempPath(directory);
            try
            {
                await _fileSystem
                    .WriteAllBytesAsync(tempPath, System.Text.Encoding.UTF8.GetBytes(json), cancellationToken)
                    .ConfigureAwait(false);
                if (_fileSystem.FileExists(_userConfigPath))
                {
                    _fileSystem.ReplaceFile(tempPath, _userConfigPath);
                }
                else
                {
                    _fileSystem.MoveFile(tempPath, _userConfigPath, overwrite: false);
                }

                return null;
            }
            catch (OperationCanceledException)
            {
                TryDeleteTemp(tempPath);
                throw;
            }
            catch
            {
                TryDeleteTemp(tempPath);
                return ConfigurationErrors.Corrupt("user");
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            return ConfigurationErrors.Corrupt("user");
        }
    }

    private void TryDeleteTemp(string tempPath)
    {
        try
        {
            if (_fileSystem.FileExists(tempPath))
            {
                _fileSystem.DeleteFile(tempPath);
            }
        }
        catch
        {
            // Best-effort cleanup; the target file is never touched.
        }
    }

    private async Task<string> ComputeGenerationAsync(string canonicalJson, CancellationToken cancellationToken)
    {
        string defaultsText = await _fileSystem
            .ReadAllTextAsync(_defaultsPath, cancellationToken)
            .ConfigureAwait(false);
        JsonObject? defaultsNode = JsonNode.Parse(defaultsText) as JsonObject
            ?? throw new JsonException("Defaults document is not an object.");
        JsonObject? userNode = JsonNode.Parse(canonicalJson) as JsonObject
            ?? throw new JsonException("Config document is not an object.");
        JsonObject merged = RouterConfigMerger.Merge(defaultsNode, userNode);
        JsonObject normalized = RouterConfigNormalizer.Normalize(merged);
        return Router.Core.Support.SafeHasher.Sha256Hex(
            RouterConfigNormalizer.ToGenerationInput(normalized));
    }

    private sealed class PolicyNotFoundMutationException : Exception
    {
        public PolicyNotFoundMutationException(string policyId)
            : base(policyId)
        {
            PolicyId = policyId;
        }

        public string PolicyId { get; }
    }
}

/// <summary>Validated effective config view returned by the operator.</summary>
public sealed record LocalRouterConfigView
{
    public required RouterConfig Config { get; init; }

    public required string ConfigGeneration { get; init; }

    public required DateTimeOffset LoadedAt { get; init; }

    public required bool HasUserConfig { get; init; }
}

/// <summary>Discriminated read outcome.</summary>
public sealed record LocalRouterConfigReadResult
{
    public LocalRouterConfigView? View { get; init; }

    public RouterError? Error { get; init; }

    public bool IsSuccess => View is not null && Error is null;

    public static LocalRouterConfigReadResult Success(LocalRouterConfigView view)
        => new() { View = view };

    public static LocalRouterConfigReadResult Failure(RouterError error)
        => new() { Error = error };
}

/// <summary>Discriminated mutation outcome (success returns the next view).</summary>
public sealed record LocalRouterConfigMutationResult
{
    public LocalRouterConfigView? View { get; init; }

    public RouterError? Error { get; init; }

    public bool IsSuccess => View is not null && Error is null;

    public static LocalRouterConfigMutationResult Success(LocalRouterConfigView view)
        => new() { View = view };

    public static LocalRouterConfigMutationResult Failure(RouterError error)
        => new() { Error = error };
}
