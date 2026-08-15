# ============================================================================
# DeepSeek Harness 启动器 (WPF 官网风格控制台 + 独立透明桌宠)
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File dsh-launcher.ps1
#       可选参数: -HideConsole  启动后隐藏控制台窗口(桌面快捷键使用)
#                -AutoTest     自动测试: 1.5秒模拟点击鲸鱼, 6秒后自动关闭
# 功能: 打开 / 重启 / 环境状态 / 技能库 / 日志 / 备份目录
#       桌宠: 独立透明置顶窗口(可拖到桌面任意位置) · 拖拽移动/双击跳/右键菜单
#             三模式(散步/跟随鼠标/待着) · 气泡跟随+可变 · DSH 会话联动
# 素材署名: dsh-whale-girl-source.png 与 whale-assets/*.png 来自
#           fornarwhal/deepseek-whale-girl-icon (CC BY-NC-SA 4.0, 非商用, 署名)
# ============================================================================
param([string]$Theme = "minimal", [switch]$HideConsole, [switch]$AutoTest, [switch]$Diag, [switch]$NoBusy)

if ($HideConsole) {
    Add-Type -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
"@ -Name LauncherWin -Namespace DSH
    [DSH.LauncherWin]::ShowWindow([DSH.LauncherWin]::GetConsoleWindow(), 0) | Out-Null
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# DPI 感知: 避免窗口被系统放大导致文字/图片发虚
try {
    Add-Type -MemberDefinition "[DllImport(\"user32.dll\")] public static extern bool SetProcessDPIAware();" -Name DpiAware -Namespace DSH
    [DSH.DpiAware]::SetProcessDPIAware() | Out-Null
} catch { }

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------- 常量 ----
$HomeDir     = $env:USERPROFILE
$DshHome     = Join-Path $HomeDir ".dsh"
$ScriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$NodeExe     = "C:\Program Files\nodejs\node.exe"
if (-not (Test-Path -LiteralPath $NodeExe)) { $NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source }
# dsh 默认从 npm 缓存取; 找不到时探测全局安装(开源用户路径不同)
$DshBin      = Join-Path $HomeDir "AppData\Local\npm-cache\_npx\1e7f6d9597241db0\node_modules\@deepseek-ai\dsh\lib\bin.js"
if (-not (Test-Path -LiteralPath $DshBin)) {
    $cmd = (Get-Command dsh -ErrorAction SilentlyContinue).Source
    if ($cmd) {
        if ($cmd -match '\.cmd$') {
            $cand = Join-Path (Split-Path -Parent $cmd) "node_modules\@deepseek-ai\dsh\lib\bin.js"
            if (Test-Path -LiteralPath $cand) { $DshBin = $cand } else { $DshBin = $cmd }
        } else { $DshBin = $cmd }
    }
}
$OutLog      = Join-Path $ScriptDir "dsh-web.out.log"
$ErrLog      = Join-Path $ScriptDir "dsh-web.err.log"
$WhaleImg    = Join-Path $ScriptDir "dsh-whale-girl-source.png"
$PetDir      = Join-Path $ScriptDir "whale-assets"
$PetGirl     = Join-Path $PetDir "whale-girl-transparent.png"
$SeaBg       = Join-Path $PetDir "sea-bg.png"
$OfficialWhale = Join-Path $PetDir "official-whale.png"
$PetAtlas    = Join-Path $PetDir "atlas.png"
$SessionsDir = Join-Path $DshHome "sessions"
$SkillsRoot  = Join-Path $DshHome "skills"
$BackupsRoot = Join-Path $DshHome "backups"
$PetCfgFile  = Join-Path $DshHome "launcher-pet.json"
$Url         = "http://127.0.0.1:3080"

# ------------------------------------------------------------- 工具函数 ----
function Get-ServerPid {
    $conn = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { return $conn.OwningProcess }
    return $null
}

function Test-ServerUp {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
        return ($null -ne $r -and $r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
    } catch { return $false }
}

function Start-DshServer {
    if (-not (Test-Path -LiteralPath $NodeExe)) { $script:NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source }
    if (-not (Test-Path -LiteralPath $DshBin))  { $script:DshBin  = (Get-Command dsh -ErrorAction SilentlyContinue).Source }
    if (-not (Test-Path -LiteralPath $DshBin))  { return $false }
    # 日志文件可能被刚杀掉的旧实例短暂锁定 → 最多重试 3 次
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $p = Start-Process -FilePath $NodeExe `
                               -ArgumentList @($DshBin, "web") `
                               -WorkingDirectory $ScriptDir `
                               -WindowStyle Hidden `
                               -RedirectStandardOutput $OutLog `
                               -RedirectStandardError  $ErrLog `
                               -PassThru
            return ($null -ne $p)
        } catch {
            Add-Content -Path "$env:TEMP\dsh-launcher-errors.log" -Value ("START-ERR: " + $_.Exception.Message)
            Start-Sleep -Milliseconds 500
        }
    }
    return $false
}

function Stop-DshServer {
    $pid2 = Get-ServerPid
    if ($pid2) {
        Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
}

function Get-LogTail([string]$path, [int]$lines = 6) {
    if (-not (Test-Path -LiteralPath $path)) { return "(暂无日志文件)" }
    try { return (Get-Content -LiteralPath $path -Tail $lines -ErrorAction Stop) -join "`n" }
    catch { return "(日志读取失败)" }
}

function Get-DshVersion {
    $pkg = Join-Path (Split-Path -Parent $DshBin) "package.json"
    if (Test-Path -LiteralPath $pkg) {
        try { return (Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json).version } catch {}
    }
    return "?"
}

function Get-SkillList {
    $result = @()
    if (-not (Test-Path -LiteralPath $SkillsRoot)) { return $result }
    Get-ChildItem -LiteralPath $SkillsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $md = Join-Path $_.FullName "SKILL.md"
        $name = $_.Name; $desc = ""
        if (Test-Path -LiteralPath $md) {
            $raw = Get-Content -LiteralPath $md -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($raw -match "(?s)^---\s*(.*?)\s*---") {
                $fm = $matches[1]
                if ($fm -match "(?m)^name:\s*['""]?([^'""\r\n]+)") { $name = $matches[1].Trim() }
                if ($fm -match "(?ms)^description:\s*['""]?(.*?)$") {
                    $d = $matches[1].Trim()
                    $d = $d -replace "['""]\s*$", ""
                    if ($d.Length -gt 110) { $d = $d.Substring(0, 107) + "..." }
                    $desc = $d
                }
                if (-not $desc -and $fm -match "(?ms)short-description:\s*['""]?(.*?)$") {
                    $desc = ($matches[1].Trim() -replace "['""]\s*$", "")
                }
            }
        }
        $result += [PSCustomObject]@{ Name = $name; Description = $desc; Path = $_.FullName }
    }
    return $result
}

function Get-EnvInfo {
    $pid2 = Get-ServerPid
    $proc = $null
    if ($pid2) { $proc = Get-Process -Id $pid2 -ErrorAction SilentlyContinue }
    $envText = ""
    if (Test-Path -LiteralPath (Join-Path $DshHome ".env")) { $envText = Get-Content -LiteralPath (Join-Path $DshHome ".env") -Raw -ErrorAction SilentlyContinue }
    $skillCount = @(Get-ChildItem -LiteralPath $SkillsRoot -Directory -ErrorAction SilentlyContinue).Count
    $backupCount = 0
    if (Test-Path -LiteralPath $BackupsRoot) { $backupCount = @(Get-ChildItem -LiteralPath $BackupsRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike ".*" }).Count }
    $startTime = "-"
    if ($proc) { $startTime = $proc.StartTime.ToString("yyyy-MM-dd HH:mm:ss") }
    $vision = "未配置"
    if ($envText -match "(?m)^VISION_API_KEY=") { $vision = "已配置" }
    $safe = "关闭"
    if ($env:DSH_SAFE_MODE -eq "1") { $safe = "开启(用户补丁层已跳过)" }
    return [PSCustomObject]@{
        Running   = ($null -ne $pid2)
        Pid       = $pid2
        StartTime = $startTime
        Version   = Get-DshVersion
        VisionKey = $vision
        Skills    = $skillCount
        Backups   = $backupCount
        SafeMode  = $safe
    }
}

function New-Bitmap([string]$path) {
    $bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
    $bmp.BeginInit()
    $bmp.UriSource = [System.Uri]::new($path)
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    return $bmp
}

