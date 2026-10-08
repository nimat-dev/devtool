#Requires -Version 5.1
<#
.SYNOPSIS
    Stops the DevOps toolbox and removes its PowerShell wrappers. The undo for setup.ps1.

.DESCRIPTION
    From the project folder (no admin rights needed), in the PowerShell window you use the tools in:

        .\uninstall.ps1

    or, if scripts are blocked on this machine:

        powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1

    1  removes the Import-Module line from your PowerShell profile (a .bak copy is kept)
    2  unloads the wrappers from this window, so az, kubectl, terraform ... are the programs
       installed on this PC again (or "not recognized" when there are none)
    3  stops and removes the toolbox containers: docker compose down, then anything still running
       from the image, such as a "dev" shell open in another window
    4  only when you ask: deletes the image and/or the volume that holds your saved logins

    The image takes minutes to build and the volume holds your Azure, GitHub and Kubernetes
    logins, so both are KEPT unless you pass -RemoveImage / -RemoveVolume. The project folder and
    .env are never touched. Run setup.ps1 to put everything back.

    Safe to run again at any time. It works without Docker running: the profile and this window
    are cleaned first. Only the default names are handled (image devtools:latest, volumes
    devtools-home and devtools_devtools-home), not ones you chose with DEVTOOLS_IMAGE or
    DEVTOOLS_VOLUME.
    Exit code: 0 done, 1 could not run, 2 finished but something above failed.

.PARAMETER RemoveImage   Also delete the image devtools:latest (setup.ps1 builds it again).
.PARAMETER RemoveVolume  Also delete the volume with your saved logins. Asks first.
.PARAMETER Force         Do not ask before deleting the volume.
.PARAMETER SkipProfile   Do not touch your PowerShell profile (new windows then load the wrappers again).
.PARAMETER NoPrompt      Never ask a question (for automation). The volume is then deleted only with -Force.
.PARAMETER ProfilePath   Profile file to clean instead of looking for yours.
#>
[CmdletBinding()]
param(
    [switch] $RemoveImage,
    [switch] $RemoveVolume,
    [switch] $Force,
    [switch] $SkipProfile,
    [switch] $NoPrompt,
    [string] $ProfilePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
$image    = 'devtools:latest'
$volumes  = @('devtools-home', 'devtools_devtools-home')    # the wrappers' volume, and the one docker compose makes
$problems = 0

# What setup.ps1 puts in the profile. Keep these in step with setup.ps1 (the tests check it).
$markerComment = '# DevOps toolbox: az, kubectl, terraform, helm, flux ... run in Docker'
$rxImport  = '(?mi)^[ \t]*(?:Import-Module|ipmo)\b[^\r\n]*Devtools\.psm1[^\r\n]*(?:\r?\n|\z)'
$rxComment = '(?mi)(?:^[ \t]*\r?\n)?^[ \t]*' + [regex]::Escape($markerComment) + '[ \t]*(?:\r?\n|\z)'

# ---- output helpers --------------------------------------------------------------------------
function Write-Step([string] $Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string] $Text)   { Write-Host "  OK    $Text" -ForegroundColor Green }
function Write-Warn([string] $Text) { Write-Host "  WARN  $Text" -ForegroundColor Yellow }
function Write-Fail([string] $Text) { Write-Host "  FAIL  $Text" -ForegroundColor Red }
function Write-Info([string] $Text) { Write-Host "        $Text" }

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

# The first line a failed command printed, shortened, for the line under a FAIL or WARN.
function Get-FirstLine($Result) {
    $first = @($Result.Output | Where-Object { "$_".Trim().Length -gt 0 }) | Select-Object -First 1
    if (-not $first) { return "exit code $($Result.ExitCode)" }
    $t = "$first".Trim()
    if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
    return $t
}

# True when this script runs in a PowerShell process of its own ("powershell -File uninstall.ps1"):
# it then cannot unload anything from the window it was started from. False when it was started
# from a prompt as .\uninstall.ps1.
function Test-OwnProcess {
    foreach ($a in @([Environment]::GetCommandLineArgs() | Select-Object -Skip 1)) {
        if ("$a" -match '^[-/](.+)$') {
            $n = $Matches[1].ToLowerInvariant()
            if ('file'.StartsWith($n) -or 'command'.StartsWith($n) -or 'encodedcommand'.StartsWith($n)) { return $true }
        }
    }
    return $false
}

