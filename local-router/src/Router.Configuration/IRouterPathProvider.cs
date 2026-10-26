namespace Router.Configuration;

/// <summary>
/// Approved path layout for the Local Router. Production resolves under the
/// existing Manager home and backup conventions; tests inject sandbox paths.
/// </summary>
public interface IRouterPathProvider
{
    string DefaultsPath { get; }

    string UserConfigPath { get; }

    string RuntimeStatePath { get; }

    string OwnerRecordPath { get; }

    string BackupRootPath { get; }

    string QuarantineRootPath { get; }

    string MigrationReceiptDirectory { get; }
}
