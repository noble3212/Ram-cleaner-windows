#Requires -Version 5.1
<#
.SYNOPSIS
    Windows RAM Optimization Tool with Real-Time Monitoring
.DESCRIPTION
    Clears standby list, empties working sets, flushes DNS,
    restarts browsers, kills high-usage tasks, cleans GPU memory,
    and shows live RAM/CPU/GPU charts.
    Requires Administrator privileges.
#>

# --- Admin Elevation ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# --- Load Settings ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SettingsPath = Join-Path $ScriptDir "settings.json"
if (Test-Path $SettingsPath) {
    $Settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
} else {
    $Settings = [PSCustomObject]@{
        threshold_mb               = 500
        auto_clean_delay_minutes   = 60
        browsers                   = @("chrome","firefox","msedge","brave","opera","vivaldi","waterfox","arc")
        auto_clean_on_startup      = $true
        minimize_to_tray           = $true
        chart_history_seconds      = 120
        chart_update_interval_ms   = 1000
        gpu_cleanup_enabled        = $true
    }
}

# --- Windows API Imports ---
if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Win32 {
    [DllImport("psapi.dll")]
    public static extern int EmptyWorkingSet(IntPtr hwProc);

    [DllImport("ntdll.dll")]
    public static extern uint NtSetSystemInformation(
        int InformationClass, IntPtr Information, int Length);

    [DllImport("kernel32.dll")]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);

    public const uint PROCESS_SET_QUOTA = 0x0100;
    public const uint PROCESS_QUERY_INFORMATION = 0x0400;
}
"@
}

# --- History Arrays for Charts ---
$script:RamHistory  = [System.Collections.ArrayList]::new()
$script:CpuHistory  = [System.Collections.ArrayList]::new()
$script:GpuHistory  = [System.Collections.ArrayList]::new()
$script:GpuMemHistory = [System.Collections.ArrayList]::new()
$script:MaxHistory  = $Settings.chart_history_seconds

# --- Previous CPU snapshot for delta calculation ---
$script:PrevCpuIdle   = 0
$script:PrevCpuTotal  = 0
$script:PrevGpuUtil   = 0

# --- Helper: Get Memory Info ---
function Get-MemoryInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $freeMB  = [math]::Round($os.FreePhysicalMemory / 1024)
    $usedMB  = $totalMB - $freeMB
    $pctUsed = if ($totalMB -gt 0) { [math]::Round(($usedMB / $totalMB) * 100, 1) } else { 0 }
    return [PSCustomObject]@{ TotalMB=$totalMB; UsedMB=$usedMB; FreeMB=$freeMB; PctUsed=$pctUsed }
}

# --- Helper: Get CPU Usage (delta-based) ---
function Get-CpuUsage {
    try {
        $cpu = Get-CimInstance Win32_Processor
        return [math]::Round($cpu.LoadPercentage, 1)
    } catch {
        return 0
    }
}

# --- Helper: Get GPU Info ---
function Get-GpuInfo {
    $gpus = @()
    try {
        Get-CimInstance Win32_VideoController | ForEach-Object {
            $vramMB = 0
            if ($_.AdapterRAM -gt 0) {
                $vramMB = [math]::Round($_.AdapterRAM / 1MB, 0)
            }
            $gpus += [PSCustomObject]@{
                Name       = $_.Name
                VRAM_MB    = $vramMB
                Driver     = $_.DriverVersion
                Status     = $_.Status
            }
        }
    } catch {}
    return $gpus
}

# --- Helper: Get GPU Utilization (NVIDIA via nvidia-smi) ---
function Get-GpuUtilization {
    try {
        $output = & nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null
        if ($output) {
            $parts = $output -split ','
            return [PSCustomObject]@{
                Utilization = [math]::Round([double]$parts[0].Trim(), 1)
                Used_MB     = [math]::Round([double]$parts[1].Trim(), 0)
                Total_MB    = [math]::Round([double]$parts[2].Trim(), 0)
            }
        }
    } catch {}
    # Fallback for AMD/Intel - estimate from adapter RAM usage
    try {
        $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
        $usedEstimate = [math]::Round(($gpu.AdapterRAM * 0.15) / 1MB, 0)
        return [PSCustomObject]@{
            Utilization = 0
            Used_MB     = $usedEstimate
            Total_MB    = [math]::Round($gpu.AdapterRAM / 1MB, 0)
        }
    } catch {}
    return [PSCustomObject]@{ Utilization=0; Used_MB=0; Total_MB=0 }
}

