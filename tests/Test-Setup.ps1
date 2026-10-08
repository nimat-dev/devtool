#Requires -Version 5.1
<#
    Tests for setup.ps1. Every scenario copies the project into a scratch folder (its name has a
    space in it on purpose), runs setup.ps1 there in a child PowerShell against a fake `docker`,
    and checks the exit code, the output, the docker calls it made and the profile file it wrote.
    No Docker daemon is needed. Works in Windows PowerShell 5.1, in PowerShell 7 on Windows, and
    in PowerShell 7 on Linux and macOS:

        pwsh -NoProfile -File tests/Test-Setup.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Setup.ps1

    The fake docker and its knobs are described in tests/FakeDocker.ps1 and tests/fakebin/docker.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root  = Split-Path -Parent $PSScriptRoot
$base  = Join-Path ([IO.Path]::GetTempPath()) "devtools-setup-test-$PID"
$proj  = Join-Path $base 'my project'                          # a space on purpose
$bare  = Join-Path $base 'bare'                                # a folder that is not the project
$empty = Join-Path $base 'empty'                               # a PATH that has no docker on it
$prof  = Join-Path (Join-Path $base 'profile dir') 'profile.ps1'   # its folder does not exist yet
$log   = Join-Path $base 'docker.log'
New-Item -ItemType Directory -Force -Path $base, $empty | Out-Null

. (Join-Path $PSScriptRoot 'FakeDocker.ps1')
$fakebin = Install-FakeDocker
$env:DOCKER_ARGS_FILE   = Join-Path $base 'last-args.txt'
$env:DOCKER_LOG_FILE    = $log       # every docker call is appended here
$env:DOCKER_FAKE_OUTPUT = '1'        # `docker run` prints a line, like a tool printing its version

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

$knobNames = 'DOCKER_FAIL_ON', 'DOCKER_SERVER', 'DOCKER_VERSION_EXIT', 'DOCKER_COMPOSE_EXIT',
         'DOCKER_BUILD_EXIT', 'DOCKER_IMAGE_EXIT', 'DOCKER_FORCE_EXIT'

# Fresh copy of the project, no profile, no docker history.
function Reset-Project {
    Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Split-Path -Parent $prof) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $proj 'certs') | Out-Null
    foreach ($f in 'setup.ps1', 'Devtools.psm1', 'Dockerfile', 'docker-compose.yml', '.env.example') {
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination $proj
    }
}

# Run setup.ps1 from $Dir in a child PowerShell. $Knobs sets fake-docker variables for this run only.
function Invoke-Setup {
    param(
        [string[]]  $Arguments = @(),
        [hashtable] $Knobs = @{},
        [string]    $Dir = $proj,
        [string]    $PathOverride,
        [switch]    $ConstrainedLanguage
    )
    foreach ($n in $knobNames) { [Environment]::SetEnvironmentVariable($n, $null) }
    foreach ($k in $Knobs.Keys) { [Environment]::SetEnvironmentVariable($k, [string] $Knobs[$k]) }
    $psArgs = @('-NoProfile')
    if ($isWin) { $psArgs += @('-ExecutionPolicy', 'Bypass') }
    if ($ConstrainedLanguage) {
        # What a security policy does to a whole session: switch it to Constrained Language Mode
        # first, then run the script in it.
        $quoted = @($Arguments | ForEach-Object { if ("$_" -like '-*') { "$_" } else { "'" + "$_".Replace("'", "''") + "'" } }) -join ' '
        $script = (Join-Path $Dir 'setup.ps1').Replace("'", "''")
        $psArgs += @('-Command', "`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'; & '$script' -NoPrompt $quoted; exit `$LASTEXITCODE")
    } else {
        $psArgs += @('-File', (Join-Path $Dir 'setup.ps1'), '-NoPrompt')
        $psArgs += $Arguments
    }

    $savedPath = $env:PATH
    $savedPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'      # Windows PowerShell 5.1 turns native stderr into errors under 'Stop'
    try {
        if ($PathOverride) { $env:PATH = $PathOverride }
        $lines = @(& $psExe @psArgs 2>&1 | ForEach-Object { "$_" })
        $code  = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPref
        $env:PATH = $savedPath
        foreach ($n in $knobNames) { [Environment]::SetEnvironmentVariable($n, $null) }
    }
    return [pscustomobject]@{ Code = $code; Text = ($lines -join "`n") }
}

