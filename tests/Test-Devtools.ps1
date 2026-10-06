#Requires -Version 7.0
<#
    Tests for Devtools.psm1, run against a fake `docker` (tests/fakebin/docker) that records
    the arguments it was given, so no Docker daemon is needed. Linux and macOS only, because
    the fake docker is a shell script (CI runs this on Ubuntu; on Windows use WSL).

        pwsh -NoProfile -File tests/Test-Devtools.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root     = Split-Path -Parent $PSScriptRoot
$module   = Join-Path $root 'Devtools.psm1'
$fakebin  = Join-Path $PSScriptRoot 'fakebin'
$tmp      = [IO.Path]::GetTempPath()
$argsFile = Join-Path $tmp "devtools-docker-args-$PID.txt"
$workDir  = Join-Path $tmp "devtools-test-work-$PID"

& chmod +x (Join-Path $fakebin 'docker')
$env:PATH = $fakebin + [IO.Path]::PathSeparator + $env:PATH   # fake docker wins over a real one
$env:DOCKER_ARGS_FILE = $argsFile
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$script:failures = 0
function Check([string] $Name, [bool] $Condition, [string] $Detail = '') {
    if ($Condition) {
        Write-Host "PASS  $Name"
    } else {
        Write-Host "FAIL  $Name"
        if ($Detail) { Write-Host "      $Detail" }
        $script:failures++
    }
}

function Get-Recorded {
    if (Test-Path $argsFile) { [string[]] @(Get-Content $argsFile) } else { [string[]] @() }
}

# Strict, order-sensitive comparison (Compare-Object ignores order).
function Same($Actual, $Expected) {
    $a = @($Actual); $b = @($Expected)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -cne $b[$i]) { return $false } }
    return $true
}

# Everything from the image name on: tool name plus its arguments.
function Get-Tail([string[]] $Rec) {
    $i = [array]::IndexOf($Rec, 'devtools:latest')
    if ($i -lt 0) { return [string[]] @() }
    return [string[]] $Rec[$i..($Rec.Count - 1)]
}

# ---- module loads cleanly ---------------------------------------------------------------
$tokens = $null; $parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($module, [ref] $tokens, [ref] $parseErrors)
Check 'module parses with zero syntax errors' (@($parseErrors).Count -eq 0)

$warn = $null
Import-Module $module -Force -WarningVariable warn -WarningAction SilentlyContinue
Check 'import produces no warnings' (@($warn).Count -eq 0)

$exported = @((Get-Command -Module Devtools).Name)
foreach ($c in 'az', 'kubectl', 'terraform', 'flux', 'helm', 'kustomize', 'azd', 'gh', 'kubectx', 'kubens',
               'dev', 'Import-DockerDesktopKube', 'Get-DevToolsInfo') {
    Check "exports '$c'" ($exported -contains $c)
}
Check 'keeps the helper Invoke-DevTool private' (-not ($exported -contains 'Invoke-DevTool'))

# ---- the docker run line ----------------------------------------------------------------
Set-Location $workDir
$cwd  = (Get-Location).ProviderPath
$tty  = if (-not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) { @('-t') } else { @() }
$base = @('run', '--rm', '-i') + $tty + @('-v', 'devtools-home:/root', '-v', "${cwd}:/work", '-w', '/work', 'devtools:latest')

az account show --output table | Out-Null
$rec = Get-Recorded
Check 'az -> exact docker run line (mounts, workdir, image, args)' `
    (Same $rec ($base + @('az', 'account', 'show', '--output', 'table'))) "got: $($rec -join ' | ')"
Check 'creds volume devtools-home:/root is mounted' ($rec -contains 'devtools-home:/root')
if ([Console]::IsOutputRedirected) {
    Check 'no TTY is allocated when output is redirected' (-not ($rec -contains '-t'))
} else {
    Write-Host 'SKIP  no-TTY check (output is a terminal here; CI redirects it)'
}

kubectl get pods -n kube-system --output wide | Out-Null
Check 'kubectl flags and namespace pass through' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectl', 'get', 'pods', '-n', 'kube-system', '--output', 'wide'))

# Regression: -out and -o are prefixes of PowerShell's -OutVariable/-OutBuffer and used to be swallowed.
terraform plan -out tf.plan | Out-Null
Check 'terraform plan -out tf.plan passes through verbatim' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'terraform', 'plan', '-out', 'tf.plan'))
kubectl get svc -o yaml | Out-Null
Check 'kubectl get svc -o yaml passes through verbatim' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectl', 'get', 'svc', '-o', 'yaml'))

az aks get-credentials --name aks-prod -g rg-prod --overwrite-existing | Out-Null
Check 'az aks get-credentials passes its full flag set' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'az', 'aks', 'get-credentials', '--name', 'aks-prod', '-g', 'rg-prod', '--overwrite-existing'))

gh repo create demo --private --source . --remote origin --push | Out-Null
Check 'gh repo create passes its full flag set' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'gh', 'repo', 'create', 'demo', '--private', '--source', '.', '--remote', 'origin', '--push'))

kubectx my-cluster | Out-Null
Check 'kubectx passes its argument' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectx', 'my-cluster'))
kubens kube-system | Out-Null
Check 'kubens passes its argument' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubens', 'kube-system'))

$env:DOCKER_FORCE_EXIT = '7'
helm status release | Out-Null
Check "the tool's exit code reaches `$LASTEXITCODE (and does not kill the session)" ($LASTEXITCODE -eq 7)
Remove-Item Env:\DOCKER_FORCE_EXIT

