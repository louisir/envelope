namespace Envelope.Windows.Tests;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        // Explicit manual smoke test only; never prompt for credentials in the automated suite.
        if (args.SequenceEqual(new[] { "--verify-local-unlock" }))
        {
            var service = new Envelope.Windows.Core.Security.FallbackLocalUnlockService(
                new Envelope.Windows.Core.Security.WindowsHelloLocalUnlockService(),
                new Envelope.Windows.Core.Security.WindowsPasswordLocalUnlockService());
            var result = await service.VerifyAsync("Envelope 解锁验证测试（仅验证当前 Windows 用户，不访问应用数据）");
            Console.WriteLine($"Verification={result.Status}; Provider={result.Provider}; HResult={result.HResult:X8}");
            return result.IsVerified ? 0 : 2;
        }
        Console.WriteLine("Envelope.Windows verification harness");
        try
        {
            await HaProtocolVerification.RunAsync();
            await NativeSecurityVerification.RunAsync();
            IntroPayloadCodecVerification.Run();
            QrCodeVerification.Run();
            await LocalUnlockCoordinatorVerification.RunAsync();
            await LocalUnlockFallbackVerification.RunAsync();
            await AppPasscodeVerification.RunAsync();
            await ExternalLaunchRequestVerification.RunAsync();
            await DomainFileStateVerification.RunAsync();
            await DeliveryReliabilityVerification.RunAsync();
            await OfflineGroupStreamVerification.RunAsync();
            await GroupSenderCandidateVerification.RunAsync();
            await GroupEngineVerification.RunAsync();
            await NetworkingVerification.RunAsync();
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"[FAIL] {error}");
            return 1;
        }
    }
}