# Every profile file that might hold the Import-Module line. A file named with -ProfilePath is used
# on its own. Otherwise: the current-user profiles of this PowerShell and of the other edition
# (Windows PowerShell 5.1 and PowerShell 7 keep theirs in sibling folders), whichever host they are for.
function Get-ProfileFiles {
    if ($ProfilePath) {
        return @($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProfilePath))
    }
    $all  = $PROFILE.CurrentUserAllHosts
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add($all)
    $list.Add($PROFILE.CurrentUserCurrentHost)
    $here = Split-Path -Parent $all
    $up   = Split-Path -Parent $here
    foreach ($dir in @($here, (Join-Path $up 'WindowsPowerShell'), (Join-Path $up 'PowerShell'))) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*profile.ps1' })) {
                $list.Add($f.FullName)
            }
        }
    }
    $seen = @{}
    $out  = @()
    foreach ($p in $list) {
        if ($p -and -not $seen.ContainsKey("$p".ToLowerInvariant())) {
            $seen["$p".ToLowerInvariant()] = $true
            $out += $p
        }
    }
    return $out
}

# Remove the toolbox lines from one profile file and report what happened. Everything else in the
# file stays exactly as it was, byte for byte: line endings, other lines, accents, and the
# byte-order mark. That is done on the raw bytes. Latin-1 maps every byte to one character and back,
# so UTF-8 (with or without a mark) and ANSI text pass through untouched; only UTF-16 needs decoding.
function Remove-ToolboxLines([string] $File) {
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $enc    = $latin1
    $bytes  = [IO.File]::ReadAllBytes($File)
    $mark   = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $mark = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $mark = 2
        $enc  = [System.Text.Encoding]::Unicode
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $mark = 2
        $enc  = [System.Text.Encoding]::BigEndianUnicode
    }
    $text = $enc.GetString($bytes, $mark, $bytes.Length - $mark)

    # To show a line to the user: undo the Latin-1 reading, so that an accent in a path looks right.
    $show = { param([string] $s) if ($enc -eq $latin1) { [System.Text.Encoding]::UTF8.GetString($latin1.GetBytes($s)) } else { $s } }

    $removed = @([regex]::Matches($text, $rxImport) | ForEach-Object { & $show $_.Value.Trim() })
    $updated = [regex]::Replace([regex]::Replace($text, $rxImport, ''), $rxComment, '')
    $changed = ($updated -cne $text)
    if ($changed) {
        Copy-Item -LiteralPath $File -Destination "$File.bak" -Force
        $body = $enc.GetBytes($updated)
        $out  = New-Object 'byte[]' ($mark + $body.Length)
        [Array]::Copy($bytes, 0, $out, 0, $mark)
        [Array]::Copy($body, 0, $out, $mark, $body.Length)
        [IO.File]::WriteAllBytes($File, $out)
    }

    # A line this cleanup does not recognise (an "if (...) { Import-Module ... }" you wrote yourself).
    $left = @()
    $n    = 0
    foreach ($line in @($updated -split "`r?`n")) {
        $n++
        if ($line -match 'Devtools\.psm1' -and $line.TrimStart() -notmatch '^#') { $left += ('line {0}: {1}' -f $n, (& $show $line.Trim())) }
    }
    return [pscustomobject]@{ Changed = $changed; Removed = $removed; Left = $left }
}

Write-Host "DevOps toolbox uninstall  ($root)" -ForegroundColor Cyan

# A security policy can put PowerShell in Constrained Language Mode. This script uses .NET calls
# that mode blocks, so say so plainly instead of failing with an obscure error.
$languageMode = "$($ExecutionContext.SessionState.LanguageMode)"
if ($languageMode -ne 'FullLanguage') {
    Write-Fail "PowerShell is running in $languageMode mode here (a security policy on this machine)."
    Write-Info 'This script needs FullLanguage mode. To undo the setup by hand:'
    Write-Info '    docker compose down                 stops the toolbox'
    Write-Info '    notepad $PROFILE.CurrentUserAllHosts   delete the Import-Module line that mentions Devtools.psm1'
    exit 1
}

