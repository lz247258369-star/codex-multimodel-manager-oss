using Router.State;

namespace Router.Core.Tests.Fakes;

/// <summary>Configurable file-security fake; never touches a real ACL.</summary>
public sealed class FakeFileSecurity : IFileSecurity
{
    public FileSecurityStatus Status { get; set; } = FileSecurityStatus.Protected;

    public FileSecurityStatus ProtectResult { get; set; } = FileSecurityStatus.Protected;

    public List<string> ProtectCalls { get; } = [];

    public FileSecurityStatus GetStatus(string path) => Status;

    public FileSecurityStatus ProtectForCurrentUser(string path)
    {
        ProtectCalls.Add(path);
        return ProtectResult;
    }
}
