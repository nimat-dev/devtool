#Requires -Version 5.1
<#
    Tests for Devtools.psm1, run against a fake `docker` that records the arguments it was
    given, so no Docker daemon is needed. Works in Windows PowerShell 5.1, in PowerShell 7 on
    Windows, and in PowerShell 7 on Linux and macOS:

        pwsh -NoProfile -File tests/Test-Devtools.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Devtools.ps1

    On Linux and macOS the fake is the shell script tests/fakebin/docker. On Windows it is a
    docker.exe compiled on the fly from tests/fakebin/docker.cs, because the module looks for
    a real docker.exe (see tests/FakeDocker.ps1).
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root     = Split-Path -Parent $PSScriptRoot
$module   = Join-Path $root 'Devtools.psm1'
$tmp      = [IO.Path]::GetTempPath()
$argsFile = Join-Path $tmp "devtools-docker-args-$PID.txt"
$workDir  = Join-Path $tmp "devtools-test-work-$PID"

. (Join-Path $PSScriptRoot 'FakeDocker.ps1')
$fakebin = Install-FakeDocker
$env:DOCKER_ARGS_FILE = $argsFile
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$env:DEVTOOLS_ALIASES = Join-Path $workDir 'no-such-aliases-file.ps1'     # the module must not read the real one

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

