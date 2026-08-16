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

# 原生像素尺寸: GDI+ 只读文件头, 快(WebP 等不支持时返回 $null)
function Get-ImageNativeSize([string]$path) {
    try {
        Add-Type -AssemblyName System.Drawing
        $img = [System.Drawing.Image]::FromFile($path)
        $w = $img.Width
        $h = $img.Height
        $img.Dispose()
        return @{ w = [double]$w; h = [double]$h }
    } catch {
        return $null
    }
}

# 设壁纸前先比大小/比例, 决定适配方式(用户需求: 比较后再决定剪切还是缩小):
#   copy  = 尺寸+比例都合适 → 直接复制, 零处理
#   scale = 比例一致且图比屏幕大 → 自动缩小到屏幕尺寸, 不弹窗
#   pad   = 小图(至少一边小于屏幕) → 白底画布铺到屏幕尺寸, 原图原生大小居中(不放大不变形), 超出的边居中裁剪
#   crop  = 比例不一致的大图 → 弹裁剪窗让用户选保留区域
# 注意: 别用 DecodePixelWidth 取尺寸 — 它会把小图放大到限宽值, 比大小全错(坑#34)
function Get-WallpaperPlan([string]$srcPath) {
    $native = Get-ImageNativeSize $srcPath
    if ($null -eq $native) {
        # GDI+ 读不了(如 WebP): 退化为不弹窗的整图缩放
        return @{ mode = 'scale'; up = $false }
    }
    $iw = $native.w
    $ih = $native.h
    Add-Type -AssemblyName System.Windows.Forms
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $tw = [double]$scr.Width
    $th = [double]$scr.Height
    $imgRatio = $iw / $ih
    $targetRatio = $tw / $th
    $ratioDiff = [Math]::Abs($imgRatio - $targetRatio) / $targetRatio
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

function Set-Wallpaper([string]$srcPath) {
    try {
        $plan = Get-WallpaperPlan $srcPath
        New-Item -ItemType Directory -Force -Path $script:WallpaperStatic | Out-Null
        $out = Join-Path $script:WallpaperStatic "current.png"
        if ($plan.mode -eq 'copy') {
            Copy-Item -LiteralPath $srcPath -Destination $out -Force
        } elseif ($plan.mode -eq 'scale') {
            # 比例一致的大图: 不弹窗, 整图缩小到屏幕尺寸
            $full = [System.Windows.Rect]::new(0, 0, 1, 1)
            Render-WallpaperCrop -src $srcPath -rect $full -out $out -fullImage
        } elseif ($plan.mode -eq 'pad') {
            # 小图/单边偏小: 白底画布铺满屏幕, 原图原生大小居中, 超出的边居中裁剪(用户需求)
            Render-WallpaperPad -src $srcPath -out $out
        } else {
            # 比例不一致的大图: 弹裁剪窗(拖拽选区域 + 滑杆/滚轮缩放)
            $rect = Show-WallpaperCropDialog $srcPath
            if ($null -eq $rect) { Show-WallpaperHint "已取消, 壁纸未更改。" ; return $false }
            Render-WallpaperCrop -src $srcPath -rect $rect -out $out
        }
        Update-WallpaperHtml $true
        if ($plan.mode -eq 'copy') {
            Show-WallpaperHint "✓ 尺寸比例正好匹配屏幕, 已直接应用。刷新 DSH 网页(F5)即可看到。"
        } elseif ($plan.mode -eq 'scale') {
            Show-WallpaperHint "✓ 原图偏大, 已按屏幕尺寸缩小后应用。刷新 DSH 网页(F5)即可看到。"
        } elseif ($plan.mode -eq 'pad') {
            Show-WallpaperHint "✓ 原图偏小/比例不同: 已等比放大到屏幕能承受的最大尺寸, 短边白底填充居中。刷新 DSH 网页(F5)即可看到。"
        } else {
            Show-WallpaperHint "✓ 壁纸已按所选区域裁剪并设为背景。刷新 DSH 网页(F5)即可看到。"
        }
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
        Show-WallpaperHint "✓ 已恢复原版UI: 玻璃已关、壁纸已清、背景源回流体。刷新网页(F5)生效。"
    } catch {
        Show-WallpaperHint "恢复失败: $($_.Exception.Message)"
    }
}

# 改写 dist/index.html 内联 <style id="dsh-wallpaper-css"> + <script id="dsh-wallpaper-bridge">:
#   $apply=$true  注入 body 壁纸背景(刷新 ?t= 时间戳防缓存; 样式/桥缺失时自动补插), 并清掉「原版UI」标记
#   $apply=$false 清空为 background:none 并写入 dsh-original 标记(桥脚本据此一次性关玻璃+清壁纸槽)
# 走 HTML 而非 JS 插件: index.html 每次请求从磁盘下发, 不受 JS 包缓存影响(坑#26)
# 壁纸透出依赖官方 Aqua 玻璃(cordis 注册 ui-aqua); 桥把壁纸喂给 Aqua 的 localStorage 槽(坑#28)
function Update-WallpaperHtml([bool]$apply) {
    $html = Join-Path (Split-Path $script:WallpaperStatic -Parent) "index.html"
    if (-not (Test-Path -LiteralPath $html)) { return }
    $text = [IO.File]::ReadAllText($html, [Text.UTF8Encoding]::new($false))
    if ($apply) {
        # 清掉「原版UI」标记注释: 设壁纸 = 离开原版状态
        $text = $text -replace '/\* dsh-original[^*]*\*/', ''
        $ts = [DateTime]::Now.Ticks
        if ($text.Contains('body{background:none !important;}')) {
            # Reset 清空过: 恢复 url
            $text = $text.Replace('body{background:none !important;}',
                "body{background:url(/wallpaper/current.png?t=$ts) center/cover no-repeat fixed !important;}")
        } elseif ($text.Contains('wallpaper/current.png?t=')) {
            # 已有 url: 仅刷新时间戳, 且**只限定在样式块内**(桥脚本里也有同样文本,
            # 全文替换会吃掉 JS 字符串的收尾引号 → 桥语法错误不执行 → 壁纸不显示, 坑#35)
            $styleRx = [regex]'(?s)(<style id="dsh-wallpaper-css">.*?)wallpaper/current\.png\?t=[^)]*(.*?</style>)'
            $text = $styleRx.Replace($text, { param($m) $m.Groups[1].Value + "wallpaper/current.png?t=$ts" + $m.Groups[2].Value })
        } else {
            # DSH 更新覆盖过 index.html: 样式块丢失, 重新插入 </head> 前
            $block = "    <style id=`"dsh-wallpaper-css`">`n" +
                     "      /* 壁纸中心注入层(启动器配套): 直接覆盖 body 背景; 默认UI不透明白色会遮住, 开启玻璃材质后透出 */`n" +
                     "      body{background:url(/wallpaper/current.png?t=$ts) center/cover no-repeat fixed !important;}`n" +
                     "    </style>`n  </head>"
            $text = $text.Replace('</head>', $block)
        }
        # 桥接脚本缺失或被误伤时重插: 校验两个关键片段完整性(坑#35); 空格无关正则
        $bridgeOk = $text.Contains('dsh-wallpaper-bridge') -and
                    [regex]::IsMatch($text, "indexOf\('wallpaper/current\.png\?t='\)") -and
                    [regex]::IsMatch($text, "'/wallpaper/current\.png\?t='\s*\+\s*t")
        if (-not $bridgeOk) {
            $text = [regex]::Replace($text, '(?s)<script id="dsh-wallpaper-bridge">.*?</script>\s*', '')
            $bridge = "    <script id=`"dsh-wallpaper-bridge`">`n" +
                      "      /* 壁纸中心桥: 把启动器写入的壁纸喂给官方 Aqua 的 localStorage 槽。 */`n" +
                      "      (function(){try{var s=document.getElementById('dsh-wallpaper-css');if(!s)return;var txt=s.textContent;var k='dsh.wallpaper.center.ts';var ok='dsh.wallpaper.center.original';if(txt.indexOf('dsh-original')>=0){if(!localStorage.getItem(ok)){localStorage.setItem('dsh.ui-aqua.enabled','false');localStorage.setItem('dsh.ui-aqua.wallpaper','');localStorage.setItem('dsh.ui-aqua.background','fluid');localStorage.removeItem(k);localStorage.setItem(ok,'1');}return;}var i=txt.indexOf('wallpaper/current.png?t=');if(i<0)return;var j=txt.indexOf(')',i);var t=txt.substring(i+24,j);if(localStorage.getItem(k)===t)return;localStorage.setItem('dsh.ui-aqua.wallpaper','/wallpaper/current.png?t='+t);localStorage.setItem('dsh.ui-aqua.background','wallpaper');localStorage.setItem('dsh.ui-aqua.enabled','true');localStorage.removeItem(ok);localStorage.setItem(k,t);}catch(e){}})();`n" +
                      "    </script>`n  </head>"
            $text = $text.Replace('</head>', $bridge)
        }
    } else {
        $text = $text -replace 'body\{background:url\([^)]*\) center/cover no-repeat fixed !important;\}',
            "`n      /* dsh-original: 原版UI, 桥脚本据此一次性关玻璃回流体 */`n      body{background:none !important;}"
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

# ------------------------------------------------------------ 壁纸裁剪窗(头像/手机壁纸式交互) ----
# 视口比例 = 主屏比例(16:10); 初始 = 居中铺满(与旧行为一致);
# 拖拽选保留区域, 滑杆/滚轮缩放(100%..400%), 大图可选范围、小图自动放大铺满
# 裁剪数学: 预览视口 480x300 逻辑像素, 显示尺寸 = 原图像素 x s, s>=sMin(=cover 缩放)
function Get-CropSourceRect([double]$imgW, [double]$imgH, [double]$sMin, [double]$zoom, [double]$offX, [double]$offY, [double]$vw, [double]$vh) {
    $s = $sMin * $zoom
    $srcX = (-$offX) / $s
    $srcY = (-$offY) / $s
    $srcW = $vw / $s
    $srcH = $vh / $s
    # 浮点边界钳制在 [0, img - src] 内
    $srcX = [Math]::Max(0.0, [Math]::Min($srcX, $imgW - $srcW))
    $srcY = [Math]::Max(0.0, [Math]::Min($srcY, $imgH - $srcH))
    return [System.Windows.Rect]::new($srcX, $srcY, $srcW, $srcH)
}

# 按当前缩放/偏移刷新裁剪窗显示
function Update-CropView {
    $st = $script:CropState
    $s = $st.sMin * $st.zoom
    $dw = $st.imgW * $s
    $dh = $st.imgH * $s
    $maxX = [Math]::Min(0.0, $st.vw - $dw)
    $maxY = [Math]::Min(0.0, $st.vh - $dh)
    $st.offX = [Math]::Max($maxX, [Math]::Min(0.0, $st.offX))
    $st.offY = [Math]::Max($maxY, [Math]::Min(0.0, $st.offY))
    $img = $st.controls['img']
    $img.Width = $dw
    $img.Height = $dh
    [System.Windows.Controls.Canvas]::SetLeft($img, $st.offX)
    [System.Windows.Controls.Canvas]::SetTop($img, $st.offY)
    $st.controls['slider'].Value = $st.zoom
    $st.controls['info'].Text = "原图 $($st.nativeW)x$($st.nativeH) → 输出 $($st.outW)x$($st.outH) · 缩放 $([int]($st.zoom * 100))%  ·  拖拽选区域, 滑杆/滚轮缩放"
}

function Show-WallpaperCropDialog([string]$srcPath) {
    try {
        $native = Get-ImageNativeSize $srcPath
        $fs = [IO.File]::OpenRead($srcPath)
        $bi = [System.Windows.Media.Imaging.BitmapImage]::new()
        $bi.BeginInit()
        $bi.StreamSource = $fs
        # 只在原图比限宽大时才解码缩小(小图不放大, 坑#34); 渲染端同规则, 像素坐标一致
        if ($null -ne $native -and $native.w -gt 2400) { $bi.DecodePixelWidth = 2400 }
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.EndInit()
        $fs.Dispose()
        $bi.Freeze()
    } catch {
        Show-WallpaperHint "无法读取该图片: $($_.Exception.Message)"
        return $null
    }
    Add-Type -AssemblyName System.Windows.Forms
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $ratio = [double]$scr.Width / [double]$scr.Height
    $vw = 480
    $vh = [int][Math]::Round($vw / $ratio)
    $imgW = [double]$bi.PixelWidth
    $imgH = [double]$bi.PixelHeight
    $sMin = [Math]::Max($vw / $imgW, $vh / $imgH)
    if ($null -eq $native) { $native = @{ w = $imgW; h = $imgH } }

    # 状态放 script 作用域(事件处理器闭包读不到函数局部变量, 老坑)
    $script:CropState = @{
        imgW = $imgW; imgH = $imgH; sMin = $sMin; vw = $vw; vh = $vh
        nativeW = $native.w; nativeH = $native.h
        outW = $scr.Width; outH = $scr.Height
        zoom = 1.0
        offX = ($vw - $imgW * $sMin) / 2
        offY = ($vh - $imgH * $sMin) / 2
        drag = $null
        controls = @{}
    }
    $st = $script:CropState

    $dlg = [System.Windows.Window]::new()
    $dlg.Owner = $window
    $dlg.Title = "选择壁纸区域"
    $dlg.Width = 600
    $dlg.Height = 540
    $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dlg.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dlg.WindowStyle = [System.Windows.WindowStyle]::ToolWindow
    $dlg.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#14161B"))

    $root = [System.Windows.Controls.Grid]::new()
    $root.Margin = [System.Windows.Thickness]::new(20, 16, 20, 16)
    $rowTitle = [System.Windows.Controls.RowDefinition]::new(); $rowTitle.Height = [System.Windows.GridLength]::Auto
    $rowView = [System.Windows.Controls.RowDefinition]::new()
    $rowInfo = [System.Windows.Controls.RowDefinition]::new(); $rowInfo.Height = [System.Windows.GridLength]::Auto
    $rowZoom = [System.Windows.Controls.RowDefinition]::new(); $rowZoom.Height = [System.Windows.GridLength]::Auto
    $rowBtns = [System.Windows.Controls.RowDefinition]::new(); $rowBtns.Height = [System.Windows.GridLength]::Auto
    $root.RowDefinitions.Add($rowTitle) | Out-Null
    $root.RowDefinitions.Add($rowView) | Out-Null
    $root.RowDefinitions.Add($rowInfo) | Out-Null
    $root.RowDefinitions.Add($rowZoom) | Out-Null
    $root.RowDefinitions.Add($rowBtns) | Out-Null
    $dlg.Content = $root

    # 标题
    $title = [System.Windows.Controls.TextBlock]::new()
    $title.Text = "选择壁纸区域 — 视口即屏幕(16:10), 拖拽移动, 滑杆/滚轮缩放"
    $title.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#E8ECF4"))
    $title.FontSize = 13
    $title.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    [System.Windows.Controls.Grid]::SetRow($title, 0)
    $root.Children.Add($title) | Out-Null

    # 裁剪视口
    $border = [System.Windows.Controls.Border]::new()
    $border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#3E4654"))
    $border.BorderThickness = [System.Windows.Thickness]::new(1)
    $border.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $border.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $cv = [System.Windows.Controls.Canvas]::new()
    $cv.Width = $vw
    $cv.Height = $vh
    $cv.ClipToBounds = $true
    $cv.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#000000"))
    $border.Child = $cv
    [System.Windows.Controls.Grid]::SetRow($border, 1)
    $root.Children.Add($border) | Out-Null

    $img = [System.Windows.Controls.Image]::new()
    $img.Source = $bi
    $img.Stretch = [System.Windows.Media.Stretch]::Fill
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    $cv.Children.Add($img) | Out-Null

    # 信息行 + 缩放行 + 按钮行
    $info = [System.Windows.Controls.TextBlock]::new()
    $info.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#8A919E"))
    $info.FontSize = 11
    $info.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    [System.Windows.Controls.Grid]::SetRow($info, 2)
    $root.Children.Add($info) | Out-Null

    $zoomRow = [System.Windows.Controls.Grid]::new()
    $zoomRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $zcol1 = [System.Windows.Controls.ColumnDefinition]::new(); $zcol1.Width = [System.Windows.GridLength]::new(44)
    $zcol2 = [System.Windows.Controls.ColumnDefinition]::new()
    $zoomRow.ColumnDefinitions.Add($zcol1) | Out-Null
    $zoomRow.ColumnDefinitions.Add($zcol2) | Out-Null
    $zoomLabel = [System.Windows.Controls.TextBlock]::new()
    $zoomLabel.Text = "缩放"
    $zoomLabel.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#8A919E"))
    $zoomLabel.FontSize = 11
    $zoomLabel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $slider = [System.Windows.Controls.Slider]::new()
    $slider.Minimum = 1
    $slider.Maximum = 4
    $slider.Value = 1
    $slider.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($zoomLabel, 0)
    [System.Windows.Controls.Grid]::SetColumn($slider, 1)
    $zoomRow.Children.Add($zoomLabel) | Out-Null
    $zoomRow.Children.Add($slider) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($zoomRow, 3)
    $root.Children.Add($zoomRow) | Out-Null

    $btnRow = [System.Windows.Controls.StackPanel]::new()
    $btnRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $btnRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $btnCancel = [System.Windows.Controls.Button]::new()
    $btnCancel.Content = "取消"
    $btnCancel.Width = 88
    $btnCancel.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $btnCancel.Style = $window.FindResource("GhostBtn")
    $btnOk = [System.Windows.Controls.Button]::new()
    $btnOk.Content = "确认应用"
    $btnOk.Width = 100
    $btnOk.Style = $window.FindResource("PrimaryBtn")
    $btnRow.Children.Add($btnCancel) | Out-Null
    $btnRow.Children.Add($btnOk) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($btnRow, 4)
    $root.Children.Add($btnRow) | Out-Null

    $st.controls['img'] = $img
    $st.controls['slider'] = $slider
    $st.controls['info'] = $info
    $st.controls['dlg'] = $dlg
    Update-CropView

    # 拖拽: MouseDown 记偏移 + MouseMove 手动移(不用 DragMove, 会卡死消息循环, 坑#22)
    $cv.Add_MouseDown({ param($s, $e)
        $st2 = $script:CropState
        $pt = $e.GetPosition($s)
        $st2.drag = @{ x = $pt.X; y = $pt.Y; offX = $st2.offX; offY = $st2.offY }
        $s.CaptureMouse() | Out-Null
    })
    $cv.Add_MouseMove({ param($s, $e)
        $st2 = $script:CropState
        if ($null -ne $st2.drag) {
            $pt = $e.GetPosition($s)
            $st2.offX = $st2.drag.offX + ($pt.X - $st2.drag.x)
            $st2.offY = $st2.drag.offY + ($pt.Y - $st2.drag.y)
            Update-CropView
        }
    })
    $cv.Add_MouseUp({ param($s, $e)
        $script:CropState.drag = $null
        $s.ReleaseMouseCapture()
    })
    $cv.Add_MouseLeave({ param($s, $e)
        if ($null -ne $script:CropState.drag) { $script:CropState.drag = $null }
    })
    $slider.Add_ValueChanged({ param($s, $e)
        $st2 = $script:CropState
        if ([Math]::Abs($st2.zoom - $s.Value) -gt 0.001) {
            $st2.zoom = [double]$s.Value
            Update-CropView
        }
    })
    $cv.Add_MouseWheel({ param($s, $e)
        $st2 = $script:CropState
        $factor = if ($e.Delta -gt 0) { 1.12 } else { 0.89 }
        $newZoom = [Math]::Min(4.0, [Math]::Max(1.0, $st2.zoom * $factor))
        if ([Math]::Abs($newZoom - $st2.zoom) -gt 0.001) {
            # 以视口中心为锚缩放(标准头像交互)
            $cx = $st2.vw / 2
            $cy = $st2.vh / 2
            $ratio2 = $newZoom / $st2.zoom
            $st2.offX = $cx - ($cx - $st2.offX) * $ratio2
            $st2.offY = $cy - ($cy - $st2.offY) * $ratio2
            $st2.zoom = $newZoom
            Update-CropView
        }
    })

    # 按钮不能用 GetNewClosure: 闭包模块里 $script: 指向闭包自己的作用域, 读不到 CropState
    # → 空引用异常被 WPF 静默吞掉, DialogResult 永远不置位, 窗口关不掉(= 点确认后卡死, 坑#33)
    $btnCancel.Add_Click({ param($s, $e) $script:CropState.controls['dlg'].DialogResult = $false })
    $btnOk.Add_Click({ param($s, $e)
        $st2 = $script:CropState
        $st2.result = Get-CropSourceRect $st2.imgW $st2.imgH $st2.sMin $st2.zoom $st2.offX $st2.offY $st2.vw $st2.vh
        $st2.controls['dlg'].DialogResult = $true
    })

    $res = $dlg.ShowDialog()
    $out = $null
    if ($res) { $out = $script:CropState.result }
    $script:CropState = $null
    return $out
}

# 把原图按裁剪矩形渲染成屏幕分辨率 PNG 写入 outPath(-fullImage = 整图缩放)
# 解码限宽 2400: 超大图处理从分钟级压到 ~0.2s(坑#32); 预览与渲染同解码尺寸, 像素坐标一致
# 裁剪用 CroppedBitmap(Int32Rect, 像素坐标): DrawImage 的源矩形重载有 DPI 陷阱, 非96DPI图会画空(坑#31)
function Render-WallpaperCrop([string]$src, [System.Windows.Rect]$rect, [string]$outPath, [switch]$fullImage) {
    $fs = [IO.File]::OpenRead($src)
    $bi = [System.Windows.Media.Imaging.BitmapImage]::new()
    $bi.BeginInit()
    $bi.StreamSource = $fs
    # 只在原图比限宽大时才解码缩小(与裁剪窗预览同规则, 像素坐标一致; 坑#34)
    $native = Get-ImageNativeSize $src
    if ($null -ne $native -and $native.w -gt 2400) { $bi.DecodePixelWidth = 2400 }
    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.EndInit()
    $fs.Dispose()
    $bi.Freeze()
    $iw = $bi.PixelWidth
    $ih = $bi.PixelHeight
    if ($fullImage) {
        $x = 0; $y = 0; $w = $iw; $h = $ih
    } else {
        $x = [int][Math]::Floor($rect.X)
        $y = [int][Math]::Floor($rect.Y)
        $w = [int][Math]::Ceiling($rect.Width)
        $h = [int][Math]::Ceiling($rect.Height)
        $x = [Math]::Max(0, [Math]::Min($x, $iw - 1))
        $y = [Math]::Max(0, [Math]::Min($y, $ih - 1))
        $w = [Math]::Min($w, $iw - $x)
        $h = [Math]::Min($h, $ih - $y)
    }
    $cb = [System.Windows.Media.Imaging.CroppedBitmap]::new($bi, [System.Windows.Int32Rect]::new($x, $y, $w, $h))
    $cb.Freeze()
    Add-Type -AssemblyName System.Windows.Forms
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $tw = [int]$scr.Width
    $th = [int]$scr.Height
    $dv = [System.Windows.Media.DrawingVisual]::new()
    $dc = $dv.RenderOpen()
    $dc.DrawImage($cb, [System.Windows.Rect]::new(0, 0, $tw, $th))
    $dc.Close()
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($tw, $th, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ofs = [IO.File]::Open($outPath, [IO.FileMode]::Create)
    $enc.Save($ofs)
    $ofs.Dispose()
}

# 白底填充(小图/单边偏小): 先按 contain 等比缩放——长边贴到屏幕边、短边留白,
# 再居中到白色画布(用户需求: UI 10:10、图 2:1 → 图等比放大到 10:5, 上下各补 2.5 白)。
# 不裁剪不变形, 与 object-fit: contain 一致
function Render-WallpaperPad([string]$src, [string]$outPath) {
    $fs = [IO.File]::OpenRead($src)
    $bi = [System.Windows.Media.Imaging.BitmapImage]::new()
    $bi.BeginInit()
    $bi.StreamSource = $fs
    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.EndInit()
    $fs.Dispose()
    $bi.Freeze()
    $iw = [double]$bi.PixelWidth
    $ih = [double]$bi.PixelHeight
    Add-Type -AssemblyName System.Windows.Forms
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $tw = [int]$scr.Width
    $th = [int]$scr.Height
    # contain 缩放系数: 长边贴边, 短边留白(系数 ≤ UI 承受的最大比例)
    $scale = [Math]::Min($tw / $iw, $th / $ih)
    $sw = $iw * $scale
    $sh = $ih * $scale
    $dx = ($tw - $sw) / 2.0
    $dy = ($th - $sh) / 2.0
    $dv = [System.Windows.Media.DrawingVisual]::new()
    $dc = $dv.RenderOpen()
    $dc.DrawRectangle([System.Windows.Media.Brushes]::White, $null, [System.Windows.Rect]::new(0, 0, $tw, $th))
    $dc.DrawImage($bi, [System.Windows.Rect]::new($dx, $dy, $sw, $sh))
    $dc.Close()
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($tw, $th, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ofs = [IO.File]::Open($outPath, [IO.FileMode]::Create)
    $enc.Save($ofs)
    $ofs.Dispose()
}

function Update-WallpaperPanel {
    $wallpaperGrid.Children.Clear()
    New-Item -ItemType Directory -Force -Path $WallpaperDir | Out-Null
    # 首卡: 原版UI 快捷卡 — 一键回出厂界面(玻璃关+壁纸清), 与壁纸卡互相切换测试
    $card0 = [System.Windows.Controls.Border]::new()
    $card0.Width = 190
    $card0.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $card0.Background = [System.Windows.Media.Brushes]::White
    $card0.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#E0E4EC"))
    $card0.BorderThickness = [System.Windows.Thickness]::new(1)
    $card0.Margin = [System.Windows.Thickness]::new(0, 0, 12, 12)
    $sp0 = [System.Windows.Controls.StackPanel]::new()
    # 缩略图: 白底 + 左侧浅灰侧栏 + 底部输入条(迷你原版UI示意)
    $thumb0 = [System.Windows.Controls.Grid]::new()
    $thumb0.Width = 188
    $thumb0.Height = 105
    $side0 = [System.Windows.Shapes.Rectangle]::new()
    $side0.Width = 56
    $side0.Height = 105
    $side0.Fill = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#F3F5F8"))
    $side0.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $side0.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $bar0 = [System.Windows.Shapes.Rectangle]::new()
    $bar0.Width = 90
    $bar0.Height = 14
    $bar0.RadiusX = 7
    $bar0.RadiusY = 7
    $bar0.Fill = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#E8EBF0"))
    $bar0.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $bar0.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
    $bar0.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $lab0 = [System.Windows.Controls.TextBlock]::new()
    $lab0.Text = "原版"
    $lab0.FontSize = 11
    $lab0.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#8A919E"))
    $lab0.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $lab0.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $lab0.Margin = [System.Windows.Thickness]::new(60, 0, 0, 0)
    $thumb0.Children.Add($side0) | Out-Null
    $thumb0.Children.Add($bar0) | Out-Null
    $thumb0.Children.Add($lab0) | Out-Null
    $nm0 = [System.Windows.Controls.TextBlock]::new()
    $nm0.Text = "原版 UI（出厂界面）"
    $nm0.FontSize = 11
    $nm0.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#3D4350"))
    $nm0.Margin = [System.Windows.Thickness]::new(8, 6, 8, 0)
    $nm0.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $btns0 = [System.Windows.Controls.StackPanel]::new()
    $btns0.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $btns0.Margin = [System.Windows.Thickness]::new(8, 6, 8, 8)
    $bRestore = [System.Windows.Controls.Button]::new()
    $bRestore.Content = "🧊 恢复原版"
    $bRestore.FontSize = 11
    $bRestore.Style = $window.FindResource("GhostBtn")
    $bRestore.Add_Click({ Reset-Wallpaper })
    $btns0.Children.Add($bRestore) | Out-Null
    $sp0.Children.Add($thumb0) | Out-Null
    $sp0.Children.Add($nm0) | Out-Null
    $sp0.Children.Add($btns0) | Out-Null
    $card0.Child = $sp0
    $wallpaperGrid.Children.Add($card0) | Out-Null
    # 壁纸卡
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
    $wallpaperHint.Text = "壁纸库: $WallpaperDir ($($files.Count) 张) · 设壁纸自动适配: 匹配直接应用 / 大图缩小 / 小图等比放大+白底填充 / 比例不同的大图弹裁剪窗 · 首卡「原版 UI」回出厂界面 · 刷新网页生效"
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