# ------------------------------------------------------------ XAML 资源 ----
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DeepSeek Harness" Width="980" Height="640"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <!-- 官网语言 v2: 玻璃胶囊 / 大字距 / 纱布撒蓝 (数据取自 deepseek.com 真实 CSS) -->
    <Style x:Key="GlassPill" TargetType="Button">
      <Setter Property="Foreground" Value="#1E232C"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="100" Background="#73FFFFFF" Padding="14,7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#C4FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E0FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MiniChip" TargetType="Button">
      <Setter Property="Foreground" Value="#3F6FE0"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="100" Background="#EDF3FF" Padding="13,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#D9E6FF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#C7DAFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FooterLink" TargetType="Button">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="Transparent" Padding="4,2">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#2F55D9"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="6" Background="{TemplateBinding Background}">
              <Border.Effect>
                <DropShadowEffect BlurRadius="14" ShadowDepth="3" Opacity="0.28" Color="#3D5BEE"/>
              </Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#3D5BEE"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#3350D8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#1E232C"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="6" Background="#61FFFFFF" BorderBrush="#8CFFFFFF" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="24,10"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#A6FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#D1FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ChipBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="18" Background="#33FFFFFF" BorderBrush="#55FFFFFF" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="16,8"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#55FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#77FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#8A93A6"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="8" Background="Transparent" Width="36" Height="32">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#EEF1F8"/>
                <Setter Property="Foreground" Value="#1F2329"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="RootBorder" CornerRadius="18" Background="#F7F8FA">
    <Border.Effect>
      <DropShadowEffect BlurRadius="28" ShadowDepth="2" Opacity="0.16" Color="#1F2329"/>
    </Border.Effect>

    <Grid>
      <!-- ============================ 极简视图 (官方浅色) ============================ -->
      <!-- ============ 极简视图 · 官网语言 v2 ============ -->
      <Grid x:Name="ViewMinimal" Background="#F9F8F8" Visibility="Visible">
        <!-- 官网同款"纱布撒蓝": 顶部淡蓝晕染渐隐 -->
        <Border Height="280" VerticalAlignment="Top" IsHitTestVisible="False">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#9CC1E7" Offset="0"/>
              <GradientStop Color="#00FAFAFA" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>

        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="60"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="56"/>
          </Grid.RowDefinitions>

          <!-- 顶栏: 透明 + 玻璃胶囊 -->
          <Grid x:Name="MinBar" Grid.Row="0" Margin="26,0,18,0" Cursor="SizeAll" Background="Transparent">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <Image x:Name="MinLogo" Width="26" Height="26" Stretch="Uniform"/>
              <TextBlock Text="DeepSeek Harness" Foreground="#1E232C" FontSize="14.5" Margin="10,0,0,0" VerticalAlignment="Center"/>
              <Border CornerRadius="100" Background="#73FFFFFF" Padding="13,5" Margin="16,0,0,0">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="MinStatusDot" Width="7" Height="7" Fill="#F0A94A" VerticalAlignment="Center"/>
                  <TextBlock x:Name="MinStatusText" Text="检测中…" Foreground="#1E232C" FontSize="12" Margin="7,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
              <Button x:Name="BtnPetToggle" Style="{StaticResource GlassPill}" Content="🐳 桌宠 开" ToolTip="显示/隐藏桌宠" Margin="0,0,8,0"/>
              <Button x:Name="BtnMinMin" Style="{StaticResource GlassPill}" Content="—" Width="36" ToolTip="最小化" Margin="0,0,8,0"/>
              <Button x:Name="BtnCloseMin" Style="{StaticResource GlassPill}" Content="✕" Width="36" ToolTip="退出"/>
            </StackPanel>
          </Grid>

          <!-- 内容区 -->
          <Grid Grid.Row="1">
            <!-- 首页 hero (整体偏上) -->
            <StackPanel x:Name="PanelHome" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-84,0,0">
              <Border CornerRadius="22" Background="#4DFFFFFF" Padding="18,8" HorizontalAlignment="Center" Visibility="Collapsed">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="OpenDot" Width="9" Height="9" Fill="#F0A94A" VerticalAlignment="Center"/>
                  <TextBlock x:Name="OpenState" Text="正在检测服务…" Foreground="#1E232C" FontSize="13" Margin="8,0,0,0"/>
                  <TextBlock x:Name="OpenDetail" Text="" Foreground="#5A6172" FontSize="13" Margin="10,0,0,0" Visibility="Collapsed"/>
                </StackPanel>
              </Border>
              <Image x:Name="HeroWhale" Width="96" Height="72" Stretch="Uniform" HorizontalAlignment="Center" RenderTransformOrigin="0.5,0.5"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,30,0,0">
                <Button x:Name="BtnOpen" Style="{StaticResource PrimaryBtn}" Content="💬 开始对话" Height="50" Background="#4D6BFE" Padding="44,0"/>
                <Button x:Name="BtnRestart" Style="{StaticResource GhostBtn}" Content="↻ 重启服务" Height="50" Margin="14,0,0,0"/>
              </StackPanel>
              <TextBlock x:Name="OpenLogBox" Text="" Foreground="#5B6472" FontSize="11.5" FontFamily="Consolas" TextWrapping="Wrap" MaxHeight="96" Visibility="Collapsed"/>
            </StackPanel>

            <!-- 环境面板 -->
            <StackPanel x:Name="PanelEnv" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Border CornerRadius="20" Background="#8CFFFFFF" BorderBrush="#B3FFFFFF" BorderThickness="1" Padding="28,26" Width="560">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="环 境 信 息" Foreground="#152443" FontSize="16" FontWeight="SemiBold"/>
                    <TextBlock Text="本机 DSH 部署与运行状况" Foreground="#8A919E" FontSize="12" Margin="12,0,0,0" VerticalAlignment="Center"/>
                    <Button x:Name="BtnEnvRefresh" Style="{StaticResource GhostBtn}" Content="↻ 刷新" FontSize="12" HorizontalAlignment="Right"/>
                  </StackPanel>
                  <StackPanel x:Name="EnvRows" Margin="0,12,0,0"/>
                </StackPanel>
              </Border>
            </StackPanel>

            <!-- 技能面板 -->
            <StackPanel x:Name="PanelSkills" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Border CornerRadius="20" Background="#8CFFFFFF" BorderBrush="#B3FFFFFF" BorderThickness="1" Padding="28,26" Width="600">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="技 能 库" Foreground="#152443" FontSize="16" FontWeight="SemiBold"/>
                    <TextBlock x:Name="SkillCountText" Text="" Foreground="#8A919E" FontSize="12" Margin="10,0,0,0" VerticalAlignment="Center"/>
                    <Button x:Name="BtnOpenSkillsDir" Style="{StaticResource GhostBtn}" Content="打开技能目录" FontSize="12" HorizontalAlignment="Right"/>
                  </StackPanel>
                  <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="340" Margin="0,12,0,0">
                    <StackPanel x:Name="SkillCards"/>
                  </ScrollViewer>
                </StackPanel>
              </Border>
            </StackPanel>

            <!-- 重启面板 -->
            <StackPanel x:Name="PanelRestart" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Border CornerRadius="20" Background="#8CFFFFFF" BorderBrush="#B3FFFFFF" BorderThickness="1" Padding="28,26" Width="580">
                <StackPanel>
                  <TextBlock Text="重 启 服 务" Foreground="#152443" FontSize="16" FontWeight="SemiBold"/>
                  <TextBlock Text="按端口 3080 找到占用进程并杀掉，再启动全新实例（配置损坏时自动安全模式重试）。" Foreground="#8A919E" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
                  <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                    <Ellipse x:Name="RestartDot" Width="9" Height="9" Fill="#F0A94A" VerticalAlignment="Center"/>
                    <TextBlock x:Name="RestartState" Text="当前服务状态未知" Foreground="#1E232C" FontSize="13.5" FontWeight="SemiBold" Margin="8,0,0,0"/>
                  </StackPanel>
                  <TextBlock x:Name="RestartDetail" Text="" Foreground="#8A919E" FontSize="12" Margin="17,6,0,0" TextWrapping="Wrap"/>
                  <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
                    <Button x:Name="BtnDoRestart" Style="{StaticResource PrimaryBtn}" Content="立即重启" Height="44" Background="#E05C5C" Padding="28,0"/>
                    <Button x:Name="BtnRestartOpen" Style="{StaticResource GhostBtn}" Content="重启后打开浏览器" Height="44" Margin="14,0,0,0"/>
                  </StackPanel>
                  <TextBlock Text="最近错误日志" Foreground="#8A919E" FontSize="11" Margin="0,16,0,6"/>
                  <Border CornerRadius="12" Background="#26E05C5C" BorderBrush="#55E05C5C" BorderThickness="1" Padding="12,10">
                    <TextBlock x:Name="RestartLogBox" Text="" Foreground="#B05050" FontSize="11.5" FontFamily="Consolas" TextWrapping="Wrap" MaxHeight="120"/>
                  </Border>
                </StackPanel>
              </Border>
            </StackPanel>
            <!-- 环境装配面板 (一键下载安装 DSH 运行环境, 借鉴大肥鱼"别人一键装配"思路) -->
            <StackPanel x:Name="PanelSetup" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Border CornerRadius="20" Background="#8CFFFFFF" BorderBrush="#B3FFFFFF" BorderThickness="1" Padding="28,26" Width="580">
                <StackPanel>
                  <TextBlock Text="环 境 装 配" Foreground="#152443" FontSize="16" FontWeight="SemiBold"/>
                  <TextBlock Text="新机器一键装配 DSH 运行环境：检测 node/npm → 自动下载安装 dsh → 生成配置，开箱即用。" Foreground="#8A919E" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
                  <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                    <TextBlock x:Name="SetupState" Text="检测中…" Foreground="#1E232C" FontSize="13.5" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap"/>
                    <Button x:Name="BtnSetupGo" Style="{StaticResource PrimaryBtn}" Content="🔧 一键装配" Height="44" Background="#4D6BFE" Padding="26,0" HorizontalAlignment="Right"/>
                  </StackPanel>
                  <Border CornerRadius="12" Background="#26FFFFFF" BorderBrush="#55FFFFFF" BorderThickness="1" Padding="12,10" Margin="0,14,0,0">
                    <TextBlock x:Name="SetupLogBox" Text="" Foreground="#5B6472" FontSize="11.5" FontFamily="Consolas" TextWrapping="Wrap" MaxHeight="160"/>
                  </Border>
                </StackPanel>
              </Border>
            </StackPanel>
          </Grid>

          <!-- footer 链接行 -->
          <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Button x:Name="NavHome" Style="{StaticResource FooterLink}" Content="首页" Margin="0,0,14,0"/>
            <Button x:Name="NavEnv" Style="{StaticResource FooterLink}" Content="环境信息" Margin="0,0,14,0"/>
            <Button x:Name="NavSkills" Style="{StaticResource FooterLink}" Content="技能库" Margin="0,0,14,0"/>
            <Button x:Name="NavSetup" Style="{StaticResource FooterLink}" Content="环境装配" Margin="0,0,14,0"/>
            <Button x:Name="NavLogs" Style="{StaticResource FooterLink}" Content="运行日志" Margin="0,0,14,0"/>
            <Button x:Name="NavBackup" Style="{StaticResource FooterLink}" Content="配置备份" Margin="0,0,14,0"/>
            <Button x:Name="NavDshDir" Style="{StaticResource FooterLink}" Content=".dsh 目录"/>
          </StackPanel>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

