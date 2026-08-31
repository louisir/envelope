namespace Envelope.Windows.Core.Security;

public sealed class SecureStoreException : Exception
{
    public SecureStoreException(string message)
        : base(message)
    {
    }

    public SecureStoreException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
