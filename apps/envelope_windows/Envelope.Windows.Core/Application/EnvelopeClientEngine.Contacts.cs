using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Native;

namespace Envelope.Windows.Core.Application;

public sealed partial class EnvelopeClientEngine
{
    public ContactSummary PreviewContactImport(string contactOrIntroJson)
    {
        var parsed = ParseContactOrIntro(contactOrIntroJson);
        if (parsed.Summary.KeyId == RequireIdentity().KeyId)
            throw new InvalidOperationException("不能把本机身份添加为联系人。");
        return parsed.Summary;
    }

    public async Task<StoredContact> ImportHumanVerifiedContactAsync(
        string contactOrIntroJson,
        string? remark = null,
        CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        var parsed = ParseContactOrIntro(contactOrIntroJson);
        if (parsed.Summary.KeyId == RequireIdentity().KeyId)
            throw new InvalidOperationException("不能把本机身份添加为联系人。");

        var contact = new StoredContact(
            parsed.Summary.KeyId,
            parsed.Summary.DisplayName,
            parsed.Summary.ContactJson,
            string.IsNullOrWhiteSpace(remark) ? null : remark.Trim(),
            parsed.DeviceId,
            parsed.P2pTicket,
            string.IsNullOrWhiteSpace(parsed.P2pTicket)
                ? null
                : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            HumanVerified: true);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            _state.Contacts.RemoveAll(item => item.KeyId == contact.KeyId);
            _state.Contacts.Add(contact);
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
        RaiseStateChanged();
        return contact;
    }

    public async Task SetContactHumanVerificationAsync(
        string keyId,
        bool verified,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var contact = _state.RequireContact(keyId);
            _state.Contacts.Remove(contact);
            _state.Contacts.Add(contact with { HumanVerified = verified });
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
        RaiseStateChanged();
    }

    private (ContactSummary Summary, string? DeviceId, string? P2pTicket) ParseContactOrIntro(
        string contactOrIntroJson)
    {
        try
        {
            return (_native.ParseContact(contactOrIntroJson), null, null);
        }
        catch (EnvelopeNativeException)
        {
            var bundle = _native.VerifyIntroBundle(contactOrIntroJson);
            return (_native.ParseContact(bundle.ContactJson), bundle.DeviceId, bundle.P2pTicket);
        }
    }
}
