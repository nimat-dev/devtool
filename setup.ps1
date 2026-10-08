#Requires -Version 5.1
<#
.SYNOPSIS
    One-file setup for the DevOps toolbox. Runs every setup command in order.

.DESCRIPTION
    From the project folder (no admin rights needed):

        powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1

    1  checks that Docker Desktop is running with Linux containers
    2  creates .env from .env.example (kept if it already exists)
    3  builds the image                       (docker compose build)
    4  adds the Import-Module line to your PowerShell profile
    5  loads the wrappers in this window      (az, kubectl, terraform, ... run in the container)
    6  verifies every tool
    then offers the Azure login and the Docker Desktop Kubernetes import.

    Safe to run again at any time: every step checks before it changes anything.
    Exit code: 0 all good, 1 setup could not finish, 2 setup finished but something above failed.

.PARAMETER SkipBuild    Do not build the image (it is already built).
.PARAMETER SkipProfile  Do not touch your PowerShell profile.
.PARAMETER SkipVerify   Do not run the tool checks.
.PARAMETER Login        Run 'az login --use-device-code' at the end without asking.
.PARAMETER ImportKube   Import Docker Desktop's Kubernetes context at the end without asking.
.PARAMETER NoPrompt     Never ask a question (for automation). The two optional steps then run
                        only when -Login / -ImportKube are given.
.PARAMETER ProfilePath  Profile file to edit instead of your all-hosts profile.
#>
[CmdletBinding()]
param(
    [switch] $SkipBuild,
    [switch] $SkipProfile,
    [switch] $SkipVerify,
    [switch] $Login,
    [switch] $ImportKube,
    [switch] $NoPrompt,
    [string] $ProfilePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
$psm1     = Join-Path $root 'Devtools.psm1'
$image    = 'devtools:latest'
$isWin    = ($env:OS -eq 'Windows_NT')
$problems = 0
$importLine = "Import-Module '{0}' -Force" -f $psm1.Replace("'", "''")

# ---- output helpers --------------------------------------------------------------------------
function Write-Step([string] $Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string] $Text)   { Write-Host "  OK    $Text" -ForegroundColor Green }
function Write-Warn([string] $Text) { Write-Host "  WARN  $Text" -ForegroundColor Yellow }
function Write-Fail([string] $Text) { Write-Host "  FAIL  $Text" -ForegroundColor Red }
function Write-Info([string] $Text) { Write-Host "        $Text" }
function Stop-Setup([string] $Text) { Write-Fail $Text; exit 1 }

# Run a native command and capture its output. Never throws: Windows PowerShell 5.1 turns a
# native command's stderr into a terminating error under $ErrorActionPreference = 'Stop'.
function Invoke-Quiet {
    param([string] $File, [string[]] $Arguments = @())
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code  = -1
    try {
        $lines = @(& $File @Arguments 2>&1 | ForEach-Object { "$_" })
        $code  = $LASTEXITCODE
    } catch {
        $lines = @($_.Exception.Message)
    } finally {
        $ErrorActionPreference = $saved
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $lines }
}

# Run a native command with its output going straight to the console; returns the exit code.
function Invoke-Live {
    param([string] $File, [string[]] $Arguments = @())
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $File @Arguments | Out-Host } finally { $ErrorActionPreference = $saved }
    return $LASTEXITCODE
}

# True when the switch was given, or (interactive only) when the user answers yes.
function Test-Wanted([bool] $Switch, [string] $Question) {
    if ($Switch) { return $true }
    if ($NoPrompt -or [Console]::IsInputRedirected) { return $false }
    return ((Read-Host "$Question [y/N]") -match '^\s*y(es)?\s*$')
}

# What a NEW PowerShell window will enforce. The Process scope is skipped on purpose: this
# script may itself be running with -ExecutionPolicy Bypass.
function Get-FutureExecutionPolicy {
    foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
        $p = "$(Get-ExecutionPolicy -Scope $scope)"
        if ($p -ne 'Undefined') { return $p }
    }
    return 'Restricted'    # the Windows client default when nothing is set
}

