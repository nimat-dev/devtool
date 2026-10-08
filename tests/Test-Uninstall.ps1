#Requires -Version 5.1
<#
    Tests for uninstall.ps1. Every scenario copies the project into a scratch folder (its name has a
    space in it on purpose), runs uninstall.ps1 there in a child PowerShell against a fake `docker`,
    and checks the exit code, the output, the docker calls it made and the profile file it left.
    Several scenarios run setup.ps1 first, so that "uninstall undoes setup" is tested for real.
    No Docker daemon is needed. Works in Windows PowerShell 5.1, in PowerShell 7 on Windows, and
    in PowerShell 7 on Linux and macOS:

        pwsh -NoProfile -File tests/Test-Uninstall.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Uninstall.ps1

    The fake docker and its knobs are described in tests/FakeDocker.ps1 and tests/fakebin/docker.
    Your own profile is never touched, except on a GitHub Actions runner (a throw-away machine),
    where the default profile locations are tested for real and put back afterwards.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root   = Split-Path -Parent $PSScriptRoot
$base   = Join-Path ([IO.Path]::GetTempPath()) "devtools-uninstall-test-$PID"
$proj   = Join-Path $base 'my project'                             # a space on purpose
$empty  = Join-Path $base 'empty'                                  # a PATH that has no docker on it
$prof   = Join-Path (Join-Path $base 'profile dir') 'profile.ps1'
$log    = Join-Path $base 'docker.log'
$psFile = Join-Path $base 'containers.txt'                         # the containers the fake docker "has"
New-Item -ItemType Directory -Force -Path $base, $empty | Out-Null

. (Join-Path $PSScriptRoot 'FakeDocker.ps1')
$fakebin = Install-FakeDocker
$env:DOCKER_ARGS_FILE   = Join-Path $base 'last-args.txt'
$env:DOCKER_LOG_FILE    = $log       # every docker call is appended here
$env:DOCKER_FAKE_OUTPUT = '1'
$env:DOCKER_PS_FILE     = $psFile    # `docker ps` lists this file, `docker rm` empties it

$psExe = (Get-Process -Id $PID).Path # the same PowerShell that runs the tests
Write-Host ("PowerShell {0} ({1}) on {2}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [Environment]::OSVersion.VersionString)

$script:failures = 0
$script:passes   = 0
function Check([string] $Name, [bool] $Condition, [string] $Detail = '') {
    if ($Condition) {
        Write-Host "PASS  $Name"
        $script:passes++
    } else {
        Write-Host "FAIL  $Name"
        if ($Detail) { Write-Host "      $Detail" }
        $script:failures++
    }
}

# Fresh copy of the project, no profile, no containers, no docker history.
function Reset-Project {
    Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Split-Path -Parent $prof) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $log, $psFile -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $proj 'certs') | Out-Null
    foreach ($f in 'setup.ps1', 'uninstall.ps1', 'Devtools.psm1', 'Dockerfile', 'docker-compose.yml', '.env.example') {
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination $proj
    }
}

# Run a child PowerShell with these arguments. $EnvVars is set for this run only. $StdIn is piped
# to it (an empty array means "stdin is closed"); without it the child inherits stdin.
function Invoke-Ps {
    param([string[]] $PsArguments = @(), [hashtable] $EnvVars = @{}, [string] $PathOverride, $StdIn = $null)
    $prior = @{}
    foreach ($k in @($EnvVars.Keys)) {
        $prior[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, [string] $EnvVars[$k])
    }
    $psArgs = @('-NoProfile')
    if ($isWin) { $psArgs += @('-ExecutionPolicy', 'Bypass') }
    $psArgs += $PsArguments

    $savedPath = $env:PATH
    $savedPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'      # Windows PowerShell 5.1 turns native stderr into errors under 'Stop'
    try {
        if ($PathOverride) { $env:PATH = $PathOverride }
        if ($null -ne $StdIn) {
            $lines = @(@($StdIn) | & $psExe @psArgs 2>&1 | ForEach-Object { "$_" })
        } else {
            $lines = @(& $psExe @psArgs 2>&1 | ForEach-Object { "$_" })
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPref
        $env:PATH = $savedPath
        foreach ($k in @($prior.Keys)) { [Environment]::SetEnvironmentVariable($k, $prior[$k]) }
    }
    return [pscustomobject]@{ Code = $code; Text = ($lines -join "`n") }
}

function Invoke-Setup {
    param([string[]] $Arguments = @(), [hashtable] $EnvVars = @{})
    return Invoke-Ps (@('-File', (Join-Path $proj 'setup.ps1'), '-NoPrompt') + $Arguments) $EnvVars
}

# uninstall.ps1 with -NoPrompt, unless -Ask (then the question is really asked and $StdIn answers it).
function Invoke-Uninstall {
    param([string[]] $Arguments = @(), [hashtable] $EnvVars = @{}, [string] $PathOverride, $StdIn = $null, [switch] $Ask, [string] $Dir = $proj)
    $a = @('-File', (Join-Path $Dir 'uninstall.ps1'))
    if (-not $Ask) { $a += '-NoPrompt' }
    return Invoke-Ps ($a + $Arguments) $EnvVars $PathOverride $StdIn
}

function Get-Calls { if (Test-Path -LiteralPath $log) { return @(Get-Content -LiteralPath $log) } else { return @() } }
function Get-CallCount([string] $Pattern) { return @(@(Get-Calls) | Where-Object { $_ -match $Pattern }).Count }
function Get-CallIndex([string] $Pattern) {
    $calls = @(Get-Calls)
    for ($i = 0; $i -lt $calls.Count; $i++) { if ($calls[$i] -match $Pattern) { return $i } }
    return -1
}
function Get-ImportLines([string] $Path = $prof) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path | Where-Object { $_ -match '^\s*(Import-Module|ipmo)\b.*Devtools\.psm1' })
}
function Read-Text([string] $Path) { return "$(Get-Content -LiteralPath $Path -Raw)" }
function Get-B64([string] $Path) { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }
function Show($r) { return "exit $($r.Code); output tail:`n      " + ((@($r.Text -split "`n") | Select-Object -Last 40) -join "`n      ") }

