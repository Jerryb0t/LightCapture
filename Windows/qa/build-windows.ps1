[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Zig,
    [Parameter(Mandatory)][string] $Project,
    [Parameter(Mandatory)][string] $Output
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Zig = (Resolve-Path -LiteralPath $Zig).ProviderPath
$Project = (Resolve-Path -LiteralPath $Project).ProviderPath
$Output = [IO.Path]::GetFullPath($Output)
$null = New-Item -ItemType Directory -Force -Path $Output
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $Output '.zig-cache'

function Invoke-Zig([string[]] $CommandArguments) {
    & $Zig @CommandArguments
    if ($LASTEXITCODE -ne 0) { throw "Zig exited $LASTEXITCODE." }
}
function Invoke-BuiltTest([string] $Path) {
    & $Path
    if ($LASTEXITCODE -ne 0) { throw "Synthetic test failed: exit $LASTEXITCODE." }
}

Push-Location -LiteralPath $Project
try {
    $target = 'x86_64-windows-gnu'
    $strict = @('-target',$target,'-O2','-Wall','-Wextra','-Werror')
    $obj = @()
    foreach ($part in @('main','lightcapture_video','support')) {
        $path = Join-Path $Output "$part.o"
        Invoke-Zig (@('cc') + $strict + @('-c',"src/$part.c",'-o',$path))
        $obj += $path
    }
    $stitch = Join-Path $Output 'stitch.o'
    Invoke-Zig (@('c++','-std=c++17') + $strict + @('-c','src/stitch_bridge.cpp','-o',$stitch))
    $resources = Join-Path $Output 'icon.res'
    Invoke-Zig @('rc','/fo',$resources,'icon.rc')
    $exe = Join-Path $Output 'LightCapture.exe'
    Invoke-Zig (@('c++','-target',$target,'-O2','-s','-municode','-Wl,--subsystem,windows') +
        $obj + @($stitch,$resources,'-ldwmapi','-lgdi32','-luser32','-lmsimg32','-lole32','-lshell32','-ladvapi32',
        '-lwindowscodecs','-lmfplat','-lmfreadwrite','-lmfuuid','-luuid','-o',$exe))
    $stitchTest = Join-Path $Output 'stitch-test.exe'
    Invoke-Zig (@('c++','-std=c++17') + $strict + @('-I','src','tests/test_vertical_stitch.cpp','-o',$stitchTest))
    Invoke-BuiltTest $stitchTest
    $nv12Test = Join-Path $Output 'nv12-test.exe'
    Invoke-Zig (@('cc','-std=c11') + $strict + @('-I','src','tests/nv12_test.c','-o',$nv12Test))
    Invoke-BuiltTest $nv12Test
} finally {
    Pop-Location
}
