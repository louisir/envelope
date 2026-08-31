using System.Text;
using System.Security.Cryptography;
using System.Windows.Media.Imaging;
using System.Windows.Media;
using Envelope.Windows.Services;

namespace Envelope.Windows.Tests;

internal static class QrCodeVerification
{
    public static void Run()
    {
        var noisySignature = Convert.ToBase64String(RandomNumberGenerator.GetBytes(1_400));
        var payload = IntroPayloadCodec.Encode(
            $"{{\"version\":1,\"signature\":\"{noisySignature}\",\"display_name\":\"二维码😀\"}}");
        var bitmap = QrCodeService.Encode(payload);
        if (bitmap.PixelWidth < 100 || bitmap.PixelHeight < 100)
            throw new InvalidOperationException("QR encoder produced an unexpectedly small bitmap.");

        var file = Path.Combine(Path.GetTempPath(), $"envelope-qr-{Guid.NewGuid():N}.png");
        try
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (var output = File.Create(file)) encoder.Save(output);

            var decoded = QrCodeService.DecodeFile(file);
            if (!string.Equals(payload, decoded, StringComparison.Ordinal))
                throw new InvalidOperationException("QR image roundtrip changed the Android-compatible payload.");
        }
        finally
        {
            if (File.Exists(file)) File.Delete(file);
        }

        Expect<InvalidDataException>(
            () => QrCodeService.Encode(new string('A', QrCodeService.MaximumPayloadUtf8Bytes + 1)),
            "QR payload byte budget");

        var oversizedFile = Path.Combine(Path.GetTempPath(), $"envelope-qr-oversized-{Guid.NewGuid():N}.png");
        var oversizedDimensionFile = Path.Combine(
            Path.GetTempPath(),
            $"envelope-qr-dimension-{Guid.NewGuid():N}.png");
        try
        {
            using (var output = File.Create(oversizedFile))
                output.SetLength(QrCodeService.MaximumImageFileBytes + 1);
            Expect<InvalidDataException>(
                () => QrCodeService.DecodeFile(oversizedFile),
                "QR encoded file-size budget");

            var pixels = new byte[QrCodeService.MaximumImageDimension + 1];
            var oversizedBitmap = BitmapSource.Create(
                QrCodeService.MaximumImageDimension + 1,
                1,
                96,
                96,
                PixelFormats.Gray8,
                null,
                pixels,
                pixels.Length);
            var oversizedEncoder = new PngBitmapEncoder();
            oversizedEncoder.Frames.Add(BitmapFrame.Create(oversizedBitmap));
            using (var output = File.Create(oversizedDimensionFile)) oversizedEncoder.Save(output);
            Expect<InvalidDataException>(
                () => QrCodeService.DecodeFile(oversizedDimensionFile),
                "QR decoded dimension budget");
        }
        finally
        {
            if (File.Exists(oversizedFile)) File.Delete(oversizedFile);
            if (File.Exists(oversizedDimensionFile)) File.Delete(oversizedDimensionFile);
        }

        Console.WriteLine("[PASS] QR image generation/decoding verification");
    }

    private static void Expect<T>(Action action, string label) where T : Exception
    {
        try
        {
            action();
        }
        catch (T)
        {
            return;
        }
        throw new InvalidOperationException($"Verification failed: {label}; expected {typeof(T).Name}.");
    }
}