dev | Out-Null
Check 'dev opens bash in the toolbox with the same mounts' (Same (Get-Recorded) ($base + @('bash')))
dev bash -c 'echo hi' | Out-Null
Check 'dev passes extra arguments through' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'bash', '-c', 'echo hi'))

$info = Get-DevToolsInfo
Check 'Get-DevToolsInfo reports image, volume and the full tool list' `
    (($info.Image -eq 'devtools:latest') -and ($info.Volume -eq 'devtools-home') -and ($info.Tools -match 'kubectx') -and ($info.Tools -match 'gh'))

# Env overrides are read at import time, so use a fresh PowerShell process.
$env:DEVTOOLS_IMAGE  = 'myregistry.azurecr.io/devtools:v2'
$env:DEVTOOLS_VOLUME = 'team-creds'
& (Join-Path $PSHOME 'pwsh') -NoProfile -Command "Import-Module '$module' -Force; az version | Out-Null" | Out-Null
Remove-Item Env:\DEVTOOLS_IMAGE, Env:\DEVTOOLS_VOLUME
$rec = Get-Recorded
Check 'DEVTOOLS_IMAGE and DEVTOOLS_VOLUME overrides are honoured' `
    (($rec -contains 'myregistry.azurecr.io/devtools:v2') -and ($rec -contains 'team-creds:/root')) "got: $($rec -join ' | ')"

# ---- Import-DockerDesktopKube ---------------------------------------------------------------
$kubeDir = Join-Path $workDir 'hostkube'
New-Item -ItemType Directory -Force -Path $kubeDir | Out-Null
$cfg = Join-Path $kubeDir 'config'
Set-Content -Path $cfg -Value 'apiVersion: v1'

Remove-Item $argsFile -ErrorAction SilentlyContinue
Import-DockerDesktopKube -KubeConfig $cfg | Out-Null
$rec = Get-Recorded
$expected = @('run', '--rm', '-i', '-v', 'devtools-home:/root', '-v', "${cfg}:/hostkube/config:ro",
              'devtools:latest', 'import-docker-desktop-kube', 'docker-desktop')
Check 'Import-DockerDesktopKube: volume + one read-only file mount + helper + default context' `
    (Same $rec $expected) "got: $($rec -join ' | ')"
Check 'Import-DockerDesktopKube mounts only that single kubeconfig file' `
    (@($rec | Where-Object { $_ -like '*:/hostkube*' }).Count -eq 1)
Check 'Import-DockerDesktopKube allocates no TTY' (-not ($rec -contains '-t'))

Import-DockerDesktopKube -Context desktop-linux -KubeConfig $cfg | Out-Null
$rec = Get-Recorded
Check 'Import-DockerDesktopKube -Context is passed through' `
    (($rec[-1] -eq 'desktop-linux') -and ($rec[-2] -eq 'import-docker-desktop-kube'))

Remove-Item $argsFile -ErrorAction SilentlyContinue
$errs = $null
Import-DockerDesktopKube -KubeConfig (Join-Path $workDir 'nope/config') -ErrorAction SilentlyContinue -ErrorVariable errs
Check 'missing kubeconfig -> error that points at Docker Desktop settings' `
    ((@($errs).Count -ge 1) -and ("$($errs[0])" -match 'Settings > Kubernetes'))
Check 'missing kubeconfig -> docker is never invoked' (-not (Test-Path $argsFile))

$env:DOCKER_FORCE_EXIT = '127'
$w = $null
Import-DockerDesktopKube -KubeConfig $cfg -WarningVariable w -WarningAction SilentlyContinue | Out-Null
Check 'exit 127 (image without the helper) -> tells you to rebuild' `
    ((@($w).Count -ge 1) -and ("$($w[0])" -match 'docker compose build'))
$env:DOCKER_FORCE_EXIT = '3'
Import-DockerDesktopKube -KubeConfig $cfg | Out-Null
Check "the helper's exit code reaches `$LASTEXITCODE" ($LASTEXITCODE -eq 3)
Remove-Item Env:\DOCKER_FORCE_EXIT

# ---- done ---------------------------------------------------------------------------------------
Set-Location $root
Remove-Item $argsFile, $workDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:failures -eq 0) {
    Write-Host "ALL TESTS PASSED ($($exported.Count) commands exported)"
} else {
    Write-Host "$($script:failures) TEST(S) FAILED"
    exit 1
}
