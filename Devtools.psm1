<#
    Devtools.psm1 — run the toolbox CLIs transparently from PowerShell.

    After importing, `az`, `kubectl`, `terraform`, `flux`, `helm`, `kustomize`
    and `azd` each run inside the devtools container against a persistent creds
    volume, with your current directory mounted at /work. Because these are
    PowerShell functions, they shadow any same-named host executable — so on a
    machine with no local az/kubectl/etc., they just become the default.

    Install (one line in your $PROFILE):
        Import-Module 'C:\path\to\devtools-toolbox\Devtools.psm1' -Force

    To find / create your profile:
        if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force }
        notepad $PROFILE      # add the Import-Module line above, save, reopen PS

    First run (device-code login — there's no browser inside the container):
        az login --use-device-code

    Optional overrides (set before Import-Module, e.g. in $PROFILE):
        $env:DEVTOOLS_IMAGE  = 'devtools:latest'     # image tag to run
        $env:DEVTOOLS_VOLUME = 'devtools-home'       # named creds volume
#>

Set-StrictMode -Version Latest

$script:DevToolsImage  = if ($env:DEVTOOLS_IMAGE)  { $env:DEVTOOLS_IMAGE }  else { 'devtools:latest' }
$script:DevToolsVolume = if ($env:DEVTOOLS_VOLUME) { $env:DEVTOOLS_VOLUME } else { 'devtools-home' }

# Resolve the real docker executable, never a function/alias, so wrappers can't recurse.
function Resolve-Docker {
    $d = Get-Command 'docker.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $d) { $d = Get-Command 'docker' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $d) {
        throw "docker was not found on PATH. Start Docker Desktop and make sure 'docker' runs in a normal shell."
    }
    return $d.Source
}

# Current host directory as a real filesystem path (handles PSDrives), -> /work.
function Get-HostWorkdir {
    $p = try { (Get-Location).ProviderPath } catch { $null }
    if ([string]::IsNullOrWhiteSpace($p)) { $p = "$PWD" }
    return $p
}

# Shared mount set for every invocation.
function Get-BaseRunArgs {
    param([bool] $AllowTty)

    $cwd = Get-HostWorkdir
    $a = [System.Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@('run', '--rm', '-i'))

    # Allocate a TTY only for genuine interactive use. Adding -t when stdout/stdin
    # is piped or captured corrupts output and breaks scripting, so guard it.
    if ($AllowTty -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) {
        $a.Add('-t')
    }

    $a.AddRange([string[]]@('-v', "$($script:DevToolsVolume):/root"))
    $a.AddRange([string[]]@('-v', "$($cwd):/work", '-w', '/work'))
    # Comma operator: return the List intact. A bare `return $a` would be unrolled
    # by PowerShell into a fixed-size array, breaking the caller's later .Add().
    return ,$a
}

# Windows PowerShell 5.1 (and PowerShell 7.0 - 7.2, or 7.3+ with $PSNativeCommandArgumentPassing
# set to 'Legacy') builds a native command line without escaping embedded double quotes and
# drops empty arguments. So `kubectl patch -p '{"a":1}'` would reach the container as {a:1}.
# For those shells the arguments are escaped by hand, following the Windows command-line rules
# (CommandLineToArgvW), so every argument arrives exactly as typed. Newer PowerShell does this
# itself, and then the arguments are passed through untouched.
function Test-LegacyNativeArgs {
    $v = $PSVersionTable.PSVersion
    if ($v.Major -lt 7 -or ($v.Major -eq 7 -and $v.Minor -lt 3)) { return $true }
    $mode = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
    return ("$mode" -eq 'Legacy')
}

function ConvertTo-LegacyNativeArg {
    param([string] $Arg)

    # An empty argument vanishes in the legacy behaviour; "" keeps it.
    if ($Arg.Length -eq 0) { return '""' }

    # Escape every double quote, doubling any backslashes directly in front of it.
    $s = [regex]::Replace($Arg, '(\\*)"', '$1$1\"')

    # PowerShell wraps an argument that contains whitespace in quotes. Windows PowerShell 5.1
    # does not protect a backslash at the very end of it, so that backslash would escape the
    # closing quote: double them. (PowerShell 7 does this itself, even in its legacy mode.)
    if ($PSVersionTable.PSVersion.Major -lt 6 -and $s -match '\s') {
        $s = [regex]::Replace($s, '(\\+)\z', '$1$1')
    }

    return $s
}

