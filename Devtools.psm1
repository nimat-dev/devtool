<#
    Devtools.psm1 - run the toolbox CLIs transparently from PowerShell.

    After importing, `az`, `kubectl`, `terraform`, `flux`, `helm`, `kustomize`
    and `azd` each run inside the devtools container against a persistent creds
    volume, with your current directory mounted at /work. Because these are
    PowerShell functions, they shadow any same-named host executable - so on a
    machine with no local az/kubectl/etc., they just become the default.

    Install (one line in your $PROFILE):
        Import-Module 'C:\path\to\devtools-toolbox\Devtools.psm1' -Force

    To find / create your profile:
        if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force }
        notepad $PROFILE      # add the Import-Module line above, save, reopen PS

    First run (device-code login - there's no browser inside the container):
        az login --use-device-code

    Typing comfort (all of it loads with the module):
        Shortcuts       k, kgp, tfp, azl, aksx ...   Get-DevToolsAlias lists them; your own go in
                        ~/.devtools-aliases.ps1 (read last, so it wins)
        Tab completion  az, kubectl, terraform, helm, flux ... the real tool in the container answers
        History         grey suggestions as you type (PSReadLine 2.1 or newer), Tab opens a menu

    Optional overrides (set before Import-Module, e.g. in $PROFILE):
        $env:DEVTOOLS_IMAGE      = 'devtools:latest'  # image tag to run
        $env:DEVTOOLS_VOLUME     = 'devtools-home'    # named creds volume
        $env:DEVTOOLS_ALIASES    = 'C:\path\my.ps1'   # your shortcuts file (default ~/.devtools-aliases.ps1)
        $env:DEVTOOLS_NO_READLINE = '1'               # leave the PSReadLine settings alone
        $env:AKS_RG, $env:AKS_NAME                    # your AKS cluster, for aksc / aksup / aksx
#>

Set-StrictMode -Version Latest

$script:DevToolsImage  = if ($env:DEVTOOLS_IMAGE)  { $env:DEVTOOLS_IMAGE }  else { 'devtools:latest' }
$script:DevToolsVolume = if ($env:DEVTOOLS_VOLUME) { $env:DEVTOOLS_VOLUME } else { 'devtools-home' }
$script:DevToolsAliasesFile = if ($env:DEVTOOLS_ALIASES) { $env:DEVTOOLS_ALIASES } else { Join-Path $HOME '.devtools-aliases.ps1' }
$script:DevToolsActive = $true     # false once the module is removed: the completers then go quiet

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

    # $LASTEXITCODE is set automatically and propagates to the caller - do NOT
    # call `exit`, that would kill the user's interactive session.
    & $docker @DockerArgs
}

# PowerShell treats a bare -- as its own end-of-parameters marker and removes it before a function
# sees its arguments, but kubectl needs it ("kubectl exec pod -- ls -la", "kubectl run x -- sh").
# This looks at what was typed and puts the -- back where it was. A quoted '--' arrives intact and
# is left alone. Anything unexpected (no line to read, a splat, a different command) means the
# arguments are returned exactly as received.
function Restore-DashDash {
    param($Invocation, $Arguments)

    $given = @($Arguments)
    try {
        $line  = [string] $Invocation.Line
        $start = [Math]::Max(0, [int] $Invocation.OffsetInLine - 1)
        if ($start -ge $line.Length) { return ,$given }

        $ast = [System.Management.Automation.Language.Parser]::ParseInput($line.Substring($start), [ref] $null, [ref] $null)
        $command = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
        if ($null -eq $command) { return ,$given }
        # After & or . the invocation name is the operator itself, so the name cannot be compared.
        $calledAs = [string] $Invocation.InvocationName
        if ($calledAs -ne '&' -and $calledAs -ne '.' -and $command.GetCommandName() -ne $calledAs) { return ,$given }

        $typed = @($command.CommandElements | Select-Object -Skip 1)
        $at = -1
        for ($i = 0; $i -lt $typed.Count; $i++) {
            if ($typed[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $typed[$i].Extent.Text -eq '--') { $at = $i; break }
        }
        # It was removed when exactly one argument fewer arrived than was typed.
        if ($at -lt 0 -or $given.Count -ne $typed.Count - 1) { return ,$given }

        $result = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $given.Count; $i++) {
            if ($i -eq $at) { $result.Add('--') }
            $result.Add($given[$i])
        }
        if ($at -ge $given.Count) { $result.Add('--') }
        return ,$result.ToArray()
    } catch {
        return ,$given
    }
}

