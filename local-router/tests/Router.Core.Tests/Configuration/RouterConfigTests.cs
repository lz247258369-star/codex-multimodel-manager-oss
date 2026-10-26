using System.Text;
using Router.Configuration;
using Router.Core.Errors;
using Router.Core.Tests.Fakes;
using Router.State;
using Xunit;

namespace Router.Core.Tests.Configuration;

public sealed class RouterConfigTests
{
    private readonly FakeClock _clock = new(1_752_000_000_000);
    private readonly WindowsFileSystem _fileSystem = new();

    [Fact]
    public async Task Defaults_load_successfully()
    {
        RouterConfigLoadResult result = await LoadDefaultsAsync();

        Assert.True(result.IsSuccess);
        Assert.Equal(1, result.Snapshot!.SchemaVersion);
    }

    [Fact]
    public async Task Missing_user_file_uses_defaults()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            RouterConfigLoadResult result = await LoadAsync(userConfigPath: Path.Combine(sandbox, "missing.json"));

            Assert.True(result.IsSuccess);
            Assert.False(result.Snapshot!.Source.HasUserConfig);
            Assert.Null(result.Snapshot.Source.UserConfigPath);
            Assert.Equal(47821, result.Snapshot.Config.LocalRouter.Port);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Defaults_plus_user_merge_applies_field_level_overrides()
    {
        RouterConfigLoadResult result = await LoadAsync(userConfigPath: TestPaths.Fixture("config/merge-user-override.json"));

        Assert.True(result.IsSuccess);
        Assert.True(result.Snapshot!.Source.HasUserConfig);
        Assert.Equal(2, result.Snapshot.Version);
        Assert.Equal(50000, result.Snapshot.Config.LocalRouter.Port);
        Assert.Equal(16, result.Snapshot.Config.LocalRouter.Limits.MaxConnections);
        Assert.Equal(20_000, result.Snapshot.Config.LocalRouter.Limits.ShutdownGraceMs);
        Assert.Equal(16_777_216, result.Snapshot.Config.LocalRouter.Limits.MaxRequestBytes);
        Assert.False(result.Snapshot.Config.LocalRouter.Enabled);
        Assert.Equal("direct", result.Snapshot.Config.Mode.ToWireName());
        Assert.Equal("127.0.0.1", result.Snapshot.Config.LocalRouter.Host);
    }

    [Fact]
    public async Task Default_mode_is_direct_and_enabled_is_false()
    {
        RouterConfigLoadResult result = await LoadDefaultsAsync();

        Assert.True(result.IsSuccess);
        Assert.Equal(RouterMode.Direct, result.Snapshot!.Config.Mode);
        Assert.False(result.Snapshot.Config.LocalRouter.Enabled);
    }

    [Fact]
    public async Task Default_host_is_loopback_and_port_is_47821()
    {
        RouterConfigLoadResult result = await LoadDefaultsAsync();

        Assert.True(result.IsSuccess);
        Assert.Equal("127.0.0.1", result.Snapshot!.Config.LocalRouter.Host);
        Assert.Equal(47821, result.Snapshot.Config.LocalRouter.Port);
    }