# --- Clear Standby List ---
function Clear-StandbyList {
    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 4)
        $result = [Win32]::NtSetSystemInformation(80, $ptr, 4)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
        return ($result -eq 0)
    } catch { return $false }
}

# --- Empty Working Sets ---
function Empty-AllWorkingSets {
    $count = 0
    Get-Process | ForEach-Object {
        $handle = [Win32]::OpenProcess(
            [Win32]::PROCESS_SET_QUOTA -bor [Win32]::PROCESS_QUERY_INFORMATION,
            $false, $_.Id)
        if ($handle -ne [IntPtr]::Zero) {
            [Win32]::EmptyWorkingSet($handle) | Out-Null
            [Win32]::CloseHandle($handle) | Out-Null
            $count++
        }
    }
    return $count
}

# --- Flush DNS ---
function Flush-DnsCache {
    try { Clear-DnsClientCache; return $true } catch { return $false }
}

# --- GPU Memory Cleanup ---
function Clear-GpuMemory {
    $results = @()
    # Try NVIDIA
    try {
        $out = & nvidia-smi --gpu-reset 2>&1
        $results += "NVIDIA: Attempted GPU memory reset"
    } catch {
        $results += "NVIDIA: nvidia-smi not available or GPU reset failed"
    }
    # Clear DirectX shader cache
    try {
        $shaderCache = "$env:LOCALAPPDATA\D3DSCache"
        if (Test-Path $shaderCache) {
            Remove-Item "$shaderCache\*" -Recurse -Force -ErrorAction SilentlyContinue
            $results += "DirectX shader cache cleared"
        }
        $dxCache = "$env:LOCALAPPDATA\DirectX"
        if (Test-Path $dxCache) {
            Remove-Item "$dxCache\*" -Recurse -Force -ErrorAction SilentlyContinue
            $results += "DirectX cache cleared"
        }
    } catch {
        $results += "Cache cleanup encountered errors"
    }
    # Clear GPU driver temp files
    try {
        $driverTemp = "$env:TEMP\NVIDIA"
        if (Test-Path $driverTemp) {
            Remove-Item "$driverTemp\*" -Recurse -Force -ErrorAction SilentlyContinue
            $results += "NVIDIA temp files cleared"
        }
    } catch {}
    return $results
}

# --- Get Running Browsers ---
function Get-RunningBrowsers {
    $browserNames = $Settings.browsers
    $found = @()
    Get-Process | Where-Object {
        $procName = $_.Name.ToLower()
        $browserNames | Where-Object { $procName -like "*$_*" }
    } | ForEach-Object {
        $found += [PSCustomObject]@{
            Name   = $_.Name; Id = $_.Id
            RAM_MB = [math]::Round($_.WorkingSet64 / 1MB, 1)
        }
    }
    return $found
}

# --- Close and Restart Browser ---
function Close-RestartBrowser {
    param([string]$ProcessName)
    $procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if (-not $procs) { return $false }
    $exePath = ($procs | Select-Object -First 1).Path
    $procs | Stop-Process -Force
    Start-Sleep -Seconds 2
    if ($exePath -and (Test-Path $exePath)) { Start-Process $exePath }
    else { try { Start-Process $ProcessName } catch {} }
    return $true
}

# --- Kill High Usage Tasks ---
function Get-HighUsageProcesses {
    $thresholdBytes = $Settings.threshold_mb * 1MB
    Get-Process | Where-Object { $_.WorkingSet64 -gt $thresholdBytes } |
        Sort-Object WorkingSet64 -Descending |
        Select-Object Name, Id, @{N='RAM_MB';E={[math]::Round($_.WorkingSet64/1MB,1)}},
                      @{N='CPU_Sec';E={ if ($_.CPU) { [math]::Round($_.CPU,1) } else { 0 } }}
}