function Get-Calls { if (Test-Path -LiteralPath $log) { return @(Get-Content -LiteralPath $log) } else { return @() } }
function Get-CallCount([string] $Pattern) { return @(@(Get-Calls) | Where-Object { $_ -match $Pattern }).Count }
function Get-ImportLines {
    if (-not (Test-Path -LiteralPath $prof)) { return @() }
    return @(Get-Content -LiteralPath $prof | Where-Object { $_ -match '^\s*Import-Module\b.*Devtools\.psm1' })
}
function Read-Text([string] $Path) { return "$(Get-Content -LiteralPath $Path -Raw)" }
function Show($r) { return "exit $($r.Code); output tail:`n      " + ((@($r.Text -split "`n") | Select-Object -Last 14) -join "`n      ") }

$expectedLine = "Import-Module '{0}' -Force" -f (Join-Path $proj 'Devtools.psm1')

# ---- the script itself --------------------------------------------------------------------------
$setupFile = Join-Path $root 'setup.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($setupFile, [ref] $tokens, [ref] $parseErrors)
Check 'setup.ps1 parses with zero syntax errors' (@($parseErrors).Count -eq 0)
foreach ($f in 'setup.ps1', 'Devtools.psm1') {
    # Windows PowerShell 5.1 reads a file without a byte-order mark as ANSI, so keep both ASCII.
    $bytes = [IO.File]::ReadAllBytes((Join-Path $root $f))
    Check "$f is ASCII only" (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0)
}
$help = Read-Text $setupFile
foreach ($p in @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })) {
    Check "parameter -$p is documented in the help comment" ($help -match "(?m)^\.PARAMETER\s+$p\b")
}

# ---- 1. first run, everything works -------------------------------------------------------------
Write-Host ''
Write-Host '-- first run'
Reset-Project
[IO.File]::WriteAllText((Join-Path (Join-Path $proj 'certs') 'corp.crt'), 'not a real certificate')
$r = Invoke-Setup @('-ProfilePath', $prof)
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'prints all six steps in order'                   ($r.Text -match '(?s)1/6.*2/6.*3/6.*4/6.*5/6.*6/6') $d
Check 'says Docker is running with Linux containers'    ($r.Text -match 'Docker engine .*Linux containers') $d
Check 'creates .env from .env.example'                  ((Test-Path -LiteralPath (Join-Path $proj '.env')) -and
                                                         ((Read-Text (Join-Path $proj '.env')) -ceq (Read-Text (Join-Path $proj '.env.example')))) $d
Check 'notices the corporate CA certificate in certs'   ($r.Text -match '1 corporate CA certificate') $d
Check 'builds once with docker compose build'           ((Get-CallCount '^compose build$') -eq 1) (@(Get-Calls) -join ' | ')
Check 'does not fall back to docker build'              ((Get-CallCount '^build ') -eq 0)
Check 'creates the profile, and the folder it lives in' (Test-Path -LiteralPath $prof) $d
Check 'puts exactly one Import-Module line in it'       (@(Get-ImportLines).Count -eq 1) (@(Get-ImportLines) -join ' | ')
Check 'that line points at the project folder'          ((@(Get-ImportLines) | Select-Object -First 1) -ieq $expectedLine) "expected: $expectedLine"
$tools = @(
    @('az', '--version'), @('kubectl', 'version', '--client'), @('terraform', 'version'),
    @('helm', 'version', '--short'), @('flux', '--version'), @('kustomize', 'version'),
    @('azd', 'version'), @('gh', '--version'), @('kubectx', '-h'), @('kubens', '-h')
)
foreach ($t in $tools) {
    $cmd = $t -join ' '
    Check "verifies '$cmd' in the container" ((Get-CallCount ('^run .* devtools:latest ' + [regex]::Escape($cmd) + '$')) -eq 1) (@(Get-Calls) -join ' | ')
}
Check 'reports every tool as OK'                        (([regex]::Matches($r.Text, '(?m)^  OK    (az|kubectl|terraform|helm|flux|kustomize|azd|gh|kubectx|kubens)\s')).Count -eq 10) $d
Check 'finishes with All set'                           ($r.Text -match 'All set') $d
Check 'tells you to open a new window (it ran with -File)' ($r.Text -match 'Open a NEW PowerShell window') $d
Check 'does not offer the optional steps with -NoPrompt' (-not ($r.Text -match 'Azure login|Docker Desktop Kubernetes')) $d