# Core runner (the "dev-run" helper). Builds a one-shot `docker run` and execs it.
# NOTE: intentionally NOT an advanced function, and tool args arrive as an explicit
# array value - so tool flags like `-out` are passed through as data, never parsed
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

# Open an interactive shell in the toolbox with the same mounts: whatever the image starts by
# default (zsh with suggestions and completion; bash in an image built before that), or the command
# you give, for example  dev bash.  AKS_RG and AKS_NAME, when set, are handed to the shell inside.
function dev {
    $devArgs = Restore-DashDash $MyInvocation $args
    $runArgs = Get-BaseRunArgs -AllowTty $true
    foreach ($n in 'AKS_RG', 'AKS_NAME') {
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($n))) { $runArgs.AddRange([string[]]@('-e', $n)) }
    }
    $runArgs.Add($script:DevToolsImage)
    if ($devArgs.Count -gt 0) { $runArgs.AddRange([string[]] $devArgs) }

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
        Image       = $script:DevToolsImage
        Volume      = $script:DevToolsVolume
        Tools       = 'az, kubectl, terraform, flux, helm, kustomize, azd, gh, kubectx, kubens, dev'
        AliasesFile = $script:DevToolsAliasesFile
    }
}

# --- Transparent CLI wrappers (hyphen-free so they shadow the host binaries) ---
# Each passes its args as the VALUE of -ToolArgs, so nothing gets re-parsed.
function az         { Invoke-DevTool -Tool az         -ToolArgs (Restore-DashDash $MyInvocation $args) }
function kubectl    { Invoke-DevTool -Tool kubectl    -ToolArgs (Restore-DashDash $MyInvocation $args) }
function terraform  { Invoke-DevTool -Tool terraform  -ToolArgs (Restore-DashDash $MyInvocation $args) }
function flux       { Invoke-DevTool -Tool flux       -ToolArgs (Restore-DashDash $MyInvocation $args) }
function helm       { Invoke-DevTool -Tool helm       -ToolArgs (Restore-DashDash $MyInvocation $args) }
function kustomize  { Invoke-DevTool -Tool kustomize  -ToolArgs (Restore-DashDash $MyInvocation $args) }
function azd        { Invoke-DevTool -Tool azd        -ToolArgs (Restore-DashDash $MyInvocation $args) }
function gh         { Invoke-DevTool -Tool gh         -ToolArgs (Restore-DashDash $MyInvocation $args) }
function kubectx    { Invoke-DevTool -Tool kubectx    -ToolArgs (Restore-DashDash $MyInvocation $args) }
function kubens     { Invoke-DevTool -Tool kubens     -ToolArgs (Restore-DashDash $MyInvocation $args) }

# ---- Shortcuts -----------------------------------------------------------------------------------
# name -> what it runs. Whatever you type after a shortcut is added at the end: `kgp -n kube-system`
# runs `kubectl get pods -n kube-system`. scripts/shell/aliases.sh holds the same list for the shell
# inside the toolbox, and tests/Test-Devtools.ps1 checks that the two agree, so change both.
# Get-DevToolsAlias lists them. Your own go in ~/.devtools-aliases.ps1 (read last, so it wins).
$script:DevToolsAliases = [ordered]@{
    # Azure
    azl       = 'az login --use-device-code'
    azwho     = 'az account show -o table'
    azsubs    = 'az account list -o table'
    azsub     = 'az account set --subscription'
    azrg      = 'az group list -o table'
    azres     = 'az resource list -o table -g'
    acrls     = 'az acr repository list -o table -n'
    # AKS and kubectl
    aksl      = 'az aks list -o table'
    k         = 'kubectl'
    kx        = 'kubectx'
    kn        = 'kubens'
    kgp       = 'kubectl get pods'
    kgpa      = 'kubectl get pods -A'
    kgn       = 'kubectl get nodes'
    kgd       = 'kubectl get deployments'
    kgs       = 'kubectl get services'
    kd        = 'kubectl describe'
    kl        = 'kubectl logs'
    klf       = 'kubectl logs -f'
    kex       = 'kubectl exec -it'
    kaf       = 'kubectl apply -f'
    krr       = 'kubectl rollout restart'
    ktop      = 'kubectl top pods'
    # Terraform
    tf        = 'terraform'
    tfi       = 'terraform init'
    tfv       = 'terraform validate'
    tff       = 'terraform fmt -recursive'
    tfp       = 'terraform plan -out=tfplan'
    tfa       = 'terraform apply tfplan'
    tfo       = 'terraform output'
    tfs       = 'terraform state list'
    tfss      = 'terraform state show'
    tfw       = 'terraform workspace list'
    tfws      = 'terraform workspace select'
    tfdestroy = 'terraform destroy'
}