# The escaping rules themselves (private helper, called inside the module's scope). They only
# apply where PowerShell builds native command lines the legacy way (Windows PowerShell 5.1).
# The one version-dependent case: 5.1 leaves a trailing backslash unprotected, 7.x does not.
$mod       = Get-Module Devtools
$trailing  = if ($PSVersionTable.PSVersion.Major -lt 6) { 'C:\my dir\\' } else { 'C:\my dir\' }
$escapeMap = @(
    , @('{"a":1}',        '{\"a\":1}')
    , @('',               '""')
    , @('plain',          'plain')
    , @('a b',            'a b')
    , @('say "hi there"', 'say \"hi there\"')
    , @('C:\path\',       'C:\path\')
    , @('a\"b',           'a\\\"b')
    , @('C:\my dir\',     $trailing)
)
foreach ($pair in $escapeMap) {
    $got = & $mod { param($s) ConvertTo-LegacyNativeArg $s } $pair[0]
    Check "legacy quoting turns [$($pair[0])] into [$($pair[1])]" ($got -ceq $pair[1]) "got: [$got]"
}

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
Check 'dev starts the image''s default shell with the same mounts (no command is added)' (Same (Get-Recorded) $base)
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

# ---- shortcuts ----------------------------------------------------------------------------------
$mod   = Get-Module Devtools
$table = & $mod { $script:DevToolsAliases }
Check 'the table has the 35 shortcuts from the agreed list' ($table.Count -eq 35) "has $($table.Count)"
$exportedNow = @((Get-Command -Module Devtools).Name)
$notExported = @($table.Keys | Where-Object { $exportedNow -notcontains $_ })
Check 'every shortcut is exported' ($notExported.Count -eq 0) "missing: $($notExported -join ', ')"
foreach ($c in 'Get-DevToolsAlias', 'aksc', 'aksup', 'aksx') { Check "exports '$c'" ($exportedNow -contains $c) }
foreach ($c in 'Resolve-AksTarget', 'Get-DevToolsCompletion', 'Initialize-DevToolsReadLine', 'Restore-DevToolsReadLine', 'Write-DevToolsError') {
    Check "keeps the helper $c private" ($exportedNow -notcontains $c)
}

$aliasFailures = @()
foreach ($name in $table.Keys) {
    Remove-Item $argsFile -ErrorAction SilentlyContinue
    & $name 'MARK' | Out-Null
    $got  = Get-Tail (Get-Recorded)
    $want = @('devtools:latest') + @(([string] $table[$name]) -split ' ') + @('MARK')
    if (-not (Same $got $want)) { $aliasFailures += "$name -> $($got -join ' ')" }
}
Check 'every shortcut runs exactly what the table says, with what you type added at the end' ($aliasFailures.Count -eq 0) ($aliasFailures -join ' | ')

kgp -n kube-system | Out-Null
Check 'kgp -n kube-system keeps its flags' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectl', 'get', 'pods', '-n', 'kube-system'))
tfp -var 'name=hello world' | Out-Null
Check 'tfp -var with a space in the value stays one argument' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'terraform', 'plan', '-out=tfplan', '-var', 'name=hello world'))

# PowerShell removes a bare -- before a function sees its arguments; the wrappers put it back,
# because kubectl exec / run need it to tell its own flags from the command's.
function Check-Tail([string] $Name, [string[]] $Want) {
    $got = Get-Tail (Get-Recorded)
    Check $Name (Same $got $Want) "got: $($got -join ' | ')"
}
kex my-pod -- sh | Out-Null
Check-Tail 'kex pod -- sh passes the double dash on' @('devtools:latest', 'kubectl', 'exec', '-it', 'my-pod', '--', 'sh')
kubectl exec my-pod -- ls -la /tmp | Out-Null
Check-Tail 'kubectl exec pod -- ls -la: the flags after the double dash stay the command''s' @('devtools:latest', 'kubectl', 'exec', 'my-pod', '--', 'ls', '-la', '/tmp')
kubectl run dbg --image=busybox -it --rm -- sh -c "echo hi" | Out-Null
Check-Tail 'kubectl run ... -- sh -c "echo hi"' @('devtools:latest', 'kubectl', 'run', 'dbg', '--image=busybox', '-it', '--rm', '--', 'sh', '-c', 'echo hi')
kubectl exec my-pod '--' sh | Out-Null
Check-Tail 'a quoted double dash arrives once, not twice' @('devtools:latest', 'kubectl', 'exec', 'my-pod', '--', 'sh')
kubectl exec my-pod -- sh -- more | Out-Null
Check-Tail 'a second double dash is the command''s own' @('devtools:latest', 'kubectl', 'exec', 'my-pod', '--', 'sh', '--', 'more')
kubectl exec my-pod -- | Out-Null
Check-Tail 'a double dash at the very end is kept' @('devtools:latest', 'kubectl', 'exec', 'my-pod', '--')
kubectl -- get | Out-Null
Check-Tail 'a double dash right after the command is kept' @('devtools:latest', 'kubectl', '--', 'get')
kubectl get pods | Out-Null; kubectl exec other -- bash | Out-Null
Check-Tail 'the right command is read when a line holds several' @('devtools:latest', 'kubectl', 'exec', 'other', '--', 'bash')
$null = 1; kgp -n x -- y | Out-Null
Check-Tail 'a shortcut in the middle of a line' @('devtools:latest', 'kubectl', 'get', 'pods', '-n', 'x', '--', 'y')
& kubectl exec my-pod -- sh | Out-Null
Check-Tail 'called with &' @('devtools:latest', 'kubectl', 'exec', 'my-pod', '--', 'sh')
1 | ForEach-Object { kubectl exec in-block -- sh } | Out-Null
Check-Tail 'inside a script block' @('devtools:latest', 'kubectl', 'exec', 'in-block', '--', 'sh')
# A splat after the double dash is something the line alone cannot size up. PowerShell 7 expands it;
# whether another version reads it as text is not this module's business, so the only promise is
# that nothing is lost or mangled: the result is either the splat expanded or the text left as it came.
$more = @('x', 'y')
kubectl exec my-pod -- @more | Out-Null
$gotSplat = Get-Tail (Get-Recorded)
$wantSplat = @('devtools:latest', 'kubectl', 'exec', 'my-pod', 'x', 'y')
$wantSplatDash = @('devtools:latest', 'kubectl', 'exec', 'my-pod', '--', 'x', 'y')
Check 'when it cannot tell (a splat), nothing is lost or mangled' ((Same $gotSplat $wantSplat) -or (Same $gotSplat $wantSplatDash) -or ($gotSplat[-1] -eq '@more')) "got: $($gotSplat -join ' | ')"
terraform plan -- x | Out-Null
Check-Tail 'every wrapper does it, not only kubectl' @('devtools:latest', 'terraform', 'plan', '--', 'x')
dev kubectl exec my-pod -- sh | Out-Null
Check-Tail 'dev does it too' @('devtools:latest', 'kubectl', 'exec', 'my-pod', '--', 'sh')

# The same list exists as shell aliases for the shell inside the toolbox. The two must not drift apart.
$shFile = Join-Path (Join-Path (Join-Path $root 'scripts') 'shell') 'aliases.sh'
$shText = Get-Content -LiteralPath $shFile -Raw
$shList = [ordered]@{}
foreach ($l in ($shText -split "`r?`n")) {
    if ($l -match "^alias ([A-Za-z0-9]+)='([^']*)'\s*$") { $shList[$Matches[1]] = $Matches[2] }
}
$onlyPs = @($table.Keys | Where-Object { -not $shList.Contains($_) })
$onlySh = @($shList.Keys | Where-Object { -not $table.Contains($_) })
$differ = @($table.Keys | Where-Object { $shList.Contains($_) -and $shList[$_] -ne $table[$_] })
Check 'the PowerShell and shell shortcut lists have the same names' (($onlyPs.Count -eq 0) -and ($onlySh.Count -eq 0)) "only PowerShell: $($onlyPs -join ', '); only shell: $($onlySh -join ', ')"
Check 'and the same expansions' ($differ.Count -eq 0) "differ: $($differ -join ', ')"
foreach ($fn in 'aksc', 'aksup', 'aksx') { Check "the shell file defines $fn too" ($shText -match "(?m)^$fn\(\) \{") }

# Get-DevToolsAlias
$list = @(Get-DevToolsAlias)
Check 'Get-DevToolsAlias lists every shortcut and the three AKS helpers' ($list.Count -eq 38) "got $($list.Count)"
$groups = @($list | ForEach-Object { $_.Group } | Sort-Object -Unique)
$wantGroups = @('Azure', 'AKS', 'kubectl', 'Terraform') | Sort-Object
Check 'Get-DevToolsAlias groups them' (($groups -join ',') -eq ($wantGroups -join ',')) "got: $($groups -join ',')"
Check 'Get-DevToolsAlias filters by name' ((@(Get-DevToolsAlias 'tf*')).Count -eq 12)
Check 'Get-DevToolsAlias shows what a shortcut runs' ((@(Get-DevToolsAlias 'kgp'))[0].Runs -eq 'kubectl get pods')

# aksc / aksup / aksx
$env:AKS_RG = 'rg-test'; $env:AKS_NAME = 'aks-test'
aksc | Out-Null
Check 'aksc uses AKS_RG and AKS_NAME' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'az', 'aks', 'get-credentials', '-g', 'rg-test', '-n', 'aks-test', '--overwrite-existing'))
aksc rg-1 aks-1 --admin | Out-Null
Check 'aksc RG NAME overrides them and passes extra flags on' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'az', 'aks', 'get-credentials', '-g', 'rg-1', '-n', 'aks-1', '--overwrite-existing', '--admin'))
aksc --admin | Out-Null
Check 'aksc --admin keeps the environment names and adds the flag' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'az', 'aks', 'get-credentials', '-g', 'rg-test', '-n', 'aks-test', '--overwrite-existing', '--admin'))
aksup | Out-Null
Check 'aksup asks for the upgrades of that cluster' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'az', 'aks', 'get-upgrades', '-g', 'rg-test', '-n', 'aks-test', '-o', 'table'))
aksx kubectl get nodes | Out-Null
Check 'aksx runs the words you type inside the cluster as one command' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'az', 'aks', 'command', 'invoke', '-g', 'rg-test', '-n', 'aks-test', '--command', 'kubectl get nodes'))
aksx 'kubectl get pods -A' | Out-Null
Check 'aksx also takes the command as one quoted string' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'az', 'aks', 'command', 'invoke', '-g', 'rg-test', '-n', 'aks-test', '--command', 'kubectl get pods -A'))