# ------------------------------------------------------------ 桌宠窗口(独立透明置顶, 借鉴大肥鱼/Desktop-Pet) ----
$petXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DSH 桌宠" Width="360" Height="430"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" Left="920" Top="380">
  <Window.Resources>
    <Style x:Key="MiniChip" TargetType="Button">
      <Setter Property="Foreground" Value="#3F6FE0"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="100" Background="#EDF3FF" Padding="13,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#D9E6FF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#C7DAFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <!-- 隐形底(alpha=1): 分层窗口透明像素会鼠标穿透, 加近乎全透明的底让全窗口可点击 -->
  <Canvas x:Name="PetStage" Background="#01000000">
    <Grid x:Name="PetHost" Width="300" Height="330" RenderTransformOrigin="0.5,0.95" Cursor="SizeAll">
      <Image x:Name="PetImage" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Bottom"/>
    </Grid>
    <TextBlock x:Name="PetEmoji" FontFamily="Segoe UI Emoji" FontSize="26" Foreground="#1F2A44" Panel.ZIndex="2"/>
    <StackPanel x:Name="BubbleRoot" Panel.ZIndex="5" Width="320" Opacity="0">
      <Border x:Name="SpeechBubble" CornerRadius="14" Background="#FFFFFF" BorderBrush="#7AA8F0" BorderThickness="2" Padding="14,11" HorizontalAlignment="Center" MaxWidth="300">
        <Border.Effect>
          <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.22" Color="#1F2A44"/>
        </Border.Effect>
        <StackPanel>
          <TextBlock x:Name="SpeechText" Text="你好呀，我是 DSH 的小鲸鱼助手~" Foreground="#1F2A44" FontSize="13.5" FontWeight="SemiBold" TextWrapping="Wrap" LineHeight="22"/>
          <WrapPanel x:Name="SpeechChips" Margin="0,10,0,0" Visibility="Collapsed">
            <Button x:Name="ChipOpen" Style="{StaticResource MiniChip}" Content="▶ 打开" FontSize="12" Margin="0,0,6,6"/>
            <Button x:Name="ChipRestart" Style="{StaticResource MiniChip}" Content="↻ 重启" FontSize="12" Margin="0,0,6,6"/>
            <Button x:Name="ChipEnv" Style="{StaticResource MiniChip}" Content="◎ 环境" FontSize="12" Margin="0,0,6,6"/>
            <Button x:Name="ChipSkills" Style="{StaticResource MiniChip}" Content="▤ 技能库" FontSize="12" Margin="0,0,6,6"/>
            <Button x:Name="ChipPet" Style="{StaticResource MiniChip}" Content="✋ 摸一摸" FontSize="12" Margin="0,0,6,6"/>
            <Button x:Name="ChipTalk" Style="{StaticResource MiniChip}" Content="💬 说说话" FontSize="12" Margin="0,0,6,6"/>
          </WrapPanel>
        </StackPanel>
      </Border>
      <Polygon x:Name="BubbleTail" Points="0,0 16,0 8,10" Fill="White" HorizontalAlignment="Center" Margin="0,-3,0,0"/>
    </StackPanel>
  </Canvas>
</Window>
'@