# Defined as functions, not aliases: a PowerShell alias cannot carry arguments of its own. One
# script block serves them all (it looks its own name up), and because it is written here in the
# module it can use the module's private helpers. The loop runs at the top level of the module, so
# each function lands in the module's scope.
$script:DevToolsAliasWords = @{}
foreach ($aliasName in $script:DevToolsAliases.Keys) {
    $script:DevToolsAliasWords[$aliasName] = [string[]] @(([string] $script:DevToolsAliases[$aliasName]) -split '\s+')
}
$script:DevToolsShortcut = {
    $words = $script:DevToolsAliasWords[$MyInvocation.MyCommand.Name]
    if ($null -eq $words) { throw "$($MyInvocation.MyCommand.Name) is a copy of a toolbox shortcut under another name; copy what it runs instead (Get-DevToolsAlias)." }
    $typed = Restore-DashDash $MyInvocation $args
    Invoke-DevTool -Tool $words[0] -ToolArgs (@($words | Select-Object -Skip 1) + $typed)
}
foreach ($aliasName in $script:DevToolsAliases.Keys) {
    Set-Item -Path ('Function:\' + $aliasName) -Value $script:DevToolsShortcut
}

# The three that take a resource group and a cluster name (shown by Get-DevToolsAlias).
$script:DevToolsSpecial = [ordered]@{
    aksc  = 'az aks get-credentials -g RG -n NAME --overwrite-existing   (RG NAME, or AKS_RG and AKS_NAME)'
    aksup = 'az aks get-upgrades -g RG -n NAME -o table   (RG NAME, or AKS_RG and AKS_NAME)'
    aksx  = 'az aks command invoke -g AKS_RG -n AKS_NAME --command "..."   (for a private cluster)'
}

# A message in red plus a failing $LASTEXITCODE, the way the tools themselves report problems.
function Write-DevToolsError {
    param([string] $Message)
    Write-Host $Message -ForegroundColor Red
    $global:LASTEXITCODE = 1
}

# The resource group and cluster name for aksc / aksup: the first two words when neither starts with
# a dash, otherwise the AKS_RG and AKS_NAME environment variables. Returns $null after saying what is missing.
function Resolve-AksTarget {
    param([string] $Helper, [string[]] $Arguments)

    $list = @($Arguments)
    if ($list.Count -ge 2 -and -not "$($list[0])".StartsWith('-') -and -not "$($list[1])".StartsWith('-')) {
        $rg      = "$($list[0])"
        $cluster = "$($list[1])"
        $list    = @($list | Select-Object -Skip 2)
    } else {
        $rg      = "$env:AKS_RG"
        $cluster = "$env:AKS_NAME"
    }
    if (-not $rg -or -not $cluster) {
        Write-DevToolsError ("$Helper needs a resource group and a cluster name:  $Helper RG NAME`n" +
                             "or set them once (they stay on your laptop):  `$env:AKS_RG = '...'; `$env:AKS_NAME = '...'`n" +
                             "A good place is $script:DevToolsAliasesFile")
        return $null
    }
    return [pscustomobject]@{ ResourceGroup = $rg; Name = $cluster; Rest = $list }
}

function aksc {
    $t = Resolve-AksTarget -Helper 'aksc' -Arguments $args
    if (-not $t) { return }
    $rest = @($t.Rest)
    az aks get-credentials -g $t.ResourceGroup -n $t.Name --overwrite-existing @rest
}

function aksup {
    $t = Resolve-AksTarget -Helper 'aksup' -Arguments $args
    if (-not $t) { return }
    $rest = @($t.Rest)
    az aks get-upgrades -g $t.ResourceGroup -n $t.Name -o table @rest
}

# aksx kubectl get nodes   runs the command inside the cluster through Azure, which works for a
# private cluster that your laptop cannot reach directly.
function aksx {
    if ($args.Count -eq 0) {
        Write-DevToolsError 'aksx: give the command to run, for example:  aksx kubectl get nodes'
        return
    }
    if (-not $env:AKS_RG -or -not $env:AKS_NAME) {
        Write-DevToolsError ("aksx: set the resource group and the cluster name first (they stay on your laptop):`n" +
                             "  `$env:AKS_RG = '...'; `$env:AKS_NAME = '...'`n" +
                             "A good place is $script:DevToolsAliasesFile")
        return
    }
    $command = ($args | ForEach-Object { "$_" }) -join ' '
    az aks command invoke -g $env:AKS_RG -n $env:AKS_NAME --command $command
}

# ---- Your own shortcuts --------------------------------------------------------------------------
# ~/.devtools-aliases.ps1 (or the file named by DEVTOOLS_ALIASES) is read after everything above, so
# what it defines wins. Any function or alias it creates is exported too. A mistake in it is
# reported as a warning and does not stop the toolbox from loading.
$script:DevToolsPersonalFunctions = @()
$script:DevToolsPersonalAliases   = @()
$script:DevToolsOverridden        = @()
if (Test-Path -LiteralPath $script:DevToolsAliasesFile -PathType Leaf) {
    $defaultNames = @($script:DevToolsAliases.Keys) + @($script:DevToolsSpecial.Keys)
    $textBefore   = @{}
    foreach ($n in $defaultNames) { $textBefore[$n] = (Get-Item -LiteralPath ('Function:\' + $n)).ScriptBlock.ToString() }
    $functionsBefore = @(Get-ChildItem -Path Function: | ForEach-Object { $_.Name })
    $aliasesBefore   = @(Get-ChildItem -Path Alias: | ForEach-Object { $_.Name })

    Set-StrictMode -Off     # your file is not held to this module's strictness while it loads
    try {
        . $script:DevToolsAliasesFile
    } catch {
        Write-Warning ("Could not read your shortcuts file {0}: {1}" -f $script:DevToolsAliasesFile, $_.Exception.Message)
    } finally {
        Set-StrictMode -Version Latest
    }

    $script:DevToolsPersonalFunctions = @(Get-ChildItem -Path Function: | ForEach-Object { $_.Name } | Where-Object { $functionsBefore -notcontains $_ })
    $script:DevToolsPersonalAliases   = @(Get-ChildItem -Path Alias: | ForEach-Object { $_.Name } | Where-Object { $aliasesBefore -notcontains $_ })
    foreach ($n in $defaultNames) {
        $now = Get-Item -LiteralPath ('Function:\' + $n) -ErrorAction SilentlyContinue
        if (-not $now -or $now.ScriptBlock.ToString() -ne $textBefore[$n]) { $script:DevToolsOverridden += $n }
    }
}

# Every shortcut, grouped: the toolbox's own, the ones your file replaces, the ones it adds.
function Get-DevToolsAlias {
    [CmdletBinding()]
    param([string] $Name = '*')

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $script:DevToolsAliases.Keys) {
        $runs  = [string] $script:DevToolsAliases[$n]
        $group = 'kubectl'
        if ($runs -like 'az aks*') { $group = 'AKS' } elseif ($runs -like 'az *') { $group = 'Azure' } elseif ($runs -like 'terraform*') { $group = 'Terraform' }
        if ($script:DevToolsOverridden -contains $n) { $group = 'Yours'; $runs = '(your own, replaces the default)' }
        $rows.Add([pscustomobject]@{ Group = $group; Alias = $n; Runs = $runs })
    }
    foreach ($n in $script:DevToolsSpecial.Keys) {
        $group = 'AKS'
        $runs  = [string] $script:DevToolsSpecial[$n]
        if ($script:DevToolsOverridden -contains $n) { $group = 'Yours'; $runs = '(your own, replaces the default)' }
        $rows.Add([pscustomobject]@{ Group = $group; Alias = $n; Runs = $runs })
    }
    foreach ($n in @($script:DevToolsPersonalFunctions) + @($script:DevToolsPersonalAliases)) {
        $rows.Add([pscustomobject]@{ Group = 'Yours'; Alias = $n; Runs = ('(from ' + $script:DevToolsAliasesFile + ')') })
    }
    foreach ($g in 'Azure', 'AKS', 'kubectl', 'Terraform', 'Yours') {
        $rows | Where-Object { $_.Group -eq $g -and $_.Alias -like $Name }
    }
}

# ---- Tab completion ------------------------------------------------------------------------------
# The real tools exist only in the container, so a Tab press asks it: one short-lived container,
# about a second. It needs an image that has devtools-complete (rebuild with setup.ps1). When the
# image is older, docker is not running or the tool has no answer, the result is nothing and
# PowerShell completes file names as usual.
$script:CompletableTools = @('az', 'kubectl', 'terraform', 'flux', 'helm', 'kustomize', 'azd', 'gh')

function Get-DevToolsCompletion {
    param($CommandAst, [int] $CursorPosition)

    $name = $CommandAst.GetCommandName()
    if (-not $name) { return }
    $text  = $CommandAst.Extent.Text
    $point = $CursorPosition - $CommandAst.Extent.StartOffset
    if ($point -lt $name.Length -or -not $text.StartsWith($name)) { return }
    if ($point -gt $text.Length) { $text = $text.PadRight($point) }     # the cursor is after a space
    $line = $text.Substring(0, $point)

    # A shortcut completes like the command it stands for: kgp -n <Tab> asks about kubectl get pods -n.
    if ($script:DevToolsAliases.Contains($name)) {
        $line = [string] $script:DevToolsAliases[$name] + $line.Substring($name.Length)
    }
    $tool = (($line -split '\s+', 2)[0]).ToLowerInvariant()
    if ($script:CompletableTools -notcontains $tool) { return }
    $line = $tool + $line.Substring($tool.Length)

    $dockerArgs = @('run', '--rm', '-v', ('{0}:/root' -f $script:DevToolsVolume), $script:DevToolsImage,
                    'devtools-complete', $tool, $line, "$($line.Length)")
    $previousExit = Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $savedPref    = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $rows = @()
    try {
        $rows = @(Invoke-Docker -DockerArgs $dockerArgs 2>$null | ForEach-Object { "$_" })
        if ($global:LASTEXITCODE -ne 0) { $rows = @() }
    } catch {
        $rows = @()
    } finally {
        $ErrorActionPreference = $savedPref
        if ($null -ne $previousExit) { $global:LASTEXITCODE = $previousExit }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $found = 0
    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row)) { continue }
        $parts = $row -split "`t", 2
        $value = $parts[0].Trim()
        if ($value.Length -eq 0 -or -not $seen.Add($value)) { continue }
        $tip = $value
        if ($parts.Count -gt 1 -and $parts[1].Trim().Length -gt 0) { $tip = $parts[1].Trim() }
        $kind = 'ParameterValue'
        if ($value.StartsWith('-')) { $kind = 'ParameterName' }
        $insert = $value
        if ($value -match '\s') { $insert = "'" + $value.Replace("'", "''") + "'" }
        [System.Management.Automation.CompletionResult]::new($insert, $value, $kind, $tip)
        $found++
        if ($found -ge 200) { break }
    }
}

$script:DevToolsCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)
    if (-not $script:DevToolsActive) { return }
    try { Get-DevToolsCompletion -CommandAst $commandAst -CursorPosition $cursorPosition } catch { }
}