dev | Out-Null
$baseNoImage = @($base | Select-Object -First ($base.Count - 1))
Check 'dev hands AKS_RG and AKS_NAME to the shell inside when they are set' `
    (Same (Get-Recorded) ($baseNoImage + @('-e', 'AKS_RG', '-e', 'AKS_NAME', 'devtools:latest'))) "got: $((Get-Recorded) -join ' | ')"

Remove-Item Env:\AKS_RG, Env:\AKS_NAME
foreach ($helper in 'aksc', 'aksup') {
    Remove-Item $argsFile -ErrorAction SilentlyContinue
    $msg = (& $helper 6>&1 | Out-String)
    Check "$helper without a cluster says what to set and never calls docker" `
        (($msg -match 'AKS_RG') -and ($msg -match 'AKS_NAME') -and -not (Test-Path $argsFile) -and ($LASTEXITCODE -eq 1)) "output: $msg"
}
Remove-Item $argsFile -ErrorAction SilentlyContinue
$msg = (aksx kubectl get nodes 6>&1 | Out-String)
Check 'aksx without a cluster says what to set and never calls docker' (($msg -match 'AKS_RG') -and -not (Test-Path $argsFile) -and ($LASTEXITCODE -eq 1)) "output: $msg"
$msg = (aksx 6>&1 | Out-String)
Check 'aksx without a command says how to use it' (($msg -match 'give the command') -and -not (Test-Path $argsFile))
dev | Out-Null
Check 'dev passes no -e when AKS_RG and AKS_NAME are not set' (Same (Get-Recorded) $base)
$info = Get-DevToolsInfo
Check 'Get-DevToolsInfo names the shortcuts file' ("$($info.AliasesFile)" -eq $env:DEVTOOLS_ALIASES) "got: $($info.AliasesFile)"