function Write-Profile([string] $Text, [bool] $Bom = $false) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $prof) | Out-Null
    [IO.File]::WriteAllText($prof, $Text, (New-Object System.Text.UTF8Encoding -ArgumentList $Bom))
}
function Set-Containers([string[]] $Ids) { [IO.File]::WriteAllText($psFile, (($Ids -join "`n") + "`n")) }

$e            = [string][char]0xE9
$expectedLine = "Import-Module '{0}' -Force" -f (Join-Path $proj 'Devtools.psm1')
$marker       = '# DevOps toolbox: az, kubectl, terraform, helm, flux ... run in Docker'
$volumesBoth  = 'devtools-home devtools_devtools-home'

# ---- the script itself --------------------------------------------------------------------------
$uninstallFile = Join-Path $root 'uninstall.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uninstallFile, [ref] $tokens, [ref] $parseErrors)
Check 'uninstall.ps1 parses with zero syntax errors' (@($parseErrors).Count -eq 0)
# Windows PowerShell 5.1 reads a file without a byte-order mark as ANSI, so keep it ASCII.
Check 'uninstall.ps1 is ASCII only' (@([IO.File]::ReadAllBytes($uninstallFile) | Where-Object { $_ -gt 127 }).Count -eq 0)
$help = Read-Text $uninstallFile
foreach ($p in @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })) {
    Check "parameter -$p is documented in the help comment" ($help -match "(?m)^\.PARAMETER\s+$p\b")
}
Check 'setup.ps1 and uninstall.ps1 agree on the comment line setup writes into the profile' ((Read-Text (Join-Path $root 'setup.ps1')).Contains($marker) -and $help.Contains($marker))

# ---- 1. undo a real setup: the profile comes back exactly as it was ------------------------------
Write-Host ''
Write-Host '-- setup, then uninstall'
Reset-Project
$original = "# my profile (caf$e)`r`nSet-Alias ll Get-ChildItem`r`n`$x = 1`r`n"
Write-Profile $original $true
$originalB64 = Get-B64 $prof
$r = Invoke-Setup @('-SkipBuild', '-SkipVerify', '-ProfilePath', $prof)
Check 'setup.ps1 added its line (the starting point)'    (($r.Code -eq 0) -and (@(Get-ImportLines).Count -eq 1) -and ((Get-B64 $prof) -cne $originalB64)) (Show $r)
$afterSetup = Read-Text $prof
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
Set-Containers 'abc123def456', 'fff111eee222'
$r = Invoke-Uninstall @('-ProfilePath', $prof)
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'prints all four steps in order'                  ($r.Text -match '(?s)1/4.*2/4.*3/4.*4/4') $d
Check 'the profile is byte for byte what it was before setup' ((Get-B64 $prof) -ceq $originalB64) $d
Check 'no Import-Module line is left'                   (@(Get-ImportLines).Count -eq 0)
Check 'shows the line it removed'                       ($r.Text.Contains($expectedLine)) $d
Check 'keeps a .bak copy that still has the line'       ((Test-Path -LiteralPath "$prof.bak") -and ((Read-Text "$prof.bak") -ceq $afterSetup)) $d
Check 'says it cleaned the profile'                     ($r.Text -match '(?m)^  OK    cleaned ') $d
Check 'runs docker compose down once'                   ((Get-CallCount '^compose down --remove-orphans$') -eq 1) (@(Get-Calls) -join ' | ')
Check 'looks for containers started from the image'     ((Get-CallCount '^ps -aq --filter ancestor=devtools:latest$') -ge 1) (@(Get-Calls) -join ' | ')
Check 'stops and removes both containers in one call'   ((Get-CallCount '^rm -f abc123def456 fff111eee222$') -eq 1) (@(Get-Calls) -join ' | ')
Check 'says it removed 2 containers'                    ($r.Text -match 'stopped and removed 2 container\(s\)') $d
Check 'keeps the image and the saved logins by default' (((Get-CallCount '^image rm') -eq 0) -and ((Get-CallCount '^volume ') -eq 0)) (@(Get-Calls) -join ' | ')
Check 'says what it kept and which flag deletes it'     (($r.Text -match 'kept the image devtools:latest.*-RemoveImage') -and ($r.Text -match 'kept your saved logins.*-RemoveVolume')) $d
Check 'leaves the project folder and .env alone'        ((Test-Path -LiteralPath (Join-Path $proj 'Devtools.psm1')) -and (Test-Path -LiteralPath (Join-Path $proj '.env'))) $d
Check 'finishes with Done'                              (($r.Text -match '(?m)^Done\.') -and -not ($r.Text -match 'problem')) $d
Check 'a separate process cannot unload the window, and says so' (($r.Text -match 'nothing to unload here') -and ($r.Text -match 'Remove-Module Devtools')) $d

