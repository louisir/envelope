using System.Runtime.InteropServices;

namespace Envelope.Windows.Core.Security;

internal enum UserConsentVerifierAvailability
{
    Available = 0,
    DeviceNotPresent = 1,
    NotConfiguredForUser = 2,
    DisabledByPolicy = 3,
    DeviceBusy = 4,
}

internal enum UserConsentVerificationResult
{
    Verified = 0,
    DeviceNotPresent = 1,
    NotConfiguredForUser = 2,
    DisabledByPolicy = 3,
    DeviceBusy = 4,
    RetriesExhausted = 5,
    Canceled = 6,
}

/// <summary>
/// Minimal ABI projection derived from the inbox Windows SDK metadata for
/// IUserConsentVerifierStatics and IAsyncInfo. It intentionally projects only
/// the two UserConsentVerifier operations needed by Envelope.
/// </summary>
internal static class UserConsentVerifierAbi
{
    private const string RuntimeClassName =
        "Windows.Security.Credentials.UI.UserConsentVerifier";
    private const int RpcEChangedMode = unchecked((int)0x80010106);
    private static readonly Guid UserConsentVerifierStaticsIid =
        new("AF4F3F91-564C-4DDC-B8B5-973447627C65");
    private static readonly Guid AsyncInfoIid =
        new("00000036-0000-0000-C000-000000000046");

    public static Task<UserConsentVerifierAvailability> CheckAvailabilityAsync(
        CancellationToken cancellationToken) => Task.Run(
        () => InvokeAvailability(cancellationToken),
        CancellationToken.None);

    public static Task<UserConsentVerificationResult> RequestVerificationAsync(
        string message,
        CancellationToken cancellationToken) => Task.Run(
        () => InvokeVerification(message, cancellationToken),
        CancellationToken.None);

    private static UserConsentVerifierAvailability InvokeAvailability(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var apartment = RoApartment.Initialize();
        var factory = GetActivationFactory();
        try
        {
            var call = GetDelegate<CheckAvailabilityAsyncDelegate>(factory, 6);
            var result = call(factory, out var operation);
            if (result < 0)
            {
                if (operation != IntPtr.Zero)
                {
                    Marshal.Release(operation);
                }

                ThrowIfFailed(result);
            }

            return (UserConsentVerifierAvailability)WaitForInt32Result(
                operation,
                cancellationToken);
        }
        finally
        {
            Marshal.Release(factory);
        }
    }

    private static UserConsentVerificationResult InvokeVerification(
        string message,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var apartment = RoApartment.Initialize();
        var factory = GetActivationFactory();
        var messageHandle = CreateHString(message);
        try
        {
            var call = GetDelegate<RequestVerificationAsyncDelegate>(factory, 7);
            var result = call(factory, messageHandle, out var operation);
            if (result < 0)
            {
                if (operation != IntPtr.Zero)
                {
                    Marshal.Release(operation);
                }

                ThrowIfFailed(result);
            }

            return (UserConsentVerificationResult)WaitForInt32Result(
                operation,
                cancellationToken);
        }
        finally
        {
            WindowsDeleteString(messageHandle);
            Marshal.Release(factory);
        }
    }

    private static IntPtr GetActivationFactory()
    {
        var runtimeClass = CreateHString(RuntimeClassName);
        try
        {
            var iid = UserConsentVerifierStaticsIid;
            ThrowIfFailed(RoGetActivationFactory(runtimeClass, ref iid, out var factory));
            if (factory == IntPtr.Zero)
            {
                throw new COMException(
                    "UserConsentVerifier activation factory returned null.",
                    unchecked((int)0x80004005));
            }

            return factory;
        }
        finally
        {
            WindowsDeleteString(runtimeClass);
        }
    }

