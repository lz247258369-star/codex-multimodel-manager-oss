using System.Reflection;
using Router.Core.Tests.Fakes;
using Router.Host;
using Router.Secrets;
using Xunit;

namespace Router.Core.Tests.Host;

public sealed class Lr2DisabledHostTests
{
    [Fact]
    public async Task Disabled_by_default_exits_zero()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            // DSR6: the shipped defaults are the disabled baseline, but the
            // effective config is defaults + user, so this runs against an
            // isolated home with no user config.
            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider: new TestPathProvider(sandbox, TestPaths.DefaultsPath),
                cancellationToken: CancellationToken.None);

            Assert.Equal(0, exitCode);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task No_secret_resolution_when_disabled()
    {
        FakeSecretResolver secretResolver = new();
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider: new TestPathProvider(sandbox, TestPaths.DefaultsPath),
                secretResolver: secretResolver,
                cancellationToken: CancellationToken.None);

            Assert.Equal(0, exitCode);
            Assert.Empty(secretResolver.Calls);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task No_user_state_or_config_is_created_when_disabled()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            TestPathProvider pathProvider = new(sandbox, TestPaths.DefaultsPath);

            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider: pathProvider,
                cancellationToken: CancellationToken.None);

            Assert.Equal(0, exitCode);
            Assert.False(Directory.Exists(pathProvider.UserConfigPath));
            Assert.False(Directory.Exists(Path.GetDirectoryName(pathProvider.RuntimeStatePath)));
            Assert.False(Directory.Exists(pathProvider.BackupRootPath));
            Assert.False(Directory.Exists(pathProvider.QuarantineRootPath));
            Assert.False(File.Exists(pathProvider.RuntimeStatePath));
            Assert.False(File.Exists(pathProvider.OwnerRecordPath));
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Missing_defaults_fails_closed_without_starting()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider: new TestPathProvider(sandbox),
                cancellationToken: CancellationToken.None);

            Assert.Equal(RouterHostBootstrap.ConfigErrorExitCode, exitCode);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Corrupt_defaults_fail_closed_without_starting()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string defaultsPath = Path.Combine(sandbox, "config", "router.defaults.json");
            Directory.CreateDirectory(Path.GetDirectoryName(defaultsPath)!);
            await File.WriteAllTextAsync(defaultsPath, "{ \"schema_version\": 1,");

            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider: new TestPathProvider(sandbox),
                cancellationToken: CancellationToken.None);

            Assert.Equal(RouterHostBootstrap.ConfigErrorExitCode, exitCode);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public async Task Enabled_defaults_fail_closed_without_starting()
    {
        string sandbox = TestPaths.NewSandboxDirectory();
        try
        {
            string defaultsPath = Path.Combine(sandbox, "config", "router.defaults.json");
            Directory.CreateDirectory(Path.GetDirectoryName(defaultsPath)!);
            string defaultsText = await File.ReadAllTextAsync(TestPaths.DefaultsPath);
            await File.WriteAllTextAsync(defaultsPath, defaultsText.Replace("\"enabled\": false", "\"enabled\": true"));

            int exitCode = await RouterHostBootstrap.RunAsync(
                Array.Empty<string>(),
                pathProvider: new TestPathProvider(sandbox),
                cancellationToken: CancellationToken.None);

            Assert.Equal(RouterHostBootstrap.ConfigErrorExitCode, exitCode);
        }
        finally
        {
            Directory.Delete(sandbox, recursive: true);
        }
    }

    [Fact]
    public void Host_assembly_has_no_aspnet_core_or_kestrel_reference()
    {
        Assembly hostAssembly = typeof(RouterHostBootstrap).Assembly;

        foreach (AssemblyName reference in hostAssembly.GetReferencedAssemblies())
        {
            Assert.False(
                reference.Name!.StartsWith("Microsoft.AspNetCore", StringComparison.OrdinalIgnoreCase),
                $"Unexpected ASP.NET Core reference: {reference.Name}");
            Assert.NotEqual("Microsoft.AspNetCore.Server.Kestrel", reference.Name, StringComparer.OrdinalIgnoreCase);
        }
    }
}