Write-Host ''
Write-Host '-- second run changes nothing'
Remove-Item -LiteralPath "$prof.bak" -Force
Remove-Item -LiteralPath $log -Force
$r = Invoke-Uninstall @('-ProfilePath', $prof)
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'leaves the profile byte for byte as it was'      ((Get-B64 $prof) -ceq $originalB64) $d
Check 'says there is nothing to remove'                 ($r.Text -match 'nothing to remove') $d
Check 'writes no new .bak'                              (-not (Test-Path -LiteralPath "$prof.bak")) $d
Check 'no container is running'                         ($r.Text -match 'no container is running from devtools:latest') $d
Check 'does not call docker rm'                         ((Get-CallCount '^rm ') -eq 0) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- setup created the profile'
Reset-Project
$r = Invoke-Setup @('-SkipBuild', '-SkipVerify', '-ProfilePath', $prof)
Check 'setup.ps1 created the profile (the starting point)' (($r.Code -eq 0) -and (@(Get-ImportLines).Count -eq 1)) (Show $r)
$r = Invoke-Uninstall @('-ProfilePath', $prof)
$left = Read-Text $prof
Check 'exits 0'                                         ($r.Code -eq 0) (Show $r)
Check 'nothing of the toolbox is left in the file'      ((-not $left.Contains('Devtools')) -and (-not $left.Contains('DevOps toolbox')) -and ($left.Trim().Length -eq 0)) $left

Write-Host ''
Write-Host '-- setup appended to a profile without a final newline'
Reset-Project
Write-Profile '$x = 1'
$r = Invoke-Setup @('-SkipBuild', '-SkipVerify', '-ProfilePath', $prof)
Check 'setup.ps1 added its line (the starting point)'   (($r.Code -eq 0) -and (@(Get-ImportLines).Count -eq 1)) (Show $r)
$r = Invoke-Uninstall @('-ProfilePath', $prof)
$left = Read-Text $prof
Check 'exits 0'                                         ($r.Code -eq 0) (Show $r)
Check 'keeps your line, drops the toolbox lines'        (($left.TrimEnd() -ceq '$x = 1') -and (@(Get-ImportLines).Count -eq 0)) $left

# ---- 2. the shapes a line can have ----------------------------------------------------------------
Write-Host ''
Write-Host '-- other ways the line can be written'
Reset-Project
$shapes = "# before`n" +
          "Import-Module 'C:\old place\Devtools.psm1' -Force`n" +
          "  import-module `"D:\other\devtools.psm1`"   # lowercase, indented, with a comment`n" +
          "ipmo C:\x\Devtools.psm1`n" +
          "# Import-Module 'C:\commented\Devtools.psm1'`n" +
          "Set-Alias ll Get-ChildItem`n"
Write-Profile $shapes
$r = Invoke-Uninstall @('-ProfilePath', $prof)
$d = Show $r
$new = Read-Text $prof
Check 'exits 0 (a commented-out line is not a problem)' ($r.Code -eq 0) $d
Check 'removes Import-Module in any case and with a comment after it' (-not ($new -match "(?m)^\s*(Import-Module|import-module)\b")) $new
Check 'removes ipmo as well'                            (-not ($new -match 'ipmo')) $new
Check 'leaves the commented-out line and your other lines' ($new -ceq "# before`n# Import-Module 'C:\commented\Devtools.psm1'`nSet-Alias ll Get-ChildItem`n") $new
Check 'reports the three lines it removed'              ((([regex]::Matches($r.Text, '(?m)^        removed: ')).Count) -eq 3) $d
Check 'keeps the Unix line endings (adds no CR)'        (-not $new.Contains("`r")) $new
Check 'the .bak holds the original'                     ((Read-Text "$prof.bak") -ceq $shapes) $d
Check 'adds no byte-order mark to a file that had none' ((([IO.File]::ReadAllBytes($prof))[0]) -ne 0xEF) $d

