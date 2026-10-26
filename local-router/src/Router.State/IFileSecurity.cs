namespace Router.State;

/// <summary>Result of a file security (ACL) inspection or hardening attempt.</summary>
public enum FileSecurityStatus
{
    Protected = 0,
    Unprotected = 1,
    Unknown = 2,
}

/// <summary>
/// File security abstraction. Tests inject fakes; production never modifies a
/// real user ACL outside the sandbox paths passed by callers.
/// </summary>
public interface IFileSecurity
{
    FileSecurityStatus GetStatus(string path);

    FileSecurityStatus ProtectForCurrentUser(string path);
}