# The tools themselves and every shortcut that stands for one of them.
try {
    $completeNames = [System.Collections.Generic.List[string]]::new()
    $completeNames.AddRange([string[]] $script:CompletableTools)
    foreach ($n in $script:DevToolsAliases.Keys) {
        $firstWord = ([string] $script:DevToolsAliases[$n] -split '\s+', 2)[0]
        if ($script:CompletableTools -contains $firstWord) { $completeNames.Add($n) }
    }
    Register-ArgumentCompleter -Native -CommandName $completeNames.ToArray() -ScriptBlock $script:DevToolsCompleter
} catch {
    Write-Verbose "Tab completion was not registered: $($_.Exception.Message)"
}

# ---- History suggestions and the Tab menu (PSReadLine) ---------------------------------------------
# PSReadLine 2.1 or newer can show a grey suggestion from your history as you type (Right arrow
# accepts it). Older versions, such as the 2.0 that Windows PowerShell 5.1 ships, cannot, so there
# the Up and Down arrows search the history for what you have typed instead. Tab opens a menu of the
# choices. Only the defaults are replaced, so a setting of your own is left alone, and everything is
# put back when the module is removed. DEVTOOLS_NO_READLINE=1 skips all of it.
$script:ReadLineUndo = [ordered]@{}

function Initialize-DevToolsReadLine {
    if ($env:DEVTOOLS_NO_READLINE) { return }
    $set = Get-Command -Name Set-PSReadLineOption -ErrorAction SilentlyContinue
    if (-not $set) { return }
    try {
        $canPredict = $set.Parameters.ContainsKey('PredictionSource')
        if ($canPredict) {
            $current = "$((Get-PSReadLineOption).PredictionSource)"
            if ($current -eq 'None') {
                Set-PSReadLineOption -PredictionSource History
                $script:ReadLineUndo['PredictionSource'] = $current
            }
        }
        $bound = @(Get-PSReadLineKeyHandler -Bound)
        $tab = $bound | Where-Object { "$($_.Key)" -eq 'Tab' } | Select-Object -First 1
        if ($tab -and @('TabCompleteNext', 'Complete') -contains "$($tab.Function)") {
            Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
            $script:ReadLineUndo['Tab'] = "$($tab.Function)"
        }
        if (-not $canPredict) {
            foreach ($row in @(@('UpArrow', 'PreviousHistory', 'HistorySearchBackward'), @('DownArrow', 'NextHistory', 'HistorySearchForward'))) {
                $handler = $bound | Where-Object { "$($_.Key)" -eq $row[0] } | Select-Object -First 1
                if ($handler -and "$($handler.Function)" -eq $row[1]) {
                    Set-PSReadLineKeyHandler -Key $row[0] -Function $row[2]
                    $script:ReadLineUndo[$row[0]] = $row[1]
                }
            }
        }
    } catch {
        Write-Verbose "PSReadLine was left as it was: $($_.Exception.Message)"
    }
}

