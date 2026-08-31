using Envelope.Windows.Core.Domain;

namespace Envelope.Windows.Core.Application;

public interface IClientStateStore
{
    Task<WindowsClientState> LoadAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(WindowsClientState state, CancellationToken cancellationToken = default);
    Task ClearAsync(CancellationToken cancellationToken = default);
}