# Whatever encoding the profile is in, everything except the toolbox lines stays byte for byte.
Write-Host ''
Write-Host '-- profiles in other encodings'
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$utf8   = New-Object System.Text.UTF8Encoding -ArgumentList $false
$utf16  = [System.Text.Encoding]::Unicode
$import = "Import-Module 'C:\Users\Jos$e\devtool\Devtools.psm1' -Force"
$before = "# caf$e`r`n$import`r`n`$x = 1`r`n"           # a profile with the toolbox line in the middle
$after  = "# caf$e`r`n`$x = 1`r`n"                       # the same without it
$bom8   = [byte[]] (0xEF, 0xBB, 0xBF)
$bom16  = [byte[]] (0xFF, 0xFE)
$cases  = @(
    [pscustomobject]@{ Name = 'UTF-8 without a byte-order mark';          Original = $utf8.GetBytes($before);                 Expected = $utf8.GetBytes($after) },
    [pscustomobject]@{ Name = 'UTF-8 with a byte-order mark';             Original = ($bom8 + $utf8.GetBytes($before));       Expected = ($bom8 + $utf8.GetBytes($after)) },
    [pscustomobject]@{ Name = 'ANSI (Windows-1252, one byte per accent)'; Original = $latin1.GetBytes($before);               Expected = $latin1.GetBytes($after) },
    [pscustomobject]@{ Name = 'UTF-16 (what > and Out-File write in 5.1)'; Original = ($bom16 + $utf16.GetBytes($before));   Expected = ($bom16 + $utf16.GetBytes($after)) },
    [pscustomobject]@{ Name = 'UTF-8 with a mark, toolbox line first';    Original = ($bom8 + $utf8.GetBytes("$import`r`n`$x = 1`r`n")); Expected = ($bom8 + $utf8.GetBytes("`$x = 1`r`n")) },
    [pscustomobject]@{ Name = 'a profile that is only the toolbox line, no final newline'; Original = $utf8.GetBytes($import); Expected = $utf8.GetBytes('') }
)
foreach ($c in $cases) {
    Reset-Project
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $prof) | Out-Null
    [IO.File]::WriteAllBytes($prof, [byte[]] $c.Original)
    $r = Invoke-Uninstall @('-ProfilePath', $prof)
    $d = Show $r
    $now      = Get-B64 $prof
    $expected = [Convert]::ToBase64String([byte[]] $c.Expected)
    Check "$($c.Name): exits 0 and says it cleaned the file" (($r.Code -eq 0) -and ($r.Text -match '(?m)^  OK    cleaned ')) $d
    Check "$($c.Name): only the toolbox line is gone"        ($now -ceq $expected) "now:      $now`n      expected: $expected"
    Check "$($c.Name): the .bak is the original"             ((Get-B64 "$prof.bak") -ceq [Convert]::ToBase64String([byte[]] $c.Original)) $d
}

Write-Host ''
Write-Host '-- a line this cleanup cannot recognise'
Reset-Project
$hand = "Set-Alias ll Get-ChildItem`r`nif (Test-Path 'C:\x\Devtools.psm1') { Import-Module 'C:\x\Devtools.psm1' }`r`n"
Write-Profile $hand
$handB64 = Get-B64 $prof
$r = Invoke-Uninstall @('-ProfilePath', $prof)
$d = Show $r
Check 'exits 2 (the wrappers are not fully gone)'       ($r.Code -eq 2) $d
Check 'names the file, the line number and the text'    (($r.Text -match 'still mentions Devtools\.psm1, line 2: if \(Test-Path') -and $r.Text.Contains($prof)) $d
Check 'tells you to delete it by hand'                  ($r.Text -match 'Delete it by hand') $d
Check 'does not touch the file'                         (((Get-B64 $prof) -ceq $handB64) -and -not (Test-Path -LiteralPath "$prof.bak")) $d
Check 'still stops the containers'                      ((Get-CallCount '^compose down') -eq 1) (@(Get-Calls) -join ' | ')
Check 'does not say Done'                               (-not ($r.Text -match '(?m)^Done\.')) $d

Write-Host ''
Write-Host '-- nothing to remove'
Reset-Project
$plain = "Set-Alias ll Get-ChildItem`r`n"
Write-Profile $plain
$plainB64 = Get-B64 $prof
$r = Invoke-Uninstall @('-ProfilePath', $prof)
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'says there is nothing to remove, and where it looked' (($r.Text -match 'nothing to remove') -and ($r.Text -match 'looked in: ')) $d
Check 'leaves the profile alone, with no .bak'          (((Get-B64 $prof) -ceq $plainB64) -and -not (Test-Path -LiteralPath "$prof.bak")) $d

Reset-Project
$r = Invoke-Uninstall @('-ProfilePath', $prof)
$d = Show $r
Check 'no profile file: exits 0'                        ($r.Code -eq 0) $d
Check 'no profile file: says so and creates nothing'    (($r.Text -match 'no profile file exists') -and -not (Test-Path -LiteralPath $prof)) $d