# ---- 1. PowerShell profile -------------------------------------------------------------------
Write-Step '1/4  PowerShell profile'
if ($SkipProfile) {
    Write-Info 'skipped (-SkipProfile): new PowerShell windows will still load the wrappers'
} else {
    $before  = $problems
    $files   = @()
    $cleaned = 0
    try {
        $files = @(Get-ProfileFiles | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    } catch {
        Write-Fail "Could not work out where your PowerShell profile is: $($_.Exception.Message)"
        $problems++
    }
    foreach ($file in $files) {
        try {
            $res = Remove-ToolboxLines $file
            if ($res.Changed) {
                $cleaned++
                Write-Ok "cleaned $file"
                foreach ($l in $res.Removed) { Write-Info "removed: $l" }
                Write-Info "backup:  $file.bak"
            }
            foreach ($l in $res.Left) {
                Write-Warn "$file still mentions Devtools.psm1, $l"
                Write-Info 'It is not a plain Import-Module line, so it was left alone. Delete it by hand.'
                $problems++
            }
        } catch {
            # Locked-down machines: a read-only or redirected Documents folder, Controlled Folder Access ...
            Write-Fail "Could not update $file : $($_.Exception.Message)"
            Write-Info 'Open it in Notepad and delete the Import-Module line that mentions Devtools.psm1.'
            $problems++
        }
    }
    if ($cleaned -eq 0 -and $problems -eq $before) {
        Write-Ok 'no toolbox line in your PowerShell profile, nothing to remove'
        if ($files.Count -eq 0) { Write-Info 'no profile file exists' }
        foreach ($file in $files) { Write-Info "looked in: $file" }
    }
}

# ---- 2. This window --------------------------------------------------------------------------
Write-Step '2/4  This PowerShell window'
$isToolbox = { $_.Path -and ((Split-Path -Leaf $_.Path) -ieq 'Devtools.psm1') }
$loaded    = @(Get-Module | Where-Object $isToolbox)
if ($loaded.Count -eq 0) {
    if (Test-OwnProcess) {
        Write-Info 'nothing to unload here: this script runs in a PowerShell process of its own'
    } else {
        Write-Info 'the wrappers were not loaded in this window'
    }
} else {
    try {
        $loaded | Remove-Module -Force
        if (@(Get-Module | Where-Object $isToolbox).Count -gt 0) { throw 'the module is still loaded' }
        if (Test-OwnProcess) {
            # The profile loaded them into this script's own process; the window it was started from is not affected.
            Write-Ok "unloaded the wrappers from this script's own PowerShell process"
        } else {
            Write-Ok 'unloaded the wrappers: az, kubectl, terraform ... are the programs installed on this PC again'
        }
    } catch {
        Write-Fail "Could not unload the wrappers: $($_.Exception.Message)"
        $problems++
    }
}

# ---- 3. Stop the toolbox ---------------------------------------------------------------------
Write-Step '3/4  Stop the toolbox'
$docker      = ''
$dockerReady = $false
$dockerWhy   = ''
$dockerHint  = 'The toolbox only runs inside Docker, so there is nothing to stop.'
$dockerCmd = Get-Command 'docker.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dockerCmd) {
    $dockerCmd = Get-Command 'docker' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $dockerCmd) {
    $dockerWhy = 'docker was not found on PATH'
} else {
    $docker = $dockerCmd.Source
    $r = Invoke-Quiet $docker @('version', '--format', '{{.Server.Os}}/{{.Server.Version}}')
    $engine = @($r.Output | Where-Object { $_ -match '^\w+/\S+$' }) | Select-Object -First 1
    if ($r.ExitCode -ne 0 -or -not $engine) {
        $dockerWhy = 'the Docker engine is not running'
    } elseif (("$engine" -split '/', 2)[0] -ne 'linux') {
        # The Linux engine can still be running behind it, so do not claim there is nothing to stop.
        $dockerWhy  = 'Docker is set to Windows containers (the toolbox is a Linux image)'
        $dockerHint = "Right-click the Docker Desktop tray icon, choose 'Switch to Linux containers' and run this again."
    } else {
        $dockerReady = $true
    }
}

function Get-ToolboxContainers {
    $r = Invoke-Quiet $docker @('ps', '-aq', '--filter', "ancestor=$image")
    return @($r.Output | Where-Object { $_ -match '^[0-9a-f]{12,64}$' })
}

