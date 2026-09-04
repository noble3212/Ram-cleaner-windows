# RAM Optimizer

A lightweight Windows RAM and system optimization utility with a real-time WPF dashboard for monitoring and managing system memory, CPU usage, GPU usage, running processes, and browser memory consumption.

> **Requires Windows PowerShell 5.1 and Administrator privileges.**

## Features

### Real-Time System Monitoring

The application continuously monitors:

* RAM usage
* RAM percentage
* Available/free RAM
* CPU utilization
* GPU utilization
* GPU VRAM usage
* Running process count
* Top processes by RAM consumption

The Performance tab maintains configurable historical data and displays live RAM, CPU, and GPU usage charts.

### RAM Optimization

The Overview tab provides several cleanup operations:

* **Clear Standby** — Attempts to clear the Windows standby memory list.
* **Empty Working Sets** — Trims process working sets using the Windows `EmptyWorkingSet` API.
* **Flush DNS** — Clears the Windows DNS client cache.
* **Clear GPU Memory** — Attempts NVIDIA GPU reset and clears relevant DirectX/shader caches.
* **Kill High-Usage** — Identifies processes exceeding the configured RAM threshold and allows the user to terminate them.
* **Restart Browsers** — Detects configured browsers and allows them to be closed and restarted.

### Process Manager

The Processes tab displays the top 50 processes sorted by RAM consumption.

Information shown includes:

| Column   | Description                |
| -------- | -------------------------- |
| Process  | Process name               |
| PID      | Windows process ID         |
| RAM (MB) | Current working-set memory |
| CPU (s)  | Accumulated CPU time       |

### System Tray

The application can minimize to the Windows system tray.

The tray menu provides:

* Open
* Clear RAM
* Exit

This allows the optimizer to continue running in the background without keeping the main window open.

### Automatic Cleanup

Automatic cleanup can periodically:

1. Clear the standby list
2. Empty process working sets
3. Flush the DNS cache
4. Refresh system statistics

The interval is configurable through `settings.json`.

---

# Requirements

## Operating System

* Windows
* Windows PowerShell 5.1 or newer

## Permissions

The application requires **Administrator privileges** because several operations interact with Windows system APIs and process memory.

If the script is not already running as Administrator, it automatically requests elevation and relaunches itself.

## Optional GPU Support

For NVIDIA GPU monitoring and management:

* NVIDIA drivers
* `nvidia-smi` available in the system PATH

AMD and Intel GPUs can still be detected through Windows' `Win32_VideoController` interface, but GPU utilization reporting is more limited.

---

# Installation

Clone or download the project.

Place the PowerShell script and configuration file in the same directory:

```text
RAM-Optimizer/
├── RAM-Optimizer.ps1
├── settings.json
└── README.md
```

Run the PowerShell script:

```powershell
.\RAM-Optimizer.ps1
```

Administrator privileges are requested automatically if required.