# ------------------------------------------------------------ 加载窗口 ----
$xml = [xml]$xaml
$reader = [System.Xml.XmlNodeReader]::new($xml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# 桌宠独立窗口
$petWinXml = [xml]$petXaml
$petWinReader = [System.Xml.XmlNodeReader]::new($petWinXml)
$petWin = [System.Windows.Markup.XamlReader]::Load($petWinReader)
$petWin.ShowInTaskbar = $false
$petWin.Topmost = $true
$petWin.Dispatcher.Add_UnhandledException({
    param($s, $e)
    try {
        Add-Content -Path "$env:TEMP\dsh-launcher-errors.log" -Value ("PET-ERR " + [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss") + ": " + $e.Exception.Message)
    } catch { }
    $e.Handled = $true
})

# 防火墙 L6: 事件处理器内任何异常不再崩掉整个进程(此前"用着用着窗口消失"的根因)
# 捕获后写日志 + Handled=true, 窗口继续存活
$window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    try {
        Add-Content -Path "$env:TEMP\dsh-launcher-errors.log" -Value ("UI-ERR " + [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss") + ": " + $e.Exception.Message)
    } catch { }
    $e.Handled = $true
})

# 无边框窗口默认不进任务栏, 最小化后"人间蒸发"像被关闭; 显式开启
$window.ShowInTaskbar = $true

# 图标与图片
try {
    $window.Icon = New-Bitmap $WhaleImg
    $window.FindName("MinLogo").Source = New-Bitmap $WhaleImg
    $window.FindName("HeroWhale").Source = New-Bitmap $OfficialWhale
} catch {
    Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value ("IMG-ERR: " + $_.Exception.Message)
}

$minStatusDot    = $window.FindName("MinStatusDot")
$minStatusText   = $window.FindName("MinStatusText")
$openDot   = $window.FindName("OpenDot")
$openState = $window.FindName("OpenState")
$openDetail = $window.FindName("OpenDetail")
$openLogBox = $window.FindName("OpenLogBox")
$restartDot = $window.FindName("RestartDot")
$restartState = $window.FindName("RestartState")
$restartDetail = $window.FindName("RestartDetail")
$restartLogBox = $window.FindName("RestartLogBox")
$envRows = $window.FindName("EnvRows")
$skillCards = $window.FindName("SkillCards")
$skillCountText = $window.FindName("SkillCountText")
$setupState = $window.FindName("SetupState")
$setupLogBox = $window.FindName("SetupLogBox")

# 桌宠窗口元素
$speechText = $petWin.FindName("SpeechText")
$speechChips = $petWin.FindName("SpeechChips")
$bubbleRoot = $petWin.FindName("BubbleRoot")
$petStage = $petWin.FindName("PetStage")
$petHost  = $petWin.FindName("PetHost")
$petImage = $petWin.FindName("PetImage")
$petEmoji = $petWin.FindName("PetEmoji")

$panels = @{
    home    = $window.FindName("PanelHome")
    restart = $window.FindName("PanelRestart")
    env     = $window.FindName("PanelEnv")
    skills  = $window.FindName("PanelSkills")
    setup   = $window.FindName("PanelSetup")
}
$navBtns = @{
    home   = $window.FindName("NavHome")
    env    = $window.FindName("NavEnv")
    skills = $window.FindName("NavSkills")
    setup  = $window.FindName("NavSetup")
}

# ------------------------------------------------------------ 全局状态 ----
$script:currentPanel = "home"
$script:busy         = $false
$script:lastIdleAt   = [DateTime]::Now
$script:rand         = [System.Random]::new()
$script:sysTick      = 0
$script:setupRunning = $false

# 鲸鱼台词池
$script:idleLines = @(
    "在海的深处，我也在陪着你写报告哦~",
    "今天的 DeepSeek 也运行得好好的呢！",
    "需要我帮你重启服务吗？点我就好~",
    "嘘…我在听海的声音，也在听你敲键盘的声音。",
    "技能库里又多了新朋友，记得去看看~",
    "如果页面打不开，可能是端口被占用了，点我重启一下？"
)
$script:petLines = @(
    "呜哇！摸头会害羞的啦…(*/ω＼*)",
    "嘿嘿，尾巴摇起来了~ 今天也一起加油！",
    "再摸的话，我可要沉进海里了哦~",
    "咕噜咕噜…（舒服地眯起眼睛）",
    "好啦好啦，摸完了就快去做正事吧！"
)
$script:talkLines = @(
    "我是 DeepSeek Harness 的看门小鲸鱼，负责 3080 端口的安全~",
    "极简界面负责干活，我负责可爱，分工明确！",
    "你知道端口残留吗？重启键就是专门治它的~",
    "要我陪你聊聊天，还是去检查一下环境？"
)
$script:thinkLines = @(
    "主人正在认真工作呢，我安静陪着~",
    "嗯…这步有点复杂，主人加油！",
    "我在海里也帮你盯着日志哦~",
    "需要重启服务的话，点我一下~",
    "咕噜咕噜…（在陪你想问题）"
)

# ------------------------------------------------------------ 桌宠引擎(标准 Codex 图集) ----
# 图集: 8x11, 192x208/格; 前 9 行 = 动作(待机/右走/左走/挥手/跳跃/失败/等待/思考/检查),
# 第 9-10 行 = 16 方向注视。规范借鉴 GaoHaoSong/Desktop-Pet (MIT)。
Add-Type -AssemblyName System.Windows.Forms

$script:cellW = 192; $script:cellH = 208
$script:frames = @{}
$script:petHasAtlas = $false
try {
    $atlas = New-Bitmap $PetAtlas
    $atlas.Freeze()
    for ($r = 0; $r -lt 11; $r++) {
        for ($c = 0; $c -lt 8; $c++) {
            $cb = [System.Windows.Media.Imaging.CroppedBitmap]::new()
            $cb.BeginInit()
            $cb.Source = $atlas
            $cb.SourceRect = [System.Windows.Int32Rect]::new($c * $script:cellW, $r * $script:cellH, $script:cellW, $script:cellH)
            $cb.EndInit()
            $cb.Freeze()
            $script:frames["$r,$c"] = $cb
        }
    }
    $script:petHasAtlas = $true
} catch {
    Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value ("ATLAS-ERR: " + $_.Exception.Message)
}

# 动画表: 帧序列 + 每帧时长(ms) — 同标准播放器
$script:anims = @{
    idle   = @{ Row = 0; F = @(0,1,2,3,4,5,6);   D = @(280,110,110,140,140,320,320) }
    right  = @{ Row = 1; F = @(0,1,2,3,4,5,6,7); D = @(120,120,120,120,120,120,120,220) }
    left   = @{ Row = 2; F = @(0,1,2,3,4,5,6,7); D = @(120,120,120,120,120,120,120,220) }
    wave   = @{ Row = 3; F = @(0,1,2,3);         D = @(140,140,140,280) }
    jump   = @{ Row = 4; F = @(0,1,2,3,4);       D = @(140,140,140,140,280) }
    failed = @{ Row = 5; F = @(0,1,2,3,4,5,6,7); D = @(140,140,140,140,140,140,140,240) }
    wait   = @{ Row = 6; F = @(0,1,2,3,4,5);     D = @(150,150,150,150,150,260) }
    think  = @{ Row = 7; F = @(0,1,2,3,4,5);     D = @(120,120,120,120,120,220) }
    review = @{ Row = 8; F = @(0,1,2,3,4,5);     D = @(150,150,150,150,150,280) }
}

$script:sw = [System.Diagnostics.Stopwatch]::StartNew()
$script:pet = @{
    mode    = "roam"      # roam 散步 | follow 跟随鼠标 | stay 原地待着
    anim    = "idle"
    aIdx    = 0
    aNext   = 0
    aLoop   = $true
    x       = 30.0
    y       = 96.0
    dir     = 1
    speed   = 0.0
    t       = 0
    max     = 0
    phase   = 0.0
    gaze    = $null
    drag    = $false
    busy    = $false
    wasBusy = $false
    busyAt  = $null
    talkCd  = 0
    fade    = 1.0
    emoji   = ""
    feeding = $false
    feedT   = 0
}
$script:petScale = [System.Windows.Media.ScaleTransform]::new(1, 1)
$script:petRotate = [System.Windows.Media.RotateTransform]::new(0)
$petGroup = [System.Windows.Media.TransformGroup]::new()
$petGroup.Children.Add($script:petRotate) | Out-Null
$petGroup.Children.Add($script:petScale) | Out-Null
$petHost.RenderTransform = $petGroup
$petHost.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.95)
$petImage.Width = 269
$petImage.Height = 291
$petImage.Stretch = [System.Windows.Media.Stretch]::Fill
$script:heroTT = [System.Windows.Media.TranslateTransform]::new(0, 0)
$window.FindName("HeroWhale").RenderTransform = $script:heroTT

function Set-PetFrame([int]$row, [int]$col) {
    if (-not $script:petHasAtlas) { return }
    $src = $script:frames["$row,$col"]
    if ($src) { $petImage.Source = $src }
}

function Set-PetAnim([string]$name, [bool]$loop = $true) {
    $a = $script:anims[$name]
    if (-not $a) { return }
    $script:pet.anim = $name
    $script:pet.aIdx = 0
    $script:pet.aLoop = $loop
    $script:pet.aNext = $script:sw.ElapsedMilliseconds + $a.D[0]
    Set-PetFrame $a.Row $a.F[0]
}

function Set-PetEmoji([string]$e) {
    $script:pet.emoji = $e
    $script:pet.emojiT = if ($e) { 30 } else { 0 }
    $petEmoji.Text = $e
    if ($e) { $petEmoji.Visibility = [System.Windows.Visibility]::Visible }
    else { $petEmoji.Visibility = [System.Windows.Visibility]::Collapsed }
}

function Set-PetTalk([string]$text, [bool]$showChips = $false, [bool]$force = $false) {
    if (-not $force -and $script:pet.talkCd -gt 0) { return }
    Set-Speech $text $showChips
    $script:pet.talkCd = 40
}

function Get-PetMouse {
    $mp = [System.Windows.Forms.Cursor]::Position
    $tl = $PetStage.PointToScreen([System.Windows.Point]::new(0, 0))
    return @{ X = $mp.X - $tl.X; Y = $mp.Y - $tl.Y }
}

function Update-PetGaze {
    # 空闲时鼠标靠近 → 16 方向注视 (规范: Atan2(dx,-dy), 22.5°/桶)
    $p = $script:pet
    $p.gaze = $null
    if (-not $script:petHasAtlas) { return }
    if ($p.anim -ne "idle") { return }
    $pt = Get-PetMouse
    $dx = $pt.X - ($p.x + 135)
    $dy = $pt.Y - ($p.y - 140)
    if ([Math]::Sqrt($dx * $dx + $dy * $dy) -gt 320) { return }
    $ang = [Math]::Atan2($dx, -$dy) * 180.0 / [Math]::PI
    if ($ang -lt 0) { $ang += 360.0 }
    $idx = [int][Math]::Round($ang / 22.5) % 16
    if ($idx -lt 8) { $p.gaze = @{ Row = 9; Col = $idx } } else { $p.gaze = @{ Row = 10; Col = $idx - 8 } }
}

function Update-Pet {
    $p = $script:pet
    $p.t++
    $p.phase += 0.10
    $p.gaze = $null
    if ($p.talkCd -gt 0) { $p.talkCd-- }
    if ($p.emojiT -gt 0) {
        $p.emojiT--
        if ($p.emojiT -eq 0) { Set-PetEmoji "" }
    }
    # 进食状态: 蹲吃 4.5 秒后回待机
    if ($p.feeding) {
        $p.feedT++
        if ($p.feedT -gt 45) {
            $p.feeding = $false
            Set-PetAnim "idle"
            $p.t = 0
            $p.max = 40 + $script:rand.Next(40)
        }
    }

    # 帧推进 (注视时冻结动作帧)
    if ($script:petHasAtlas) {
        if ($null -ne $p.gaze) {
            Set-PetFrame $p.gaze.Row $p.gaze.Col
        } else {
            $a = $script:anims[$p.anim]
            if ($script:sw.ElapsedMilliseconds -ge $p.aNext) {
                $p.aIdx++
                if ($p.aIdx -ge $a.F.Count) {
                    if ($p.aLoop) { $p.aIdx = 0 }
                    else {
                        Set-PetAnim "idle"
                        $p.t = 0
                        $p.max = 30 + $script:rand.Next(40)
                    }
                }
                $p.aNext = $script:sw.ElapsedMilliseconds + $a.D[$p.aIdx]
                Set-PetFrame $a.Row $a.F[$p.aIdx]
            }
        }
    }

    $breath = 1 + 0.012 * [Math]::Sin($p.phase)
    $targetSpeed = 0.0

    if ($p.busy) {
        # DSH 任务进行中 → 思考踱步: think/review 为主, 偶尔走两步(真移动); 交互动画优先
        if ($p.anim -ne "think" -and $p.anim -ne "review" -and $p.anim -ne "wave" -and $p.anim -ne "jump" -and $p.anim -ne "right" -and $p.anim -ne "left") {
            if ($script:rand.Next(2) -eq 0) { Set-PetAnim "think" } else { Set-PetAnim "review" }
        }
        if ($p.anim -eq "right" -or $p.anim -eq "left") {
            $targetSpeed = 2.0
            $p.walkT--
            if ($p.walkT -le 0) { Set-PetAnim "think"; $p.t = 0; $p.max = 50 + $script:rand.Next(60) }
        } elseif ($p.t -ge $p.max) {
            $p.t = 0
            $p.max = 50 + $script:rand.Next(60)
            if ($script:rand.Next(3) -eq 0) {
                $p.dir = if ($script:rand.Next(2) -eq 0) { 1 } else { -1 }
                if ($p.dir -eq 1) { Set-PetAnim "right" } else { Set-PetAnim "left" }
                $p.walkT = 15 + $script:rand.Next(15)
            }
        }
    } elseif ($p.drag) {
        $targetSpeed = 0.0
    } else {
        switch ($p.mode) {
            "roam" {
                if ($p.anim -eq "idle") {
                    Update-PetGaze
                    if ($null -eq $p.gaze -and $p.t -ge $p.max) {
                        $p.dir = if ($script:rand.Next(2) -eq 0) { 1 } else { -1 }
                        if ($p.dir -eq 1) { Set-PetAnim "right" } else { Set-PetAnim "left" }
                        $p.t = 0
                        $p.max = 25 + $script:rand.Next(35)
                    }
                } else {
                    $targetSpeed = 2.8
                    if ($p.t -ge $p.max) { Set-PetAnim "idle"; $p.t = 0; $p.max = 60 + $script:rand.Next(60) }
                }
            }
            "follow" {
                $mp = [System.Windows.Forms.Cursor]::Position
                $mx = $mp.X / $script:dpiScale
                $targetLeft = $mx - 180
                $dx = $targetLeft - $petWin.Left
                if ([Math]::Abs($dx) -gt 24) {
                    $p.dir = if ($dx -gt 0) { 1 } else { -1 }
                    $name = if ($p.dir -eq 1) { "right" } else { "left" }
                    if ($p.anim -ne $name) { Set-PetAnim $name }
                    $targetSpeed = [Math]::Min(4.2, [Math]::Abs($dx) / 50.0)
                } else {
                    if ($p.anim -ne "idle") { Set-PetAnim "idle" }
                    Update-PetGaze
                }
            }
            "stay" {
                if ($p.anim -ne "idle") { Set-PetAnim "idle" }
                Update-PetGaze
            }
        }
    }

    # 本帧注视即时生效 (覆盖上面刚推进的待机帧)
    if ($null -ne $p.gaze -and $script:petHasAtlas) { Set-PetFrame $p.gaze.Row $p.gaze.Col }

    # 加减速惯性
    if ($p.speed -lt $targetSpeed) { $p.speed = [Math]::Min($targetSpeed, $p.speed + 0.35) }
    elseif ($p.speed -gt $targetSpeed) { $p.speed = [Math]::Max($targetSpeed, $p.speed - 0.35) }

    # 窗口级真移动: 走路时移动桌宠窗口本身(Codex/大肥鱼式), 宠物在窗口内位置固定
    if ($p.speed -gt 0.05) {
        $petWin.Left += $p.dir * $p.speed
        $wa = [System.Windows.SystemParameters]::WorkArea
        $minX = $wa.Left
        $maxX = $wa.Right - $petWin.Width
        if ($petWin.Left -lt $minX -or $petWin.Left -gt $maxX) {
            $petWin.Left = [Math]::Max($minX, [Math]::Min($maxX, $petWin.Left))
            $p.dir = -$p.dir
            if ($p.dir -eq 1) { Set-PetAnim "right" } else { Set-PetAnim "left" }
            $p.fade = 0.5
        }
    }
    if ($p.fade -lt 1.0) { $p.fade = [Math]::Min(1.0, $p.fade + 0.06) }
    $petHost.Opacity = $p.fade

    # 摇摆 + 拖拽侧身 (走路时摆动幅度更大, 补帧数少的僵硬感)
    $lean = if ($p.drag) { 8.0 } else { 0.0 }
    $walking = ($p.anim -eq "right" -or $p.anim -eq "left")
    $swing = if ($walking) { 4.5 } else { 2 }
    $script:petRotate.Angle = [Math]::Sin($p.phase * 2.2) * $swing + $lean
    # 进食咀嚼挤压: 身体随咀嚼微微压缩回弹
    $chew = if ($p.feeding) { 1 - 0.045 * [Math]::Abs([Math]::Sin($p.phase * 7)) } else { 1 }
    $script:petScale.ScaleX = $p.dir * $breath * $script:petSize * $chew
    $script:petScale.ScaleY = $breath * $script:petSize * $chew

    # 跳跃抛物线 / 走路弹跳 (上下起伏让步伐更生动)
    $jumpY = 0.0
    if ($p.anim -eq "jump") {
        $a = $script:anims["jump"]
        $prog = $p.aIdx / [Math]::Max(1, $a.F.Count - 1)
        $jumpY = -90 * [Math]::Sin([Math]::PI * $prog)
    } elseif ($walking) {
        $jumpY = -[Math]::Abs([Math]::Sin($p.phase * 2.8)) * 16
    }

    $y = $p.y + $jumpY
    [System.Windows.Controls.Canvas]::SetLeft($petHost, $p.x)
    [System.Windows.Controls.Canvas]::SetTop($petHost, $y)
    if ($p.emoji) {
        [System.Windows.Controls.Canvas]::SetLeft($petEmoji, $p.x + 140)
        [System.Windows.Controls.Canvas]::SetTop($petEmoji, $y - 40)
    }

    # 气泡跟随: 悬在桌宠头顶, 随走动/跳跃移动; 到时自动淡出
    if ($bubbleRoot.Opacity -gt 0.05) {
        $bw = $bubbleRoot.ActualWidth
        if ($bw -lt 10) { $bw = 320 }
        $bh = $bubbleRoot.ActualHeight
        if ($bh -lt 10) { $bh = 60 }
        $bx = $p.x + 150 - $bw / 2
        $bx = [Math]::Max(6, [Math]::Min(34, $bx))
        $by = $y + 30 - $bh
        $by = [Math]::Max(8, $by)
        [System.Windows.Controls.Canvas]::SetLeft($bubbleRoot, $bx)
        [System.Windows.Controls.Canvas]::SetTop($bubbleRoot, $by)
    }
    if ($script:bubbleHideAt -gt 0 -and $script:sw.ElapsedMilliseconds -ge $script:bubbleHideAt) {
        Hide-Bubble
    }
}

# ------------------------------------------------------------ UI 工具 ----
function Set-Panel([string]$name) {
    $script:currentPanel = $name
    foreach ($k in $panels.Keys) {
        if ($k -eq $name) { $panels[$k].Visibility = [System.Windows.Visibility]::Visible }
        else { $panels[$k].Visibility = [System.Windows.Visibility]::Collapsed }
    }
    $blue = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#2F55D9"))
    $gray = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#6B7280"))
    foreach ($k in $navBtns.Keys) {
        if ($k -eq $name) {
            $navBtns[$k].Foreground = $blue
            $navBtns[$k].FontWeight = [System.Windows.FontWeights]::SemiBold
        } else {
            $navBtns[$k].Foreground = $gray
            $navBtns[$k].FontWeight = [System.Windows.FontWeights]::Normal
        }
    }
    if ($name -eq "env") { Update-EnvPanel }
    if ($name -eq "skills") { Update-SkillsPanel }
    if ($name -eq "restart") { Update-RestartPanel }
    if ($name -eq "home") { Update-OpenPanel }
    if ($name -eq "setup") { Update-SetupPanel }
}

function Set-DotColor($dot, [string]$color) {
    $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
}

function Update-OpenPanel {
    $up = Test-ServerUp
    $pid2 = Get-ServerPid
    if ($up) {
        Set-DotColor $openDot "#22A06B"
        $openState.Text = "服务运行中"
        if ($pid2) { $openDetail.Text = "http://127.0.0.1:3080 · PID $pid2 · 点击下方按钮打开浏览器" }
        else { $openDetail.Text = "http://127.0.0.1:3080" }
    } else {
        Set-DotColor $openDot "#F0A94A"
        $openState.Text = "服务未运行"
        $openDetail.Text = "点击「打开 Harness」将自动启动服务（约 5-15 秒）并打开浏览器"
    }
    $openLogBox.Text = Get-LogTail $OutLog
}

function Update-RestartPanel {
    $up = Test-ServerUp
    $pid2 = Get-ServerPid
    if ($up) {
        Set-DotColor $restartDot "#22A06B"
        $restartState.Text = "服务运行中 (PID $pid2)"
        $restartDetail.Text = "重启会先释放 3080 端口，再启动全新实例。若配置损坏，将自动以安全模式重试。"
    } else {
        Set-DotColor $restartDot "#F0A94A"
        $restartState.Text = "服务未运行"
        $restartDetail.Text = "当前没有服务在运行，点击「立即重启」将直接启动新实例。"
    }
    $restartLogBox.Text = Get-LogTail $ErrLog
}

# ------------------------------------------------------------ 环境装配(一键下载安装 DSH) ----
function Test-Cmd([string]$name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Get-DshState {
    $cmd = Get-Command dsh -ErrorAction SilentlyContinue
    if ($cmd) { return "已安装 ($($cmd.Source))" }
    $global = Join-Path $env:APPDATA "npm\node_modules\@deepseek-ai\dsh\lib\bin.js"
    if (Test-Path -LiteralPath $global) { return "已安装 (npm 全局)" }
    if (Test-Path -LiteralPath $DshBin) { return "已安装 (npm 缓存)" }
    return $null
}

function Update-SetupPanel {
    $node = Test-Cmd "node"
    $npm  = Test-Cmd "npm"
    $dsh  = Get-DshState
    $lines = @()
    if ($node) { $lines += "node ✓ $node" } else { $lines += "node ✗ 未检测到（请先安装 Node.js: https://nodejs.org）" }
    if ($npm)  { $lines += "npm  ✓ $npm" } else { $lines += "npm  ✗ 未检测到（随 Node.js 安装）" }
    if ($dsh)  { $lines += "dsh  ✓ $dsh" } else { $lines += "dsh  ✗ 未安装 → 点「一键装配」自动下载安装" }
    $setupState.Text = ($lines -join "`n")
    if (-not $script:setupRunning) { $setupLogBox.Text = "" }
}

function Start-SetupDsh {
    if ($script:setupRunning) { return }
    if (-not (Test-Cmd "node")) {
        $setupLogBox.Text = "未检测到 Node.js。请先到 https://nodejs.org 下载安装 LTS 版，再回来点一键装配。"
        return
    }
    if (-not (Test-Cmd "npm")) {
        $setupLogBox.Text = "npm 不可用，请重装 Node.js（安装包自带 npm）。"
        return
    }
    $script:setupRunning = $true
    $setupLogBox.Text = "开始安装 @deepseek-ai/dsh …（约 1-2 分钟，走 npmmirror 国内源）`n"
    $logFile = Join-Path $env:TEMP "dsh-setup.log"
    try { Remove-Item $logFile -Force -ErrorAction SilentlyContinue } catch { }
    $cmdline = "npm install -g @deepseek-ai/dsh --registry=https://registry.npmmirror.com > `"$logFile`" 2>&1"
    $script:setupProc = Start-Process cmd -ArgumentList '/c', $cmdline -WindowStyle Hidden -PassThru
    $script:setupTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:setupTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:setupTimer.Add_Tick({
        if ($script:setupProc.HasExited) {
            $script:setupTimer.Stop()
            $script:setupRunning = $false
            $tail = ""
            try { $tail = (Get-Content -LiteralPath "$env:TEMP\dsh-setup.log" -Tail 8 -ErrorAction SilentlyContinue) -join "`n" } catch { }
            $ok = (Get-DshState)
            if ($ok) {
                $setupLogBox.Text = "✓ 装配完成！DSH 已可用。`n$tail"
                $setupState.Text = "dsh ✓ $ok"
                Set-PetTalk "环境装好啦，随时可以开工~" $false $true
            } else {
                $setupLogBox.Text = "✗ 安装失败或未检测到 dsh，请看日志尾部：`n$tail"
                Invoke-PetSad "呜…装配失败了，看看日志再试一次吧~"
            }
        } else {
            try { $t = (Get-Content -LiteralPath "$env:TEMP\dsh-setup.log" -Tail 2 -ErrorAction SilentlyContinue) -join " "; $setupLogBox.Text = "安装中…`n$t" } catch { }
        }
    })
    $script:setupTimer.Start()
}

