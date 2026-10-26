using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Router.Core.Tests.Fakes;

/// <summary>Locates copied fixtures and the production defaults file in test output.</summary>
public static class TestPaths
{
    public static string DefaultsPath
        => Path.Combine(AppContext.BaseDirectory, "config", "router.defaults.json");

    public static string Fixture(string relativePath)
        => Path.Combine(AppContext.BaseDirectory, "fixtures", "local-router", "v1", relativePath);

    public static string NewSandboxDirectory()
    {
        string path = Path.Combine(Path.GetTempPath(), "lr2-tests-" + Guid.NewGuid().ToString("N"));
        if (Path.Exists(path))
        {
            throw new IOException("Test sandbox destination already exists.");
        }

        if (OperatingSystem.IsWindows())
        {
            CreatePrivateWindowsDirectory(path);
        }
        else
        {
            Directory.CreateDirectory(path);
        }

        return path;
    }

    [SupportedOSPlatform("windows")]
    private static void CreatePrivateWindowsDirectory(string path)
    {
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        SecurityIdentifier user = identity.User
            ?? throw new IOException("Test sandbox requires a verifiable current-user identity.");
        DirectorySecurity security = new();
        security.SetOwner(user);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            user,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        // Supply the private descriptor during creation. Never repair an
        // inherited ACL on an existing directory or expose a new broad sandbox.
        new DirectoryInfo(path).Create(security);
    }
}