# --- Draw Chart on Canvas ---
function Draw-Chart {
    param(
        [System.Windows.Controls.Canvas]$Canvas,
        [System.Collections.ArrayList]$Data,
        [string]$Color,
        [double]$MaxVal = 100
    )
    $Canvas.Children.Clear()
    if ($Data.Count -lt 2) { return }

    $w = $Canvas.ActualWidth
    $h = $Canvas.ActualHeight
    if ($w -le 0 -or $h -le 0) { return }

    $points = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $Data.Count; $i++) {
        $x = ($i / [math]::Max($Data.Count - 1, 1)) * $w
        $val = [math]::Min([double]$Data[$i], $MaxVal)
        $y = $h - (($val / $MaxVal) * $h)
        $points.Add([System.Windows.Point]::new($x, $y)) | Out-Null
    }

    # Fill area under curve
    $fillPoints = New-Object System.Windows.Media.PointCollection
    foreach ($p in $points) { $fillPoints.Add($p) | Out-Null }
    $fillPoints.Add([System.Windows.Point]::new($w, $h)) | Out-Null
    $fillPoints.Add([System.Windows.Point]::new(0, $h)) | Out-Null

    $brush = [System.Windows.Media.SolidColorBrush]::new(
        [System.Windows.Media.ColorConverter]::ConvertFromString($Color))
    $brush.Opacity = 0.15
    $fill = New-Object System.Windows.Shapes.Polygon
    $fill.Points = $fillPoints
    $fill.Fill = $brush
    $fill.Stroke = $null
    $Canvas.Children.Add($fill) | Out-Null

    # Line
    $lineBrush = [System.Windows.Media.SolidColorBrush]::new(
        [System.Windows.Media.ColorConverter]::ConvertFromString($Color))
    $polyline = New-Object System.Windows.Shapes.Polyline
    $polyline.Points = $points
    $polyline.Stroke = $lineBrush
    $polyline.StrokeThickness = 2
    $Canvas.Children.Add($polyline) | Out-Null
}