Write-Host ''
Write-Host '-- the profile is locked by another program'
Reset-Project
$locked = "Set-Alias ll Get-ChildItem`r`nImport-Module 'C:\x\Devtools.psm1' -Force`r`n"
Write-Profile $locked
$lockedB64 = Get-B64 $prof
$lock = [IO.File]::Open($prof, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { $r = Invoke-Uninstall @('-ProfilePath', $prof) } finally { $lock.Dispose() }
$d = Show $r
Check 'exits 2'                                         ($r.Code -eq 2) $d
Check 'says it could not update the profile'            ($r.Text -match 'Could not update ') $d
Check 'tells you what to delete by hand'                ($r.Text -match 'delete the Import-Module line') $d
Check 'still stops the containers and unloads'          (((Get-CallCount '^compose down') -eq 1) -and ($r.Text -match '2/4')) $d
Check 'does not say Done'                               (-not ($r.Text -match '(?m)^Done\.')) $d
Check 'the profile is unchanged'                        ((Get-B64 $prof) -ceq $lockedB64) $d

Write-Host ''
Write-Host '-- -SkipProfile'
Reset-Project
Write-Profile $locked
$r = Invoke-Uninstall @('-SkipProfile', '-ProfilePath', $prof)
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'leaves the profile alone'                        (((Get-B64 $prof) -ceq $lockedB64) -and -not (Test-Path -LiteralPath "$prof.bak")) $d
Check 'says the step was skipped'                       ($r.Text -match 'skipped \(-SkipProfile\)') $d
Check 'warns that new windows still load the wrappers'  ($r.Text -match 'new PowerShell windows load the wrappers again') $d

# ---- 3. this window -------------------------------------------------------------------------------
Write-Host ''
Write-Host '-- wrappers loaded in the session that runs it'
Reset-Project
$psm1   = (Join-Path $proj 'Devtools.psm1').Replace("'", "''")
$script = (Join-Path $proj 'uninstall.ps1').Replace("'", "''")
$state  = "'STATE before=' + `$b + ' after=' + [bool](Get-Command Get-DevToolsInfo -ErrorAction SilentlyContinue) + ' module=' + [bool](Get-Module Devtools)"
$cmd    = "Import-Module '$psm1' -Force -Global; `$b = [bool](Get-Command Get-DevToolsInfo -ErrorAction SilentlyContinue); " +
          "& '$script' -NoPrompt -SkipProfile; `$c = `$LASTEXITCODE; $state; exit `$c"
$r = Invoke-Ps @('-Command', $cmd)
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'the wrappers were loaded before'                 ($r.Text -match 'STATE before=True') $d
Check 'the wrappers are gone afterwards'                ($r.Text -match 'after=False module=False') $d
Check 'says it unloaded them, from its own process only' ($r.Text -match "(?m)^  OK    unloaded the wrappers from this script's own PowerShell process") $d

Write-Host ''
Write-Host '-- run from a prompt (not in a process of its own)'
Reset-Project
$line1 = "Import-Module '$psm1' -Force"
$line2 = "& '$script' -NoPrompt -SkipProfile"
$r = Invoke-Ps @() @{} '' @($line1, $line2, 'exit $LASTEXITCODE')
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'unloads the wrappers from that window'           ($r.Text -match '(?m)^  OK    unloaded the wrappers: az, kubectl, terraform \.\.\. are the programs installed on this PC again') $d
Check 'says they are gone from this window'             ($r.Text -match 'The wrappers are gone from this window') $d
Check 'does not claim a separate process'               (-not ($r.Text -match 'nothing to unload here')) $d

# ---- 4. Docker: stopping the toolbox ---------------------------------------------------------------
Write-Host ''
Write-Host '-- no container is running'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile')
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'says no container is running'                    ($r.Text -match 'no container is running from devtools:latest') $d
Check 'does not call docker rm'                         ((Get-CallCount '^rm ') -eq 0) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- a container cannot be removed'
Reset-Project
Write-Profile $locked
Set-Containers 'abc123def456', 'fff111eee222'
$r = Invoke-Uninstall @('-ProfilePath', $prof) @{ DOCKER_FAIL_ON = 'rm' }
$d = Show $r
Check 'exits 2'                                         ($r.Code -eq 2) $d
Check 'names the containers that are still there'       ($r.Text -match '2 container\(s\) started from devtools:latest are still there: abc123def456 fff111eee222') $d
Check 'does not say Done'                               (-not ($r.Text -match '(?m)^Done\.')) $d
Check 'the profile was cleaned all the same'            (@(Get-ImportLines).Count -eq 0) $d

Write-Host ''
Write-Host '-- docker compose down fails'
Reset-Project
Set-Containers 'abc123def456'
$r = Invoke-Uninstall @('-SkipProfile') @{ DOCKER_FAIL_ON = 'down' }
$d = Show $r
Check 'exits 0 (the containers are found directly)'     ($r.Code -eq 0) $d
Check 'warns that compose down did not finish'          ($r.Text -match 'WARN  docker compose down did not finish') $d
Check 'still removes the container'                     (($r.Text -match 'stopped and removed 1 container') -and ((Get-CallCount '^rm -f abc123def456$') -eq 1)) $d

Write-Host ''
Write-Host "-- 'docker compose' is missing"
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile') @{ DOCKER_COMPOSE_EXIT = 1 }
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'does not call compose down'                      ((Get-CallCount '^compose down') -eq 0) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- run from a folder without docker-compose.yml'
Reset-Project
Remove-Item -LiteralPath (Join-Path $proj 'docker-compose.yml')
Set-Containers 'abc123def456'
$r = Invoke-Uninstall @('-SkipProfile')
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'does not call compose at all'                    ((Get-CallCount '^compose ') -eq 0) (@(Get-Calls) -join ' | ')
Check 'still removes the container by image'            ((Get-CallCount '^rm -f abc123def456$') -eq 1) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- docker is not installed'
Reset-Project
Write-Profile $locked
$r = Invoke-Uninstall @('-ProfilePath', $prof) -PathOverride $empty
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'says docker was not found, so nothing was checked' (($r.Text -match 'docker was not found') -and ($r.Text -match 'nothing to stop')) $d
Check 'the profile is still cleaned'                    (@(Get-ImportLines).Count -eq 0) $d
Check 'does not call docker at all'                     (@(Get-Calls).Count -eq 0) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- the Docker engine is not running'
Reset-Project
Write-Profile $locked
$r = Invoke-Uninstall @('-ProfilePath', $prof) @{ DOCKER_VERSION_EXIT = 1 }
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'says the engine is not running'                  ($r.Text -match 'engine is not running') $d
Check 'the profile is still cleaned'                    (@(Get-ImportLines).Count -eq 0) $d
Check 'looks for no containers'                         (((Get-CallCount '^ps ') -eq 0) -and ((Get-CallCount '^rm ') -eq 0)) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- Docker is set to Windows containers'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile') @{ DOCKER_SERVER = 'windows/27.0.0' }
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check "says how to switch to Linux containers"          ($r.Text -match 'Switch to Linux containers') $d
Check 'does not claim there is nothing to stop'         (-not ($r.Text -match 'nothing to stop')) $d
Check 'looks for no containers'                         ((Get-CallCount '^ps ') -eq 0) (@(Get-Calls) -join ' | ')