# ---- your own shortcuts file ------------------------------------------------------------------------
$personal = Join-Path $workDir 'my-aliases.ps1'
function Import-WithPersonal([string] $Content) {
    Set-Content -LiteralPath $personal -Value $Content -Encoding ASCII
    $env:DEVTOOLS_ALIASES = $personal
    # The module's own Write-Warning does not go through Import-Module's -WarningVariable, so the
    # warning stream is merged into the output and picked out of it.
    $merged = @(Import-Module $module -Force 3>&1)
    $script:warnings = @($merged | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { "$($_.Message)" })
}
Import-WithPersonal @'
$undefinedOnPurpose = $notDefinedAnywhere
function kgp { kubectl get pods -o wide @args }
function mykube { kubectl get nodes @args }
Set-Alias kk kubectl
$env:DEVTOOLS_TEST_MARK = 'loaded'
'@
Check 'a shortcuts file loads without a warning, even if it is not strict-mode clean' (@($script:warnings).Count -eq 0) "warnings: $($script:warnings -join ' | ')"
Check 'a variable the file sets is there' ($env:DEVTOOLS_TEST_MARK -eq 'loaded')
kgp -n x | Out-Null
Check 'your kgp replaces the default one' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectl', 'get', 'pods', '-o', 'wide', '-n', 'x'))
mykube | Out-Null
Check 'a new function in your file works from the prompt' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectl', 'get', 'nodes'))
kk get ns | Out-Null
Check 'a new alias in your file works from the prompt' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectl', 'get', 'ns'))
kgn | Out-Null
Check 'the other shortcuts are untouched' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectl', 'get', 'nodes'))
$list = @(Get-DevToolsAlias)
$yours = @($list | Where-Object { $_.Group -eq 'Yours' } | ForEach-Object { $_.Alias } | Sort-Object)
Check 'Get-DevToolsAlias shows what is yours (new names and replaced ones)' (($yours -join ',') -eq 'kgp,kk,mykube') "got: $($yours -join ',')"
Remove-Item Env:\DEVTOOLS_TEST_MARK

Import-WithPersonal 'function oops {'
Check 'a syntax error in the file is a warning that names the file' ((@($script:warnings).Count -ge 1) -and ("$($script:warnings[0])" -match 'my-aliases'))
k get ns | Out-Null
Check 'and the toolbox still works' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'kubectl', 'get', 'ns'))

Import-WithPersonal "throw 'boom'"
Check 'an error thrown by the file is a warning with its message' ((@($script:warnings).Count -ge 1) -and ("$($script:warnings[0])" -match 'boom'))

Import-WithPersonal 'Remove-Item Function:\kgn'
Check 'a file that deletes a shortcut does not break the import' ((@($script:warnings).Count -eq 0) -and (-not (Get-Command kgn -ErrorAction SilentlyContinue)))

Remove-Item -LiteralPath $personal
$env:DEVTOOLS_ALIASES = Join-Path $workDir 'no-such-file.ps1'
Import-Module $module -Force
Check 'without the file everything is back to the defaults' ((Get-Command kgn -ErrorAction SilentlyContinue) -and (@(Get-DevToolsAlias | Where-Object { $_.Group -eq 'Yours' }).Count -eq 0))

# ---- Tab completion -----------------------------------------------------------------------------------
# The fake docker prints a canned answer for `docker run`, the way devtools-complete would.
$runFile = Join-Path $workDir 'complete-answer.txt'
$env:DOCKER_RUN_FILE = $runFile
[IO.File]::WriteAllText($runFile, "get`tDisplay one or many resources`ndescribe`tShow details`n--namespace`tNamespace scope`nget`tduplicate`nmy value`n")