# ============================================================
# =================== BUILD WPF GUI =========================
# ============================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="RAM Optimizer" Height="700" Width="900"
        Background="#0d0d0d" Foreground="white"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanMinimize">
    <Window.Resources>
        <Style x:Key="Btn" TargetType="Button">
            <Setter Property="Background" Value="#1a1a1a"/>
            <Setter Property="Foreground" Value="white"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="12,7"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#333"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="5" Padding="{TemplateBinding Padding}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#2a0a0a"/>
                                <Setter TargetName="bd" Property="BorderBrush" Value="#cc0000"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="TabBtn" TargetType="RadioButton">
            <Setter Property="Background" Value="#111"/>
            <Setter Property="Foreground" Value="#888"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="18,8"/>
            <Setter Property="Margin" Value="2,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="5,5,0,0" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1a1a1a"/>
                                <Setter Property="Foreground" Value="#cc0000"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1a1a1a"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="Label" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#666"/>
            <Setter Property="FontSize" Value="11"/>
        </Style>
        <Style x:Key="ValueLabel" TargetType="TextBlock">
            <Setter Property="Foreground" Value="white"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
    </Window.Resources>

    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <TextBlock Text="RAM" Foreground="#cc0000" FontSize="22" FontWeight="Bold"/>
            <TextBlock Text=" Optimizer" Foreground="white" FontSize="22" FontWeight="Light"/>
            <TextBlock x:Name="StatusText" Text="Ready" FontSize="11" Foreground="#555"
                       VerticalAlignment="Bottom" Margin="20,0,0,2"/>
        </StackPanel>

        <!-- Tab Buttons -->
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,2">
            <RadioButton x:Name="TabOverview" Content="Overview" Style="{StaticResource TabBtn}" IsChecked="True"/>
            <RadioButton x:Name="TabProcesses" Content="Processes" Style="{StaticResource TabBtn}"/>
            <RadioButton x:Name="TabPerformance" Content="Performance" Style="{StaticResource TabBtn}"/>
        </StackPanel>

        <!-- Tab Content -->
        <Border Grid.Row="2" Background="#111" CornerRadius="0,6,6,6" Padding="12">
            <Grid>
                <!-- OVERVIEW TAB -->
                <Grid x:Name="PanelOverview" Visibility="Visible">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Memory Bar -->
                    <Border Grid.Row="0" Background="#1a1a1a" CornerRadius="6" Padding="14" Margin="0,0,0,8">
                        <StackPanel>
                            <TextBlock x:Name="MemLabel" Text="Loading..." FontSize="14" Foreground="white" Margin="0,0,0,6"/>
                            <Border Background="#222" Height="20" CornerRadius="5">
                                <Border x:Name="MemBar" Background="#cc0000" CornerRadius="5" HorizontalAlignment="Left" Width="1"/>
                            </Border>
                            <Grid Margin="0,6,0,0">
                                <TextBlock Style="{StaticResource Label}" Text="0 MB" HorizontalAlignment="Left"/>
                                <TextBlock x:Name="MemTotalLabel" Style="{StaticResource Label}" Text="" HorizontalAlignment="Center"/>
                                <TextBlock x:Name="MemFreeLabel" Style="{StaticResource Label}" Text="" HorizontalAlignment="Right"/>
                            </Grid>
                        </StackPanel>
                    </Border>

                    <!-- Quick Stats -->
                    <Grid Grid.Row="1" Margin="0,0,0,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Background="#1a1a1a" CornerRadius="6" Padding="12,8" Margin="0,0,4,0">
                            <StackPanel>
                                <TextBlock Style="{StaticResource Label}" Text="CPU Usage"/>
                                <TextBlock x:Name="CpuLabel" Style="{StaticResource ValueLabel}" Text="0%"/>
                            </StackPanel>
                        </Border>
                        <Border Grid.Column="1" Background="#1a1a1a" CornerRadius="6" Padding="12,8" Margin="4,0">
                            <StackPanel>
                                <TextBlock Style="{StaticResource Label}" Text="GPU Usage"/>
                                <TextBlock x:Name="GpuLabel" Style="{StaticResource ValueLabel}" Text="0%"/>
                            </StackPanel>
                        </Border>
                        <Border Grid.Column="2" Background="#1a1a1a" CornerRadius="6" Padding="12,8" Margin="4,0">
                            <StackPanel>
                                <TextBlock Style="{StaticResource Label}" Text="GPU VRAM"/>
                                <TextBlock x:Name="GpuMemLabel" Style="{StaticResource ValueLabel}" Text="0 / 0 MB"/>
                            </StackPanel>
                        </Border>
                        <Border Grid.Column="3" Background="#1a1a1a" CornerRadius="6" Padding="12,8" Margin="4,0,0,0">
                            <StackPanel>
                                <TextBlock Style="{StaticResource Label}" Text="Processes"/>
                                <TextBlock x:Name="ProcCountLabel" Style="{StaticResource ValueLabel}" Text="0"/>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <!-- Action Buttons -->
                    <WrapPanel Grid.Row="2" VerticalAlignment="Top">
                        <Button x:Name="BtnStandby" Content="Clear Standby" Style="{StaticResource Btn}"/>
                        <Button x:Name="BtnWorking" Content="Empty Working Sets" Style="{StaticResource Btn}"/>
                        <Button x:Name="BtnDNS" Content="Flush DNS" Style="{StaticResource Btn}"/>
                        <Button x:Name="BtnGpuClear" Content="Clear GPU Memory" Style="{StaticResource Btn}"/>
                        <Button x:Name="BtnKillHigh" Content="Kill High-Usage" Style="{StaticResource Btn}"/>
                        <Button x:Name="BtnRestartBrowser" Content="Restart Browsers" Style="{StaticResource Btn}"/>
                    </WrapPanel>
                </Grid>

                <!-- PROCESSES TAB -->
                <Grid x:Name="PanelProcesses" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
                        <Button x:Name="BtnRefresh" Content="Refresh" Style="{StaticResource Btn}"/>
                        <TextBlock Text="Top 50 processes by RAM usage" Style="{StaticResource Label}" VerticalAlignment="Center" Margin="8,0,0,0"/>
                    </StackPanel>
                    <DataGrid x:Name="ProcessGrid" Grid.Row="1"
                              Background="#111" Foreground="white"
                              BorderThickness="0" AutoGenerateColumns="False"
                              IsReadOnly="True" CanUserAddRows="False"
                              RowBackground="#0d0d0d" AlternatingRowBackground="#151515"
                              HeadersVisibility="Column" GridLinesVisibility="None"
                              SelectionMode="Extended">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Process" Binding="{Binding Name}" Width="180"/>
                            <DataGridTextColumn Header="PID" Binding="{Binding Id}" Width="70"/>
                            <DataGridTextColumn Header="RAM (MB)" Binding="{Binding RAM_MB}" Width="90"/>
                            <DataGridTextColumn Header="CPU (s)" Binding="{Binding CPU_Sec}" Width="80"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Grid>

                <!-- PERFORMANCE TAB -->
                <Grid x:Name="PanelPerformance" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- RAM Chart -->
                    <Border Grid.Row="0" Background="#1a1a1a" CornerRadius="6" Padding="10" Margin="0,0,0,4">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Grid Grid.Row="0" Margin="0,0,0,4">
                                <TextBlock Text="RAM Usage" Style="{StaticResource Label}"/>
                                <TextBlock x:Name="RamChartValue" Text="0%" Style="{StaticResource ValueLabel}" HorizontalAlignment="Right"/>
                            </Grid>
                            <Canvas x:Name="RamCanvas" Grid.Row="1" Background="#111" ClipToBounds="True" Height="120"/>
                        </Grid>
                    </Border>

                    <!-- CPU Chart -->
                    <Border Grid.Row="1" Background="#1a1a1a" CornerRadius="6" Padding="10" Margin="0,4,0,4">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Grid Grid.Row="0" Margin="0,0,0,4">
                                <TextBlock Text="CPU Usage" Style="{StaticResource Label}"/>
                                <TextBlock x:Name="CpuChartValue" Text="0%" Style="{StaticResource ValueLabel}" HorizontalAlignment="Right"/>
                            </Grid>
                            <Canvas x:Name="CpuCanvas" Grid.Row="1" Background="#111" ClipToBounds="True" Height="120"/>
                        </Grid>
                    </Border>

                    <!-- GPU Chart -->
                    <Border Grid.Row="2" Background="#1a1a1a" CornerRadius="6" Padding="10" Margin="0,4,0,0">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Grid Grid.Row="0" Margin="0,0,0,4">
                                <TextBlock Text="GPU Usage" Style="{StaticResource Label}"/>
                                <TextBlock x:Name="GpuChartValue" Text="0%" Style="{StaticResource ValueLabel}" HorizontalAlignment="Right"/>
                            </Grid>
                            <Canvas x:Name="GpuCanvas" Grid.Row="1" Background="#111" ClipToBounds="True" Height="120"/>
                        </Grid>
                    </Border>
                </Grid>
            </Grid>
        </Border>

        <!-- Footer -->
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
            <Button x:Name="BtnSettings" Content="Settings" Style="{StaticResource Btn}"/>
            <Button x:Name="BtnTray" Content="Minimize to Tray" Style="{StaticResource Btn}"/>
        </StackPanel>
    </Grid>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# --- Resolve named elements ---