If PowerShell's execution policy prevents the script from running, it can be launched with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\RAM-Optimizer.ps1
```

---

# Configuration

The application looks for a `settings.json` file in the same directory as the script.

If the file does not exist, default settings are generated internally.

Example configuration:

```json
{
    "threshold_mb": 500,
    "auto_clean_delay_minutes": 60,
    "browsers": [
        "chrome",
        "firefox",
        "msedge",
        "brave",
        "opera",
        "vivaldi",
        "waterfox",
        "arc"
    ],
    "auto_clean_on_startup": true,
    "minimize_to_tray": true,
    "chart_history_seconds": 120,
    "chart_update_interval_ms": 1000,
    "gpu_cleanup_enabled": true
}
```

## Configuration Options

### `threshold_mb`

RAM threshold used by **Kill High-Usage**.

```json
"threshold_mb": 500
```

Processes using more than this amount of working-set memory are presented for possible termination.

### `auto_clean_delay_minutes`

Controls the automatic cleanup timer interval.

```json
"auto_clean_delay_minutes": 60
```

### `browsers`

List of browser process names that the application can detect and restart.

```json
"browsers": [
    "chrome",
    "firefox",
    "msedge",
    "brave"
]
```

### `auto_clean_on_startup`

Controls whether the automatic cleanup timer is started when the application launches.

```json
"auto_clean_on_startup": true
```

### `minimize_to_tray`

Configuration option for tray behavior.

```json
"minimize_to_tray": true
```

### `chart_history_seconds`

Controls the maximum amount of historical samples retained for the charts.

```json
"chart_history_seconds": 120
```

### `chart_update_interval_ms`

Controls how frequently monitoring data is collected.

```json
"chart_update_interval_ms": 1000
```

The default value of `1000` means the dashboard updates approximately once per second.

### `gpu_cleanup_enabled`

Controls the intended GPU cleanup configuration.

```json
"gpu_cleanup_enabled": true
```

---

# How It Works

The application combines PowerShell, WPF, Windows APIs, CIM/WMI information, and optional NVIDIA tooling.

## Memory Monitoring

System memory information is obtained through:

```text
Win32_OperatingSystem
```

The application calculates:

```text
Used RAM = Total RAM - Free RAM
```

and displays both the absolute memory usage and percentage utilization.

## CPU Monitoring

CPU utilization is retrieved through:

```text
Win32_Processor
```

The reported `LoadPercentage` is used as the current CPU utilization value.

## GPU Monitoring

GPU information is obtained through:

```text
Win32_VideoController
```

For NVIDIA GPUs, the application additionally attempts to use:

```text
nvidia-smi
```

to obtain:

* GPU utilization
* Used VRAM
* Total VRAM

AMD and Intel GPUs fall back to Windows adapter information when NVIDIA tooling is unavailable.

## Working Set Management

The application imports the Windows `EmptyWorkingSet` API from `psapi.dll`.

It opens eligible processes with the required permissions and asks Windows to trim their working sets.

## Standby Memory

The application calls `NtSetSystemInformation` from `ntdll.dll` to request standby-list clearing.

This is a low-level Windows operation and therefore requires elevated privileges.

## DNS Cleanup

DNS cleanup uses:

```powershell
Clear-DnsClientCache
```

to flush the Windows DNS client cache.

---

# Interface

The application contains three primary tabs.

## Overview

Provides:

* Current RAM usage
* RAM utilization bar
* CPU utilization
* GPU utilization
* GPU VRAM usage
* Process count
* Memory/system cleanup actions

## Processes

Displays the 50 processes currently consuming the most RAM.

The list can be manually refreshed.

## Performance

Provides historical charts for:

* RAM
* CPU
* GPU

The default history window is 120 seconds.

---

# GPU Cleanup

The GPU cleanup function attempts to perform several operations.

For NVIDIA systems it invokes:

```powershell
nvidia-smi --gpu-reset
```

It also attempts to clear:

```text
%LOCALAPPDATA%\D3DSCache
%LOCALAPPDATA%\DirectX
%TEMP%\NVIDIA
```

### Important

NVIDIA GPU reset availability depends on the GPU, driver, workload, and whether the GPU is currently being used by other applications.

A GPU driving a display or actively being used by another process may reject a reset request.

The application therefore treats GPU reset as an **attempt**, rather than guaranteeing that VRAM has been completely freed.

---

# Safety Considerations

This application performs potentially disruptive system operations.

### Kill High-Usage

The **Kill High-Usage** function can terminate processes with:

```powershell
Stop-Process -Force
```

Always review the process list before confirming.

Killing an important Windows process or application can cause:

* Unsaved data loss
* Application crashes
* Temporary system instability
* Session termination

### Restart Browsers

Restarting browsers terminates their processes before attempting to launch them again.

Make sure important browser work is saved before using this function.

### Memory Optimization

Trimming working sets and clearing standby memory does **not** inherently increase the physical amount of RAM installed in the system.

Windows normally manages memory aggressively on its own. These functions are intended primarily for situations where manually reclaiming memory is useful for a particular workload or troubleshooting scenario.

---

# Performance

The monitoring system uses background thread-pool work for system queries so that expensive operations do not unnecessarily block the WPF interface.

The dashboard uses a configurable update interval:

```text
Default: 1000 ms
```

Historical chart data is retained using in-memory arrays with a configurable maximum history length.

---

# Project Structure

A typical installation can contain:

```text
RAM-Optimizer/
│
├── RAM-Optimizer.ps1
├── settings.json
└── README.md
```

The PowerShell script contains:

```text
Admin elevation
Configuration loading
Windows API definitions
Memory monitoring
CPU monitoring
GPU monitoring
Standby-list cleanup
Working-set cleanup
DNS cleanup
GPU cleanup
Browser detection
Browser restarting
High-memory process detection
WPF interface
System tray integration
Performance charts
Automatic cleanup
```

---

# Troubleshooting

## Script immediately requests Administrator privileges

This is expected behavior.

The application requires elevated privileges for several memory-management operations.

---

## GPU usage shows 0%

If using NVIDIA hardware, verify that:

```powershell
nvidia-smi
```

works from PowerShell.

If `nvidia-smi` is unavailable, the application falls back to Windows GPU information.

AMD and Intel GPU utilization reporting is more limited.

---

## GPU reset fails

This can be normal.

A GPU may reject reset requests when:

* It is driving a display
* An application is using the GPU
* Another process has an active GPU context
* The driver does not support the requested reset operation

The script reports the attempt rather than assuming the reset succeeded.

---

## No browsers are detected

Check the `browsers` array in `settings.json`.

Process names are matched against the configured browser names.

For example:

```json
"browsers": [
    "chrome",
    "firefox",
    "msedge",
    "brave"
]
```

---

## RAM usage doesn't stay lower

This is normal.

Windows may immediately reuse memory after it has been freed or trimmed. Memory that appears "used" is not necessarily wasted memory.

The optimizer should therefore be viewed as a **manual/system-management utility**, not as a permanent RAM reduction mechanism.

---

# Disclaimer

This software performs low-level Windows memory and process-management operations.

Use it at your own risk.

The author is not responsible for:

* Lost data
* Terminated processes
* Application crashes
* GPU driver issues
* System instability
* Unsaved work
* Any damage resulting from improper use

Always save important work before performing aggressive cleanup operations.

---

# License

Add your preferred license here.

For example:

```text
MIT License
```

If this project is intended to be open source, a license file such as `LICENSE` should be included with the repository.

---

# Contributing

Contributions, bug reports, and improvements are welcome.

Potential areas for future development include:

* AMD GPU utilization support
* Intel GPU utilization support
* Per-GPU monitoring for multi-GPU systems
* More granular process controls
* Configurable cleanup profiles
* Startup integration
* Windows notifications
* Historical statistics
* More advanced GPU memory management
* Exporting performance data
* Additional system diagnostics

---

## Status

**Windows RAM Optimizer — Functional**

A PowerShell/WPF system utility providing real-time resource monitoring and configurable RAM/system cleanup operations.

