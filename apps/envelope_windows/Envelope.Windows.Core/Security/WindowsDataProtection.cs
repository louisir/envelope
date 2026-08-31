using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Envelope.Windows.Core.Security;

/// <summary>
/// Dependency-free DPAPI CurrentUser wrapper. The application entropy is a
/// context separator, not a password; account protection is provided by DPAPI.
/// </summary>
internal static class WindowsDataProtection
{
    private const uint CryptprotectUiForbidden = 0x1;
    private static readonly byte[] OptionalEntropy =
        "Envelope.Windows.SecureStore.DPAPI.v1"u8.ToArray();

    public static byte[] Protect(byte[] plaintext)
    {
        ArgumentNullException.ThrowIfNull(plaintext);
        EnsureWindows();

        var input = AllocateBlob(plaintext);
        var entropy = AllocateBlob(OptionalEntropy);
        var output = default(DataBlob);
        try
        {
            if (!CryptProtectData(
                    ref input,
                    "Envelope Windows AES master key",
                    ref entropy,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    CryptprotectUiForbidden,
                    out output))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            return CopyBlob(output);
        }
        finally
        {
            FreeAllocatedBlob(ref input, clear: true);
            FreeAllocatedBlob(ref entropy, clear: false);
            FreeLocalBlob(ref output, clear: false);
        }
    }

    public static byte[] Unprotect(byte[] protectedData)
    {
        ArgumentNullException.ThrowIfNull(protectedData);
        EnsureWindows();

        var input = AllocateBlob(protectedData);
        var entropy = AllocateBlob(OptionalEntropy);
        var output = default(DataBlob);
        var description = IntPtr.Zero;
        try
        {
            if (!CryptUnprotectData(
                    ref input,
                    out description,
                    ref entropy,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    CryptprotectUiForbidden,
                    out output))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            return CopyBlob(output);
        }
        finally
        {
            FreeAllocatedBlob(ref input, clear: false);
            FreeAllocatedBlob(ref entropy, clear: false);
            FreeLocalBlob(ref output, clear: true);
            if (description != IntPtr.Zero)
            {
                LocalFree(description);
            }
        }
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Windows DPAPI secure storage is available only on Windows.");
        }
    }

    private static DataBlob AllocateBlob(byte[] value)
    {
        if (value.Length == 0)
        {
            return default;
        }

        var pointer = Marshal.AllocHGlobal(value.Length);
        Marshal.Copy(value, 0, pointer, value.Length);
        return new DataBlob
        {
            Size = value.Length,
            Data = pointer,
        };
    }

    private static byte[] CopyBlob(DataBlob blob)
    {
        if (blob.Size <= 0 || blob.Data == IntPtr.Zero)
        {
            return [];
        }

        var value = new byte[blob.Size];
        Marshal.Copy(blob.Data, value, 0, value.Length);
        return value;
    }

    private static void FreeAllocatedBlob(ref DataBlob blob, bool clear)
    {
        if (blob.Data == IntPtr.Zero)
        {
            return;
        }

        if (clear && blob.Size > 0)
        {
            for (var index = 0; index < blob.Size; index++)
            {
                Marshal.WriteByte(blob.Data, index, 0);
            }
        }

        Marshal.FreeHGlobal(blob.Data);
        blob = default;
    }

    private static void FreeLocalBlob(ref DataBlob blob, bool clear)
    {
        if (blob.Data != IntPtr.Zero)
        {
            if (clear && blob.Size > 0)
            {
                for (var index = 0; index < blob.Size; index++)
                {
                    Marshal.WriteByte(blob.Data, index, 0);
                }
            }

            LocalFree(blob.Data);
            blob = default;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn,
        string? description,
        ref DataBlob optionalEntropy,
        IntPtr reserved,
        IntPtr prompt,
        uint flags,
        out DataBlob dataOut);

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn,
        out IntPtr description,
        ref DataBlob optionalEntropy,
        IntPtr reserved,
        IntPtr prompt,
        uint flags,
        out DataBlob dataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
