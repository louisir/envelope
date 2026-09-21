[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$androidRoot = Join-Path $repoRoot 'apps\envelope_app\android\app\src\main\res'
$destination = Join-Path $repoRoot 'apps\envelope_windows\Envelope.Windows\Resources'
# ICO frames contain Android's original PNG bytes. No redrawing of the brandmark.
$frames = @('mdpi','hdpi','xhdpi','xxhdpi','xxxhdpi') | ForEach-Object {
    $data = [IO.File]::ReadAllBytes((Join-Path $androidRoot "mipmap-$_\ic_launcher.png"))
    $width = ([int]$data[16] -shl 24) -bor ([int]$data[17] -shl 16) -bor ([int]$data[18] -shl 8) -bor [int]$data[19]
    $height = ([int]$data[20] -shl 24) -bor ([int]$data[21] -shl 16) -bor ([int]$data[22] -shl 8) -bor [int]$data[23]
    if ($width -ne $height -or $width -lt 1 -or $width -gt 256) { throw 'Unexpected Android icon dimensions.' }
    [PSCustomObject]@{ Width=$width; Height=$height; Bytes=$data }
}
$buffer = [IO.MemoryStream]::new()
$writer = [IO.BinaryWriter]::new($buffer)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($frame in $frames) {
        $writer.Write([byte]($frame.Width % 256)); $writer.Write([byte]($frame.Height % 256))
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$frame.Bytes.Length); $writer.Write([uint32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
    $writer.Flush()
    [IO.File]::WriteAllBytes((Join-Path $destination 'AppIcon.ico'), $buffer.ToArray())
    Copy-Item -LiteralPath (Join-Path $androidRoot 'mipmap-xxxhdpi\ic_launcher.png') -Destination (Join-Path $destination 'AppIcon.png') -Force
} finally { $writer.Dispose(); $buffer.Dispose() }
