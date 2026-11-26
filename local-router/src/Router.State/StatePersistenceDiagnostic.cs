using System.ComponentModel;
using System.Globalization;
using System.Security;

namespace Router.State;

/// <summary>Fixed operation names for content-free persistence failure diagnostics.</summary>
public enum StatePersistenceOperation
{
    CreateDirectory,
    CreateTempPath,
    WriteAllBytes,
    FileExists,
    MoveFile,
    ReplaceFile,
    ReadAllBytes,
    CopyFile,
    DeleteFile,
    ReadFileSecurity,
    SetFileSecurity,
    VerifyFileSecurity,
}

/// <summary>
/// Reports the failing operation and native error without paths, identities,
/// exception messages, request content, or provider data. This is diagnostic
/// output only; it does not change persistence or ACL authorization.
/// </summary>
public static class StatePersistenceDiagnostic
{
    public static string Describe(string targetPath, StatePersistenceOperation operation, Exception error)
    {
        ArgumentNullException.ThrowIfNull(error);

        int nativeCode = error is Win32Exception native
            ? native.NativeErrorCode
            : ((unchecked((uint)error.HResult) >> 16) & 0x1fff) == 7
                ? error.HResult & 0xffff
                : 0;
        string category = nativeCode switch
        {
            32 => "sharing_violation",
            5 => "access_denied",
            // OSS-M4-2-HOTFIX2-FIX1: ERROR_UNABLE_TO_REMOVE_REPLACED, reported as
            // itself; it is not a confirmed sharing violation.
            1175 => "unable_to_remove_replaced",
            _ => "unknown",
        };
        string cause = error switch
        {
            Win32Exception => "Win32Exception",
            UnauthorizedAccessException => "UnauthorizedAccessException",
            IOException => "IOException",
            OperationCanceledException => "OperationCanceledException",
            ArgumentException => "ArgumentException",
            PlatformNotSupportedException => "PlatformNotSupportedException",
            NotSupportedException => "NotSupportedException",
            SecurityException => "SecurityException",
            _ => "Exception",
        };
        string operationName = operation switch
        {
            StatePersistenceOperation.CreateDirectory => "CreateDirectory",
            StatePersistenceOperation.CreateTempPath => "CreateTempPath",
            StatePersistenceOperation.WriteAllBytes => "WriteAllBytes",
            StatePersistenceOperation.FileExists => "FileExists",
            StatePersistenceOperation.MoveFile => "MoveFile",
            StatePersistenceOperation.ReplaceFile => "ReplaceFile",
            StatePersistenceOperation.ReadAllBytes => "ReadAllBytes",
            StatePersistenceOperation.CopyFile => "CopyFile",
            StatePersistenceOperation.DeleteFile => "DeleteFile",
            StatePersistenceOperation.ReadFileSecurity => "ReadFileSecurity",
            StatePersistenceOperation.SetFileSecurity => "SetFileSecurity",
            StatePersistenceOperation.VerifyFileSecurity => "VerifyFileSecurity",
            _ => "Unknown",
        };
        return string.Create(CultureInfo.InvariantCulture,
            $"[local-router] state_persistence_failed: target={TargetRole(targetPath)} operation={operationName} cause={cause} hresult={error.HResult:x8} native={nativeCode} category={category}.");
    }

    public static void Report(string targetPath, StatePersistenceOperation operation, Exception error)
    {
        try
        {
            Console.Error.WriteLine(Describe(targetPath, operation, error));
        }
        catch
        {
            // Diagnostics cannot replace the original failure or authorize work.
        }
    }

    private static string TargetRole(string path)
    {
        if (string.IsNullOrEmpty(path)) { return "managed_file"; }
        string name = path[(path.LastIndexOfAny(['\\', '/']) + 1)..];
        if (name.Equals("router.pid.json", StringComparison.OrdinalIgnoreCase)) { return "owner_record"; }
        if (name.Equals("router.state.json", StringComparison.OrdinalIgnoreCase)) { return "runtime_state"; }
        return "managed_file";
    }
}