    [Theory]
    [InlineData("config/invalid/host-0.0.0.0.json", RouterErrorCode.ConfigSecurityViolation)]
    [InlineData("config/invalid/host-colon-colon.json", RouterErrorCode.ConfigSecurityViolation)]
    [InlineData("config/invalid/host-hostname.json", RouterErrorCode.ConfigSecurityViolation)]
    [InlineData("config/invalid/port-zero.json", RouterErrorCode.ConfigSecurityViolation)]
    [InlineData("config/invalid/port-too-large.json", RouterErrorCode.ConfigSecurityViolation)]
    [InlineData("config/invalid/unknown-schema.json", RouterErrorCode.ConfigSchemaUnsupported)]
    [InlineData("config/invalid/future-schema.json", RouterErrorCode.ConfigSchemaUnsupported)]
    [InlineData("config/invalid/corrupt.json", RouterErrorCode.ConfigCorrupt)]
    [InlineData("config/invalid/duplicate-ids.json", RouterErrorCode.ConfigInvalid)]
    [InlineData("config/invalid/unknown-enum.json", RouterErrorCode.ConfigInvalid)]
    [InlineData("config/invalid/bad-limit.json", RouterErrorCode.ConfigSecurityViolation)]
    [InlineData("config/invalid/mode-router-disabled.json", RouterErrorCode.ConfigInvalid)]
    [InlineData("config/invalid/unknown-field.json", RouterErrorCode.ConfigSecurityViolation)]
    [InlineData("config/invalid/inline-token.json", RouterErrorCode.ConfigSecurityViolation)]
    [InlineData("config/invalid/bad-capability.json", RouterErrorCode.ConfigInvalid)]
    [InlineData("config/invalid/bad-provider.json", RouterErrorCode.ConfigInvalid)]
    [InlineData("config/invalid/bad-secret-name.json", RouterErrorCode.SecretReferenceInvalid)]
    public async Task Invalid_defaults_fail_closed(string fixturePath, string expectedCode)
    {
        RouterConfigLoadResult result = await LoadDefaultsAsync(defaultsPath: TestPaths.Fixture(fixturePath));

        Assert.False(result.IsSuccess);
        Assert.Equal(expectedCode, result.Error!.Code);
    }

    [Fact]
    public async Task Unknown_nested_field_is_a_security_violation()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string userPath = Path.Combine(sandbox, "user.json");
            await File.WriteAllTextAsync(userPath, """
                {
                  "local_router": {
                    "enabled": false,
                    "evil": true
                  }
                }
                """);

            RouterConfigLoadResult result = await LoadAsync(userConfigPath: userPath);

            Assert.False(result.IsSuccess);
            Assert.Equal(RouterErrorCode.ConfigSecurityViolation, result.Error!.Code);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task User_array_replaces_defaults_and_duplicate_ids_fail()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string validUser = Path.Combine(sandbox, "valid-user.json");
            await File.WriteAllTextAsync(validUser, """
                {
                  "clients": [
                    {
                      "client_id": "client.codex_cli",
                      "adapter_id": "adapter.client.codex_cli.responses.v1",
                      "enabled": true,
                      "auth_scope": "responses:invoke",
                      "capabilities": ["text", "streaming"],
                      "version": 1
                    }
                  ]
                }
                """);

            RouterConfigLoadResult valid = await LoadAsync(userConfigPath: validUser);
            Assert.True(valid.IsSuccess);
            Assert.Single(valid.Snapshot!.Config.Clients);

            string duplicateUser = Path.Combine(sandbox, "duplicate-user.json");
            await File.WriteAllTextAsync(duplicateUser, """
                {
                  "clients": [
                    {
                      "client_id": "client.codex_cli",
                      "adapter_id": "adapter.client.codex_cli.responses.v1",
                      "enabled": true,
                      "auth_scope": "responses:invoke",
                      "capabilities": ["text"],
                      "version": 1
                    },
                    {
                      "client_id": "client.codex_cli",
                      "adapter_id": "adapter.client.codex_cli.responses.v1",
                      "enabled": true,
                      "auth_scope": "responses:invoke",
                      "capabilities": ["text"],
                      "version": 1
                    }
                  ]
                }
                """);

            RouterConfigLoadResult duplicate = await LoadAsync(userConfigPath: duplicateUser);
            Assert.False(duplicate.IsSuccess);
            Assert.Equal(RouterErrorCode.ConfigInvalid, duplicate.Error!.Code);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Invalid_entity_id_format_is_rejected()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string userPath = Path.Combine(sandbox, "user.json");
            await File.WriteAllTextAsync(userPath, """
                {
                  "clients": [
                    {
                      "client_id": "client_bad!",
                      "adapter_id": "adapter.client.codex_cli.responses.v1",
                      "enabled": true,
                      "auth_scope": "responses:invoke",
                      "capabilities": ["text"],
                      "version": 1
                    }
                  ]
                }
                """);

            RouterConfigLoadResult result = await LoadAsync(userConfigPath: userPath);

