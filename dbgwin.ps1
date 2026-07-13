# Enlarge the Box16 window after launch.
#
# Box16 opens at 658x558 and its debugger panels (Disassembler, CPU status, stack,
# memory dump) are ImGui windows drawn INSIDE that window - at the default size they
# overlap each other and the Disassembler's symbol/address column is clipped, which
# makes loaded symbols look like they never loaded. -scale does NOT help: it is a
# render setting and leaves the window size untouched (measured: 658x558 at -scale
# 1, 2 and 3 alike). Resizing the OS window is the only thing that gives them room.
#
# Called by dbg.bat. Safe to run standalone: .\dbgwin.ps1
param(
    [int]$Width  = 1680,
    [int]$Height = 1020,
    [int]$TimeoutSec = 10
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Box16Win {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@

# the window is not up the instant the process is, so poll for a valid handle
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$h = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    $p = Get-Process Box16 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        $p.Refresh()
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $h = $p.MainWindowHandle; break }
    }
    Start-Sleep -Milliseconds 250
}

if ($h -eq [IntPtr]::Zero) {
    Write-Host "dbgwin: no Box16 window found - leaving it alone."
    exit 0
}

# SWP_NOZORDER (0x0004). SDL clamps to what fits the desktop, which is fine.
[void][Box16Win]::SetWindowPos($h, [IntPtr]::Zero, 40, 40, $Width, $Height, 0x0004)
[void][Box16Win]::SetForegroundWindow($h)