# ---- 5. -RemoveImage --------------------------------------------------------------------------------
Write-Host ''
Write-Host '-- -RemoveImage'
Reset-Project
Set-Containers 'abc123def456'
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveImage')
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'checks the image, then deletes it'               (((Get-CallCount '^image inspect devtools:latest$') -eq 1) -and ((Get-CallCount '^image rm devtools:latest$') -eq 1)) (@(Get-Calls) -join ' | ')
Check 'says it deleted the image'                       ($r.Text -match 'deleted the image devtools:latest') $d
Check 'removes the containers BEFORE the image'         (((Get-CallIndex '^rm -f ') -ge 0) -and ((Get-CallIndex '^rm -f ') -lt (Get-CallIndex '^image rm'))) (@(Get-Calls) -join ' | ')
Check 'does not touch the volume'                       ((Get-CallCount '^volume ') -eq 0) (@(Get-Calls) -join ' | ')
Check 'still says the saved logins were kept'           ($r.Text -match 'kept your saved logins') $d

Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveImage') @{ DOCKER_IMAGE_EXIT = 1 }
$d = Show $r
Check 'image already gone: exits 0'                     ($r.Code -eq 0) $d
Check 'image already gone: says so, deletes nothing'    (($r.Text -match 'the image devtools:latest is not there') -and ((Get-CallCount '^image rm') -eq 0)) $d

Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveImage') @{ DOCKER_FAIL_ON = 'rm' }
$d = Show $r
Check 'delete fails: exits 2'                           ($r.Code -eq 2) $d
Check 'delete fails: says so'                           ($r.Text -match 'Could not delete the image devtools:latest') $d

Reset-Project
Write-Profile $locked
$r = Invoke-Uninstall @('-ProfilePath', $prof, '-RemoveImage') @{ DOCKER_VERSION_EXIT = 1 }
$d = Show $r
Check 'engine down: exits 2'                            ($r.Code -eq 2) $d
Check 'engine down: says the image was not removed and why' (($r.Text -match 'The image devtools:latest was not removed') -and ($r.Text -match 'engine is not running')) $d
Check 'engine down: the profile is cleaned all the same' (@(Get-ImportLines).Count -eq 0) $d

# ---- 6. -RemoveVolume ---------------------------------------------------------------------------------
Write-Host ''
Write-Host '-- -RemoveVolume without -Force and nobody to ask'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveVolume') @{ DOCKER_VOLUMES = $volumesBoth }
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'keeps the volumes and says -Force is needed'     (($r.Text -match 'kept devtools-home and devtools_devtools-home : deleting it needs -Force') -and ((Get-CallCount '^volume rm') -eq 0)) $d

Write-Host ''
Write-Host '-- -RemoveVolume -Force'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveVolume', '-Force') @{ DOCKER_VOLUMES = $volumesBoth }
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'deletes the wrappers volume'                     ((Get-CallCount '^volume rm devtools-home$') -eq 1) (@(Get-Calls) -join ' | ')
Check 'deletes the volume docker compose creates'       ((Get-CallCount '^volume rm devtools_devtools-home$') -eq 1) (@(Get-Calls) -join ' | ')
Check 'says it deleted both'                            (([regex]::Matches($r.Text, '(?m)^  OK    deleted the volume ')).Count -eq 2) $d
Check 'does not touch the image'                        ((Get-CallCount '^image rm') -eq 0) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- -RemoveVolume when only the docker compose volume exists'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveVolume', '-Force') @{ DOCKER_VOLUMES = 'devtools_devtools-home' }
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'looks for both names'                            (((Get-CallCount '^volume inspect devtools-home$') -eq 1) -and ((Get-CallCount '^volume inspect devtools_devtools-home$') -eq 1)) (@(Get-Calls) -join ' | ')
Check 'deletes only the one that exists'                (((Get-CallCount '^volume rm devtools_devtools-home$') -eq 1) -and ((Get-CallCount '^volume rm devtools-home$') -eq 0)) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- -RemoveVolume when there is no volume'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveVolume', '-Force')
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'says there is nothing to delete'                 (($r.Text -match 'no toolbox volume found') -and ((Get-CallCount '^volume rm') -eq 0)) $d