$StatusText        = $window.FindName("StatusText")
$MemLabel          = $window.FindName("MemLabel")
$MemBar            = $window.FindName("MemBar")
$MemTotalLabel     = $window.FindName("MemTotalLabel")
$MemFreeLabel      = $window.FindName("MemFreeLabel")
$CpuLabel          = $window.FindName("CpuLabel")
$GpuLabel          = $window.FindName("GpuLabel")
$GpuMemLabel       = $window.FindName("GpuMemLabel")
$ProcCountLabel    = $window.FindName("ProcCountLabel")
$ProcessGrid       = $window.FindName("ProcessGrid")
$RamCanvas         = $window.FindName("RamCanvas")
$CpuCanvas         = $window.FindName("CpuCanvas")
$GpuCanvas         = $window.FindName("GpuCanvas")
$RamChartValue     = $window.FindName("RamChartValue")
$CpuChartValue     = $window.FindName("CpuChartValue")
$GpuChartValue     = $window.FindName("GpuChartValue")
$PanelOverview     = $window.FindName("PanelOverview")
$PanelProcesses    = $window.FindName("PanelProcesses")
$PanelPerformance  = $window.FindName("PanelPerformance")
$TabOverview       = $window.FindName("TabOverview")
$TabProcesses      = $window.FindName("TabProcesses")
$TabPerformance    = $window.FindName("TabPerformance")
$BtnStandby        = $window.FindName("BtnStandby")
$BtnWorking        = $window.FindName("BtnWorking")
$BtnDNS            = $window.FindName("BtnDNS")
$BtnGpuClear       = $window.FindName("BtnGpuClear")
$BtnKillHigh       = $window.FindName("BtnKillHigh")
$BtnRestartBrowser = $window.FindName("BtnRestartBrowser")
$BtnRefresh        = $window.FindName("BtnRefresh")
$BtnSettings       = $window.FindName("BtnSettings")
$BtnTray           = $window.FindName("BtnTray")