# True when this script runs in a PowerShell process of its own ("powershell -File setup.ps1"):
# the wrappers it loads vanish when that process exits. False when it was started from a prompt
# as .\setup.ps1, which leaves them loaded in that window.
function Test-OwnProcess {
    foreach ($a in @([Environment]::GetCommandLineArgs() | Select-Object -Skip 1)) {
        if ("$a" -match '^[-/](.+)$') {
            $n = $Matches[1].ToLowerInvariant()
            if ('file'.StartsWith($n) -or 'command'.StartsWith($n) -or 'encodedcommand'.StartsWith($n)) { return $true }
        }
    }
    return $false
}

Write-Host "DevOps toolbox setup  ($root)" -ForegroundColor Cyan

# A security policy can put PowerShell in Constrained Language Mode. Devtools.psm1 and this script
# use .NET calls that mode blocks, so say so plainly instead of failing with an obscure error.
$languageMode = "$($ExecutionContext.SessionState.LanguageMode)"
if ($languageMode -ne 'FullLanguage') {
    Write-Fail "PowerShell is running in $languageMode mode here (a security policy on this machine)."
    Write-Info 'The wrappers and this script need FullLanguage mode, so they cannot work in this PowerShell.'
    Write-Info 'You can still use the toolbox without them:'
    Write-Info '    docker compose build'
    Write-Info '    docker compose run --rm dev      a shell with every tool in it'
    exit 1
}

# ---- 1. Docker -------------------------------------------------------------------------------
Write-Step '1/6  Docker'
foreach ($f in 'Dockerfile', 'docker-compose.yml', 'Devtools.psm1') {
    if (-not (Test-Path -LiteralPath (Join-Path $root $f))) {
        Stop-Setup "Cannot find $f next to setup.ps1. Run it from the project folder (the one that holds the Dockerfile)."
    }
}
$dockerCmd = Get-Command 'docker.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dockerCmd) {
    $dockerCmd = Get-Command 'docker' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $dockerCmd) {
    Stop-Setup 'docker was not found on PATH. Start Docker Desktop, open a NEW PowerShell window and run this again.'
}
$docker = $dockerCmd.Source

$r = Invoke-Quiet $docker @('version', '--format', '{{.Server.Os}}/{{.Server.Version}}')
$engine = @($r.Output | Where-Object { $_ -match '^\w+/\S+$' }) | Select-Object -First 1
if ($r.ExitCode -ne 0 -or -not $engine) {
    Stop-Setup 'Docker is installed but its engine is not running. Start Docker Desktop, wait for "Engine running", then run this again.'
}
$osType, $engineVersion = ("$engine" -split '/', 2)
if ($osType -ne 'linux') {
    Stop-Setup "Docker is set to $osType containers but the toolbox is a Linux image. Right-click the Docker Desktop tray icon and choose 'Switch to Linux containers'."
}
Write-Ok "Docker engine $engineVersion, Linux containers"
$haveCompose = ((Invoke-Quiet $docker @('compose', 'version')).ExitCode -eq 0)
if (-not $haveCompose) { Write-Warn "'docker compose' is not available, using 'docker build' (.env settings are ignored)." }

# ---- 2. Settings -----------------------------------------------------------------------------
Write-Step '2/6  Settings (.env)'
$envFile = Join-Path $root '.env'
$example = Join-Path $root '.env.example'
if (Test-Path -LiteralPath $envFile) {
    Write-Ok '.env already exists, keeping it'
} elseif (Test-Path -LiteralPath $example) {
    Copy-Item -LiteralPath $example -Destination $envFile
    Write-Ok 'created .env from .env.example (edit it to set a proxy or pin tool versions)'
} else {
    Write-Warn 'no .env.example found, using the built-in defaults'
}
$certs = @(Get-ChildItem -LiteralPath (Join-Path $root 'certs') -Filter '*.crt' -ErrorAction SilentlyContinue)
if ($certs.Count -gt 0) { Write-Ok "$($certs.Count) corporate CA certificate(s) in certs\ will be trusted during the build" }