Write-Host ''
Write-Host '-- -RemoveVolume fails'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveVolume', '-Force') @{ DOCKER_VOLUMES = 'devtools-home'; DOCKER_FAIL_ON = 'rm' }
$d = Show $r
Check 'exits 2'                                         ($r.Code -eq 2) $d
Check 'says it could not delete the volume'             ($r.Text -match 'Could not delete the volume devtools-home') $d

Write-Host ''
Write-Host '-- -RemoveVolume with the engine down'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveVolume', '-Force') @{ DOCKER_VERSION_EXIT = 1 }
$d = Show $r
Check 'exits 2'                                         ($r.Code -eq 2) $d
Check 'says the saved logins were not removed and why'  (($r.Text -match 'The saved logins were not removed') -and ($r.Text -match 'engine is not running')) $d

Write-Host ''
Write-Host '-- -RemoveVolume asks, and the answer is yes'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveVolume') @{ DOCKER_VOLUMES = $volumesBoth } -Ask -StdIn @('y')
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'asks about both volumes by name'                 ($r.Text -match 'Delete devtools-home and devtools_devtools-home\?') $d
Check 'deletes them'                                    (((Get-CallCount '^volume rm devtools-home$') -eq 1) -and ((Get-CallCount '^volume rm devtools_devtools-home$') -eq 1)) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- -RemoveVolume asks, and the answer is no'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveVolume') @{ DOCKER_VOLUMES = $volumesBoth } -Ask -StdIn @('n')
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'keeps the volumes'                               (((Get-CallCount '^volume rm') -eq 0) -and ($r.Text -match 'kept devtools-home and devtools_devtools-home')) $d

Write-Host ''
Write-Host '-- -RemoveVolume asks, and nobody answers'
Reset-Project
$r = Invoke-Uninstall @('-SkipProfile', '-RemoveVolume') @{ DOCKER_VOLUMES = $volumesBoth } -Ask -StdIn @()
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'keeps the volumes (no answer is not a yes)'      ((Get-CallCount '^volume rm') -eq 0) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- everything at once'
Reset-Project
Write-Profile $locked
Set-Containers 'abc123def456'
$r = Invoke-Uninstall @('-ProfilePath', $prof, '-RemoveImage', '-RemoveVolume', '-Force') @{ DOCKER_VOLUMES = $volumesBoth }
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'profile cleaned, containers stopped, image and volumes deleted' ((@(Get-ImportLines).Count -eq 0) -and ((Get-CallCount '^rm -f abc123def456$') -eq 1) -and ((Get-CallCount '^image rm devtools:latest$') -eq 1) -and ((Get-CallCount '^volume rm ') -eq 2)) $d
Check 'finishes with Done'                              ($r.Text -match '(?m)^Done\.') $d

