using System.IO;
using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QRCoder;
using ZXing;
using ZXing.Common;

namespace Envelope.Windows.Services;

internal static class QrCodeService
{
    internal const int MaximumPayloadUtf8Bytes = 2_900;
    internal const long MaximumImageFileBytes = 32L * 1024 * 1024;
    internal const int MaximumImageDimension = 4_096;
    internal const long MaximumDecodedPixels = 16L * 1024 * 1024;
    internal const int MaximumImageFrames = 16;

    public static BitmapSource Encode(string payload)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(payload);
        var payloadBytes = Encoding.UTF8.GetByteCount(payload);
        if (payloadBytes > MaximumPayloadUtf8Bytes)
            throw new InvalidDataException(
                $"二维码载荷为 {payloadBytes} UTF-8 bytes，超过 {MaximumPayloadUtf8Bytes} bytes 安全上限。");

        using var generator = new QRCodeGenerator();
        QRCodeData data;
        try
        {
            data = generator.CreateQrCode(
                payload,
                QRCodeGenerator.ECCLevel.L,
                forceUtf8: true,
                utf8BOM: false);
        }
        catch (Exception error) when (error.GetType().Name.Contains("DataTooLong", StringComparison.Ordinal))
        {
            throw new InvalidDataException("二维码载荷超过 QR Code Version 40-L 容量。", error);
        }
        using (data)
        {
            using var code = new PngByteQRCode(data);
            var png = code.GetGraphic(8, drawQuietZones: true);
            using var stream = new MemoryStream(png, writable: false);
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.StreamSource = stream;
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
    }

    public static string DecodeFile(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var file = new FileInfo(path);
        if (!file.Exists) throw new FileNotFoundException("二维码图片不存在。", path);
        if (file.Length <= 0 || file.Length > MaximumImageFileBytes)
            throw new InvalidDataException(
                $"二维码图片大小必须在 1 byte 到 {MaximumImageFileBytes / (1024 * 1024)} MiB 之间。");

        using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var decoder = BitmapDecoder.Create(
            stream,
            BitmapCreateOptions.PreservePixelFormat | BitmapCreateOptions.DelayCreation,
            BitmapCacheOption.OnDemand);
        if (decoder.Frames.Count == 0)
            throw new InvalidDataException("图片不包含可解码的图像帧。");
        if (decoder.Frames.Count > MaximumImageFrames)
            throw new InvalidDataException($"二维码图片帧数超过 {MaximumImageFrames} 帧安全上限。");

        foreach (var frame in decoder.Frames)
        {
            ValidateDimensions(frame.PixelWidth, frame.PixelHeight);
            var value = DecodeBitmap(frame);
            if (!string.IsNullOrWhiteSpace(value)) return value;
        }
        throw new InvalidDataException("图片中没有识别到 Envelope 二维码。");
    }

    private static string? DecodeBitmap(BitmapSource source)
    {
        ValidateDimensions(source.PixelWidth, source.PixelHeight);
        var converted = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        converted.Freeze();
        var stride = checked(converted.PixelWidth * 4);
        var pixels = new byte[checked(stride * converted.PixelHeight)];
        converted.CopyPixels(pixels, stride, 0);

        var luminance = new RGBLuminanceSource(
            pixels,
            converted.PixelWidth,
            converted.PixelHeight,
            RGBLuminanceSource.BitmapFormat.BGRA32);
        var reader = new BarcodeReaderGeneric
        {
            AutoRotate = true,
            Options = new DecodingOptions
            {
                TryHarder = true,
                PossibleFormats = [BarcodeFormat.QR_CODE],
            },
        };
        return reader.Decode(luminance)?.Text;
    }

    private static void ValidateDimensions(int width, int height)
    {
        if (width <= 0 || height <= 0 ||
            width > MaximumImageDimension || height > MaximumImageDimension ||
            checked((long)width * height) > MaximumDecodedPixels)
            throw new InvalidDataException(
                $"二维码图片尺寸 {width}x{height} 超出解码安全上限。");
    }
}
