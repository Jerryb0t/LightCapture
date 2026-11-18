[CmdletBinding(DefaultParameterSetName='Executable')]
param(
    [Parameter(Mandatory, ParameterSetName='Executable')][string] $Executable,
    [Parameter(Mandatory, ParameterSetName='Archive')][string] $Archive,
    [Parameter(Mandatory, ParameterSetName='Archive')][string] $ChecksumFile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Run only on the disposable Windows test account, not on a personal machine:
# LightCapture starts its normal global shortcut, while the harness sends no keys.
if (-not $IsWindows) { throw 'This smoke test needs PowerShell 7 on Windows.' }
$workspace = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'lightcapture-smoke-' + [Guid]::NewGuid().ToString('N'))
$application = $null
$reopener = $null
$settingsClass = 'LightCaptureWindows.Settings.v1'
$dispatchClass = 'LightCaptureWindows.Dispatch.v1'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LightCaptureSmokeWindow
{
    [DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    public static extern IntPtr FindWindowW(string cls, IntPtr title);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr wnd, out uint pid);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr wnd);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr wnd, int control);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr wnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr wnd, int id);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode, ExactSpelling=true)]
    public static extern bool PostMessageW(IntPtr wnd, uint msg, UIntPtr wp, IntPtr lp);
}
'@

