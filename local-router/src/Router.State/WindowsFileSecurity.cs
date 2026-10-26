using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.Versioning;

namespace Router.State;

/// <summary>
/// Windows ACL implementation. Non-Windows or unverifiable ACLs fail closed as
/// <see cref="FileSecurityStatus.Unknown"/>. Only the current user is granted
/// access after inheritance is removed.
/// </summary>
public sealed class WindowsFileSecurity : IFileSecurity
{
    private const string EveryoneSid = "S-1-1-0";
    private const string UsersSid = "S-1-5-32-545";
    private const string AuthenticatedUsersSid = "S-1-5-11";

    public FileSecurityStatus GetStatus(string path)
        => GetStatus(path, StatePersistenceOperation.ReadFileSecurity);

    private static FileSecurityStatus GetStatus(string path, StatePersistenceOperation operation)
    {
        if (!OperatingSystem.IsWindows())
        {
            return FileSecurityStatus.Unknown;
        }

        try
        {
            FileSecurity security = new FileInfo(path).GetAccessControl();
            bool protectedRules = security.AreAccessRulesProtected;
            bool broadWrite = HasBroadWriteAccess(security);

            return protectedRules && !broadWrite
                ? FileSecurityStatus.Protected
                : FileSecurityStatus.Unprotected;
        }
        catch (Exception error)
        {
            StatePersistenceDiagnostic.Report(path, operation, error);
            return FileSecurityStatus.Unknown;
        }
    }

    public FileSecurityStatus ProtectForCurrentUser(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            return FileSecurityStatus.Unknown;
        }

        StatePersistenceOperation operation = StatePersistenceOperation.ReadFileSecurity;
        try
        {
            SecurityIdentifier? currentUser = WindowsIdentity.GetCurrent().User;
            if (currentUser is null)
            {
                return FileSecurityStatus.Unknown;
            }

            FileSecurity security = new FileInfo(path).GetAccessControl();
            operation = StatePersistenceOperation.SetFileSecurity;
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(
                currentUser,
                FileSystemRights.FullControl,
                InheritanceFlags.None,
                PropagationFlags.None,
                AccessControlType.Allow));
            new FileInfo(path).SetAccessControl(security);
            return GetStatus(path, StatePersistenceOperation.VerifyFileSecurity);
        }
        catch (Exception error)
        {
            StatePersistenceDiagnostic.Report(path, operation, error);
            return FileSecurityStatus.Unknown;
        }
    }

    [SupportedOSPlatform("windows")]
    private static bool HasBroadWriteAccess(FileSecurity security)
    {
        return security.GetAccessRules(true, true, typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>()
            .Any(static rule => rule.AccessControlType == AccessControlType.Allow
                && (rule.FileSystemRights & FileSystemRights.Write) != 0
                && IsBroadIdentity(rule.IdentityReference));
    }

    [SupportedOSPlatform("windows")]
    private static bool IsBroadIdentity(IdentityReference identity)
    {
        return identity.Value is { } value
            && (value == EveryoneSid || value == UsersSid || value == AuthenticatedUsersSid);
    }
}