# ---- 2. second run: nothing is duplicated, nothing of yours is overwritten ------------------------
Write-Host ''
Write-Host '-- second run'
$profileBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($prof))
[IO.File]::AppendAllText((Join-Path $proj '.env'), "`n# my own setting`n")
Remove-Item -LiteralPath $log -Force
$r = Invoke-Setup @('-SkipBuild', '-SkipVerify', '-ProfilePath', $prof)
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'leaves the profile exactly as it was (byte for byte)' (([Convert]::ToBase64String([IO.File]::ReadAllBytes($prof))) -ceq $profileBefore) $d
Check 'still has exactly one Import-Module line'        (@(Get-ImportLines).Count -eq 1)
Check 'says the profile is already set up'              ($r.Text -match 'already set up') $d
Check 'keeps your edited .env'                          ((Read-Text (Join-Path $proj '.env')) -match '# my own setting') $d
Check '-SkipBuild: no build, only checks the image exists' (((Get-CallCount '^(compose )?build') -eq 0) -and ((Get-CallCount '^image inspect devtools:latest$') -eq 1)) (@(Get-Calls) -join ' | ')
Check '-SkipVerify: no tool is run'                     ((Get-CallCount '^run ') -eq 0) (@(Get-Calls) -join ' | ')

# ---- 3. the project moved: the old profile line is replaced, the rest is kept --------------------
Write-Host ''
Write-Host '-- project folder moved'
Reset-Project
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $prof) | Out-Null
$e = [string][char]0xE9
$old = "# my profile (caf$e)`r`nSet-Alias ll Get-ChildItem`r`nImport-Module 'C:\old place\Devtools.psm1' -Force`r`n`$x = 1`r`n"
[IO.File]::WriteAllText($prof, $old, (New-Object System.Text.UTF8Encoding $true))
$r = Invoke-Setup @('-SkipBuild', '-SkipVerify', '-ProfilePath', $prof)
$d = Show $r
$new = Read-Text $prof
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'replaces the old line with the new folder'       ($new.Contains($expectedLine) -and -not $new.Contains('C:\old place')) $new
Check 'leaves exactly one Import-Module line'           (@(Get-ImportLines).Count -eq 1)
Check 'keeps your other profile lines'                  ($new.Contains('Set-Alias ll Get-ChildItem') -and $new.Contains('$x = 1')) $new
Check 'keeps non-ASCII text in the profile'             ($new.Contains("caf$e")) $new
Check 'keeps the Windows line endings'                  ($new.Contains("`r`n") -and -not ($new -match "(?<!`r)`n")) $new
Check 'saves a .bak copy of the old profile'            ((Test-Path -LiteralPath "$prof.bak") -and (Read-Text "$prof.bak").Contains('C:\old place')) $d
Check 'writes UTF-8 with a byte-order mark (5.1 reads it right)' ((([IO.File]::ReadAllBytes($prof))[0]) -eq 0xEF) $d

Write-Host ''
Write-Host '-- project folder moved, and the old line was typed by hand'
Reset-Project
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $prof) | Out-Null
[IO.File]::WriteAllText($prof, "import-module 'c:\old place\devtools.psm1' -force`r`n`$y = 2`r`n")
$r = Invoke-Setup @('-SkipBuild', '-SkipVerify', '-ProfilePath', $prof)
$d = Show $r
$new = Read-Text $prof
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'replaces a lowercase import-module line too'     ($new.Contains($expectedLine) -and -not $new.Contains('old place')) $new
Check 'leaves exactly one Import-Module line'           (@(Get-ImportLines).Count -eq 1) $new
Check 'keeps your other profile line'                   ($new.Contains('$y = 2')) $new

Reset-Project
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $prof) | Out-Null
[IO.File]::WriteAllText($prof, "ipmo C:\old\Devtools.psm1`r`n")
$r = Invoke-Setup @('-SkipBuild', '-SkipVerify', '-ProfilePath', $prof)
$new = Read-Text $prof
Check 'replaces an ipmo line too'                       (($r.Code -eq 0) -and $new.Contains($expectedLine) -and -not ($new -match 'ipmo')) $new