function Assert-PreviewHash {
    param([string] $ZipPath, [string] $ShaFile)
    $name = [IO.Path]::GetFileName($ZipPath)
    $pattern = '^([a-fA-F0-9]{64})[ \t]+\*?' + [regex]::Escape($name) + '$'
    $line = @(Get-Content -LiteralPath $ShaFile | Where-Object { $_ -match $pattern })
    if ($line.Count -ne 1 -or $line[0] -notmatch $pattern) {
        throw 'Archive expected checksum missing or ambiguous.'
    }
    $expected = $Matches[1]
    if ((Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash -ne $expected) {
        throw 'Archive SHA-256 does not match.'
    }
    Write-Host "Preview archive SHA-256 verified: $expected"
}

function Assert-NativeX64Gui {
    param([string] $Path)
    $pe = [IO.File]::ReadAllBytes($Path)
    if ($pe.Length -lt 64 -or [BitConverter]::ToUInt16($pe,0) -ne 0x5a4d) { throw 'Missing PE DOS header.' }
    $ofs = [BitConverter]::ToInt32($pe,0x3c)
    if ($ofs -lt 64 -or $ofs -gt ($pe.Length - 94)) { throw 'Invalid PE header offset.' }
    if ([BitConverter]::ToUInt32($pe,$ofs) -ne 0x4550 -or
        [BitConverter]::ToUInt16($pe,$ofs + 4) -ne 0x8664 -or
        [BitConverter]::ToUInt16($pe,$ofs + 24) -ne 0x020b -or
        [BitConverter]::ToUInt16($pe,$ofs + 24 + 68) -ne 2) {
        throw 'Expected an x64 PE32+ GUI executable.'
    }
}

function Get-OwnedWindow {
    param([Diagnostics.Process] $App, [string] $Class)
    $wnd = [LightCaptureSmokeWindow]::FindWindowW($Class,[IntPtr]::Zero)
    if ($wnd -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    [uint32] $processId = 0
    [void] [LightCaptureSmokeWindow]::GetWindowThreadProcessId($wnd,[ref] $processId)
    if ($processId -ne [uint32] $App.Id) { throw 'Existing LightCapture HWND did not belong to this smoke-test process.' }
    return $wnd
}

function Await-Settings {
    param([Diagnostics.Process] $App, [bool] $Visible)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($App.HasExited) { throw "App exited before expected settings state, code $($App.ExitCode)." }
        $dispatch = Get-OwnedWindow $App $dispatchClass
        if ($dispatch -ne [IntPtr]::Zero) {
            if ([LightCaptureSmokeWindow]::IsWindowVisible($dispatch)) {
                throw 'The resident dispatcher must stay hidden.'
            }
            $wnd = Get-OwnedWindow $App $settingsClass
            if ($Visible -and $wnd -ne [IntPtr]::Zero -and [LightCaptureSmokeWindow]::IsWindowVisible($wnd)) {
                return $wnd
            }
            if (-not $Visible -and $wnd -eq [IntPtr]::Zero) {
                return $dispatch
            }
        }
        Start-Sleep -Milliseconds 80
    } while ($watch.Elapsed.TotalSeconds -lt 12)
    throw "App did not reach expected settings state (visible=$Visible, absent if false)."
}

function Assert-F2Reservation {
    param([bool] $HeldByApp)
    # The runner uses default settings, no external app, and never sends keys.
    $id = 1709
    $registered = [LightCaptureSmokeWindow]::RegisterHotKey([IntPtr]::Zero,$id,0x4000,0x71) # MOD_NOREPEAT, F2
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($registered) {
        if (-not [LightCaptureSmokeWindow]::UnregisterHotKey([IntPtr]::Zero,$id)) {
            throw 'Harness could not release temporary F2 registration.'
        }
        if ($HeldByApp) { throw 'Default F2 hotkey was released while the app was still resident.' }
    } elseif (-not $HeldByApp -or $err -ne 1409) { # ERROR_HOTKEY_ALREADY_REGISTERED
        throw "Unexpected F2 hotkey availability (held by app=$HeldByApp, error=$err)."
    }
}

function Write-MemorySample {
    param([Diagnostics.Process] $App, [string] $Label)
    $App.Refresh()
    Write-Host ("Hosted Windows, {0}: Private Bytes={1}; Working Set={2}" -f
        $Label, $App.PrivateMemorySize64, $App.WorkingSet64)
}

function Send-AppMessage {
    param([IntPtr] $Window, [uint32] $Message, [uint32] $WP, [IntPtr] $LP)
    if (-not [LightCaptureSmokeWindow]::PostMessageW($Window,$Message,[UIntPtr]::new($WP),$LP)) {
        throw "PostMessageW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }
}

function Await-ExitNormally {
    param([Diagnostics.Process] $App, [string] $Label)
    if (-not $App.WaitForExit(12000)) { throw "$Label did not exit." }
    if ($App.ExitCode -ne 0) { throw "$Label exited with $($App.ExitCode)." }
}

try {
    if ([LightCaptureSmokeWindow]::FindWindowW($settingsClass,[IntPtr]::Zero) -ne [IntPtr]::Zero -or
        [LightCaptureSmokeWindow]::FindWindowW($dispatchClass,[IntPtr]::Zero) -ne [IntPtr]::Zero) {
        throw 'An existing instance is open. This test will not touch it.'
    }
    if ($PSCmdlet.ParameterSetName -eq 'Archive') {
        Assert-PreviewHash $Archive $ChecksumFile
        $null = New-Item -ItemType Directory -Path $workspace
        Expand-Archive -LiteralPath $Archive -DestinationPath $workspace
        $Executable = Join-Path $workspace 'LightCapture.exe'
    }
    $Executable = (Resolve-Path -LiteralPath $Executable).ProviderPath
    Assert-NativeX64Gui $Executable
    $working = Split-Path -Parent $Executable
    Write-Host "Testing executable SHA-256 $((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash). Running without elevation requests under the runner account."

    Assert-F2Reservation $false
    $application = Start-Process -FilePath $Executable -WorkingDirectory $working -PassThru
    $wnd = Await-Settings $application $true
    Write-Host 'PASS: Normal launch created visible settings.'

    $dispatch = Get-OwnedWindow $application $dispatchClass
    for ($cycle = 1; $cycle -le 6; $cycle++) {
        Send-AppMessage $wnd 0x0010 0 ([IntPtr]::Zero) # WM_CLOSE
        if ((Await-Settings $application $false) -ne $dispatch) {
            throw 'Releasing settings replaced the resident dispatcher.'
        }
        if ($cycle -in @(1,3,6)) {
            Assert-F2Reservation $true
            Write-MemorySample $application "settings close $cycle"
        }

        $reopener = Start-Process -FilePath $Executable -WorkingDirectory $working -PassThru
        Await-ExitNormally $reopener 'Second instance'
        $reopener.Dispose()
        $reopener = $null
        $wnd = Await-Settings $application $true
    }
    Write-Host 'PASS: Settings destroyed and recreated for six close/reopen cycles in the original process, with the same hidden dispatcher.'

    # Invoke the same handler as the application's Quit button; no synthetic input
    # or blanket process termination. Low word = settings Quit control ID; high = BN_CLICKED (0).
    $quitId = 15
    $quit = [LightCaptureSmokeWindow]::GetDlgItem($wnd,$quitId)
    if ($quit -eq [IntPtr]::Zero) { throw 'Settings Quit button not found.' }
    Send-AppMessage $wnd 0x0111 $quitId $quit
    Await-ExitNormally $application 'LightCapture'
    Write-Host 'PASS: Settings Quit closed the resident process normally.'

    $application.Dispose()
    $application = Start-Process -FilePath $Executable -WorkingDirectory $working -ArgumentList '--background' -PassThru
    $dispatch = Await-Settings $application $false
    Start-Sleep -Seconds 1
    if ((Await-Settings $application $false) -ne $dispatch) { throw 'Background dispatcher changed.' }
    Assert-F2Reservation $true
    Write-MemorySample $application 'background startup before settings'
    Write-Host 'PASS: Background startup created a hidden dispatcher and no settings window.'
    $reopener = Start-Process -FilePath $Executable -WorkingDirectory $working -PassThru
    Await-ExitNormally $reopener 'Reopen instance'
    $wnd = Await-Settings $application $true
    $quit = [LightCaptureSmokeWindow]::GetDlgItem($wnd,$quitId)
    if ($quit -eq [IntPtr]::Zero) { throw 'Settings Quit button not found after reopening.' }
    Send-AppMessage $wnd 0x0111 $quitId $quit
    Await-ExitNormally $application 'Background LightCapture'
    Assert-F2Reservation $false
    Write-Host 'PASS: Reopen and normal quit also work after background launch.'
} finally {
    # Only kill child PIDs that this disposable test itself started, and only on failure.
    foreach ($child in @($reopener,$application)) {
        if ($null -ne $child) {
            if (-not $child.HasExited) { $child.Kill(); $null = $child.WaitForExit(5000) }
            $child.Dispose()
        }
    }
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force }
}