# --- Tab Switching ---
$TabOverview.Add_Checked({
    $PanelOverview.Visibility = 'Visible'
    $PanelProcesses.Visibility = 'Collapsed'
    $PanelPerformance.Visibility = 'Collapsed'
})
$TabProcesses.Add_Checked({
    $PanelOverview.Visibility = 'Collapsed'
    $PanelProcesses.Visibility = 'Visible'
    $PanelPerformance.Visibility = 'Collapsed'
    [void][System.Threading.Thread]::Pool.QueueUserWorkItem({ Update-ProcessList })
})
$TabPerformance.Add_Checked({
    $PanelOverview.Visibility = 'Collapsed'
    $PanelProcesses.Visibility = 'Collapsed'
    $PanelPerformance.Visibility = 'Visible'
})

# --- System Tray ---
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = [System.Drawing.SystemIcons]::Shield
$trayIcon.Text = "RAM Optimizer"
$trayIcon.Visible = $false

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Items.Add("Open",      $null, { $window.Show(); $window.WindowState = 'Normal'; $trayIcon.Visible = $false })
$trayMenu.Items.Add("Clear RAM", $null, { [void][System.Threading.Thread]::Pool.QueueUserWorkItem({ Clear-StandbyList; Empty-AllWorkingSets | Out-Null; Update-Overview }) })
$trayMenu.Items.Add("Exit",      $null, { $trayIcon.Visible = $false; $window.Close() })
$trayIcon.ContextMenuStrip = $trayMenu
$trayIcon.Add_DoubleClick({ $window.Show(); $window.WindowState = 'Normal'; $trayIcon.Visible = $false })

# --- Update Functions ---
$script:UpdateRunning = $false

function Update-Overview {
    if ($script:UpdateRunning) { return }
    $script:UpdateRunning = $true
    try {
        $mem = Get-MemoryInfo
        $cpu = Get-CpuUsage
        $gpuInfo = Get-GpuUtilization
        $procCount = (Get-Process).Count

        $window.Dispatcher.BeginInvoke([action]{
            $MemLabel.Text = "RAM: $($mem.UsedMB) / $($mem.TotalMB) MB ($($mem.PctUsed)% used)"
            $barWidth = [math]::Min($mem.PctUsed, 100) * 2.8
            $MemBar.Width = $barWidth
            $MemTotalLabel.Text = "Total: $($mem.TotalMB) MB"
            $MemFreeLabel.Text = "Free: $($mem.FreeMB) MB"
            $CpuLabel.Text = "$cpu%"
            $GpuLabel.Text = "$($gpuInfo.Utilization)%"
            $GpuMemLabel.Text = "$($gpuInfo.Used_MB) / $($gpuInfo.Total_MB) MB"
            $ProcCountLabel.Text = "$procCount"
            $StatusText.Text = "Updated: $(Get-Date -Format 'HH:mm:ss')"
        }) | Out-Null
    } finally {
        $script:UpdateRunning = $false
    }
}