# ---- 7. a policy that limits PowerShell --------------------------------------------------------------
Write-Host ''
Write-Host '-- PowerShell is in Constrained Language Mode'
Reset-Project
Write-Profile $locked
$script = (Join-Path $proj 'uninstall.ps1').Replace("'", "''")
$clm = "`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'; & '$script' -NoPrompt -ProfilePath '$($prof.Replace("'", "''"))'; exit `$LASTEXITCODE"
$r = Invoke-Ps @('-Command', $clm)
$d = Show $r
Check 'exits 1'                                         ($r.Code -eq 1) $d
Check 'names the language mode'                         ($r.Text -match 'ConstrainedLanguage') $d
Check 'tells you how to undo the setup by hand'         (($r.Text -match 'docker compose down') -and ($r.Text -match 'Import-Module line')) $d
Check 'changes nothing and calls no docker'             ((@(Get-Calls).Count -eq 0) -and ((Get-B64 $prof) -ceq $lockedB64) -and -not (Test-Path -LiteralPath "$prof.bak")) $d

# ---- 8. where it looks for your profile ----------------------------------------------------------------
# Without -ProfilePath the script looks in the current-user profile folders of this PowerShell and of
# the other edition. Pointing HOME / USERPROFILE / XDG_CONFIG_HOME at a scratch folder moves them
# on Linux and macOS. Where that does not move them (Windows), a GitHub Actions runner, which is
# thrown away after the job, is used for real and put back afterwards.
function Test-DefaultLocations([string] $AllHosts, [hashtable] $EnvVars, [string] $Label) {
    Write-Host ''
    Write-Host "-- default profile locations ($Label)"
    Reset-Project
    $dirCur = Split-Path -Parent $AllHosts
    $up     = Split-Path -Parent $dirCur
    $others = @((Join-Path $dirCur 'Microsoft.PowerShell_profile.ps1'),
                (Join-Path (Join-Path $up 'WindowsPowerShell') 'profile.ps1'),
                (Join-Path (Join-Path $up 'PowerShell') 'profile.ps1'))

    $r = Invoke-Setup @('-SkipBuild', '-SkipVerify') $EnvVars
    $setupLines = @(Get-ImportLines $AllHosts)
    Check 'setup.ps1 puts its line in the all-hosts profile (the starting point)' (($r.Code -eq 0) -and ($setupLines.Count -eq 1) -and ($setupLines[0] -ieq $expectedLine)) (Show $r)

    $targets = @($AllHosts)
    $n = 0
    foreach ($f in $others) {
        if ($targets -contains $f) { continue }       # the same file under another spelling, on Windows
        $n++
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null
        [IO.File]::WriteAllText($f, "Set-Alias keep$n Get-ChildItem`r`nImport-Module 'C:\old place\Devtools.psm1' -Force`r`n")
        $targets += $f
    }

    $r = Invoke-Uninstall @() $EnvVars
    $d = Show $r
    Check 'exits 0'                                     ($r.Code -eq 0) $d
    foreach ($f in $targets) {
        $name = Split-Path -Leaf (Split-Path -Parent $f)
        $name = "$name/" + (Split-Path -Leaf $f)
        # Windows paths are not case sensitive, and the folder may be spelled differently on disk.
        Check "cleans $name"                            ((Test-Path -LiteralPath $f) -and -not (Read-Text $f).Contains('Devtools.psm1') -and ($r.Text.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0)) $d
    }
    Check 'keeps your other lines in the files it cleaned' (@($targets | Where-Object { $_ -ne $AllHosts } | Where-Object { -not (Read-Text $_).Contains('Set-Alias keep') }).Count -eq 0) $d
    Check 'writes a .bak next to each file it changed'  (@($targets | Where-Object { -not (Test-Path -LiteralPath "$_.bak") }).Count -eq 0) $d
}

$home1 = Join-Path $base 'home'
$redirect = @{ HOME = $home1; USERPROFILE = $home1; XDG_CONFIG_HOME = (Join-Path $home1 '.config') }
New-Item -ItemType Directory -Force -Path $home1 | Out-Null
$probe = Invoke-Ps @('-Command', '$PROFILE.CurrentUserAllHosts') $redirect
$redirected = ("$($probe.Text)" -split "`n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 1)
$redirected = "$redirected".Trim()
if ($redirected.StartsWith($home1, [StringComparison]::OrdinalIgnoreCase)) {
    Test-DefaultLocations $redirected $redirect 'a scratch home folder'
} elseif ($env:GITHUB_ACTIONS -eq 'true') {
    # A throw-away machine: use the real profile folders, and put every file back afterwards.
    $real = (Invoke-Ps @('-Command', '$PROFILE.CurrentUserAllHosts')).Text -split "`n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 1
    $real = "$real".Trim()
    $dirCur = Split-Path -Parent $real
    $up     = Split-Path -Parent $dirCur
    $watch  = @($real, (Join-Path $dirCur 'Microsoft.PowerShell_profile.ps1'),
                (Join-Path (Join-Path $up 'WindowsPowerShell') 'profile.ps1'), (Join-Path (Join-Path $up 'PowerShell') 'profile.ps1'),
                (Join-Path (Join-Path $up 'WindowsPowerShell') 'Microsoft.PowerShell_profile.ps1'), (Join-Path (Join-Path $up 'PowerShell') 'Microsoft.PowerShell_profile.ps1'))
    $saved = @{}
    $dirsBefore = @{}
    foreach ($f in $watch) {
        foreach ($p in @($f, "$f.bak")) {
            if (Test-Path -LiteralPath $p) { $saved[$p] = [IO.File]::ReadAllBytes($p) }
        }
        $dirsBefore[(Split-Path -Parent $f)] = (Test-Path -LiteralPath (Split-Path -Parent $f))
    }
    try {
        # Start from a clean slate so that "setup put its line in the all-hosts profile" is a fair check.
        foreach ($f in $watch) { Remove-Item -LiteralPath $f, "$f.bak" -Force -ErrorAction SilentlyContinue }
        Test-DefaultLocations $real @{} 'this runner''s real profile folders'
    } finally {
        foreach ($f in $watch) {
            foreach ($p in @($f, "$f.bak")) {
                if ($saved.ContainsKey($p)) { [IO.File]::WriteAllBytes($p, $saved[$p]) } else { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
            }
        }
        foreach ($dir in @($dirsBefore.Keys)) {
            if (-not $dirsBefore[$dir] -and (Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir -Force }
        }
    }
} else {
    Write-Host ''
    Write-Host "SKIP  default profile locations: this PowerShell ignores HOME / USERPROFILE here ($redirected), and this is not a throw-away runner"
}

# ---- done ----------------------------------------------------------------------------------------------
Set-Location $root
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
Remove-FakeDocker $fakebin
Write-Host ''
# Always finish with an explicit exit code (see the end of tests/Test-Devtools.ps1).
if ($script:failures -eq 0) {
    Write-Host "ALL UNINSTALL TESTS PASSED ($($script:passes) checks)"
    exit 0
}
Write-Host "$($script:failures) UNINSTALL TEST(S) FAILED"
exit 1
