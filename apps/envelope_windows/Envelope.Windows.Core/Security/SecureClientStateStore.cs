using Envelope.Windows.Core.Application;
using Envelope.Windows.Core.Domain;

namespace Envelope.Windows.Core.Security;

/// <summary>
/// Persists the complete Windows client state (identity, contacts, messages,
/// groups, counters, transfers, and pending work) in one authenticated slot.
/// </summary>
public sealed class SecureClientStateStore(
    IWindowsSecureStore secureStore) : IClientStateStore
{
    private readonly IWindowsSecureStore _secureStore =
        secureStore ?? throw new ArgumentNullException(nameof(secureStore));

    public async Task<WindowsClientState> LoadAsync(
        CancellationToken cancellationToken = default)
    {
        var state = await _secureStore.LoadStateAsync<WindowsClientState>(
                SecureStateSlots.WindowsClientState,
                cancellationToken)
            .ConfigureAwait(false) ?? new WindowsClientState();
        state.Validate();
        return state;
    }

    public async Task SaveAsync(
        WindowsClientState state,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(state);
        state.Validate();
        await _secureStore.SaveStateAsync(
                SecureStateSlots.WindowsClientState,
                state,
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        _ = await _secureStore.DeleteStateAsync(
                SecureStateSlots.WindowsClientState,
                cancellationToken)
            .ConfigureAwait(false);
    }
}
