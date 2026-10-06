#Requires -Version 5.1
<#
    Tests for Devtools.psm1, run against a fake `docker` that records the arguments it was
    given, so no Docker daemon is needed. Works in Windows PowerShell 5.1, in PowerShell 7 on
    Windows, and in PowerShell 7 on Linux and macOS:

        pwsh -NoProfile -File tests/Test-Devtools.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Devtools.ps1

    On Linux and macOS the fake is the shell script tests/fakebin/docker. On Windows it is a
    docker.exe compiled on the fly from tests/fakebin/docker.cs, because the module looks for
    a real docker.exe.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root     = Split-Path -Parent $PSScriptRoot
$module   = Join-Path $root 'Devtools.psm1'
$tmp      = [IO.Path]::GetTempPath()
$isWin    = ($env:OS -eq 'Windows_NT')
$argsFile = Join-Path $tmp "devtools-docker-args-$PID.txt"
$workDir  = Join-Path $tmp "devtools-test-work-$PID"

if ($isWin) {
    $fakebin = Join-Path $tmp "devtools-fakebin-$PID"
    New-Item -ItemType Directory -Force -Path $fakebin | Out-Null
    $cs  = Join-Path (Join-Path $PSScriptRoot 'fakebin') 'docker.cs'
    $exe = Join-Path $fakebin 'docker.exe'
    # Add-Type -OutputAssembly only exists in Windows PowerShell, so compile with that
    # whichever PowerShell is running the tests.
    $compile = "Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath '$cs') -OutputAssembly '$exe' -OutputType ConsoleApplication"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $compile
    if (-not (Test-Path -LiteralPath $exe)) { throw "could not build the fake docker.exe from $cs" }
} else {
    $fakebin = Join-Path $PSScriptRoot 'fakebin'
    & chmod +x (Join-Path $fakebin 'docker')
}
$env:PATH = $fakebin + [IO.Path]::PathSeparator + $env:PATH   # fake docker wins over a real one
$env:DOCKER_ARGS_FILE = $argsFile
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

Write-Host ("PowerShell {0} ({1}) on {2}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [Environment]::OSVersion.VersionString)

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

# ---- arguments must arrive exactly as typed ------------------------------------------------
# Windows PowerShell 5.1 builds a native command line without escaping embedded double
# quotes, so JSON and quoted values can reach the program mangled. Every case here is
# something people really type (kubectl patch -p, terraform -var, az --tags ...).
$json = '{"spec":{"replicas":3}}'
kubectl patch deployment web -p $json | Out-Null
Check 'JSON with double quotes reaches the container intact' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectl', 'patch', 'deployment', 'web', '-p', $json)) "got: $((Get-Tail (Get-Recorded)) -join ' | ')"

terraform apply -var 'name=hello world' | Out-Null
Check 'an argument that contains a space stays one argument' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'terraform', 'apply', '-var', 'name=hello world')) "got: $((Get-Tail (Get-Recorded)) -join ' | ')"

az group create --name rg --tags 'owner=John "JD" Smith' | Out-Null
Check 'embedded double quotes plus a space survive' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'az', 'group', 'create', '--name', 'rg', '--tags', 'owner=John "JD" Smith')) "got: $((Get-Tail (Get-Recorded)) -join ' | ')"

terraform '-chdir=C:\my dir\' plan | Out-Null
Check 'a Windows path with a space and a trailing backslash survives' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'terraform', '-chdir=C:\my dir\', 'plan')) "got: $((Get-Tail (Get-Recorded)) -join ' | ')"

kubectl config set-context ctx --namespace '' | Out-Null
Check 'an empty-string argument is preserved' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectl', 'config', 'set-context', 'ctx', '--namespace', '')) "got: $((Get-Tail (Get-Recorded)) -join ' | ')"

$spaceDir = Join-Path $workDir 'dir with space'
New-Item -ItemType Directory -Force -Path $spaceDir | Out-Null
Set-Location $spaceDir
az version | Out-Null
$spaceCwd = (Get-Location).ProviderPath
Check 'a working directory that contains spaces is mounted as one argument' `
    ((Get-Recorded) -contains "${spaceCwd}:/work") "got: $((Get-Recorded) -join ' | ')"
Set-Location $workDir

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
$self = (Get-Process -Id $PID).Path     # the PowerShell that is running these tests
& $self -NoProfile -Command "Import-Module '$module' -Force; az version | Out-Null" | Out-Null
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
if ($isWin) { Remove-Item $fakebin -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''
# Always finish with an explicit exit code. The checks above leave $LASTEXITCODE at 3 (they
# test exit-code propagation), and CI runners end a pwsh step with `exit $LASTEXITCODE`,
# which would turn a fully green run into a failed step.
if ($script:failures -eq 0) {
    Write-Host "ALL TESTS PASSED ($($exported.Count) commands exported)"
    exit 0
}
Write-Host "$($script:failures) TEST(S) FAILED"
exit 1
