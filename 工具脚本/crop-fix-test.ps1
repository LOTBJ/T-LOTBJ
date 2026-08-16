# Verify: (1) dialog OK/Cancel handlers close the window (plain scriptblock pattern, no GetNewClosure)
#         (2) Get-WallpaperPlan decision logic (copy / scale-up / scale-down / crop), native-size based
$out = Join-Path $env:TEMP 'crop-fix-result.txt'
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s) }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Windows.Forms

# ---- part 2: Get-WallpaperPlan (mirror of launcher logic, native sizes via GDI+) ----
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
    if ($ratioDiff -lt 0.03) {
        if ($fitSize -and $isPng) { return @{ mode = 'copy' } }
        return @{ mode = 'scale'; up = (($iw -lt $tw) -or ($ih -lt $th)) }
    }
    return @{ mode = 'crop' }
}

function Make-Png([string]$path, [int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(255, 40, 80, 160))
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$p1 = Join-Path $env:TEMP 'plan-2000x1250.png'; Make-Png $p1 2000 1250
$p2 = Join-Path $env:TEMP 'plan-800x500.png';   Make-Png $p2 800 500
$p3 = Join-Path $env:TEMP 'plan-4000x2500.png'; Make-Png $p3 4000 2500
$p4 = Join-Path $env:TEMP 'plan-1000x2000.png'; Make-Png $p4 1000 2000
Say ("screen: {0}x{1}" -f [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)
$d1 = Get-WallpaperPlan $p1; Say ("2000x1250 (16:10, right size) -> {0} (expect copy)" -f $d1.mode)
$d2 = Get-WallpaperPlan $p2; Say ("800x500 (16:10, small) -> {0} up={1} (expect scale/True)" -f $d2.mode, $d2.up)
$d3 = Get-WallpaperPlan $p3; Say ("4000x2500 (16:10, big) -> {0} up={1} (expect scale/False)" -f $d3.mode, $d3.up)
$d4 = Get-WallpaperPlan $p4; Say ("1000x2000 (portrait) -> {0} (expect crop)" -f $d4.mode)

# ---- part 1: dialog close via plain-scriptblock handlers ----
$script:CropState = @{ result = $null; controls = @{}; imgW = 1.0; imgH = 1.0; sMin = 1.0; zoom = 1.0; offX = 0.0; offY = 0.0; vw = 1.0; vh = 1.0 }
function Get-CropSourceRect([double]$imgW, [double]$imgH, [double]$sMin, [double]$zoom, [double]$offX, [double]$offY, [double]$vw, [double]$vh) {
    return [System.Windows.Rect]::new(1, 2, 3, 4)
}

$dlg = New-Object System.Windows.Window
$dlg.Width = 320; $dlg.Height = 200
$dlg.WindowStyle = [System.Windows.WindowStyle]::ToolWindow
$sp = New-Object System.Windows.Controls.StackPanel
$btnOk = New-Object System.Windows.Controls.Button
$btnOk.Content = 'OK'
$btnCancel = New-Object System.Windows.Controls.Button
$btnCancel.Content = 'Cancel'
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

# auto-click OK after the dialog is up
$t = New-Object System.Windows.Threading.DispatcherTimer
$t.Interval = [TimeSpan]::FromMilliseconds(600)
$t.Add_Tick({
    $t.Stop()
    $btnOk.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
})
$t.Start()
$res = $dlg.ShowDialog()
Say ("ok-click closed dialog: {0} result-rect-set: {1} (expect True/True)" -f ($res -eq $true), ($script:CropState.result -ne $null))

[IO.File]::WriteAllLines($out, $lines)