# ---- 4. things that must stop the script before it changes anything ------------------------------
Write-Host ''
Write-Host '-- Docker not running'
Reset-Project
$r = Invoke-Setup @('-ProfilePath', $prof) @{ DOCKER_VERSION_EXIT = 1 }
$d = Show $r
Check 'exits 1'                                         ($r.Code -eq 1) $d
Check 'says the engine is not running'                  ($r.Text -match 'engine is not running') $d
Check 'builds nothing, runs nothing'                    (((Get-CallCount '^compose build') -eq 0) -and ((Get-CallCount '^run ') -eq 0)) (@(Get-Calls) -join ' | ')
Check 'creates neither .env nor a profile'              (-not (Test-Path -LiteralPath (Join-Path $proj '.env')) -and -not (Test-Path -LiteralPath $prof)) $d

Write-Host ''
Write-Host '-- Docker set to Windows containers'
Reset-Project
$r = Invoke-Setup @('-ProfilePath', $prof) @{ DOCKER_SERVER = 'windows/27.0.0' }
$d = Show $r
Check 'exits 1'                                         ($r.Code -eq 1) $d
Check "says how to switch to Linux containers"          ($r.Text -match 'Switch to Linux containers') $d
Check 'builds nothing'                                  ((Get-CallCount '^compose build') -eq 0) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- docker is not installed'
Reset-Project
$r = Invoke-Setup @('-ProfilePath', $prof) -PathOverride $empty
$d = Show $r
Check 'exits 1'                                         ($r.Code -eq 1) $d
Check 'says docker was not found'                       ($r.Text -match 'docker was not found') $d

Write-Host ''
Write-Host '-- run from a folder that is not the project'
New-Item -ItemType Directory -Force -Path $bare | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'setup.ps1') -Destination $bare -Force
Copy-Item -LiteralPath (Join-Path $root 'Devtools.psm1') -Destination $bare -Force
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
$r = Invoke-Setup @('-ProfilePath', $prof) -Dir $bare
$d = Show $r
Check 'exits 1'                                         ($r.Code -eq 1) $d
Check 'says it cannot find the Dockerfile'              ($r.Text -match 'Cannot find Dockerfile') $d
Check 'does not call docker at all'                     (@(Get-Calls).Count -eq 0) (@(Get-Calls) -join ' | ')

# ---- 5. build problems ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- the build fails'
Reset-Project
$r = Invoke-Setup @('-ProfilePath', $prof) @{ DOCKER_BUILD_EXIT = 1 }
$d = Show $r
Check 'exits 1'                                         ($r.Code -eq 1) $d
Check 'says the build failed'                           ($r.Text -match 'image build failed') $d
Check 'points at certs\ and the proxy settings'         (($r.Text -match 'certs') -and ($r.Text -match 'HTTPS_PROXY')) $d
Check 'does not touch the profile or run any tool'      (-not (Test-Path -LiteralPath $prof) -and ((Get-CallCount '^run ') -eq 0)) $d

Write-Host ''
Write-Host "-- 'docker compose' is missing"
Reset-Project
$r = Invoke-Setup @('-ProfilePath', $prof) @{ DOCKER_COMPOSE_EXIT = 1 }
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'warns that compose is not available'             ($r.Text -match "'docker compose' is not available") $d
Check 'builds with plain docker build -t devtools:latest .' ((Get-CallCount '^build -t devtools:latest \.$') -eq 1) (@(Get-Calls) -join ' | ')
Check 'does not call compose build'                     ((Get-CallCount '^compose build') -eq 0) (@(Get-Calls) -join ' | ')

Write-Host ''
Write-Host '-- -SkipBuild but the image is missing'
Reset-Project
$r = Invoke-Setup @('-SkipBuild', '-ProfilePath', $prof) @{ DOCKER_IMAGE_EXIT = 1 }
$d = Show $r
Check 'exits 1'                                         ($r.Code -eq 1) $d
Check 'says the image does not exist yet'               ($r.Text -match 'does not exist yet') $d
Check 'builds nothing'                                  (((Get-CallCount '^compose build') -eq 0) -and ((Get-CallCount '^build ') -eq 0)) (@(Get-Calls) -join ' | ')

