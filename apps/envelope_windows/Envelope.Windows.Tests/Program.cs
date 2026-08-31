namespace Envelope.Windows.Tests;

internal static class Program
{
    public static async Task<int> Main()
    {
        Console.WriteLine("Envelope.Windows verification harness");
        try
        {
            await NativeSecurityVerification.RunAsync();
            IntroPayloadCodecVerification.Run();
            QrCodeVerification.Run();
            await LocalUnlockCoordinatorVerification.RunAsync();
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