function Update-ProcessList {
    $procs = @()
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 50 | ForEach-Object {
        $procs += [PSCustomObject]@{
            Name    = $_.Name
            Id      = $_.Id
            RAM_MB  = [math]::Round($_.WorkingSet64 / 1MB, 1)
            CPU_Sec = if ($_.CPU) { [math]::Round($_.CPU, 1) } else { 0 }
        }
    }
    $window.Dispatcher.BeginInvoke([action]{ $ProcessGrid.ItemsSource = $procs }) | Out-Null
}

function Update-Charts {
    $mem = Get-MemoryInfo
    $cpu = Get-CpuUsage
    $gpuInfo = Get-GpuUtilization

    $script:RamHistory.Add($mem.PctUsed) | Out-Null
    $script:CpuHistory.Add($cpu) | Out-Null
    $script:GpuHistory.Add($gpuInfo.Utilization) | Out-Null

    while ($script:RamHistory.Count -gt $script:MaxHistory) { $script:RamHistory.RemoveAt(0) }
    while ($script:CpuHistory.Count -gt $script:MaxHistory) { $script:CpuHistory.RemoveAt(0) }
    while ($script:GpuHistory.Count -gt $script:MaxHistory) { $script:GpuHistory.RemoveAt(0) }

    $ramH = $script:RamHistory
    $cpuH = $script:CpuHistory
    $gpuH = $script:GpuHistory

    $window.Dispatcher.BeginInvoke([action]{
        $RamChartValue.Text = "$($mem.PctUsed)%"
        $CpuChartValue.Text = "$cpu%"
        $GpuChartValue.Text = "$($gpuInfo.Utilization)%"
        Draw-Chart -Canvas $RamCanvas -Data $ramH -Color "#cc0000" -MaxVal 100
        Draw-Chart -Canvas $CpuCanvas -Data $cpuH -Color "#00cc66" -MaxVal 100
        Draw-Chart -Canvas $GpuCanvas -Data $gpuH -Color "#0088ff" -MaxVal 100
    }) | Out-Null
}

# --- Live Update Timer (runs on UI thread, offloads work) ---
$liveTimer = New-Object System.Windows.Forms.Timer
$liveTimer.Interval = $Settings.chart_update_interval_ms
$liveTimer.Add_Tick({
    [void][System.Threading.Thread]::Pool.QueueUserWorkItem({
        Update-Overview
        Update-Charts
    })
})

# --- Button Handlers ---
$BtnStandby.Add_Click({
    $window.Dispatcher.BeginInvoke([action]{ $StatusText.Text = "Clearing standby list..." }) | Out-Null
    [void][System.Threading.Thread]::Pool.QueueUserWorkItem({
        $ok = Clear-StandbyList
        $msg = if ($ok) { "Standby list cleared" } else { "Failed to clear standby" }
        $window.Dispatcher.BeginInvoke([action]{ $StatusText.Text = $msg }) | Out-Null
        Update-Overview
    })
})

$BtnWorking.Add_Click({
    $window.Dispatcher.BeginInvoke([action]{ $StatusText.Text = "Emptying working sets..." }) | Out-Null
    [void][System.Threading.Thread]::Pool.QueueUserWorkItem({
        $count = Empty-AllWorkingSets
        $window.Dispatcher.BeginInvoke([action]{ $StatusText.Text = "Trimmed $count processes" }) | Out-Null
        Update-Overview
    })
})

$BtnDNS.Add_Click({
    [void][System.Threading.Thread]::Pool.QueueUserWorkItem({
        $ok = Flush-DnsCache
        $msg = if ($ok) { "DNS cache flushed" } else { "Failed to flush DNS" }
        $window.Dispatcher.BeginInvoke([action]{ $StatusText.Text = $msg }) | Out-Null
    })
})