# ---- 3. Build --------------------------------------------------------------------------------
Write-Step '3/6  Build the image (the first build takes a few minutes)'
if ($SkipBuild) {
    if ((Invoke-Quiet $docker @('image', 'inspect', $image)).ExitCode -ne 0) {
        Stop-Setup "-SkipBuild was given but the image $image does not exist yet. Run again without it."
    }
    Write-Ok "skipped (-SkipBuild), using the existing image $image"
} else {
    $buildArgs = if ($haveCompose) { @('compose', 'build') } else { @('build', '-t', $image, '.') }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location -LiteralPath $root
    try { $code = Invoke-Live $docker $buildArgs } finally { Pop-Location }
    if ($code -ne 0) {
        Write-Info 'Behind a corporate network the usual causes are:'
        Write-Info '- TLS inspection: put your company root CA (PEM, *.crt) in certs\ and run this again'
        Write-Info '- proxy: set HTTP_PROXY and HTTPS_PROXY in .env (and in Docker Desktop > Settings > Resources > Proxies)'
        Write-Info 'More in README.md under Troubleshooting.'
        Stop-Setup "The image build failed (exit code $code)."
    }
    Write-Ok ('image {0} built in {1:n0}s' -f $image, $clock.Elapsed.TotalSeconds)
}

# ---- 4. PowerShell profile -------------------------------------------------------------------
Write-Step '4/6  PowerShell profile'
if ($SkipProfile) {
    Write-Info 'skipped (-SkipProfile)'
} else {
    $target = ''
    try {
        $target = if ($ProfilePath) {
            $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProfilePath)
        } else {
            $PROFILE.CurrentUserAllHosts
        }
        # Read it the way PowerShell itself would, so non-ASCII text in an existing profile survives.
        $text = if (Test-Path -LiteralPath $target) { "$(Get-Content -LiteralPath $target -Raw)" } else { '' }
        # (?i): a line typed by hand as "import-module ... devtools.psm1" counts too. (?=\r?$): works for CRLF files.
        $rx   = '(?mi)^[ \t]*(?:Import-Module|ipmo)\b[^\r\n]*Devtools\.psm1[^\r\n]*(?=\r?$)'

        if (@($text -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains $importLine) {
            Write-Ok "already set up in $target"
        } elseif ($text -match $rx) {
            # An older line points at another folder (the project was moved or re-extracted).
            Copy-Item -LiteralPath $target -Destination "$target.bak" -Force
            $updated = [regex]::Replace($text, $rx, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $importLine })
            [IO.File]::WriteAllText($target, $updated, (New-Object System.Text.UTF8Encoding $true))
            Write-Ok "updated the existing Import-Module line in $target (backup: $target.bak)"
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Add-Content -LiteralPath $target -Encoding UTF8 -Value ("`r`n# DevOps toolbox: az, kubectl, terraform, helm, flux ... run in Docker`r`n" + $importLine)
            Write-Ok "added the Import-Module line to $target"
        }
    } catch {
        # Locked-down machines: a read-only or redirected Documents folder, Controlled Folder Access ...
        Write-Fail "Could not update your profile ($target): $($_.Exception.Message)"
        Write-Info 'Add this line to it yourself, or run it in each PowerShell window you want the tools in:'
        Write-Info "    $importLine"
        $problems++
    }
    if ($isWin -and ((Get-FutureExecutionPolicy) -in 'Restricted', 'AllSigned')) {
        Write-Warn "PowerShell's execution policy is $(Get-FutureExecutionPolicy), so NEW windows will not load the profile."
        Write-Info 'For your user only, no admin needed:  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned'
        Write-Info 'If Group Policy sets it that is refused; use "docker compose run --rm dev" for a shell instead.'
    }
}

