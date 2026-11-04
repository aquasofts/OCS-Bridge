$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sizes = @(256, 128, 64, 48, 32, 16)
$images = @()
foreach ($size in $sizes) {
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.ScaleTransform($size / 256.0, $size / 256.0)
    $shape = [Drawing.Drawing2D.GraphicsPath]::new()
    $shape.AddArc(8, 8, 112, 112, 180, 90)
    $shape.AddArc(136, 8, 112, 112, 270, 90)
    $shape.AddArc(136, 136, 112, 112, 0, 90)
    $shape.AddArc(8, 136, 112, 112, 90, 90)
    $shape.CloseFigure()
    $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#367D76'))
    $graphics.FillPath($brush, $shape)
    $bolt = [Drawing.PointF[]]@(
        [Drawing.PointF]::new(142, 49), [Drawing.PointF]::new(77, 139),
        [Drawing.PointF]::new(119, 139), [Drawing.PointF]::new(108, 207),
        [Drawing.PointF]::new(182, 113), [Drawing.PointF]::new(139, 113)
    )
    $graphics.FillPolygon([Drawing.Brushes]::White, $bolt)
    $png = [IO.MemoryStream]::new()
    $bitmap.Save($png, [Drawing.Imaging.ImageFormat]::Png)
    $images += ,($png.ToArray())
    $png.Dispose(); $brush.Dispose(); $shape.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
$file = [IO.File]::Create((Join-Path $projectRoot 'windows/runner/resources/app_icon.ico'))
$writer = [IO.BinaryWriter]::new($file)
try {
    $writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($index = 0; $index -lt $sizes.Count; $index++) {
        $dimension = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([UInt16]1); $writer.Write([UInt16]32)
        $writer.Write([UInt32]$images[$index].Length); $writer.Write([UInt32]$offset)
        $offset += $images[$index].Length
    }
    foreach ($png in $images) { $writer.Write([byte[]]$png) }
} finally { $writer.Dispose() }