# Run the real docker with these arguments, each one arriving exactly as given.
function Invoke-Docker {
    param([string[]] $DockerArgs)

    $docker = Resolve-Docker
    if (Test-LegacyNativeArgs) {
        $DockerArgs = @($DockerArgs | ForEach-Object { ConvertTo-LegacyNativeArg $_ })
    }

    # $LASTEXITCODE is set automatically and propagates to the caller — do NOT
    # call `exit`, that would kill the user's interactive session.
    & $docker @DockerArgs
}

# Core runner (the "dev-run" helper). Builds a one-shot `docker run` and execs it.
# NOTE: intentionally NOT an advanced function, and tool args arrive as an explicit
# array value — so tool flags like `-out` are passed through as data, never parsed
# as parameters of this function.
function Invoke-DevTool {
    param(
        [string]   $Tool,
        [string[]] $ToolArgs = @()
    )

    $runArgs = Get-BaseRunArgs -AllowTty $true
    $runArgs.Add($script:DevToolsImage)
    $runArgs.Add($Tool)
    if ($ToolArgs.Count -gt 0) { $runArgs.AddRange([string[]] $ToolArgs) }

    Invoke-Docker -DockerArgs ($runArgs.ToArray())
}

# Open an interactive bash shell in the toolbox with the same mounts.
function dev {
    $devArgs = @($args)
    $runArgs = Get-BaseRunArgs -AllowTty $true
    $runArgs.Add($script:DevToolsImage)
    if ($devArgs.Count -gt 0) { $runArgs.AddRange([string[]] $devArgs) } else { $runArgs.Add('bash') }

    Invoke-Docker -DockerArgs ($runArgs.ToArray())
}

# Make Docker Desktop's Kubernetes usable from the toolbox. The container keeps its own
# kubeconfig on the volume and cannot see the Windows one, so this copies ONE context out
# of ~\.kube\config (that single file is mounted read-only for this one call) and points it
# at the Docker Desktop host. Needs Kubernetes enabled in Docker Desktop. Re-run it after
# "Reset Kubernetes Cluster", because the cluster certificates change.
function Import-DockerDesktopKube {
    [CmdletBinding()]
    param(
        [string] $Context    = 'docker-desktop',
        [string] $KubeConfig = (Join-Path (Join-Path $HOME '.kube') 'config')
    )

    if (-not (Test-Path -LiteralPath $KubeConfig -PathType Leaf)) {
        Write-Error ("No kubeconfig at $KubeConfig. In Docker Desktop open Settings > Kubernetes, " +
                     "enable it, wait until it shows Running, then run this again.")
        return
    }

    $runArgs = [System.Collections.Generic.List[string]]::new()
    $runArgs.AddRange([string[]]@('run', '--rm', '-i'))
    $runArgs.AddRange([string[]]@('-v', "$($script:DevToolsVolume):/root"))
    $runArgs.AddRange([string[]]@('-v', "$($KubeConfig):/hostkube/config:ro"))
    $runArgs.Add($script:DevToolsImage)
    $runArgs.AddRange([string[]]@('import-docker-desktop-kube', $Context))

    Invoke-Docker -DockerArgs ($runArgs.ToArray())

    # 127 = "executable not found": the image predates the helper scripts.
    if ($LASTEXITCODE -eq 127) {
        Write-Warning 'This image has no import-docker-desktop-kube yet. Rebuild it first:  docker compose build'
    }
}

# Show what the wrappers are pointed at.
function Get-DevToolsInfo {
    [pscustomobject]@{
        Image  = $script:DevToolsImage
        Volume = $script:DevToolsVolume
        Tools  = 'az, kubectl, terraform, flux, helm, kustomize, azd, gh, kubectx, kubens, dev'
    }
}

# --- Transparent CLI wrappers (hyphen-free so they shadow the host binaries) ---
# Each passes its args as the VALUE of -ToolArgs, so nothing gets re-parsed.
function az        { Invoke-DevTool -Tool az        -ToolArgs $args }
function kubectl   { Invoke-DevTool -Tool kubectl   -ToolArgs $args }
function terraform { Invoke-DevTool -Tool terraform -ToolArgs $args }
function flux      { Invoke-DevTool -Tool flux      -ToolArgs $args }
function helm      { Invoke-DevTool -Tool helm      -ToolArgs $args }
function kustomize { Invoke-DevTool -Tool kustomize -ToolArgs $args }
function azd       { Invoke-DevTool -Tool azd       -ToolArgs $args }
function gh        { Invoke-DevTool -Tool gh        -ToolArgs $args }
function kubectx   { Invoke-DevTool -Tool kubectx   -ToolArgs $args }
function kubens    { Invoke-DevTool -Tool kubens    -ToolArgs $args }

Export-ModuleMember -Function az, kubectl, terraform, flux, helm, kustomize, azd, gh, kubectx, kubens, dev, Import-DockerDesktopKube, Get-DevToolsInfo