function Add-EnvRow($label, $value) {
    $row = [System.Windows.Controls.Grid]::new()
    $row.Margin = [System.Windows.Thickness]::new(14, 10, 14, 10)
    $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(150)
    $c2 = [System.Windows.Controls.ColumnDefinition]::new(); $c2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $row.ColumnDefinitions.Add($c1) | Out-Null
    $row.ColumnDefinitions.Add($c2) | Out-Null
    $lbl = [System.Windows.Controls.TextBlock]::new()
    $lbl.Text = $label
    $lbl.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#8A919E"))
    $lbl.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $val = [System.Windows.Controls.TextBlock]::new()
    $val.Text = $value
    $val.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#1F2329"))
    $val.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $val.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
    [System.Windows.Controls.Grid]::SetColumn($val, 1)
    $row.Children.Add($lbl) | Out-Null
    $row.Children.Add($val) | Out-Null
    $envRows.Children.Add($row) | Out-Null
}

function Update-EnvPanel {
    $envRows.Children.Clear()
    $info = Get-EnvInfo
    if ($info.Running) { Add-EnvRow "服务状态" "运行中" } else { Add-EnvRow "服务状态" "未运行" }
    Add-EnvRow "进程 PID" ($info.Pid -as [string])
    Add-EnvRow "启动时间" $info.StartTime
    Add-EnvRow "DSH 版本" $info.Version
    if ($info.Running) { Add-EnvRow "端口 3080" "监听中" } else { Add-EnvRow "端口 3080" "空闲" }
    Add-EnvRow "视觉 Key" $info.VisionKey
    Add-EnvRow "技能数量" $info.Skills
    Add-EnvRow "配置备份" $info.Backups
    Add-EnvRow "安全模式" $info.SafeMode
}