function Get-Completions([string] $Text, [int] $Cursor = -1) {
    if ($Cursor -lt 0) { $Cursor = $Text.Length }
    Remove-Item $argsFile -ErrorAction SilentlyContinue
    $r = [System.Management.Automation.CommandCompletion]::CompleteInput($Text, $Cursor, $null)
    return @($r.CompletionMatches)
}

$matches1 = Get-Completions 'kubectl '
$texts = @($matches1 | ForEach-Object { $_.CompletionText })
Check 'Tab on kubectl offers what the container answered' (($texts -contains 'get') -and ($texts -contains 'describe') -and ($texts -contains '--namespace')) "got: $($texts -join ', ')"
Check 'a candidate with a space is quoted' ($texts -contains "'my value'")
Check 'a repeated candidate is offered once' (@($texts | Where-Object { $_ -ceq 'get' }).Count -eq 1)
$flag = $matches1 | Where-Object { $_.CompletionText -eq '--namespace' } | Select-Object -First 1
$word = $matches1 | Where-Object { $_.CompletionText -eq 'get' } | Select-Object -First 1
Check 'a flag is a parameter name, a word is a parameter value' (("$($flag.ResultType)" -eq 'ParameterName') -and ("$($word.ResultType)" -eq 'ParameterValue'))
Check 'the description after the tab becomes the tooltip' ("$($word.ToolTip)" -eq 'Display one or many resources')
Check 'the docker call: volume, image, devtools-complete, tool, line and position' `
    (Same (Get-Recorded) @('run', '--rm', '-v', 'devtools-home:/root', 'devtools:latest', 'devtools-complete', 'kubectl', 'kubectl ', '8')) "got: $((Get-Recorded) -join ' | ')"

$null = Get-Completions 'kubectl get po'
Check 'the line and position follow the cursor' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'devtools-complete', 'kubectl', 'kubectl get po', '14')) "got: $((Get-Recorded) -join ' | ')"
$null = Get-Completions 'kubectl get pods -n kube' 11
Check 'only what is before the cursor is sent' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'devtools-complete', 'kubectl', 'kubectl get', '11')) "got: $((Get-Recorded) -join ' | ')"
$null = Get-Completions 'echo x; terraform ap'
Check 'a command after a semicolon is completed on its own' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'devtools-complete', 'terraform', 'terraform ap', '12')) "got: $((Get-Recorded) -join ' | ')"

$null = Get-Completions 'kgp -n '
Check 'a shortcut completes as the command it stands for' `
    (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'devtools-complete', 'kubectl', 'kubectl get pods -n ', '20')) "got: $((Get-Recorded) -join ' | ')"
$null = Get-Completions 'tf wor'
Check 'tf completes as terraform' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'devtools-complete', 'terraform', 'terraform wor', '13')) "got: $((Get-Recorded) -join ' | ')"
$null = Get-Completions 'k '
Check 'k completes as kubectl' (Same (Get-Tail (Get-Recorded)) @('devtools:latest', 'devtools-complete', 'kubectl', 'kubectl ', '8')) "got: $((Get-Recorded) -join ' | ')"

foreach ($tool in 'az', 'terraform', 'helm', 'flux', 'kustomize', 'azd', 'gh') {
    $null = Get-Completions "$tool "
    Check "$tool is completed through the container" ((Get-Recorded) -contains $tool) "got: $((Get-Recorded) -join ' | ')"
}
foreach ($name in 'kx', 'kn', 'kubectx', 'kubens') {
    $null = Get-Completions "$name "
    Check "$name is not sent to the container (it has nothing to complete)" (-not (Test-Path $argsFile))
}
$null = Get-Completions 'kgp'
Check 'completing the command name itself does not call the container' (-not (Test-Path $argsFile))

$global:LASTEXITCODE = 5
$null = Get-Completions 'kubectl '
Check 'a Tab press leaves $LASTEXITCODE alone' ($global:LASTEXITCODE -eq 5)
$env:DOCKER_FORCE_EXIT = '1'
$after = Get-Completions 'kubectl '
Check 'when the container fails there are no suggestions from it' (@($after | Where-Object { $_.CompletionText -eq 'get' }).Count -eq 0)
Check 'and $LASTEXITCODE is still left alone' ($global:LASTEXITCODE -eq 5)
Remove-Item Env:\DOCKER_FORCE_EXIT
$global:LASTEXITCODE = 0

