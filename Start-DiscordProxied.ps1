#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedCopy {
    $windowsPowerShell = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -Verb RunAs -WorkingDirectory $PSScriptRoot | Out-Null
}

function Wait-ForDiscordStartup {
    param(
        [int]$StableSeconds = 30,
        [int]$TimeoutSeconds = 180
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastNewestStartTime = $null
    $stableSince = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        $discordProcesses = @(Get-Process -Name 'Discord', 'DiscordCanary', 'DiscordPTB' -ErrorAction SilentlyContinue)
        $startTimes = @($discordProcesses | ForEach-Object {
                try { $_.StartTime.ToUniversalTime() } catch { $null }
            } | Where-Object { $null -ne $_ })

        if ($startTimes.Count -gt 0) {
            $newestStartTime = @($startTimes | Sort-Object -Descending)[0]
            if ($null -eq $lastNewestStartTime -or $newestStartTime -ne $lastNewestStartTime) {
                $lastNewestStartTime = $newestStartTime
                $stableSince = [DateTime]::UtcNow
            }
            elseif ($null -ne $stableSince -and ([DateTime]::UtcNow - $stableSince).TotalSeconds -ge $StableSeconds) {
                return
            }
        }
        else {
            $lastNewestStartTime = $null
            $stableSince = $null
        }

        Start-Sleep -Seconds 1
    }

    throw "Discord did not remain running for $StableSeconds seconds within the $TimeoutSeconds-second startup timeout."
}

if (-not (Test-Administrator)) {
    try {
        Start-ElevatedCopy
    }
    catch {
        Write-Host "Administrator permission is required to start the sing-box TUN interface. $($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'Press Enter to close this window' | Out-Null
    }
    exit
}

$statePath = Join-Path $PSScriptRoot 'install-state.json'
$singBoxProcess = $null
$failureMessage = $null

try {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Installation state was not found at '$statePath'. Run Install.ps1 again."
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $singBoxPath = [string]$state.sing_box_path
    $configPath = [string]$state.config_path
    $discordUpdatePath = [string]$state.discord_update_path

    foreach ($requiredFile in @($singBoxPath, $configPath, $discordUpdatePath)) {
        if ([string]::IsNullOrWhiteSpace($requiredFile) -or -not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "A required file is missing: '$requiredFile'. Run Install.ps1 again."
        }
    }

    $logFolder = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    $standardOutputPath = Join-Path $logFolder 'sing-box.stdout.log'
    $standardErrorPath = Join-Path $logFolder 'sing-box.stderr.log'
    Remove-Item -LiteralPath $standardOutputPath, $standardErrorPath -Force -ErrorAction SilentlyContinue

    $singBoxArguments = 'run -c "{0}"' -f $configPath
    $singBoxProcess = Start-Process -FilePath $singBoxPath -ArgumentList $singBoxArguments -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $standardOutputPath -RedirectStandardError $standardErrorPath

    Start-Sleep -Seconds 2
    if ($singBoxProcess.HasExited) {
        $details = @(
            Get-Content -LiteralPath $standardErrorPath -Raw -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $standardOutputPath -Raw -ErrorAction SilentlyContinue
        ) -join [Environment]::NewLine
        throw "sing-box stopped before Discord could start. $details"
    }

    Start-Process -FilePath $discordUpdatePath -ArgumentList '--processStart Discord.exe' | Out-Null
    Wait-ForDiscordStartup -StableSeconds 30 -TimeoutSeconds 180
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    if ($null -ne $singBoxProcess) {
        try {
            if (-not $singBoxProcess.HasExited) {
                Stop-Process -Id $singBoxProcess.Id -Force -ErrorAction SilentlyContinue
                $singBoxProcess.WaitForExit(5000) | Out-Null
            }
        }
        catch {
            Write-Warning "Could not stop sing-box cleanly: $($_.Exception.Message)"
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
    Write-Host $failureMessage -ForegroundColor Red
    Read-Host 'Press Enter to close this window' | Out-Null
}