    private static int WaitForInt32Result(
        IntPtr operation,
        CancellationToken cancellationToken)
    {
        if (operation == IntPtr.Zero)
        {
            throw new COMException(
                "UserConsentVerifier returned a null async operation.",
                unchecked((int)0x80004005));
        }

        var asyncInfo = IntPtr.Zero;
        try
        {
            var iid = AsyncInfoIid;
            ThrowIfFailed(Marshal.QueryInterface(operation, in iid, out asyncInfo));
            var getStatus = GetDelegate<GetAsyncStatusDelegate>(asyncInfo, 7);
            var getError = GetDelegate<GetAsyncErrorDelegate>(asyncInfo, 8);
            var cancel = GetDelegate<AsyncControlDelegate>(asyncInfo, 9);
            var close = GetDelegate<AsyncControlDelegate>(asyncInfo, 10);

            try
            {
                while (true)
                {
                    if (cancellationToken.IsCancellationRequested)
                    {
                        _ = cancel(asyncInfo);
                        cancellationToken.ThrowIfCancellationRequested();
                    }

                    ThrowIfFailed(getStatus(asyncInfo, out var status));
                    switch (status)
                    {
                        case AsyncStatus.Started:
                            if (cancellationToken.WaitHandle.WaitOne(25))
                            {
                                _ = cancel(asyncInfo);
                                cancellationToken.ThrowIfCancellationRequested();
                            }
                            break;
                        case AsyncStatus.Completed:
                            var getResults = GetDelegate<GetInt32ResultsDelegate>(operation, 8);
                            ThrowIfFailed(getResults(operation, out var result));
                            return result;
                        case AsyncStatus.Canceled:
                            throw new OperationCanceledException(
                                "Windows UserConsentVerifier operation was canceled.",
                                cancellationToken);
                        case AsyncStatus.Error:
                            ThrowIfFailed(getError(asyncInfo, out var errorCode));
                            throw new COMException(
                                "Windows UserConsentVerifier operation failed.",
                                errorCode);
                        default:
                            throw new COMException(
                                $"Windows returned an unknown async status: {(int)status}.",
                                unchecked((int)0x80004005));
                    }
                }
            }
            finally
            {
                _ = close(asyncInfo);
            }
        }
        finally
        {
            if (asyncInfo != IntPtr.Zero)
            {
                Marshal.Release(asyncInfo);
            }

            Marshal.Release(operation);
        }
    }

    private static IntPtr CreateHString(string value)
    {
        ThrowIfFailed(WindowsCreateString(value, checked((uint)value.Length), out var handle));
        return handle;
    }

    private static TDelegate GetDelegate<TDelegate>(IntPtr instance, int slot)
        where TDelegate : Delegate
    {
        var vtable = Marshal.ReadIntPtr(instance);
        if (vtable == IntPtr.Zero)
        {
            throw new COMException("Windows Runtime object has a null vtable.");
        }

        var address = Marshal.ReadIntPtr(vtable, checked(slot * IntPtr.Size));
        if (address == IntPtr.Zero)
        {
            throw new COMException("Windows Runtime method has a null address.");
        }

        return Marshal.GetDelegateForFunctionPointer<TDelegate>(address);
    }

    private static void ThrowIfFailed(int hresult)
    {
        if (hresult < 0)
        {
            Marshal.ThrowExceptionForHR(hresult);
        }
    }

    private enum AsyncStatus
    {
        Started = 0,
        Completed = 1,
        Canceled = 2,
        Error = 3,
    }

    private readonly struct RoApartment(bool uninitialize) : IDisposable
    {
        private readonly bool _uninitialize = uninitialize;

        public static RoApartment Initialize()
        {
            var result = RoInitialize(1); // RO_INIT_MULTITHREADED
            if (result < 0 && result != RpcEChangedMode)
            {
                ThrowIfFailed(result);
            }

            return new RoApartment(result >= 0);
        }

        public void Dispose()
        {
            if (_uninitialize)
            {
                RoUninitialize();
            }
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int CheckAvailabilityAsyncDelegate(
        IntPtr @this,
        out IntPtr operation);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int RequestVerificationAsyncDelegate(
        IntPtr @this,
        IntPtr message,
        out IntPtr operation);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetAsyncStatusDelegate(
        IntPtr @this,
        out AsyncStatus status);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetAsyncErrorDelegate(
        IntPtr @this,
        out int errorCode);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int AsyncControlDelegate(IntPtr @this);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetInt32ResultsDelegate(
        IntPtr @this,
        out int result);

    [DllImport("combase.dll")]
    private static extern int RoInitialize(uint initType);

    [DllImport("combase.dll")]
    private static extern void RoUninitialize();

    [DllImport("combase.dll")]
    private static extern int RoGetActivationFactory(
        IntPtr activatableClassId,
        ref Guid iid,
        out IntPtr factory);

    [DllImport("combase.dll", CharSet = CharSet.Unicode)]
    private static extern int WindowsCreateString(
        string source,
        uint length,
        out IntPtr value);

    [DllImport("combase.dll")]
    private static extern int WindowsDeleteString(IntPtr value);
}
