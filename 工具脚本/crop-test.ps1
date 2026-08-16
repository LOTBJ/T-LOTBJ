# One-off test for wallpaper crop math + render (run with powershell.exe -STA).
# Mirrors the functions inside dsh-launcher.ps1.
$out = Join-Path $env:TEMP 'crop-test-result.txt'
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s) }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationCore

function Get-CropSourceRect([double]$imgW, [double]$imgH, [double]$sMin, [double]$zoom, [double]$offX, [double]$offY, [double]$vw, [double]$vh) {
    $s = $sMin * $zoom
    $srcX = (-$offX) / $s
    $srcY = (-$offY) / $s
    $srcW = $vw / $s
    $srcH = $vh / $s
    $srcX = [Math]::Max(0.0, [Math]::Min($srcX, $imgW - $srcW))
    $srcY = [Math]::Max(0.0, [Math]::Min($srcY, $imgH - $srcH))
    return [System.Windows.Rect]::new($srcX, $srcY, $srcW, $srcH)
}

# ---- math tests: viewport 480x300, image 1000x2000 ----
$vw = 480.0; $vh = 300.0; $imgW = 1000.0; $imgH = 2000.0
$sMin = [Math]::Max($vw / $imgW, $vh / $imgH)   # 0.48
Say "sMin=$sMin"
$r1 = Get-CropSourceRect $imgW $imgH $sMin 1.0 0 (-330.0) $vw $vh
Say ("r1: x={0} y={1} w={2} h={3}" -f [Math]::Round($r1.X,2), [Math]::Round($r1.Y,2), [Math]::Round($r1.Width,2), [Math]::Round($r1.Height,2))
Say ("r1-in-bounds: {0}" -f (($r1.X -ge -0.01) -and ($r1.Y -ge -0.01) -and ($r1.X + $r1.Width -le $imgW + 0.01) -and ($r1.Y + $r1.Height -le $imgH + 0.01)))
$r2 = Get-CropSourceRect $imgW $imgH $sMin 2.0 0 (-810.0) $vw $vh
Say ("r2: y={0} h={1} in-bounds: {2}" -f [Math]::Round($r2.Y,2), [Math]::Round($r2.Height,2), (($r2.Y -ge -0.01) -and ($r2.Y + $r2.Height -le $imgH + 0.01)))
$r3 = Get-CropSourceRect $imgW $imgH $sMin 1.0 250.0 100.0 $vw $vh   # bad offsets get clamped
Say ("r3-clamped: x={0} y={1} in-bounds: {2}" -f [Math]::Round($r3.X,2), [Math]::Round($r3.Y,2), (($r3.X -ge -0.01) -and ($r3.Y -ge -0.01) -and ($r3.X + $r3.Width -le $imgW + 0.01) -and ($r3.Y + $r3.Height -le $imgH + 0.01)))

# ---- render test: 800x1000 source, top half red, bottom half blue ----
$src = Join-Path $env:TEMP 'crop-src.png'
$bmp = New-Object System.Drawing.Bitmap 800, 1000
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(255, 30, 60, 200))
$g.FillRectangle([System.Drawing.Brushes]::Red, 0, 0, 800, 500)
$g.Dispose()
$bmp.Save($src, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

function Render-WallpaperCrop([string]$srcPath, [System.Windows.Rect]$rect, [string]$outPath, [int]$tw, [int]$th) {
    $fs = [IO.File]::OpenRead($srcPath)
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.StreamSource = $fs
    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.EndInit()
    $fs.Dispose()
    $bi.Freeze()
    $iw = $bi.PixelWidth; $ih = $bi.PixelHeight
    $x = [int][Math]::Floor($rect.X); $y = [int][Math]::Floor($rect.Y)
    $w = [int][Math]::Ceiling($rect.Width); $h = [int][Math]::Ceiling($rect.Height)
    $x = [Math]::Max(0, [Math]::Min($x, $iw - 1))
    $y = [Math]::Max(0, [Math]::Min($y, $ih - 1))
    $w = [Math]::Min($w, $iw - $x); $h = [Math]::Min($h, $ih - $y)
    $cb = New-Object System.Windows.Media.Imaging.CroppedBitmap($bi, (New-Object System.Windows.Int32Rect($x, $y, $w, $h)))
    $cb.Freeze()
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawImage($cb, [System.Windows.Rect]::new(0, 0, $tw, $th))
    $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($tw, $th, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ofs = [IO.File]::Open($outPath, [IO.FileMode]::Create)
    $enc.Save($ofs)
    $ofs.Dispose()
}

$out1 = Join-Path $env:TEMP 'crop-out-blue.png'
$out2 = Join-Path $env:TEMP 'crop-out-red.png'
Render-WallpaperCrop $src ([System.Windows.Rect]::new(0, 500, 800, 500)) $out1 640 400
Render-WallpaperCrop $src ([System.Windows.Rect]::new(0, 0, 800, 500)) $out2 640 400
$chk1 = New-Object System.Drawing.Bitmap($out1)
$chk2 = New-Object System.Drawing.Bitmap($out2)
$p1 = $chk1.GetPixel(320, 200); $p2 = $chk2.GetPixel(320, 200)
Say ("out1 size: {0}x{1} center color: R={2} G={3} B={4} (expect blue-ish)" -f $chk1.Width, $chk1.Height, $p1.R, $p1.G, $p1.B)
Say ("out2 size: {0}x{1} center color: R={2} G={3} B={4} (expect red-ish)" -f $chk2.Width, $chk2.Height, $p2.R, $p2.G, $p2.B)
$chk1.Dispose(); $chk2.Dispose()

[IO.File]::WriteAllLines($out, $lines)