# After the module is removed its completers go quiet (PowerShell cannot unregister them).
$mod = Get-Module Devtools
$completerSb = & $mod { $script:DevToolsCompleter }
$ast = [System.Management.Automation.Language.Parser]::ParseInput('kubectl get ', [ref] $null, [ref] $null).EndBlock.Statements[0].PipelineElements[0]
$live = @(& $completerSb '' $ast 12)
Check 'the completer answers while the module is loaded' ($live.Count -ge 3)
Remove-Module Devtools
Remove-Item $argsFile -ErrorAction SilentlyContinue
$quiet = @(& $completerSb '' $ast 12)
Check 'after Remove-Module the completer answers nothing and does not call docker' (($quiet.Count -eq 0) -and -not (Test-Path $argsFile))
Import-Module $module -Force
Remove-Item Env:\DOCKER_RUN_FILE

# ---- history suggestions and the Tab menu (PSReadLine) ----------------------------------------------------
# Stand-ins for PSReadLine, which is not loaded in a script run. Functions win over cmdlets, so the
# module sees these even where the real PSReadLine is loaded.
$global:RlCalls = [System.Collections.Generic.List[string]]::new()
$global:RlPrediction = 'None'
$global:RlTabFunction = 'TabCompleteNext'
$global:RlThrow = $false
function global:Set-PSReadLineOption { param([string] $PredictionSource, [string] $PredictionViewStyle) $global:RlCalls.Add("option PredictionSource=$PredictionSource") }
function global:Get-PSReadLineOption { [pscustomobject]@{ PredictionSource = $global:RlPrediction } }
function global:Get-PSReadLineKeyHandler {
    param([switch] $Bound)
    [pscustomobject]@{ Key = 'Tab'; Function = $global:RlTabFunction }
    [pscustomobject]@{ Key = 'UpArrow'; Function = 'PreviousHistory' }
    [pscustomobject]@{ Key = 'DownArrow'; Function = 'NextHistory' }
    [pscustomobject]@{ Key = 'Shift+Tab'; Function = 'TabCompletePrevious' }
}
function global:Set-PSReadLineKeyHandler {
    param([string] $Key, [string] $Function)
    if ($global:RlThrow) { throw 'no console' }
    $global:RlCalls.Add("key $Key=$Function")
}
function Invoke-Rl([string] $Action) {
    $global:RlCalls.Clear()
    & (Get-Module Devtools) ([scriptblock]::Create($Action))
    return ,@($global:RlCalls)     # the comma keeps an empty list from turning into $null
}

Import-Module $module -Force
$mod = Get-Module Devtools
$interactiveHere = & $mod { Test-InteractiveConsole }
# (A person who dot-sources this file in a console window is an interactive session, so there the
# import is allowed to touch the keys; the pty test covers that case.)
Check 'importing the module outside an interactive console leaves PSReadLine alone' ($interactiveHere -or $global:RlCalls.Count -eq 0) "calls: $($global:RlCalls -join ' | ')"

function Test-Interactive([string] $HostName, [string[]] $CommandLine, [bool] $Redirected = $false) {
    & $mod { param($h, $c, $r) Test-InteractiveConsole -HostName $h -CommandLine $c -Redirected $r } $HostName $CommandLine $Redirected
}
Check 'a plain console window counts as interactive'              (Test-Interactive 'ConsoleHost' @())
Check 'so does one started with -NoLogo'                          (Test-Interactive 'ConsoleHost' @('-NoLogo'))
Check 'and one started with -NoExit -Command (an editor terminal)' (Test-Interactive 'ConsoleHost' @('-NoExit', '-Command', 'x'))
Check 'the ISE does not'                                          (-not (Test-Interactive 'Windows PowerShell ISE Host' @()))
Check 'a redirected session does not'                             (-not (Test-Interactive 'ConsoleHost' @() $true))
Check '-File does not (a script run)'                             (-not (Test-Interactive 'ConsoleHost' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'setup.ps1')))
Check '-Command and its short forms do not'                       ((-not (Test-Interactive 'ConsoleHost' @('-Command', 'x'))) -and (-not (Test-Interactive 'ConsoleHost' @('-c', 'x'))) -and (-not (Test-Interactive 'ConsoleHost' @('-ec', 'eA='))))
Check '-NonInteractive does not'                                  (-not (Test-Interactive 'ConsoleHost' @('-NonInteractive')))