# ---- 6. one tool is broken ----------------------------------------------------------------------
Write-Host ''
Write-Host '-- one tool fails its check'
Reset-Project
$r = Invoke-Setup @('-ProfilePath', $prof) @{ DOCKER_FAIL_ON = 'terraform' }
$d = Show $r
Check 'exits 2 (set up, but a check failed)'            ($r.Code -eq 2) $d
Check 'names the broken tool'                           ($r.Text -match '(?m)^  FAIL  terraform') $d
Check 'still checks the tools after it'                 ($r.Text -match '(?m)^  OK    kubens') $d
Check 'counts the failure'                              ($r.Text -match '1 problem\(s\)') $d
Check 'the profile was still set up'                    (@(Get-ImportLines).Count -eq 1) $d
Check 'does not say All set'                            (-not ($r.Text -match 'All set')) $d

Write-Host ''
Write-Host '-- the profile cannot be written'
Reset-Project
$blocker = Join-Path $base 'a file'                  # a FILE where the profile's folder should be
[IO.File]::WriteAllText($blocker, 'x')
$r = Invoke-Setup @('-SkipBuild', '-ProfilePath', (Join-Path $blocker 'profile.ps1'))
$d = Show $r
Check 'exits 2 (the rest is set up, the profile is not)' ($r.Code -eq 2) $d
Check 'says it could not update the profile'            ($r.Text -match 'Could not update your profile') $d
Check 'shows the line to add by hand'                   ($r.Text.Contains($expectedLine)) $d
Check 'still loads the wrappers and checks the tools'   (($r.Text -match '(?m)^  OK    kubens') -and -not ($r.Text -match 'All set')) $d

Write-Host ''
Write-Host '-- PowerShell is in Constrained Language Mode'
Reset-Project
$r = Invoke-Setup @('-ProfilePath', $prof) -ConstrainedLanguage
$d = Show $r
Check 'exits 1'                                         ($r.Code -eq 1) $d
Check 'names the language mode'                         ($r.Text -match 'ConstrainedLanguage') $d
Check 'points at docker compose run --rm dev'           ($r.Text -match 'docker compose run --rm dev') $d
Check 'changes nothing and calls no docker'             ((@(Get-Calls).Count -eq 0) -and -not (Test-Path -LiteralPath (Join-Path $proj '.env')) -and -not (Test-Path -LiteralPath $prof)) $d

# ---- 7. flags ----------------------------------------------------------------------------------
Write-Host ''
Write-Host '-- -SkipProfile'
Reset-Project
$r = Invoke-Setup @('-SkipProfile', '-SkipVerify', '-ProfilePath', $prof)
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'does not create the profile'                     (-not (Test-Path -LiteralPath $prof)) $d
Check 'shows the Import-Module line to run by hand'     ($r.Text.Contains($expectedLine)) $d

Write-Host ''
Write-Host '-- -Login and -ImportKube'
Reset-Project
$r = Invoke-Setup @('-SkipVerify', '-Login', '-ImportKube', '-ProfilePath', $prof)
$d = Show $r
Check 'exits 0'                                         ($r.Code -eq 0) $d
Check 'runs az login --use-device-code in the container' ((Get-CallCount '^run .* devtools:latest az login --use-device-code$') -eq 1) (@(Get-Calls) -join ' | ')
# With no kubeconfig on this machine the import only warns; with one it runs the importer.
Check 'tries the Docker Desktop Kubernetes import'      (($r.Text -match 'No kubeconfig') -or ((Get-CallCount 'devtools:latest import-docker-desktop-kube docker-desktop$') -eq 1)) $d

Write-Host ''
Write-Host '-- -Login fails'
Reset-Project
$r = Invoke-Setup @('-SkipVerify', '-Login', '-ProfilePath', $prof) @{ DOCKER_FAIL_ON = 'login' }
$d = Show $r
Check 'still exits 0 (the optional steps never fail the setup)' ($r.Code -eq 0) $d
Check 'says the login did not finish'                   ($r.Text -match 'login did not finish') $d

# ---- done ---------------------------------------------------------------------------------------
Set-Location $root
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
Remove-FakeDocker $fakebin
Write-Host ''
# Always finish with an explicit exit code (see the end of tests/Test-Devtools.ps1).
if ($script:failures -eq 0) {
    Write-Host "ALL SETUP TESTS PASSED ($($script:passes) checks)"
    exit 0
}
Write-Host "$($script:failures) SETUP TEST(S) FAILED"
exit 1