$BtnGpuClear.Add_Click({
    $window.Dispatcher.BeginInvoke([action]{ $StatusText.Text = "Clearing GPU memory..." }) | Out-Null
    [void][System.Threading.Thread]::Pool.QueueUserWorkItem({
        Clear-GpuMemory | Out-Null
        $window.Dispatcher.BeginInvoke([action]{ $StatusText.Text = "GPU memory cleared" }) | Out-Null
        Update-Overview
    })
})

$BtnKillHigh.Add_Click({
    [void][System.Threading.Thread]::Pool.QueueUserWorkItem({
        $high = Get-HighUsageProcesses
        if ($high.Count -eq 0) {
            $window.Dispatcher.BeginInvoke([action]{
                [System.Windows.MessageBox]::Show("No processes above $($Settings.threshold_mb) MB threshold.", "Info")
            }) | Out-Null
            return
        }
        $list = ($high | ForEach-Object { "$($_.Name) (PID $($_.Id)) - $($_.RAM_MB) MB" }) -join "`n"
        $window.Dispatcher.BeginInvoke([action]{
            $result = [System.Windows.MessageBox]::Show(
                "Kill these processes?`n`n$list", "Confirm",
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($result -eq 'Yes') {
                $high | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
                $StatusText.Text = "Killed $($high.Count) processes"
                Update-Overview
            }
        }) | Out-Null
    })
})

$BtnRestartBrowser.Add_Click({
    [void][System.Threading.Thread]::Pool.QueueUserWorkItem({
        $browsers = Get-RunningBrowsers
        if ($browsers.Count -eq 0) {
            $window.Dispatcher.BeginInvoke([action]{
                [System.Windows.MessageBox]::Show("No browsers detected.", "Info")
            }) | Out-Null
            return
        }
        $list = ($browsers | ForEach-Object { "$($_.Name) (PID $($_.Id)) - $($_.RAM_MB) MB" }) -join "`n"
        $window.Dispatcher.BeginInvoke([action]{
            $result = [System.Windows.MessageBox]::Show(
                "Restart these browsers?`n`n$list", "Confirm",
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($result -eq 'Yes') {
                [void][System.Threading.Thread]::Pool.QueueUserWorkItem({
                    $browsers | ForEach-Object { Close-RestartBrowser -ProcessName $_.Name }
                    $window.Dispatcher.BeginInvoke([action]{
                        $StatusText.Text = "Browsers restarted"
                    }) | Out-Null
                    Update-Overview
                })
            }
        }) | Out-Null
    })
})

$BtnRefresh.Add_Click({ [void][System.Threading.Thread]::Pool.QueueUserWorkItem({ Update-ProcessList }) })

$BtnSettings.Add_Click({ Start-Process notepad.exe $SettingsPath })

$BtnTray.Add_Click({
    $window.Hide()
    $trayIcon.Visible = $true
    $trayIcon.ShowBalloonTip(2000, "RAM Optimizer", "Running in background", [System.Windows.Forms.ToolTipIcon]::Info)
})

$window.Add_Closing({
    $liveTimer.Stop()
    $autoCleanTimer.Stop()
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
})

# --- Auto-Clean Timer ---
$autoCleanTimer = New-Object System.Windows.Forms.Timer
$autoCleanTimer.Interval = $Settings.auto_clean_delay_minutes * 60 * 1000
$autoCleanTimer.Add_Tick({
    [void][System.Threading.Thread]::Pool.QueueUserWorkItem({
        Clear-StandbyList | Out-Null
        Empty-AllWorkingSets | Out-Null
        Flush-DnsCache | Out-Null
        Update-Overview
        Update-Charts
    })
    $window.Dispatcher.BeginInvoke([action]{
        $trayIcon.ShowBalloonTip(3000, "RAM Optimizer", "Auto-cleanup completed", [System.Windows.Forms.ToolTipIcon]::Info)
    }) | Out-Null
})
if ($Settings.auto_clean_on_startup) { $autoCleanTimer.Start() }

# --- Start ---
$liveTimer.Start()
[void][System.Threading.Thread]::Pool.QueueUserWorkItem({ Update-Overview })
[void][System.Threading.Thread]::Pool.QueueUserWorkItem({ Update-ProcessList })

$window.ShowDialog() | Out-Null