function Restore-DevToolsReadLine {
    try {
        foreach ($key in @($script:ReadLineUndo.Keys)) {
            if ($key -eq 'PredictionSource') {
                Set-PSReadLineOption -PredictionSource $script:ReadLineUndo[$key]
            } else {
                Set-PSReadLineKeyHandler -Key $key -Function $script:ReadLineUndo[$key]
            }
        }
    } catch {
        Write-Verbose "PSReadLine could not be restored: $($_.Exception.Message)"
    }
    $script:ReadLineUndo = [ordered]@{}
}

# True in a console window that is about to show a prompt. A script run (-File, -Command), a redirected
# session, the ISE and an editor's host have no use for these keys and are left alone. The state of
# PSReadLine is not what decides: Windows PowerShell 5.1 loads it only after the profile has run.
function Test-InteractiveConsole {
    param(
        [string]   $HostName    = $Host.Name,
        [string[]] $CommandLine = @([Environment]::GetCommandLineArgs() | Select-Object -Skip 1),
        [bool]     $Redirected  = ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)
    )

    if ($HostName -ne 'ConsoleHost' -or $Redirected) { return $false }
    $scripted = $false
    $noExit   = $false
    foreach ($a in @($CommandLine)) {
        if ("$a" -notmatch '^[-/]([A-Za-z]+)$') { continue }
        $n = $Matches[1].ToLowerInvariant()
        if ($n.Length -ge 3 -and 'noexit'.StartsWith($n)) { $noExit = $true }
        elseif ($n.Length -ge 4 -and 'noninteractive'.StartsWith($n)) { return $false }
        elseif ('file'.StartsWith($n) -or 'command'.StartsWith($n) -or 'encodedcommand'.StartsWith($n) -or $n -eq 'ec') { $scripted = $true }
    }
    return ($noExit -or -not $scripted)
}

if (Test-InteractiveConsole) { Initialize-DevToolsReadLine }

# Removing the module (Remove-Module, or Import-Module -Force over it) hands the keys back and
# silences its completers; PowerShell has no way to unregister them.
$ExecutionContext.SessionState.Module.OnRemove = {
    $script:DevToolsActive = $false
    Restore-DevToolsReadLine
}

$exportFunctions = @('az', 'kubectl', 'terraform', 'flux', 'helm', 'kustomize', 'azd', 'gh', 'kubectx', 'kubens',
                     'dev', 'Import-DockerDesktopKube', 'Get-DevToolsInfo', 'Get-DevToolsAlias', 'aksc', 'aksup', 'aksx') +
                   @($script:DevToolsAliases.Keys) + @($script:DevToolsPersonalFunctions)
$exportFunctions = @($exportFunctions | Where-Object { Test-Path -LiteralPath ('Function:\' + $_) })
if (@($script:DevToolsPersonalAliases).Count -gt 0) {
    Export-ModuleMember -Function $exportFunctions -Alias @($script:DevToolsPersonalAliases)
} else {
    Export-ModuleMember -Function $exportFunctions
}
