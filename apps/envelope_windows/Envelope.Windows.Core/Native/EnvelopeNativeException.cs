namespace Envelope.Windows.Core.Native;

public sealed class EnvelopeNativeException : Exception
{
    public EnvelopeNativeException(string message)
        : base(message)
    {
    }

    public EnvelopeNativeException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
