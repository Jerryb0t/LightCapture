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
$expectedClass = 'LightCaptureWindows.Settings.v1'

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
    param([Diagnostics.Process] $App)
    $wnd = [LightCaptureSmokeWindow]::FindWindowW($expectedClass,[IntPtr]::Zero)
    if ($wnd -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    [uint32] $processId = 0
    [void] [LightCaptureSmokeWindow]::GetWindowThreadProcessId($wnd,[ref] $processId)
    if ($processId -ne [uint32] $App.Id) { throw 'Existing LightCapture HWND did not belong to this smoke-test process.' }
    return $wnd
}

function Await-Visibility {
    param([Diagnostics.Process] $App, [bool] $Visible)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($App.HasExited) { throw "App exited before expected visibility, code $($App.ExitCode)." }
        $wnd = Get-OwnedWindow $App
        if ($wnd -ne [IntPtr]::Zero -and [LightCaptureSmokeWindow]::IsWindowVisible($wnd) -eq $Visible) {
            return $wnd
        }
        Start-Sleep -Milliseconds 80
    } while ($watch.Elapsed.TotalSeconds -lt 12)
    throw "App main window not found in expected visible=$Visible state."
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
    if ([LightCaptureSmokeWindow]::FindWindowW($expectedClass,[IntPtr]::Zero) -ne [IntPtr]::Zero) {
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

    $application = Start-Process -FilePath $Executable -WorkingDirectory $working -PassThru
    $wnd = Await-Visibility $application $true
    Write-Host 'PASS: Normal launch created visible settings.'

    Send-AppMessage $wnd 0x0010 0 ([IntPtr]::Zero) # WM_CLOSE
    $null = Await-Visibility $application $false
    Write-Host 'PASS: Close hid settings and left the app resident.'

    $reopener = Start-Process -FilePath $Executable -WorkingDirectory $working -PassThru
    Await-ExitNormally $reopener 'Second instance'
    $wnd = Await-Visibility $application $true
    Write-Host 'PASS: Second launch reopened the original process.'

    # Invoke the same handler as the application's Quit button; no synthetic input
    # or blanket process termination. Low word = settings Quit control ID; high = BN_CLICKED (0).
    $quitId = 15
    $quit = [LightCaptureSmokeWindow]::GetDlgItem($wnd,$quitId)
    if ($quit -eq [IntPtr]::Zero) { throw 'Settings Quit button not found.' }
    Send-AppMessage $wnd 0x0111 $quitId $quit
    Await-ExitNormally $application 'LightCapture'
    Write-Host 'PASS: Settings Quit closed the resident process normally.'

    $application = Start-Process -FilePath $Executable -WorkingDirectory $working -ArgumentList '--background' -PassThru
    $wnd = Await-Visibility $application $false
    Write-Host 'PASS: Background launch created settings without showing it.'
    $reopener = Start-Process -FilePath $Executable -WorkingDirectory $working -PassThru
    Await-ExitNormally $reopener 'Reopen instance'
    $wnd = Await-Visibility $application $true
    $quit = [LightCaptureSmokeWindow]::GetDlgItem($wnd,$quitId)
    if ($quit -eq [IntPtr]::Zero) { throw 'Settings Quit button not found after reopening.' }
    Send-AppMessage $wnd 0x0111 $quitId $quit
    Await-ExitNormally $application 'Background LightCapture'
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
