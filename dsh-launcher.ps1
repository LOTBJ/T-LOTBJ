# ============================================================================
# DeepSeek Harness 启动器 (WPF 官网风格控制台 · 主体)
# 桌宠: 依附的 bigfish 鲸鱼娘(dsh-whale-pet.py, PySide6), 启动器拉起/退出
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File dsh-launcher.ps1
#       可选参数: -HideConsole  启动后隐藏控制台窗口(桌面快捷键使用)
#                -AutoTest     自动测试: 验证防崩防火墙后自动关闭
# 功能: 打开 / 一键重启 / 环境状态 / 技能库 / 装配 / 日志 / 备份目录
#       桌宠开关: 拉起/关闭 python 桌宠进程(顶栏 🐳 按钮 / 托盘菜单)
# 桌宠素材与代码: dafeiyu-pet (MIT) + fornarwhal/deepseek-whale-girl-icon
#                 (CC BY-NC-SA 4.0, 非商用, 署名)
# ============================================================================
param([string]$Theme = "minimal", [switch]$HideConsole, [switch]$AutoTest, [switch]$Diag, [switch]$NoBusy)

# 单实例保护: 防止双击快捷方式启动多个实例(多个桌宠/状态混乱)
$script:isFirstInstance = $false
$script:singleMutex = [System.Threading.Mutex]::new($true, "Global\DSHLauncher-Single", [ref]$script:isFirstInstance)
if (-not $script:isFirstInstance) {
    try {
        Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h); [DllImport("user32.dll")] public static extern System.IntPtr FindWindow(string c, string n);' -Name WinAct -Namespace DSH
        $h = [DSH.WinAct]::FindWindow($null, "DeepSeek Harness")
        if ($h -ne [IntPtr]::Zero) { [DSH.WinAct]::SetForegroundWindow($h) | Out-Null }
    } catch { }
    exit 0
}

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
$OfficialWhale = Join-Path $PetDir "official-whale.png"
$SessionsDir = Join-Path $DshHome "sessions"
$SkillsRoot  = Join-Path $DshHome "skills"
$BackupsRoot = Join-Path $DshHome "backups"
$PetCfgFile  = Join-Path $DshHome "launcher-pet.json"
$WallpaperDir = Join-Path $DshHome "wallpapers"
$Url         = "http://127.0.0.1:3080"

# ------------------------------------------------------------- 工具函数 ----
function Get-ServerPid {
    $conn = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { return $conn.OwningProcess }
    return $null
}

function Test-ServerUp {
    # 端口优先(毫秒级): 无监听直接判未运行, 避免服务挂掉时 HTTP 请求每 3 秒卡 UI 2 秒
    if (-not (Get-ServerPid)) { return $false }
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 1
        return ($null -ne $r -and $r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
    } catch { return $false }
}

function Start-DshServer {
    if (-not (Test-Path -LiteralPath $NodeExe)) { $script:NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source }
    if (-not (Test-Path -LiteralPath $DshBin))  { $script:DshBin  = (Get-Command dsh -ErrorAction SilentlyContinue).Source }
    if (-not (Test-Path -LiteralPath $DshBin))  { return $false }
    # 日志文件可能被刚杀掉的旧实例短暂锁定 → 最多重试 5 次
    for ($i = 0; $i -lt 5; $i++) {
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
            Start-Sleep -Milliseconds 800
        }
    }
    return $false
}