$calls = Invoke-Rl 'Initialize-DevToolsReadLine'
Check 'new PSReadLine: turns the history suggestions on and Tab into a menu' (($calls -join '|') -eq 'option PredictionSource=History|key Tab=MenuComplete') "got: $($calls -join ' | ')"
Check 'new PSReadLine: the Up and Down arrows keep their default meaning' (-not ($calls -match 'UpArrow|DownArrow'))
$calls = Invoke-Rl 'Restore-DevToolsReadLine'
Check 'and Remove-Module hands both back' (($calls -join '|') -eq 'option PredictionSource=None|key Tab=TabCompleteNext') "got: $($calls -join ' | ')"
$calls = Invoke-Rl 'Restore-DevToolsReadLine'
Check 'handing back twice does nothing the second time' ($calls.Count -eq 0)

$global:RlPrediction = 'HistoryAndPlugin'
$calls = Invoke-Rl 'Initialize-DevToolsReadLine'
Check 'a suggestion source you already have is left alone' (($calls -join '|') -eq 'key Tab=MenuComplete') "got: $($calls -join ' | ')"
$null = Invoke-Rl 'Restore-DevToolsReadLine'

$global:RlPrediction = 'None'; $global:RlTabFunction = 'MenuComplete'
$calls = Invoke-Rl 'Initialize-DevToolsReadLine'
Check 'a Tab that is already a menu is left alone' (($calls -join '|') -eq 'option PredictionSource=History') "got: $($calls -join ' | ')"
$null = Invoke-Rl 'Restore-DevToolsReadLine'
$global:RlTabFunction = 'SomethingOfMine'
$calls = Invoke-Rl 'Initialize-DevToolsReadLine'
Check 'a Tab you bound yourself is left alone' (-not ($calls -match 'key Tab'))
$null = Invoke-Rl 'Restore-DevToolsReadLine'
$global:RlTabFunction = 'Complete'
$calls = Invoke-Rl 'Initialize-DevToolsReadLine'
Check 'the Linux and macOS default Tab (Complete) becomes a menu too' ($calls -contains 'key Tab=MenuComplete')
$null = Invoke-Rl 'Restore-DevToolsReadLine'
$global:RlTabFunction = 'TabCompleteNext'

# An old PSReadLine (the 2.0 in Windows PowerShell 5.1) has no PredictionSource.
function global:Set-PSReadLineOption { param([string] $EditMode) $global:RlCalls.Add("option EditMode=$EditMode") }
function global:Get-PSReadLineOption { [pscustomobject]@{ EditMode = 'Windows' } }
$calls = Invoke-Rl 'Initialize-DevToolsReadLine'
Check 'old PSReadLine: no suggestion setting is touched' (-not ($calls -match 'option'))
Check 'old PSReadLine: Up and Down search the history for what you typed' (($calls -contains 'key UpArrow=HistorySearchBackward') -and ($calls -contains 'key DownArrow=HistorySearchForward'))
Check 'old PSReadLine: Tab still becomes a menu' ($calls -contains 'key Tab=MenuComplete')
$calls = Invoke-Rl 'Restore-DevToolsReadLine'
Check 'old PSReadLine: all three are handed back' (($calls -contains 'key UpArrow=PreviousHistory') -and ($calls -contains 'key DownArrow=NextHistory') -and ($calls -contains 'key Tab=TabCompleteNext'))

$env:DEVTOOLS_NO_READLINE = '1'
$calls = Invoke-Rl 'Initialize-DevToolsReadLine'
Check 'DEVTOOLS_NO_READLINE=1 leaves PSReadLine alone' ($calls.Count -eq 0)
Remove-Item Env:\DEVTOOLS_NO_READLINE

$global:RlThrow = $true
$threw = $false
try { $null = Invoke-Rl 'Initialize-DevToolsReadLine' } catch { $threw = $true }
Check 'a host where PSReadLine cannot be changed is not an error' (-not $threw)
$global:RlThrow = $false

Remove-Item Function:\Set-PSReadLineOption, Function:\Get-PSReadLineOption, Function:\Get-PSReadLineKeyHandler, Function:\Set-PSReadLineKeyHandler
Remove-Variable RlCalls, RlPrediction, RlTabFunction, RlThrow -Scope Global
Import-Module $module -Force

# ---- done ---------------------------------------------------------------------------------------
Set-Location $root
Remove-Item $argsFile, $workDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-FakeDocker $fakebin
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
