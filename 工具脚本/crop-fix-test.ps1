# Verify: (1) Get-WallpaperPlan decisions (copy/scale/pad/crop)
#         (2) dialog OK/Cancel closes (plain scriptblock pattern)
#         (3) bridge JS survives the launcher's style-ts refresh (pitfall #35 regression)
#         (4) pad render: white canvas + centered native-size image + center-cropped overhang
$out = Join-Path $env:TEMP 'crop-fix-result.txt'
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s) }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Windows.Forms

# ---- (1) plan decisions ----
function Get-ImageNativeSize([string]$path) {
    try {
        $img = [System.Drawing.Image]::FromFile($path)
        $w = $img.Width; $h = $img.Height
        $img.Dispose()
        return @{ w = [double]$w; h = [double]$h }
    } catch { return $null }
}
function Get-WallpaperPlan([string]$srcPath) {
    $native = Get-ImageNativeSize $srcPath
    if ($null -eq $native) { return @{ mode = 'scale'; up = $false } }
    $iw = $native.w; $ih = $native.h
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $tw = [double]$scr.Width; $th = [double]$scr.Height
    $ratioDiff = [Math]::Abs(($iw / $ih) - ($tw / $th)) / ($tw / $th)
    $isPng = ([System.IO.Path]::GetExtension($srcPath)).ToLower() -eq '.png'
    $fitSize = ($iw -le $tw * 1.05) -and ($ih -le $th * 1.05) -and ($iw -ge $tw * 0.85) -and ($ih -ge $th * 0.85)
    $covers = ($iw -ge $tw * 0.98) -and ($ih -ge $th * 0.98)
    if ($ratioDiff -lt 0.03) {
        if ($fitSize -and $isPng) { return @{ mode = 'copy' } }
        if ($covers) { return @{ mode = 'scale'; up = $false } }
        return @{ mode = 'pad' }
    }
    if ($covers) { return @{ mode = 'crop' } }
    return @{ mode = 'pad' }
}
function Make-Png([string]$path, [int]$w, [int]$h, [System.Drawing.Color]$c) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($c)
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
$blue = [System.Drawing.Color]::FromArgb(255, 30, 60, 200)
$p1 = Join-Path $env:TEMP 'plan-2000x1250.png'; Make-Png $p1 2000 1250 $blue
$p2 = Join-Path $env:TEMP 'plan-800x500.png';   Make-Png $p2 800 500 $blue
$p3 = Join-Path $env:TEMP 'plan-4000x2500.png'; Make-Png $p3 4000 2500 $blue
$p4 = Join-Path $env:TEMP 'plan-1000x2000.png'; Make-Png $p4 1000 2000 $blue
$p5 = Join-Path $env:TEMP 'plan-3000x1800.png'; Make-Png $p5 3000 1800 $blue
$p6 = Join-Path $env:TEMP 'plan-2500x800.png';  Make-Png $p6 2500 800 $blue
Say ("screen: {0}x{1}" -f [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)
$d1 = Get-WallpaperPlan $p1; Say ("2000x1250 near-fit -> {0} (expect copy)" -f $d1.mode)
$d2 = Get-WallpaperPlan $p2; Say ("800x500 small -> {0} (expect pad)" -f $d2.mode)
$d3 = Get-WallpaperPlan $p3; Say ("4000x2500 big same-ratio -> {0} (expect scale)" -f $d3.mode)
$d4 = Get-WallpaperPlan $p4; Say ("1000x2000 portrait small-ish -> {0} (expect pad)" -f $d4.mode)
$d5 = Get-WallpaperPlan $p5; Say ("3000x1800 big diff-ratio -> {0} (expect crop)" -f $d5.mode)
$d6 = Get-WallpaperPlan $p6; Say ("2500x800 wide short -> {0} (expect pad)" -f $d6.mode)

# ---- (3) bridge corruption regression ----
$htmlFake = '<!doctype html><html><head>' + "`n" +
'    <style id="dsh-wallpaper-css">' + "`n" +
'      body{background:url(/wallpaper/current.png?t=111) center/cover no-repeat fixed !important;}' + "`n" +
'    </style>' + "`n" +
'    <script id="dsh-wallpaper-bridge">' + "`n" +
"      (function(){try{var s=document.getElementById('dsh-wallpaper-css');if(!s)return;var txt=s.textContent;var k='dsh.wallpaper.center.ts';var ok='dsh.wallpaper.center.original';if(txt.indexOf('dsh-original')>=0){return;}var i=txt.indexOf('wallpaper/current.png?t=');if(i<0)return;var j=txt.indexOf(')',i);var t=txt.substring(i+24,j);if(localStorage.getItem(k)===t)return;localStorage.setItem('dsh.ui-aqua.wallpaper','/wallpaper/current.png?t='+t);localStorage.setItem('dsh.ui-aqua.background','wallpaper');localStorage.setItem('dsh.ui-aqua.enabled','true');localStorage.removeItem(ok);localStorage.setItem(k,t);}catch(e){}})();" + "`n" +
'    </script>' + "`n" +
'  </head><body></body></html>'
$ts = [DateTime]::Now.Ticks
$styleRx = [regex]'(?s)(<style id="dsh-wallpaper-css">.*?)wallpaper/current\.png\?t=[^)]*(.*?</style>)'
$updated = $styleRx.Replace($htmlFake, { param($m) $m.Groups[1].Value + "wallpaper/current.png?t=$ts" + $m.Groups[2].Value })
function Test-BridgeOk([string]$t) {
    return ($t.Contains('dsh-wallpaper-bridge') -and
            [regex]::IsMatch($t, "indexOf\('wallpaper/current\.png\?t='\)") -and
            [regex]::IsMatch($t, "'/wallpaper/current\.png\?t='\s*\+\s*t"))
}
Say ("bridge survives style-ts refresh: {0} ts-updated: {1} (expect True/True)" -f (Test-BridgeOk $updated), $updated.Contains("t=$ts"))
# corrupted bridge -> auto repair branch
$corrupted = $htmlFake.Replace("indexOf('wallpaper/current.png?t=')", "indexOf('wallpaper/current.png?t=999)")
if (-not (Test-BridgeOk $corrupted)) {
    $corrupted = [regex]::Replace($corrupted, '(?s)<script id="dsh-wallpaper-bridge">.*?</script>\s*', '')
    $corrupted = $corrupted.Replace('</head>', "    <script id=`"dsh-wallpaper-bridge`">`n      (function(){var k='dsh.wallpaper.center.ts';var i=0;var j=0;var t='';var s=document.getElementById('dsh-wallpaper-css');var txt=s.textContent;var ok='dsh.wallpaper.center.original';if(txt.indexOf('dsh-original')>=0){if(!localStorage.getItem(ok)){localStorage.setItem('dsh.ui-aqua.enabled','false');localStorage.setItem('dsh.ui-aqua.wallpaper','');localStorage.setItem('dsh.ui-aqua.background','fluid');localStorage.removeItem(k);localStorage.setItem(ok,'1');}return;}i=txt.indexOf('wallpaper/current.png?t=');if(i<0)return;j=txt.indexOf(')',i);t=txt.substring(i+24,j);if(localStorage.getItem(k)===t)return;localStorage.setItem('dsh.ui-aqua.wallpaper','/wallpaper/current.png?t='+t);localStorage.setItem('dsh.ui-aqua.background','wallpaper');localStorage.setItem('dsh.ui-aqua.enabled','true');localStorage.removeItem(ok);localStorage.setItem(k,t);}catch(e){}})();`n    </script>`n  </head>")
}
Say ("corrupted bridge repaired: {0} (expect True)" -f ((Test-BridgeOk $corrupted) -and -not $corrupted.Contains('t=999')))

# ---- (4) pad render pixel test: contain scale + white fill ----
# case A: 400x800 portrait (1:2) -> scale=min(2048/400, 1280/800)=1.6 -> 640x1280, white bars left/right
# case B: 2500x800 wide -> scale=min(2048/2500, 1280/800)=0.8192 -> 2048x655, white bars top/bottom
function Test-Pad([string]$srcImg, [int]$tw, [int]$th, [string]$label, [int[]]$bluePts, [int[]]$whitePts) {
    $fs = [IO.File]::OpenRead($srcImg)
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit(); $bi.StreamSource = $fs; $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bi.EndInit()
    $fs.Dispose(); $bi.Freeze()
    $iw = [double]$bi.PixelWidth; $ih = [double]$bi.PixelHeight
    $scale = [Math]::Min($tw / $iw, $th / $ih)
    $sw = $iw * $scale; $sh = $ih * $scale
    $dx = ($tw - $sw) / 2.0; $dy = ($th - $sh) / 2.0
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawRectangle([System.Windows.Media.Brushes]::White, $null, [System.Windows.Rect]::new(0, 0, $tw, $th))
    $dc.DrawImage($bi, [System.Windows.Rect]::new($dx, $dy, $sw, $sh))
    $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($tw, $th, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $padOut = Join-Path $env:TEMP "pad-out-$label.png"
    $ofs = [IO.File]::Open($padOut, [IO.FileMode]::Create)
    $enc.Save($ofs); $ofs.Dispose()
    $chk = New-Object System.Drawing.Bitmap($padOut)
    $b1 = $chk.GetPixel($bluePts[0], $bluePts[1])
    $w1 = $chk.GetPixel($whitePts[0], $whitePts[1])
    $w2 = $chk.GetPixel($whitePts[2], $whitePts[3])
    Say ("pad {0}: scale={1:N3} dest={2:N0}x{3:N0} blue@({4},{5})={6},{7},{8} white@({9},{10})={11},{12},{13} white@({14},{15})={16},{17},{18}" -f $label, $scale, $sw, $sh, $bluePts[0], $bluePts[1], $b1.R, $b1.G, $b1.B, $whitePts[0], $whitePts[1], $w1.R, $w1.G, $w1.B, $whitePts[2], $whitePts[3], $w2.R, $w2.G, $w2.B)
    $chk.Dispose()
}
Make-Png (Join-Path $env:TEMP 'plan-400x800.png') 400 800 $blue
Make-Png (Join-Path $env:TEMP 'plan-2500x800.png') 2500 800 $blue
Test-Pad (Join-Path $env:TEMP 'plan-400x800.png') 2048 1280 'portrait' @(1024, 640) @(100, 640, 1900, 640)
Test-Pad (Join-Path $env:TEMP 'plan-2500x800.png') 2048 1280 'wide' @(1024, 640) @(1024, 100, 1024, 1200)

# ---- (2) dialog close ----
$script:CropState = @{ result = $null; controls = @{}; imgW = 1.0; imgH = 1.0; sMin = 1.0; zoom = 1.0; offX = 0.0; offY = 0.0; vw = 1.0; vh = 1.0 }
function Get-CropSourceRect([double]$imgW, [double]$imgH, [double]$sMin, [double]$zoom, [double]$offX, [double]$offY, [double]$vw, [double]$vh) {
    return [System.Windows.Rect]::new(1, 2, 3, 4)
}
$dlg = New-Object System.Windows.Window
$dlg.Width = 320; $dlg.Height = 200
$dlg.WindowStyle = [System.Windows.WindowStyle]::ToolWindow
$sp = New-Object System.Windows.Controls.StackPanel
$btnOk = New-Object System.Windows.Controls.Button; $btnOk.Content = 'OK'
$btnCancel = New-Object System.Windows.Controls.Button; $btnCancel.Content = 'Cancel'
$sp.Children.Add($btnOk) | Out-Null
$sp.Children.Add($btnCancel) | Out-Null
$dlg.Content = $sp
$script:CropState.controls['dlg'] = $dlg
$btnCancel.Add_Click({ param($s, $e) $script:CropState.controls['dlg'].DialogResult = $false })
$btnOk.Add_Click({ param($s, $e)
    $st2 = $script:CropState
    $st2.result = Get-CropSourceRect $st2.imgW $st2.imgH $st2.sMin $st2.zoom $st2.offX $st2.offY $st2.vw $st2.vh
    $st2.controls['dlg'].DialogResult = $true
})
$t = New-Object System.Windows.Threading.DispatcherTimer
$t.Interval = [TimeSpan]::FromMilliseconds(600)
$t.Add_Tick({ $t.Stop(); $btnOk.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) })
$t.Start()
$res = $dlg.ShowDialog()
Say ("ok-click closed dialog: {0} result-rect-set: {1} (expect True/True)" -f ($res -eq $true), ($script:CropState.result -ne $null))

[IO.File]::WriteAllLines($out, $lines)
