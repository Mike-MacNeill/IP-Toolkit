param(
    [string]$SourcePath = (Join-Path $PSScriptRoot "Designer.png"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "IPToolkit.Windows\Assets\IPToolkit.ico"),
    [string]$PreviewPath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

function New-IconFrame([int]$Size, [System.Drawing.Bitmap]$Source) {
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $scale = [Math]::Max($Size / $Source.Width, $Size / $Source.Height)
    $width = [single]($Source.Width * $scale)
    $height = [single]($Source.Height * $scale)
    $destination = [System.Drawing.RectangleF]::new(($Size - $width) / 2, ($Size - $height) / 2, $width, $height)
    $graphics.DrawImage($Source, $destination)
    $graphics.Dispose()
    return $bitmap
}

$source = [System.Drawing.Bitmap]::new($SourcePath)
$frames = @()
foreach ($size in @(256, 128, 64, 48, 32, 16)) {
    $bitmap = New-IconFrame $size $source
    $png = [System.IO.MemoryStream]::new()
    $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $frames += [pscustomobject]@{ Size = $size; Bytes = $png.ToArray() }
    if ($PreviewPath -and $size -eq 512) { $bitmap.Save($PreviewPath, [System.Drawing.Imaging.ImageFormat]::Png) }
    $png.Dispose()
    $bitmap.Dispose()
}

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$stream = [System.IO.MemoryStream]::new()
$writer = [System.IO.BinaryWriter]::new($stream)
$writer.Write([uint16]0)
$writer.Write([uint16]1)
$writer.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($frame in $frames) {
    $dimension = if ($frame.Size -eq 256) { [byte]0 } else { [byte]$frame.Size }
    $writer.Write($dimension)
    $writer.Write($dimension)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$frame.Bytes.Length)
    $writer.Write([uint32]$offset)
    $offset += $frame.Bytes.Length
}
foreach ($frame in $frames) { $writer.Write($frame.Bytes) }
$writer.Flush()
[System.IO.File]::WriteAllBytes($OutputPath, $stream.ToArray())
$writer.Dispose()
$stream.Dispose()

if ($PreviewPath) {
    $preview = New-IconFrame 512 $source
    $preview.Save($PreviewPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $preview.Dispose()
}
$source.Dispose()
Write-Output "Generated icon: $OutputPath"