function Stop-DshServer {
    $pid2 = Get-ServerPid
    if ($pid2) {
        # 杀整棵进程树(node 常有子进程残留: 锁日志文件+占端口, 导致重启失效)
        try { Start-Process taskkill -ArgumentList '/PID', $pid2, '/T', '/F' -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue } catch { }
        Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 1200
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
              <Border CornerRadius="20" Background="#F2FFFFFF" BorderBrush="#B3FFFFFF" BorderThickness="1" Padding="28,26" Width="560">
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
              <Border CornerRadius="20" Background="#F2FFFFFF" BorderBrush="#B3FFFFFF" BorderThickness="1" Padding="28,26" Width="600">
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

            <!-- 环境装配面板 (一键下载安装 DSH 运行环境, 借鉴大肥鱼"别人一键装配"思路) -->
            <StackPanel x:Name="PanelSetup" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Border CornerRadius="20" Background="#F2FFFFFF" BorderBrush="#B3FFFFFF" BorderThickness="1" Padding="28,26" Width="580">
                <StackPanel>
                  <TextBlock Text="环 境 装 配" Foreground="#152443" FontSize="16" FontWeight="SemiBold"/>
                  <TextBlock Text="新机器一键装配 DSH 运行环境：检测 node/npm → 自动下载安装 dsh → 生成配置，开箱即用。" Foreground="#8A919E" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
                  <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                    <TextBlock x:Name="SetupState" Text="检测中…" Foreground="#1E232C" FontSize="13.5" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap" Width="400"/>
                    <Button x:Name="BtnSetupGo" Style="{StaticResource PrimaryBtn}" Content="🔧 一键装配" Height="44" Background="#4D6BFE" Padding="26,0" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                  </StackPanel>
                  <Border CornerRadius="12" Background="#26FFFFFF" BorderBrush="#55FFFFFF" BorderThickness="1" Padding="12,10" Margin="0,14,0,0">
                    <TextBlock x:Name="SetupLogBox" Text="" Foreground="#5B6472" FontSize="11.5" FontFamily="Consolas" TextWrapping="Wrap" MaxHeight="160"/>
                  </Border>
                </StackPanel>
              </Border>
            </StackPanel>

            <!-- 壁纸中心 (自选壁纸: 预览/添加/URL下载/设为背景/删除) -->
            <StackPanel x:Name="PanelWallpaper" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Border CornerRadius="20" Background="#F2FFFFFF" BorderBrush="#B3FFFFFF" BorderThickness="1" Padding="28,26" Width="680">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="壁 纸 中 心" Foreground="#152443" FontSize="16" FontWeight="SemiBold"/>
                    <TextBlock Text="用你自己的图(即梦/截图/下载)做 DSH 背景; 玻璃材质在 DSH 设置里自行开关, 互不干扰" Foreground="#8A919E" FontSize="12" Margin="12,0,0,0" VerticalAlignment="Center"/>
                    <Button x:Name="BtnWallpaperAdd" Style="{StaticResource GhostBtn}" Content="➕ 添加图片" FontSize="12" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    <Button x:Name="BtnWallpaperUrl" Style="{StaticResource GhostBtn}" Content="⬇️ URL 下载" FontSize="12" Margin="8,0,0,0" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    <Button x:Name="BtnWallpaperReset" Style="{StaticResource GhostBtn}" Content="↩ 恢复默认(无壁纸)" FontSize="12" Margin="8,0,0,0" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                  </StackPanel>
                  <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="360" Margin="0,14,0,0">
                    <WrapPanel x:Name="WallpaperGrid"/>
                  </ScrollViewer>
                  <TextBlock x:Name="WallpaperHint" Text="" Foreground="#8A919E" FontSize="11" Margin="0,10,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </Grid>

          <!-- footer 链接行 -->
          <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Button x:Name="NavHome" Style="{StaticResource FooterLink}" Content="首页" Margin="0,0,14,0"/>
            <Button x:Name="NavEnv" Style="{StaticResource FooterLink}" Content="环境信息" Margin="0,0,14,0"/>
            <Button x:Name="NavSkills" Style="{StaticResource FooterLink}" Content="技能库" Margin="0,0,14,0"/>
            <Button x:Name="NavWallpaper" Style="{StaticResource FooterLink}" Content="壁纸中心" Margin="0,0,14,0"/>
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

# ------------------------------------------------------------ 加载窗口 ----
$xml = [xml]$xaml
$reader = [System.Xml.XmlNodeReader]::new($xml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

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
$envRows = $window.FindName("EnvRows")
$skillCards = $window.FindName("SkillCards")
$skillCountText = $window.FindName("SkillCountText")
$setupState = $window.FindName("SetupState")
$wallpaperGrid = $window.FindName("WallpaperGrid")
$wallpaperHint = $window.FindName("WallpaperHint")
$setupLogBox = $window.FindName("SetupLogBox")

$panels = @{
    home    = $window.FindName("PanelHome")
    env     = $window.FindName("PanelEnv")
    skills  = $window.FindName("PanelSkills")
    setup   = $window.FindName("PanelSetup")
    wallpaper = $window.FindName("PanelWallpaper")
}
$navBtns = @{
    home   = $window.FindName("NavHome")
    env    = $window.FindName("NavEnv")
    skills = $window.FindName("NavSkills")
    setup  = $window.FindName("NavSetup")
    wallpaper = $window.FindName("NavWallpaper")
}

# ------------------------------------------------------------ 全局状态 ----
$script:currentPanel = "home"
$script:busy         = $false
$script:setupRunning = $false
$script:skillsCache  = $null
$script:skillsCacheAt = [DateTime]::MinValue

# ------------------------------------------------------------ 桌宠进程管理(依附 bigfish Python 桌宠) ----
$script:PetScript = Join-Path $ScriptDir "dsh-whale-pet.py"
$script:petProc = $null
function Start-Pet {
    try {
        if ($script:petProc -and -not $script:petProc.HasExited) { return }
        # pythonw 优先(无控制台窗口); 回退 python + Hidden
        $python = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
        if ($python) {
            $script:petProc = Start-Process $python -ArgumentList ('"' + $script:PetScript + '"') -WorkingDirectory $ScriptDir -PassThru
        } else {
            $python = (Get-Command python -ErrorAction SilentlyContinue).Source
            if ($python) {
                $script:petProc = Start-Process $python -ArgumentList ('"' + $script:PetScript + '"') -WorkingDirectory $ScriptDir -WindowStyle Hidden -PassThru
            }
        }
    } catch { }
}
function Stop-Pet {
    try {
        if ($script:petProc -and -not $script:petProc.HasExited) { $script:petProc.Kill() }
    } catch { }
}
function Get-PetAlive {
    return ($script:petProc -and -not $script:petProc.HasExited)
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
    if ($name -eq "home") { Update-OpenPanel }
    if ($name -eq "setup") { Update-SetupPanel }
    if ($name -eq "wallpaper") { Update-WallpaperPanel }
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

# ------------------------------------------------------------ 壁纸中心 ----
$script:WallpaperStatic = "C:\Users\tang\AppData\Local\npm-cache\_npx\1e7f6d9597241db0\node_modules\@deepseek-ai\dsh-web-frontend\dist\wallpaper"

function Set-Wallpaper([string]$srcPath) {
    try {
        New-Item -ItemType Directory -Force -Path $script:WallpaperStatic | Out-Null
        Copy-Item -LiteralPath $srcPath -Destination (Join-Path $script:WallpaperStatic "current.png") -Force
        Update-WallpaperHtml $true
        Show-WallpaperHint "✓ 壁纸已写入页面背景。注意: 默认UI是不透明白色, 会遮住壁纸——在 DSH 设置里开启玻璃材质后才能透出; 之后刷新网页(F5)生效。"
        return $true
    } catch {
        Show-WallpaperHint "设置失败: $($_.Exception.Message)"
        return $false
    }
}

function Reset-Wallpaper {
    try {
        Remove-Item -LiteralPath (Join-Path $script:WallpaperStatic "current.png") -Force -ErrorAction SilentlyContinue
        Update-WallpaperHtml $false
        Show-WallpaperHint "✓ 已移除壁纸背景。刷新网页(F5)后恢复默认。"
    } catch {
        Show-WallpaperHint "恢复失败: $($_.Exception.Message)"
    }
}

# 改写 dist/index.html 内联样式 <style id="dsh-wallpaper-css">:
#   $apply=$true  注入 body 壁纸背景(刷新 ?t= 时间戳防缓存; 样式块缺失时自动补插)
#   $apply=$false 清空为 background:none(不删样式块, 便于下次再设)
# 走 HTML 而非 JS 插件: index.html 每次请求从磁盘下发, 不受 JS 包缓存影响(坑#26)
function Update-WallpaperHtml([bool]$apply) {
    $html = Join-Path (Split-Path $script:WallpaperStatic -Parent) "index.html"
    if (-not (Test-Path -LiteralPath $html)) { return }
    $text = [IO.File]::ReadAllText($html, [Text.UTF8Encoding]::new($false))
    if ($apply) {
        $ts = [DateTime]::Now.Ticks
        if ($text.Contains('body{background:none !important;}')) {
            # Reset 清空过: 恢复 url
            $text = $text.Replace('body{background:none !important;}',
                "body{background:url(/wallpaper/current.png?t=$ts) center/cover no-repeat fixed !important;}")
        } elseif ($text.Contains('wallpaper/current.png?t=')) {
            # 已有 url: 仅刷新时间戳(用 MatchEvaluator, 避开替换串里 $ 的坑)
            $rx = [regex]'wallpaper/current\.png\?t=[^)]*'
            $text = $rx.Replace($text, { param($m) "wallpaper/current.png?t=$ts" })
        } else {
            # DSH 更新覆盖过 index.html: 样式块丢失, 重新插入 </head> 前
            $block = "    <style id=`"dsh-wallpaper-css`">`n" +
                     "      /* 壁纸中心注入层(启动器配套): 直接覆盖 body 背景; 默认UI不透明白色会遮住, 开启玻璃材质后透出 */`n" +
                     "      body{background:url(/wallpaper/current.png?t=$ts) center/cover no-repeat fixed !important;}`n" +
                     "    </style>`n  </head>"
            $text = $text.Replace('</head>', $block)
        }
    } else {
        $text = $text -replace 'body\{background:url\([^)]*\) center/cover no-repeat fixed !important;\}',
            'body{background:none !important;}'
    }
    [IO.File]::WriteAllText($html, $text, [Text.UTF8Encoding]::new($false))
}

# 壁纸提示(自动消失, ~8s): 解决"成功提示永久留在面板上"的观感问题
function Show-WallpaperHint([string]$text) {
    $wallpaperHint.Text = $text
    if (-not $script:wallpaperHintTimer) {
        $script:wallpaperHintTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:wallpaperHintTimer.Interval = [TimeSpan]::FromSeconds(8)
        $script:wallpaperHintTimer.Add_Tick({
            $script:wallpaperHintTimer.Stop()
            $wallpaperHint.Text = ""
        })
    }
    $script:wallpaperHintTimer.Stop()
    $script:wallpaperHintTimer.Start()
}

function Update-WallpaperPanel {
    $wallpaperGrid.Children.Clear()
    New-Item -ItemType Directory -Force -Path $WallpaperDir | Out-Null
    $files = @(Get-ChildItem -LiteralPath $WallpaperDir -File | Where-Object { $_.Extension -match '\.(png|jpg|jpeg|webp|bmp|gif)$' } | Sort-Object LastWriteTime -Descending)
    $cur = Join-Path $script:WallpaperStatic "current.png"
    if ($files.Count -eq 0) {
        $t = [System.Windows.Controls.TextBlock]::new()
        $t.Text = "壁纸库是空的。点「➕ 添加图片」选你本地图（即梦下载的图直接选），或「⬇️ URL 下载」粘链接。"
        $t.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#8A919E"))
        $t.FontSize = 12
        $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $t.Width = 560
        $wallpaperGrid.Children.Add($t) | Out-Null
        $wallpaperHint.Text = "壁纸库: $WallpaperDir"
        return
    }
    $isCurrent = $false
    if (Test-Path -LiteralPath $cur) { $isCurrent = $true }
    foreach ($f in $files) {
        $card = [System.Windows.Controls.Border]::new()
        $card.Width = 190
        $card.CornerRadius = [System.Windows.CornerRadius]::new(12)
        $card.Background = [System.Windows.Media.Brushes]::White
        $card.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#E0E4EC"))
        $card.BorderThickness = [System.Windows.Thickness]::new(1)
        $card.Margin = [System.Windows.Thickness]::new(0, 0, 12, 12)
        $sp = [System.Windows.Controls.StackPanel]::new()
        # 缩略图
        $img = [System.Windows.Controls.Image]::new()
        $img.Width = 188
        $img.Height = 105
        $img.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        try {
            $bi = [System.Windows.Media.Imaging.BitmapImage]::new()
            $bi.BeginInit()
            $bi.UriSource = [System.Uri]::new($f.FullName)
            $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.DecodePixelWidth = 376
            $bi.EndInit()
            $bi.Freeze()
            $img.Source = $bi
        } catch { }
        # 名称
        $nm = [System.Windows.Controls.TextBlock]::new()
        $nm.Text = $f.Name
        $nm.FontSize = 11
        $nm.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#3D4350"))
        $nm.Margin = [System.Windows.Thickness]::new(8, 6, 8, 0)
        $nm.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        # 按钮行
        $btns = [System.Windows.Controls.StackPanel]::new()
        $btns.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $btns.Margin = [System.Windows.Thickness]::new(8, 6, 8, 8)
        $bSet = [System.Windows.Controls.Button]::new()
        $bSet.Content = "✅ 设为背景"
        $bSet.FontSize = 11
        $bSet.Style = $window.FindResource("GhostBtn")
        $bSet.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        # 路径存 Tag: 事件处理器闭包读不到循环局部变量(老坑), 经 $s.Tag 传递
        $bSet.Tag = $f.FullName
        $bSet.Add_Click({ param($s, $e) Set-Wallpaper ([string]$s.Tag) })
        $bDel = [System.Windows.Controls.Button]::new()
        $bDel.Content = "🗑"
        $bDel.FontSize = 11
        $bDel.Style = $window.FindResource("GhostBtn")
        $bDel.Tag = $f.FullName
        $bDel.Add_Click({
            param($s, $e)
            Remove-Item -LiteralPath ([string]$s.Tag) -Force -ErrorAction SilentlyContinue
            Update-WallpaperPanel
        })
        $btns.Children.Add($bSet) | Out-Null
        $btns.Children.Add($bDel) | Out-Null
        $sp.Children.Add($img) | Out-Null
        $sp.Children.Add($nm) | Out-Null
        $sp.Children.Add($btns) | Out-Null
        $card.Child = $sp
        $wallpaperGrid.Children.Add($card) | Out-Null
    }
    $wallpaperHint.Text = "壁纸库: $WallpaperDir ($($files.Count) 张) · 壁纸写入 DSH 页面背景; 默认UI不透明白色会遮住它, 开启玻璃材质(DSH设置)后透出 · 刷新网页生效"
}

function Add-WallpaperFile {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Filter = "图片文件|*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.gif"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        New-Item -ItemType Directory -Force -Path $WallpaperDir | Out-Null
        $dest = Join-Path $WallpaperDir ([System.IO.Path]::GetFileName($dlg.FileName))
        Copy-Item -LiteralPath $dlg.FileName -Destination $dest -Force
        Update-WallpaperPanel
    }
}

function Add-WallpaperUrl {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $u = [Microsoft.VisualBasic.Interaction]::InputBox("粘贴图片链接（jpg/png/webp）：", "URL 下载壁纸", "")
    if (-not $u) { return }
    try {
        $ext = [System.IO.Path]::GetExtension($u)
        if ($ext -notmatch '\.(png|jpg|jpeg|webp|bmp|gif)$') { $ext = ".png" }
        New-Item -ItemType Directory -Force -Path $WallpaperDir | Out-Null
        $dest = Join-Path $WallpaperDir ("wp-" + (Get-Date -Format "yyyyMMdd-HHmmss") + $ext)
        Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing -TimeoutSec 30
        Update-WallpaperPanel
        Show-WallpaperHint "✓ 下载完成，点「设为背景」应用。"
    } catch {
        Show-WallpaperHint "下载失败: $($_.Exception.Message)"
    }
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
            } else {
                $setupLogBox.Text = "✗ 安装失败或未检测到 dsh，请看日志尾部：`n$tail"
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
    # 缓存技能列表(30 秒内重复切换面板不再扫目录, 减少卡顿)
    if ($null -eq $script:skillsCache -or $script:skillsCacheAt -lt ([DateTime]::Now - [TimeSpan]::FromSeconds(30))) {
        $script:skillsCache = @(Get-SkillList)
        $script:skillsCacheAt = [DateTime]::Now
    }
    $skillCards.Children.Clear()
    $skills = $script:skillsCache
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
# 打开 DSH 界面: 独立 Edge 实例(独立 profile + app 窗口), 不和使用中的 Edge 混在一起
function Start-DshUrl {
    $edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path -LiteralPath $edge)) { $edge = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }
    $profile = Join-Path $DshHome "edge-dsh"
    # PWA 优先: 已安装 DSH PWA 时经 shell:AppsFolder 启动 → 任务栏鲸鱼娘独立图标
    # (注意: 目录名与 AppID 后缀不一致, 必须用 Get-StartApps 查, 不能手写 app-id)
    $appId = ""
    try {
        $app = Get-StartApps | Where-Object { $_.Name -eq "DeepSeek Harness" } | Select-Object -First 1
        if ($app) { $appId = $app.AppID }
    } catch { }
    try {
        if ($appId) {
            Start-Process "shell:AppsFolder\$appId"
        } elseif (Test-Path -LiteralPath $edge) {
            Start-Process $edge -ArgumentList "--user-data-dir=`"$profile`"", "--app=$Url"
        } else {
            Start-Process $Url
        }
    } catch {
        Start-Process $Url
    }
}

function Start-OpenFlow {
    if ($script:busy) { $openState.Text = "正在忙，请稍候…"; return }
    $script:busy = $true
    $script:busySince = [DateTime]::Now
    $openState.Text = "正在打开…"
    $openDetail.Text = "如果服务未运行，将自动启动（约 5-15 秒）"
    if (Test-ServerUp) {
        Start-DshUrl
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
            Start-DshUrl
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
    if ($script:busy) {
        $openState.Text = "正在忙，请稍候…"
        return
    }
    $script:busy = $true
    $script:busySince = [DateTime]::Now
    $openState.Text = "正在重启…"
    Stop-DshServer
    $ok = Start-DshServer
    if (-not $ok) {
        $openState.Text = "启动失败：未找到 dsh 可执行文件"
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
            Update-StatusAll
            $openState.Text = "重启完成 ✓"
            if ($openBrowser) { Start-DshUrl }
        } elseif ($script:restartWaited -gt 45) {
            $script:restartPoll.Stop()
            $script:busy = $false
            $openState.Text = "重启超时，请查看日志"
            $openLogBox.Text = Get-LogTail $ErrLog
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

# ------------------------------------------------------------ 事件绑定 ----
$window.FindName("BtnCloseMin").Add_Click({
    # 直接关闭: 整个退出(含桌宠), 不驻留后台
    $window.Close()
})
$window.FindName("BtnMinMin").Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
$window.FindName("BtnPetToggle").Add_Click({
    # 桌宠 = 依附的 bigfish Python 进程: 开关 = 拉起/关闭进程
    if (Get-PetAlive) {
        Stop-Pet
        $window.FindName("BtnPetToggle").Content = "🐳 桌宠 关"
    } else {
        Start-Pet
        $window.FindName("BtnPetToggle").Content = "🐳 桌宠 开"
    }
})

# 导航
$window.FindName("NavHome").Add_Click({ Set-Panel "home" })
$window.FindName("NavEnv").Add_Click({ Set-Panel "env" })
$window.FindName("NavSkills").Add_Click({ Set-Panel "skills" })
$window.FindName("NavSetup").Add_Click({ Set-Panel "setup" })
$window.FindName("NavWallpaper").Add_Click({ Set-Panel "wallpaper" })
$window.FindName("NavLogs").Add_Click({ if (Test-Path -LiteralPath $ErrLog) { Start-Process explorer.exe -ArgumentList "`"$ErrLog`"" } })
$window.FindName("NavBackup").Add_Click({ if (Test-Path -LiteralPath $BackupsRoot) { Start-Process explorer.exe -ArgumentList "`"$BackupsRoot`"" } })
$window.FindName("NavDshDir").Add_Click({ if (Test-Path -LiteralPath $DshHome) { Start-Process explorer.exe -ArgumentList "`"$DshHome`"" } })

# 主操作
$window.FindName("BtnOpen").Add_Click({ Start-OpenFlow })
$window.FindName("BtnRestart").Add_Click({ Start-RestartFlow $true })
$window.FindName("BtnEnvRefresh").Add_Click({ Update-EnvPanel })
$window.FindName("BtnSetupGo").Add_Click({ Start-SetupDsh })
$window.FindName("BtnWallpaperAdd").Add_Click({ Add-WallpaperFile })
$window.FindName("BtnWallpaperUrl").Add_Click({ Add-WallpaperUrl })
$window.FindName("BtnWallpaperReset").Add_Click({ Reset-Wallpaper })
$window.FindName("BtnOpenSkillsDir").Add_Click({ if (Test-Path -LiteralPath $SkillsRoot) { Start-Process explorer.exe -ArgumentList "`"$SkillsRoot`"" } })

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
    if (Get-PetAlive) {
        Stop-Pet
        $window.FindName("BtnPetToggle").Content = "🐳 桌宠 关"
    } else {
        Start-Pet
        $window.FindName("BtnPetToggle").Content = "🐳 桌宠 开"
    }
} | Out-Null
$script:miAutoStart = Add-TrayItem ("开机自启: " + $(if ($script:autoStart) { "开" } else { "关" })) {
    $script:autoStart = -not $script:autoStart
    try {
        if ($script:autoStart) {
            # 经 vbs 包装器启动(完全无控制台闪现); vbs 不存在则回退 powershell 命令
            $vbs = Join-Path $ScriptDir '启动DSH.vbs'
            if (Test-Path -LiteralPath $vbs) { $cmd = 'wscript.exe "' + $vbs + '"' }
            else { $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $ScriptDir 'dsh-launcher.ps1') + '" -HideConsole' }
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

# ------------------------------------------------------------ 定时器 ----
# 状态刷新 (3s) + busy 看门狗(联动已移至 bigfish Python 桌宠内部)
$script:statusTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:statusTimer.Interval = [TimeSpan]::FromSeconds(3)
$script:statusTimer.Add_Tick({
    Update-StatusAll
    # busy 看门狗: 任何流程卡死超过 60 秒强制复位, 防止重启按钮永久失效
    if ($script:busy -and $script:busySince -and ([DateTime]::Now - $script:busySince).TotalSeconds -gt 60) {
        $script:busy = $false
        $openState.Text = "上次操作超时，已自动恢复"
    }
})
$script:statusTimer.Start()

# ------------------------------------------------------------ 启动 ----
Update-StatusAll
Update-OpenPanel
# 自动拉起 bigfish 桌宠(依附)
Start-Pet

# 自动测试: 2.5秒验证"抛错不死"(L6防火墙), 6秒后自动关闭
if ($AutoTest) {
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
        Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value ("DIAG hero: src=" + ($null -ne $hero.Source) + " w=" + $hero.ActualWidth + " h=" + $hero.ActualHeight + " vis=" + $hero.Visibility)
        Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value ("DIAG pet:  process=" + (Get-PetAlive))
        Add-Content -Path "$env:TEMP\dsh-diag.txt" -Value ("DIAG window: actualW=" + $window.ActualWidth + " actualH=" + $window.ActualHeight)
        $window.Close()
    })
    $t.Start()
}

# 主窗口关闭: 结束桌宠进程并退出(Stop-Process 自身是唯一稳定退出方式)
$window.Add_Closed({
    Stop-Pet
    Stop-Process -Id $PID -Force
})

# 非模态双窗口: Show() 代替 ShowDialog(), 否则模态会禁用桌宠窗口的一切点击
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
