# Shared by the PowerShell tests. Dot-source it:
#
#     . (Join-Path $PSScriptRoot 'FakeDocker.ps1')
#     $fakebin = Install-FakeDocker       # a recording fake `docker` is now first on PATH
#     ...
#     Remove-FakeDocker $fakebin
#
# On Linux and macOS the fake is the shell script tests/fakebin/docker. On Windows it is a
# docker.exe compiled from tests/fakebin/docker.cs, because the module, setup.ps1 and uninstall.ps1
# look for a real docker.exe. (See the top of tests/fakebin/docker for the knobs the fake understands.)

$isWin = ($env:OS -eq 'Windows_NT')

function Install-FakeDocker {
    if ($isWin) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) "devtools-fakebin-$PID"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $cs  = Join-Path (Join-Path $PSScriptRoot 'fakebin') 'docker.cs'
        $exe = Join-Path $dir 'docker.exe'
        # Add-Type -OutputAssembly only exists in Windows PowerShell, so compile with that
        # whichever PowerShell is running the tests.
        $compile = "Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath '$cs') -OutputAssembly '$exe' -OutputType ConsoleApplication"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $compile
        if (-not (Test-Path -LiteralPath $exe)) { throw "could not build the fake docker.exe from $cs" }
    } else {
        $dir = Join-Path $PSScriptRoot 'fakebin'
        & chmod +x (Join-Path $dir 'docker')
    }
    $env:PATH = $dir + [IO.Path]::PathSeparator + $env:PATH     # the fake wins over a real docker
    return $dir
}

function Remove-FakeDocker([string] $Dir) {
    if ($isWin) { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
}