# ---- 5. Load the wrappers --------------------------------------------------------------------
Write-Step '5/6  Load the wrappers'
if ($isWin) {
    try { Unblock-File -LiteralPath $psm1 } catch { }     # clears the "downloaded from the internet" mark
}
try {
    Import-Module -Name $psm1 -Force -Global
} catch {
    Stop-Setup "Could not load Devtools.psm1: $($_.Exception.Message)"
}
Write-Ok 'az, kubectl, terraform, flux, helm, kustomize, azd, gh, kubectx, kubens and dev now run in the container'

# ---- 6. Verify -------------------------------------------------------------------------------
Write-Step '6/6  Verify every tool (one container per tool)'
if ($SkipVerify) {
    Write-Info 'skipped (-SkipVerify)'
} else {
    $info = Get-DevToolsInfo
    Write-Info ('image {0}, credentials volume {1}' -f $info.Image, $info.Volume)
    $checks = @(
        @('az',        '--version'),
        @('kubectl',   'version', '--client'),
        @('terraform', 'version'),
        @('helm',      'version', '--short'),
        @('flux',      '--version'),
        @('kustomize', 'version'),
        @('azd',       'version'),
        @('gh',        '--version'),
        @('kubectx',   '-h'),
        @('kubens',    '-h')
    )
    foreach ($c in $checks) {
        $name = $c[0]
        $r    = Invoke-Quiet $name @($c | Select-Object -Skip 1)
        $first = @($r.Output | Where-Object { "$_".Trim().Length -gt 0 }) | Select-Object -First 1
        $text  = if ($name -in 'kubectx', 'kubens') { 'ready' } elseif ($first) { "$first".Trim() } else { '' }
        if ($text.Length -gt 60) { $text = $text.Substring(0, 60) }
        if ($r.ExitCode -eq 0) {
            Write-Ok ('{0,-10} {1}' -f $name, $text)
        } else {
            Write-Fail ('{0,-10} exit code {1}  {2}' -f $name, $r.ExitCode, $text)
            $problems++
        }
    }
}

# ---- Optional: Azure login and Docker Desktop Kubernetes -------------------------------------
$didLogin = $false
$didKube  = $false
if (Test-Wanted $Login 'Sign in to Azure now (device code, no browser needed in the container)?') {
    Write-Step 'Azure login'
    try { az login --use-device-code; $didLogin = ($LASTEXITCODE -eq 0) } catch { Write-Warn $_.Exception.Message }
    if (-not $didLogin) { Write-Warn 'the login did not finish; run  az login --use-device-code  when you are ready' }
}
if (Test-Wanted $ImportKube "Import Docker Desktop's Kubernetes context now (Kubernetes must be enabled in Docker Desktop)?") {
    Write-Step 'Docker Desktop Kubernetes'
    try { Import-DockerDesktopKube -ErrorAction Stop; $didKube = ($LASTEXITCODE -eq 0) } catch { Write-Warn $_.Exception.Message }
    if (-not $didKube) { Write-Warn 'not imported; fix the message above and run  Import-DockerDesktopKube' }
}

# ---- Summary ---------------------------------------------------------------------------------
Write-Host ''
if ($problems -gt 0) {
    Write-Fail "$problems problem(s) above need attention."
    exit 2
}
Write-Host 'All set.' -ForegroundColor Green
if ($SkipProfile) {
    Write-Info 'Your profile was not changed. In any PowerShell window, load the tools with:'
    Write-Info "    $importLine"
} elseif (Test-OwnProcess) {
    Write-Info 'Open a NEW PowerShell window: az, kubectl, terraform ... now run in the container there.'
    Write-Info 'To use them in the window you started this from, run:'
    Write-Info "    $importLine"
} else {
    Write-Info 'az, kubectl, terraform ... run in the container in this window now; new windows load them from your profile.'
}
Write-Host 'Next:'
if (-not $didLogin) { Write-Info 'az login --use-device-code      sign in to Azure (the token stays in the toolbox volume)' }
if (-not $didKube)  { Write-Info 'Import-DockerDesktopKube        use Docker Desktop''s Kubernetes (enable it in Docker Desktop first)' }
Write-Info 'kubectx, kubens, kubectl ...    work like the real tools'
Write-Info 'dev                             a full shell inside the toolbox'
exit 0
