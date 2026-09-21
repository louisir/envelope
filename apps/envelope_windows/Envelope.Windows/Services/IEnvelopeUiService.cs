using Envelope.Windows.Models;

namespace Envelope.Windows.Services;

public enum UiAction
{
    ShowContactQr,
    ScanContactQr,
    PasteContact,
    CreateGroup,
    ManageGroupMembers,
    LeaveGroup,
    AcceptGroupInvitation,
    DeclineGroupInvitation,
    EditContact,
    DeleteContact,
    SendMessage,
    AttachFile,
    OpenAttachment,
    DeleteLocalMessage,
    DeleteSelectedMessages,
    LoadEarlierMessages,
    MarkConversationRead,
    SealOfflineEnvelope,
    ImportEnvelopeFile,
    ImportEnvelopePath,
    PasteEnvelope,
    UnsealEnvelopeText,
    CreateIdentity,
    RecoverIdentity,
    ClearIdentity,
    CopyKeyId,
    ExportBackup,
    RestoreBackup,
    SaveSyncEntry,
    SyncNow,
    ClearFileCache,
    ExportDiagnostics,
    ClearDiagnostics,
    ChangeUnlockCode,
    OpenUserManual,
    OpenSourceRepository,
    OpenLicense,
}

public sealed record UiOperationRequest(
    UiAction Action,
    string? ContextId = null,
    string? Text = null,
    IReadOnlyDictionary<string, string>? Options = null);

public sealed record UiOperationResult(
    bool Succeeded,
    string StatusResourceKey,
    object? Data = null);

public sealed class UiServiceStatusChangedEventArgs(string statusResourceKey) : EventArgs
{
    public string StatusResourceKey { get; } = statusResourceKey;
}

/// <summary>
/// UI-facing application boundary. A production adapter can compose the Core,
/// Native, storage, and networking services without leaking those details into XAML.
/// </summary>
public interface IEnvelopeUiService
{
    event EventHandler<UiServiceStatusChangedEventArgs>? StatusChanged;

    Task<UiWorkspaceSnapshot> LoadAsync(CancellationToken cancellationToken = default);

    Task<UiOperationResult> ExecuteAsync(
        UiOperationRequest request,
        CancellationToken cancellationToken = default);
}