if (-not $dockerReady) {
    Write-Warn "$dockerWhy, so no containers were checked."
    Write-Info $dockerHint
} else {
    $composeFile = Join-Path $root 'docker-compose.yml'
    if ((Test-Path -LiteralPath $composeFile) -and ((Invoke-Quiet $docker @('compose', 'version')).ExitCode -eq 0)) {
        Push-Location -LiteralPath $root
        try { $r = Invoke-Quiet $docker @('compose', 'down', '--remove-orphans') } finally { Pop-Location }
        if ($r.ExitCode -eq 0) {
            Write-Ok 'docker compose down'
        } else {
            Write-Warn "docker compose down did not finish: $(Get-FirstLine $r)"
        }
    }

    # Anything still started from the image: a "dev" shell, a port-forward, a tool that is mid-run.
    $ids = @(Get-ToolboxContainers)
    if ($ids.Count -eq 0) {
        Write-Ok "no container is running from $image"
    } else {
        $null = Invoke-Quiet $docker (@('rm', '-f') + $ids)    # stops and removes; judged by what is left, not by the exit code
        $left = @(Get-ToolboxContainers)
        if ($left.Count -eq 0) {
            Write-Ok "stopped and removed $($ids.Count) container(s) started from $image"
        } else {
            Write-Fail "$($left.Count) container(s) started from $image are still there: $($left -join ' ')"
            Write-Info 'Stop them in Docker Desktop (Containers) and run this again.'
            $problems++
        }
    }
}

# ---- 4. Image and saved logins ---------------------------------------------------------------
Write-Step '4/4  Image and saved logins'
if ($RemoveImage) {
    if (-not $dockerReady) {
        Write-Fail "The image $image was not removed: $dockerWhy. Start Docker Desktop and run this again with -RemoveImage."
        $problems++
    } elseif ((Invoke-Quiet $docker @('image', 'inspect', $image)).ExitCode -ne 0) {
        Write-Ok "the image $image is not there"
    } else {
        $r = Invoke-Quiet $docker @('image', 'rm', $image)
        if ($r.ExitCode -eq 0) {
            Write-Ok "deleted the image $image"
        } else {
            Write-Fail "Could not delete the image $image : $(Get-FirstLine $r)"
            $problems++
        }
    }
} else {
    Write-Info "kept the image $image (setup.ps1 would rebuild it in a few minutes); add -RemoveImage to delete it"
}

if ($RemoveVolume) {
    if (-not $dockerReady) {
        Write-Fail "The saved logins were not removed: $dockerWhy. Start Docker Desktop and run this again with -RemoveVolume."
        $problems++
    } else {
        $present = @($volumes | Where-Object { (Invoke-Quiet $docker @('volume', 'inspect', $_)).ExitCode -eq 0 })
        if ($present.Count -eq 0) {
            Write-Ok 'no toolbox volume found, nothing to delete'
        } else {
            $names = $present -join ' and '
            $go    = [bool] $Force
            if (-not $go -and $NoPrompt) {
                Write-Warn "kept $names : deleting it needs -Force when no question can be asked"
            } elseif (-not $go) {
                $answer   = ''
                $question = 'Delete {0}? It holds your saved az, gh and kubectl logins and everything else in the toolbox home folder. [y/N]' -f $names
                try { $answer = "$(Read-Host $question)" } catch { }
                $go = ($answer -match '^\s*y(es)?\s*$')
                if (-not $go) { Write-Info "kept $names" }
            }
            if ($go) {
                foreach ($v in $present) {
                    $r = Invoke-Quiet $docker @('volume', 'rm', $v)
                    if ($r.ExitCode -eq 0) {
                        Write-Ok "deleted the volume $v (your saved logins)"
                    } else {
                        Write-Fail "Could not delete the volume $v : $(Get-FirstLine $r)"
                        $problems++
                    }
                }
            }
        }
    }
} else {
    Write-Info "kept your saved logins (volume $($volumes[0])); add -RemoveVolume to delete them"
}

# ---- Summary ---------------------------------------------------------------------------------
Write-Host ''
if ($problems -gt 0) {
    Write-Fail "$problems problem(s) above need attention."
    exit 2
}
Write-Host 'Done.' -ForegroundColor Green
if ($SkipProfile) {
    Write-Info 'Your profile was not changed, so new PowerShell windows load the wrappers again.'
}
if (Test-OwnProcess) {
    Write-Info 'PowerShell windows that are open now keep the wrappers until you close them,'
    Write-Info 'or run this in them:  Remove-Module Devtools'
} else {
    Write-Info 'The wrappers are gone from this window. Other PowerShell windows that are open keep them'
    Write-Info 'until you close them, or run this in them:  Remove-Module Devtools'
}
Write-Info "The project folder ($root) and your .env were not touched."
Write-Info 'To set everything up again:  .\setup.ps1'
exit 0