function Update-SkillsPanel {
    $skillCards.Children.Clear()
    $skills = @(Get-SkillList)
    $skillCountText.Text = "共 $($skills.Count) 个技能"
    if ($skills.Count -eq 0) {
        $t = [System.Windows.Controls.TextBlock]::new()
        $t.Text = "技能目录为空。"
        $t.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#8A919E"))
        $skillCards.Children.Add($t) | Out-Null
        return
    }
    foreach ($s in $skills) {
        $card = [System.Windows.Controls.Border]::new()
        $card.CornerRadius = [System.Windows.CornerRadius]::new(12)
        $card.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("White"))
        $card.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#E7EAF0"))
        $card.BorderThickness = [System.Windows.Thickness]::new(1)
        $card.Padding = [System.Windows.Thickness]::new(16, 12, 16, 12)
        $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
        $card.Cursor = [System.Windows.Input.Cursors]::Hand
        $sp = [System.Windows.Controls.StackPanel]::new()
        $name = [System.Windows.Controls.TextBlock]::new()
        $name.Text = $s.Name
        $name.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#1F2329"))
        $name.FontSize = 14
        $name.FontWeight = [System.Windows.FontWeights]::SemiBold
        $desc = [System.Windows.Controls.TextBlock]::new()
        if ($s.Description) { $desc.Text = $s.Description } else { $desc.Text = "(无描述)" }
        $desc.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#8A919E"))
        $desc.FontSize = 12
        $desc.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
        $desc.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $sp.Children.Add($name) | Out-Null
        $sp.Children.Add($desc) | Out-Null
        $card.Child = $sp
        $path = $s.Path
        $card.Add_MouseLeftButtonUp({ Start-Process explorer.exe -ArgumentList "`"$path`"" }) | Out-Null
        $card.Add_MouseEnter({ $card.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#F7F9FD")) }) | Out-Null
        $card.Add_MouseLeave({ $card.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("White")) }) | Out-Null
        $skillCards.Children.Add($card) | Out-Null
    }
}

# ------------------------------------------------------------ 动作流程 ----
function Start-OpenFlow {
    if ($script:busy) { return }
    $script:busy = $true
    $openState.Text = "正在打开…"
    $openDetail.Text = "如果服务未运行，将自动启动（约 5-15 秒）"
    if (Test-ServerUp) {
        Start-Process $Url
        $openState.Text = "已打开浏览器"
        $script:busy = $false
        return
    }
    $ok = Start-DshServer
    if (-not $ok) {
        $openState.Text = "启动失败：未找到 dsh 可执行文件"
        $script:busy = $false
        return
    }
    $openDetail.Text = "服务启动中，请稍候…"
    $script:openWaited = 0
    $script:openPoll = [System.Windows.Threading.DispatcherTimer]::new()
    $script:openPoll.Interval = [TimeSpan]::FromSeconds(1)
    $script:openPoll.Add_Tick({
        $script:openWaited++
        if (Test-ServerUp) {
            $script:openPoll.Stop()
            $script:busy = $false
            Start-Process $Url
            Update-OpenPanel
            Update-StatusAll
            $openState.Text = "服务已启动并打开浏览器"
        } elseif ($script:openWaited -gt 40) {
            $script:openPoll.Stop()
            $script:busy = $false
            $openState.Text = "启动超时，请查看日志"
            $openDetail.Text = Get-LogTail $ErrLog
        }
    })
    $script:openPoll.Start()
}

function Start-RestartFlow([bool]$openBrowser) {
    if ($script:busy) { return }
    $script:busy = $true
    $restartState.Text = "正在重启…"
    $restartDetail.Text = "释放端口 3080 → 启动新实例"
    Stop-DshServer
    $ok = Start-DshServer
    if (-not $ok) {
        $restartState.Text = "启动失败：未找到 dsh 可执行文件"
        $script:busy = $false
        return
    }
    $script:restartWaited = 0
    $script:restartPoll = [System.Windows.Threading.DispatcherTimer]::new()
    $script:restartPoll.Interval = [TimeSpan]::FromSeconds(1)
    $script:restartPoll.Add_Tick({
        $script:restartWaited++
        if (Test-ServerUp) {
            $script:restartPoll.Stop()
            $script:busy = $false
            Update-RestartPanel
            Update-StatusAll
            $restartState.Text = "重启完成 ✓"
            if ($openBrowser) { Start-Process $Url }
        } elseif ($script:restartWaited -gt 45) {
            $script:restartPoll.Stop()
            $script:busy = $false
            $restartState.Text = "重启超时（可能已安全模式重试中）"
            $restartDetail.Text = Get-LogTail $ErrLog
            Invoke-PetSad "呜…重启超时了，帮我看看日志嘛~"
        }
    })
    $script:restartPoll.Start()
}

function Update-StatusAll {
    $up = Test-ServerUp
    $pid2 = Get-ServerPid
    if ($up) { $color = "#22A06B"; $text = "运行中 · PID $pid2" }
    else { $color = "#F0A94A"; $text = "未运行" }
    Set-DotColor $minStatusDot $color
    $minStatusText.Text = $text
}

# ------------------------------------------------------------ 鲸鱼互动 ----
# 气泡: 跟随桌宠 + 淡入淡出 + 内容可变(闲聊/思考/庆祝/回嘴/系统提醒)
$script:bubbleHideAt = 0
function Set-Speech([string]$text, [bool]$showChips = $false, [int]$stayMs = 4200) {
    $speechText.Text = $text
    if ($showChips) { $speechChips.Visibility = [System.Windows.Visibility]::Visible }
    else { $speechChips.Visibility = [System.Windows.Visibility]::Collapsed }
    $bubbleRoot.Opacity = 0
    $da = [System.Windows.Media.Animation.DoubleAnimation]::new(1.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180)))
    $bubbleRoot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $da)
    $script:bubbleHideAt = $script:sw.ElapsedMilliseconds + $stayMs
    $script:lastIdleAt = [DateTime]::Now
}

function Hide-Bubble {
    if ($bubbleRoot.Opacity -gt 0.05) {
        $da = [System.Windows.Media.Animation.DoubleAnimation]::new(0.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(240)))
        $bubbleRoot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $da)
    }
    $script:bubbleHideAt = 0
}

function Say-Idle {
    $now = [DateTime]::Now
    if (($now - $script:lastIdleAt).TotalSeconds -lt 12) { return }
    if ($speechChips.Visibility -eq [System.Windows.Visibility]::Visible) { return }
    if ($script:pet.busy) { $line = $script:thinkLines | Get-Random }
    else { $line = $script:idleLines | Get-Random }
    Set-Speech $line
}

# ------------------------------------------------------------ 桌宠交互 ----
$script:pet.downX = 0.0
$script:pet.downY = 0.0
$script:pet.moved = $false

function Invoke-PetClicked([bool]$force = $false) {
    if ($script:pet.drag) { return }
    Set-PetTalk "怎么啦？想让我做什么？" $true $true
    Set-PetAnim "wave" $false
    Set-PetEmoji "👋"
}

function Invoke-PetJump {
    Set-PetAnim "jump" $false
    Set-PetEmoji "🎈"
}

# 失败动作模组(failed 动画 + 😵 + 台词): 装配/重启失败等场景调用
function Invoke-PetSad([string]$text) {
    Set-PetAnim "failed" $false
    Set-PetEmoji "😵"
    Set-PetTalk $text $false $true
}

function Add-PetMenuItem([string]$text, [string]$tag, [System.Windows.Controls.ContextMenu]$menu) {
    $mi = [System.Windows.Controls.MenuItem]::new()
    $mi.Header = $text
    $mi.Tag = $tag
    $mi.Add_Click({ param($s, $e) Invoke-PetMenu ([string]$s.Tag) })
    $menu.Items.Add($mi) | Out-Null
    return $mi
}

function Invoke-PetMenu([string]$tag) {
    $p = $script:pet
    switch ($tag) {
        "roam"   { $p.mode = "roam";   Set-PetTalk "好呀，我去溜达溜达~" }
        "follow" { $p.mode = "follow"; Set-PetTalk "我跟着你的鼠标走，嘿嘿~" }
        "stay"   { $p.mode = "stay";   Set-PetTalk "那我乖乖待着~" }
        "feed" {
            # 进食动作模组: wait(蹲坐) + 咀嚼挤压 + 🍪 持续, 4.5 秒后回待机
            Set-PetEmoji "🍪"
            Set-PetTalk "哇，谢谢你！啊呜一口~" $false $true
            Set-PetAnim "wait" $true
            $script:pet.feeding = $true
            $script:pet.feedT = 0
        }
        "bigger" {
            if ($script:petSize -lt 1.25) { $script:petSize += 0.10; Save-PetCfg; Set-PetTalk "再大一点就抱不动啦~" }
        }
        "smaller" {
            if ($script:petSize -gt 0.75) { $script:petSize -= 0.10; Save-PetCfg; Set-PetTalk "变小一点，方便你干活~" }
        }
        "exit" { Set-PetTalk "再见啦~"; $window.Close() }
    }
}

# 桌宠大小: 持久化(关闭重开保持上次的大小)
$script:petSize = 1.0
try {
    if (Test-Path -LiteralPath $PetCfgFile) {
        $cfg = Get-Content -LiteralPath $PetCfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.petSize -and $cfg.petSize -ge 0.5 -and $cfg.petSize -le 1.6) { $script:petSize = [double]$cfg.petSize }
    }
} catch { }

function Save-PetCfg {
    try {
        @{ petSize = $script:petSize } | ConvertTo-Json | Set-Content -LiteralPath $PetCfgFile -Encoding UTF8
    } catch { }
}
$script:petMenu = [System.Windows.Controls.ContextMenu]::new()
Add-PetMenuItem "🚶 散步模式" "roam" $script:petMenu | Out-Null
Add-PetMenuItem "🖱 跟随鼠标" "follow" $script:petMenu | Out-Null
Add-PetMenuItem "🏠 原地待着" "stay" $script:petMenu | Out-Null
$script:petMenu.Items.Add([System.Windows.Controls.Separator]::new()) | Out-Null
Add-PetMenuItem "🍪 喂食" "feed" $script:petMenu | Out-Null
Add-PetMenuItem "🔍 放大一点" "bigger" $script:petMenu | Out-Null
Add-PetMenuItem "🔎 缩小一点" "smaller" $script:petMenu | Out-Null
$script:petMenu.Items.Add([System.Windows.Controls.Separator]::new()) | Out-Null
Add-PetMenuItem "👋 退出" "exit" $script:petMenu | Out-Null
$petHost.ContextMenu = $script:petMenu

# 桌宠窗口交互: 双击跳 / 按住拖整窗(大肥鱼·Desktop-Pet 同款 DragMove) / 短按=单击挥手 / 右键菜单
$petHost.Add_MouseLeftButtonDown({
    param($s, $e)
    $p = $script:pet
    if ($e.ClickCount -ge 2) { Invoke-PetJump; return }
    $p.drag = $true
    $downAt = [DateTime]::Now
    Add-Content -Path "$env:TEMP\dsh-pet-click.log" -Value ("MOUSEDOWN hit, clickcount=" + $e.ClickCount)
    try { $petWin.DragMove() } catch { Add-Content -Path "$env:TEMP\dsh-pet-click.log" -Value ("DRAGMOVE-ERR: " + $_.Exception.Message) }
    $p.drag = $false
    Add-Content -Path "$env:TEMP\dsh-pet-click.log" -Value ("MOUSEDOWN done, dur=" + [int]([DateTime]::Now - $downAt).TotalMilliseconds)
    if (([DateTime]::Now - $downAt).TotalMilliseconds -lt 220) { Invoke-PetClicked }
})

# ------------------------------------------------------------ 事件绑定 ----
$window.FindName("BtnCloseMin").Add_Click({
    # 关闭 = 隐藏到托盘(桌面端常驻, 桌宠继续陪伴); 托盘菜单里才是真退出
    $window.Hide()
    try { $script:tray.ShowBalloonTip(2000, "DeepSeek Harness", "已隐藏到托盘，桌宠继续陪伴~ 托盘菜单可退出。", [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
})
$window.FindName("BtnMinMin").Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
$window.FindName("BtnPetToggle").Add_Click({
    if ($petWin.IsVisible) {
        $petWin.Hide()
        $window.FindName("BtnPetToggle").Content = "🐳 桌宠 关"
    } else {
        $petWin.Show()
        $window.FindName("BtnPetToggle").Content = "🐳 桌宠 开"
    }
})

# 导航
$window.FindName("NavHome").Add_Click({ Set-Panel "home" })
$window.FindName("NavEnv").Add_Click({ Set-Panel "env" })
$window.FindName("NavSkills").Add_Click({ Set-Panel "skills" })
$window.FindName("NavSetup").Add_Click({ Set-Panel "setup" })
$window.FindName("NavLogs").Add_Click({ if (Test-Path -LiteralPath $ErrLog) { Start-Process explorer.exe -ArgumentList "`"$ErrLog`"" } })
$window.FindName("NavBackup").Add_Click({ if (Test-Path -LiteralPath $BackupsRoot) { Start-Process explorer.exe -ArgumentList "`"$BackupsRoot`"" } })
$window.FindName("NavDshDir").Add_Click({ if (Test-Path -LiteralPath $DshHome) { Start-Process explorer.exe -ArgumentList "`"$DshHome`"" } })

# 主操作
$window.FindName("BtnOpen").Add_Click({ Start-OpenFlow })
$window.FindName("BtnRestart").Add_Click({ Set-Panel "restart" })
$window.FindName("BtnDoRestart").Add_Click({ Start-RestartFlow $false })
$window.FindName("BtnRestartOpen").Add_Click({ Start-RestartFlow $true })
$window.FindName("BtnEnvRefresh").Add_Click({ Update-EnvPanel })
$window.FindName("BtnSetupGo").Add_Click({ Start-SetupDsh })
$window.FindName("BtnOpenSkillsDir").Add_Click({ if (Test-Path -LiteralPath $SkillsRoot) { Start-Process explorer.exe -ArgumentList "`"$SkillsRoot`"" } })

# 桌宠气泡内的操作按钮
$petWin.FindName("ChipOpen").Add_Click({ Set-Speech "好嘞，这就帮你打开~"; Start-OpenFlow })
$petWin.FindName("ChipRestart").Add_Click({ Set-Speech "收到，正在重启，等我一下下~"; Start-RestartFlow $true })
$petWin.FindName("ChipEnv").Add_Click({
    Set-Speech "环境信息在控制台里更清楚，这就带你过去~"
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate()
    Set-Panel "env"
    Update-StatusAll
})
$petWin.FindName("ChipSkills").Add_Click({
    Set-Speech "技能库走这边，看看新朋友~"
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate()
    Set-Panel "skills"
    Update-StatusAll
})
$petWin.FindName("ChipPet").Add_Click({ Set-Speech ($script:petLines | Get-Random); Set-PetAnim "wave" $false; Set-PetEmoji "😊" })
$petWin.FindName("ChipTalk").Add_Click({ Set-Speech ($script:talkLines | Get-Random) })

# 标题栏拖拽
$window.FindName("MinBar").Add_MouseLeftButtonDown({ $window.DragMove() })

# ------------------------------------------------------------ 托盘(桌面端常驻) ----
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -MemberDefinition @"
[DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int i);
[DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr h, int i, int v);
"@ -Name WinLong -Namespace DSH

$script:clickThrough = $false
$script:autoStart = $false
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
try { if (Get-ItemProperty -Path $RunKey -Name "DSHLauncher" -ErrorAction SilentlyContinue) { $script:autoStart = $true } } catch { }

$script:tray = [System.Windows.Forms.NotifyIcon]::new()
$script:tray.Text = "DeepSeek Harness"
try { $script:tray.Icon = [System.Drawing.Icon]::new((Join-Path $ScriptDir "dsh-whale-girl.ico")) } catch { }
$script:tray.Visible = $true

$script:trayMenu = [System.Windows.Forms.ContextMenuStrip]::new()
function Add-TrayItem([string]$text, [scriptblock]$action) {
    $mi = [System.Windows.Forms.ToolStripMenuItem]::new()
    $mi.Text = $text
    $mi.Add_Click({ & $action })
    $script:trayMenu.Items.Add($mi) | Out-Null
    return $mi
}

Add-TrayItem "打开控制台" {
    $window.Show()
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate()
} | Out-Null
Add-TrayItem "显示/隐藏桌宠" {
    if ($petWin.IsVisible) {
        $petWin.Hide()
        $window.FindName("BtnPetToggle").Content = "🐳 桌宠 关"
    } else {
        $petWin.Show()
        $window.FindName("BtnPetToggle").Content = "🐳 桌宠 开"
    }
} | Out-Null
$script:miThrough = Add-TrayItem "鼠标穿透桌宠: 关" {
    $script:clickThrough = -not $script:clickThrough
    $hwnd = ([System.Windows.Interop.WindowInteropHelper]::new($petWin)).Handle
    $ex = [DSH.WinLong]::GetWindowLong($hwnd, -20)
    if ($script:clickThrough) { $ex = $ex -bor 0x20 -bor 0x80000 } else { $ex = $ex -band (-bnot 0x20) }
    [DSH.WinLong]::SetWindowLong($hwnd, -20, $ex) | Out-Null
    $script:miThrough.Text = "鼠标穿透桌宠: " + $(if ($script:clickThrough) { "开" } else { "关" })
}
$script:miAutoStart = Add-TrayItem ("开机自启: " + $(if ($script:autoStart) { "开" } else { "关" })) {
    $script:autoStart = -not $script:autoStart
    try {
        if ($script:autoStart) {
            $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $ScriptDir 'dsh-launcher.ps1') + '" -HideConsole'
            Set-ItemProperty -Path $RunKey -Name "DSHLauncher" -Value $cmd
        } else {
            Remove-ItemProperty -Path $RunKey -Name "DSHLauncher" -ErrorAction SilentlyContinue
        }
    } catch { }
    $script:miAutoStart.Text = "开机自启: " + $(if ($script:autoStart) { "开" } else { "关" })
}
$script:trayMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null
Add-TrayItem "退出" { $window.Close() } | Out-Null
$script:tray.ContextMenuStrip = $script:trayMenu
$script:tray.Add_DoubleClick({
    $window.Show()
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate()
})

# ------------------------------------------------------------ DSH 会话活跃度联动 ----
# sessions 目录最近 15s 内有写入 → 主人在忙: 桌宠切 think/review 动画
# 忙完(持续>20s) → 跳跃庆祝 + 台词
function Update-PetBusy {
    if ($NoBusy) { $script:pet.busy = $false; return }
    $busy = $false
    if (Test-Path -LiteralPath $SessionsDir) {
        try {
            $newest = Get-ChildItem -LiteralPath $SessionsDir -File -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest -and ([DateTime]::Now - $newest.LastWriteTime).TotalSeconds -lt 15) { $busy = $true }
        } catch { }
    }
    $p = $script:pet
    if ($busy -and -not $p.busy) {
        $p.busy = $true
        $p.busyAt = [DateTime]::Now
        Set-PetTalk "主人在忙呢，我陪你一起~"
    } elseif (-not $busy -and $p.busy) {
        $p.busy = $false
        $p.wasBusy = $true
        if ($p.busyAt) {
            $sec = ([DateTime]::Now - $p.busyAt).TotalSeconds
            $p.busyAt = $null
            if ($sec -gt 20) {
                Set-PetAnim "jump" $false
                Set-PetEmoji "🎉"
                Set-PetTalk "忙完啦！任务完成，辛苦啦~"
            }
        }
    }

    # 系统监控(借鉴 大肥鱼桌宠): 每 12 秒检查一次, 超阈值冒泡提醒
    $script:sysTick++
    if ($script:sysTick % 4 -eq 0) {
        try {
            $mem = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($mem -and $mem.TotalVisibleMemorySize -gt 0) {
                $memPct = 100 * (1 - $mem.FreePhysicalMemory / $mem.TotalVisibleMemorySize)
                if ($memPct -gt 90) { Set-PetTalk ("内存快满啦 ({0:N0}%)，记得清理哦~" -f $memPct) }
            }
            $cpuAvg = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average).Average
            if ($cpuAvg -and $cpuAvg -gt 85) { Set-PetTalk ("CPU 好烫 ({0:N0}%)，喝口水歇歇~" -f $cpuAvg) }
        } catch { }
    }
}

# ------------------------------------------------------------ 定时器 ----
# 状态刷新 + 会话活跃度 (3s)
$script:statusTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:statusTimer.Interval = [TimeSpan]::FromSeconds(3)
$script:statusTimer.Add_Tick({
    Update-StatusAll
    Update-PetBusy
})
$script:statusTimer.Start()

# 桌宠行为循环 (100ms)
$script:petTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:petTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:petTimer.Add_Tick({
    Update-Pet
    if ($script:heroTT) { $script:heroTT.Y = [Math]::Sin($script:pet.phase * 0.6) * 7 }
})
$script:petTimer.Start()

# 待机台词 (4s 检查一次)
$script:idleTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:idleTimer.Interval = [TimeSpan]::FromSeconds(4)
$script:idleTimer.Add_Tick({ Say-Idle })
$script:idleTimer.Start()

# ------------------------------------------------------------ 启动 ----
Set-PetAnim "idle"
[System.Windows.Controls.Canvas]::SetLeft($petHost, $script:pet.x)
[System.Windows.Controls.Canvas]::SetTop($petHost, $script:pet.y)

Update-StatusAll
Update-OpenPanel
Update-RestartPanel

# 桌宠默认显示(独立透明置顶窗口), 可用主界面顶栏开关隐藏
$petWin.Show()
# DPI 比例: 鼠标物理坐标→逻辑坐标换算(窗口级移动用)
$script:dpiScale = 1.0
try { $script:dpiScale = [System.Windows.PresentationSource]::FromVisual($petWin).CompositionTarget.TransformToDevice.M11 } catch { }
Set-Speech "你好呀，我是 DSH 的小鲸鱼助手~ 点我一下，看看我能帮你做什么？" $true 8000

# 自动测试: 1.5秒模拟点击鲸鱼, 2.5秒验证"抛错不死"(L6防火墙), 6秒后自动关闭
if ($AutoTest) {
    $script:testTick = [System.Windows.Threading.DispatcherTimer]::new()
    $script:testTick.Interval = [TimeSpan]::FromMilliseconds(1500)
    $script:testTick.Add_Tick({
        $script:testTick.Stop()
        Invoke-PetClicked
    })
    $script:testTick.Start()
    $script:boomTick = [System.Windows.Threading.DispatcherTimer]::new()
    $script:boomTick.Interval = [TimeSpan]::FromMilliseconds(2500)
    $script:boomTick.Add_Tick({
        $script:boomTick.Stop()
        throw "TEST-UI-BOOM (window must survive)"
    })
    $script:boomTick.Start()
    $script:surviveTick = [System.Windows.Threading.DispatcherTimer]::new()
    $script:surviveTick.Interval = [TimeSpan]::FromMilliseconds(3200)
    $script:surviveTick.Add_Tick({
        $script:surviveTick.Stop()
        Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value "BOOM-SURVIVED window still alive"
    })
    $script:surviveTick.Start()
    $script:testClose = [System.Windows.Threading.DispatcherTimer]::new()
    $script:testClose.Interval = [TimeSpan]::FromSeconds(6)
    $script:testClose.Add_Tick({
        $script:testClose.Stop()
        $window.Close()
    })
    $script:testClose.Start()
}

if ($Diag) {
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    $t.Interval = [TimeSpan]::FromSeconds(2)
    $t.Add_Tick({
        $t.Stop()
        $hero = $window.FindName("HeroWhale")
        $pet = $petImage
        Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value ("DIAG hero: src=" + ($null -ne $hero.Source) + " w=" + $hero.ActualWidth + " h=" + $hero.ActualHeight + " vis=" + $hero.Visibility)
        Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value ("DIAG pet:  src=" + ($null -ne $pet.Source) + " w=" + $pet.ActualWidth + " h=" + $pet.ActualHeight)
        Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value ("DIAG pet2:  anim=" + $script:pet.anim + " aIdx=" + $script:pet.aIdx + " mode=" + $script:pet.mode + " busy=" + $script:pet.busy + " size=" + $script:petSize + " hasAtlas=" + $script:petHasAtlas + " petWinVis=" + $petWin.IsVisible)
        Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value ("DIAG emoji: vis=" + $petEmoji.Visibility + " text=" + $petEmoji.Text + " talkCd=" + $script:pet.talkCd)
        Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value ("DIAG window: actualW=" + $window.ActualWidth + " actualH=" + $window.ActualHeight)
        $window.Close()
    })
    $t.Start()
}

# 主窗口关闭时同步关闭桌宠窗口并强制退出
# (BeginInvokeShutdown/ExitAllFrames/Environment.Exit 在此双窗口场景下都不可靠, 进程会残留;
#  最小实验证实 Stop-Process 自身是唯一稳定退出方式)
$window.Add_Closed({
    try { $petWin.Close() } catch { }
    Stop-Process -Id $PID -Force
})

# 非模态双窗口: Show() 代替 ShowDialog(), 否则模态会禁用桌宠窗口的一切点击
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