            Assert.False(result.IsSuccess);
            Assert.Equal(RouterErrorCode.ConfigInvalid, result.Error!.Code);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public void Normalization_is_deterministic_and_orders_arrays()
    {
        string defaultsText = File.ReadAllText(TestPaths.DefaultsPath);
        var first = System.Text.Json.Nodes.JsonNode.Parse(defaultsText)!.AsObject();
        var second = System.Text.Json.Nodes.JsonNode.Parse(defaultsText)!.AsObject();

        string firstJson = RouterConfigNormalizer.ToJson(RouterConfigNormalizer.Normalize(first));
        string secondJson = RouterConfigNormalizer.ToJson(RouterConfigNormalizer.Normalize(second));

        Assert.Equal(firstJson, secondJson);
        Assert.DoesNotContain("\n", firstJson);
    }

    [Fact]
    public async Task Config_generation_is_stable_across_loads()
    {
        RouterConfigLoadResult first = await LoadDefaultsAsync();
        RouterConfigLoadResult second = await LoadDefaultsAsync();

        Assert.True(first.IsSuccess);
        Assert.True(second.IsSuccess);
        Assert.Equal(first.Snapshot!.ConfigGeneration, second.Snapshot!.ConfigGeneration);
        Assert.Matches("^[0-9a-f]{64}$", first.Snapshot.ConfigGeneration);
    }

    [Fact]
    public async Task Config_generation_changes_on_semantic_change()
    {
        RouterConfigLoadResult defaults = await LoadDefaultsAsync();
        RouterConfigLoadResult merged = await LoadAsync(userConfigPath: TestPaths.Fixture("config/merge-user-override.json"));

        Assert.True(defaults.IsSuccess);
        Assert.True(merged.IsSuccess);
        Assert.NotEqual(defaults.Snapshot!.ConfigGeneration, merged.Snapshot!.ConfigGeneration);
    }

    [Fact]
    public async Task Config_generation_ignores_updated_at_only_changes()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string defaultsText = await File.ReadAllTextAsync(TestPaths.DefaultsPath);
            string firstPath = Path.Combine(sandbox, "first.json");
            string secondPath = Path.Combine(sandbox, "second.json");
            await File.WriteAllTextAsync(firstPath, defaultsText);
            await File.WriteAllTextAsync(secondPath, defaultsText.Replace("2026-08-27T00:00:00Z", "2030-01-01T00:00:00Z"));

            RouterConfigLoadResult first = await LoadDefaultsAsync(defaultsPath: firstPath);
            RouterConfigLoadResult second = await LoadDefaultsAsync(defaultsPath: secondPath);

            Assert.True(first.IsSuccess);
            Assert.True(second.IsSuccess);
            Assert.Equal(first.Snapshot!.ConfigGeneration, second.Snapshot!.ConfigGeneration);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Loaded_at_does_not_affect_generation()
    {
        RouterConfigLoadResult result = await LoadDefaultsAsync();

        _clock.AdvanceMilliseconds(60_000);
        RouterConfigLoadResult later = await LoadDefaultsAsync();

        Assert.True(result.IsSuccess);
        Assert.True(later.IsSuccess);
        Assert.Equal(result.Snapshot!.ConfigGeneration, later.Snapshot!.ConfigGeneration);
        Assert.True(later.Snapshot!.LoadedAt > result.Snapshot!.LoadedAt);
    }

    [Fact]
    public async Task Missing_defaults_file_fails_closed()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            RouterConfigLoadResult result = await LoadDefaultsAsync(defaultsPath: Path.Combine(sandbox, "missing.json"));

            Assert.False(result.IsSuccess);
            Assert.Equal(RouterErrorCode.ConfigMissingRequired, result.Error!.Code);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public void Defaults_fixture_matches_production_defaults()
    {
        string production = File.ReadAllText(TestPaths.DefaultsPath);
        string fixture = File.ReadAllText(TestPaths.Fixture("config/default-disabled.json"));

        Assert.Equal(production, fixture);
    }

    private Task<RouterConfigLoadResult> LoadDefaultsAsync(string? defaultsPath = null)
        => LoadAsync(defaultsPath ?? TestPaths.DefaultsPath, null);

    private async Task<RouterConfigLoadResult> LoadAsync(string? defaultsPath = null, string? userConfigPath = null)
    {
        RouterConfigurationLoader loader = new(_fileSystem, _clock);
        return await loader.LoadAsync(
            defaultsPath ?? TestPaths.DefaultsPath,
            userConfigPath,
            CancellationToken.None);
    }
}
