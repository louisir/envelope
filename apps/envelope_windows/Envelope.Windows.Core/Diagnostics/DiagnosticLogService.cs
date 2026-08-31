using System.Text.Json;

namespace Envelope.Windows.Core.Diagnostics;

/// <summary>
/// Writes one JSON object per line. Callers must never put plaintext messages,
/// file contents, recovery phrases, private identities, or storage keys in fields.
/// </summary>
public sealed class DiagnosticLogService
{
    private readonly string _directory;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly JsonSerializerOptions _json = new(JsonSerializerDefaults.Web);

    public DiagnosticLogService(string directory)
    {
        _directory = directory;
    }

    public async Task WriteAsync(
        string level,
        string eventName,
        IReadOnlyDictionary<string, object?>? fields = null,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(_directory);
        var record = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["timestamp"] = DateTimeOffset.UtcNow,
            ["level"] = level,
            ["event"] = eventName,
            ["platform"] = "windows",
        };
        if (fields is not null)
        {
            foreach (var (key, value) in fields)
            {
                EnsureSafeFieldName(key);
                record[key] = value;
            }
        }

        var line = JsonSerializer.Serialize(record, _json) + Environment.NewLine;
        var path = Path.Combine(_directory, $"envelope-{DateTime.UtcNow:yyyyMMdd}.jsonl");
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await File.AppendAllTextAsync(path, line, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Clear()
    {
        if (!Directory.Exists(_directory))
        {
            return;
        }

        foreach (var file in Directory.EnumerateFiles(_directory, "envelope-*.jsonl"))
        {
            File.Delete(file);
        }
    }

    public string ExportTo(string outputDirectory)
    {
        Directory.CreateDirectory(outputDirectory);
        var output = Path.Combine(outputDirectory, $"envelope-diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}");
        Directory.CreateDirectory(output);
        if (Directory.Exists(_directory))
        {
            foreach (var file in Directory.EnumerateFiles(_directory, "envelope-*.jsonl"))
            {
                File.Copy(file, Path.Combine(output, Path.GetFileName(file)), overwrite: true);
            }
        }
        return output;
    }

    private static void EnsureSafeFieldName(string name)
    {
        var normalized = name.Replace("-", "_", StringComparison.Ordinal).ToLowerInvariant();
        var forbidden = new[] { "text", "content", "payload", "private", "identity_json", "recovery", "password", "secret", "key_material" };
        if (forbidden.Any(normalized.Contains))
        {
            throw new ArgumentException($"诊断字段可能包含敏感数据，已拒绝：{name}", nameof(name));
        }
    }
}
