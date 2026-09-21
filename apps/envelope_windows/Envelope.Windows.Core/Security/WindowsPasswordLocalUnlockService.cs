using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace Envelope.Windows.Core.Security;

/// <summary>Native Windows Security password prompt, authenticated locally against the current Windows SID.</summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsPasswordLocalUnlockService : ILocalUnlockService
{
    private const string Provider = "Windows Security account password";
    private const uint ErrorCancelled = 1223;

    public Task<LocalUnlockAvailability> GetAvailabilityAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new LocalUnlockAvailability(LocalUnlockAvailabilityStatus.Available,
            Provider, "使用当前 Windows 账户密码验证身份。"));
    }

    public Task<LocalUnlockResult> VerifyAsync(string message, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(message);
        return Task.Run(() => Verify(message, cancellationToken), CancellationToken.None);
    }

    private static LocalUnlockResult Verify(string message, CancellationToken cancellationToken)
    {
        IntPtr packed = IntPtr.Zero;
        uint packedSize = 0;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var current = WindowsIdentity.GetCurrent();
            if (current.User is null) return Failure("无法识别当前 Windows 用户。");
            var info = new CredUiInfo { Size = Marshal.SizeOf<CredUiInfo>(), Caption = "Envelope · 解锁",
                Message = message + "\n请输入当前 Windows 账户（" + current.Name + "）的登录密码。" };
            uint package = 0;
            // Windows owns the prompt. No save checkbox or custom password controls.
            var result = CredUIPromptForWindowsCredentials(ref info, 0, ref package,
                IntPtr.Zero, 0, out packed, out packedSize, IntPtr.Zero, 0x200 | 0x1000);
            if (result == ErrorCancelled) return new(LocalUnlockVerificationStatus.Canceled, Provider, "已取消 Windows 身份验证，本地内容仍保持锁定。");
            if (result != 0) return Failure("无法打开 Windows 安全验证窗口：" + new Win32Exception((int)result).Message, (int)result);
            cancellationToken.ThrowIfCancellationRequested();

            uint userLength = 0, domainLength = 0, passwordLength = 0;
            _ = CredUnPackAuthenticationBuffer(1, packed, packedSize, IntPtr.Zero, ref userLength,
                IntPtr.Zero, ref domainLength, IntPtr.Zero, ref passwordLength);
            var unpackError = Marshal.GetLastWin32Error();
            if (unpackError != 122 || userLength == 0 || passwordLength == 0 ||
                userLength > 65536 || domainLength > 65536 || passwordLength > 65536)
                return Failure("无法读取系统返回的账户凭据。", unpackError);
            using var user = new SensitiveBuffer(userLength);
            using var domain = new SensitiveBuffer(Math.Max(1, domainLength));
            using var password = new SensitiveBuffer(passwordLength);
            if (!CredUnPackAuthenticationBuffer(1, packed, packedSize, user.Pointer, ref userLength,
                domain.Pointer, ref domainLength, password.Pointer, ref passwordLength))
                return Failure("无法读取系统返回的账户凭据。", Marshal.GetLastWin32Error());
            if (Marshal.ReadInt16(password.Pointer) == 0)
                return Failure("Windows 账户密码不能为空。请先设置 Windows 账户密码或 Windows Hello PIN。");
            // Username/domain are not secrets. Keep the password only in zeroed native buffers.
            var account = Marshal.PtrToStringUni(user.Pointer) ?? string.Empty;
            var authority = Marshal.PtrToStringUni(domain.Pointer);
            var slash = account.IndexOf('\\');
            if (slash >= 0) { authority = account[..slash]; account = account[(slash + 1)..]; }
            if (string.IsNullOrWhiteSpace(authority)) authority = account.Contains('@') ? null : Environment.MachineName;
            if (!LogonUser(account, authority, password.Pointer, 2, 0, out var token))
            {
                var error = Marshal.GetLastWin32Error();
                token?.Dispose();
                return Failure("Windows 账户密码验证失败：" + new Win32Exception(error).Message, error);
            }
            using (token)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!IsCurrentWindowsUser(token, current.User))
                    return Failure("验证的账户不是当前运行 Envelope 的 Windows 用户。请使用 " + current.Name + "。", 5);
            }
            return new(LocalUnlockVerificationStatus.Verified, Provider, "当前 Windows 用户验证通过。");
        }
        catch (OperationCanceledException) { return new(LocalUnlockVerificationStatus.Canceled, Provider, "已取消身份验证，本地内容仍保持锁定。"); }
        catch (Exception error) { return new(LocalUnlockVerificationStatus.Error, Provider, "Windows 账户验证失败。", error.HResult); }
        finally
        {
            if (packed != IntPtr.Zero) { Zero(packed, packedSize); Marshal.FreeCoTaskMem(packed); }
        }
    }

    private static LocalUnlockResult Failure(string detail, int? error = null) =>
        new(LocalUnlockVerificationStatus.Error, Provider, detail,
            error is > 0 ? unchecked((int)(0x80070000u | ((uint)error.Value & 0xffff))) : error);

    private static bool IsCurrentWindowsUser(SafeAccessTokenHandle token, SecurityIdentifier expected)
    {
        using var authenticated = new WindowsIdentity(token.DangerousGetHandle());
        return authenticated.User is { } sid && sid.Equals(expected);
    }

    private static void Zero(IntPtr buffer, uint bytes)
    {
        for (uint i = 0; i < bytes; i++) Marshal.WriteByte(buffer, checked((int)i), 0);
    }

    private sealed class SensitiveBuffer : IDisposable
    {
        private readonly uint _bytes;
        public IntPtr Pointer { get; }
        public SensitiveBuffer(uint characters) { _bytes = checked(characters * 2); Pointer = Marshal.AllocCoTaskMem(checked((int)_bytes)); Zero(Pointer, _bytes); }
        public void Dispose() { Zero(Pointer, _bytes); Marshal.FreeCoTaskMem(Pointer); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CredUiInfo { public int Size; public IntPtr Parent; public string Message; public string Caption; public IntPtr Banner; }
    [DllImport("credui.dll", EntryPoint = "CredUIPromptForWindowsCredentialsW", CharSet = CharSet.Unicode)]
    private static extern uint CredUIPromptForWindowsCredentials(ref CredUiInfo info, uint error, ref uint package,
        IntPtr input, uint inputSize, out IntPtr output, out uint outputSize, IntPtr save, uint flags);
    [DllImport("credui.dll", EntryPoint = "CredUnPackAuthenticationBufferW", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredUnPackAuthenticationBuffer(uint flags, IntPtr buffer, uint size,
        IntPtr user, ref uint userSize, IntPtr domain, ref uint domainSize, IntPtr password, ref uint passwordSize);
    [DllImport("advapi32.dll", EntryPoint = "LogonUserW", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LogonUser(string user, string? domain, IntPtr password, int logonType, int provider, out SafeAccessTokenHandle token);
}
