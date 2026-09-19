#requires -Version 5.1

[CmdletBinding()]
param([switch]$ElevatedWorker)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedCopy {
    $windowsPowerShell = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ElevatedWorker' -f $PSCommandPath
    return Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -WorkingDirectory $PSScriptRoot -PassThru
}

function Show-NativeToast {
    param(
        [Parameter(Mandatory = $true)][string]$AppUserModelId,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $title = [Security.SecurityElement]::Escape('Discord Proxy has been disabled')
    $escapedMessage = [Security.SecurityElement]::Escape($Message)
    $toastXml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $toastXml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$title</text><text>$escapedMessage</text></binding></visual></toast>")
    $toast = [Windows.UI.Notifications.ToastNotification]::new($toastXml)
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppUserModelId)
    $notifier.Show($toast)
}

function Wait-ForDiscordRpcPort {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$SingBoxProcess)

    if ($null -eq (Get-Command 'Get-NetTCPConnection' -ErrorAction SilentlyContinue)) {
        throw 'Get-NetTCPConnection is unavailable, so Discord RPC readiness cannot be detected.'
    }

    $rpcPorts = [uint16[]](6463..6472)
    $discordProcessNames = @('Discord', 'DiscordCanary', 'DiscordPTB')

    while ($true) {
        if ($SingBoxProcess.HasExited) {
            throw 'sing-box stopped while waiting for Discord to open its RPC port.'
        }

        $connections = @(Get-NetTCPConnection -LocalPort $rpcPorts -State Listen -ErrorAction SilentlyContinue)
        foreach ($connection in $connections) {
            $owner = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
            if ($null -ne $owner -and $discordProcessNames -contains $owner.ProcessName) {
                return $connection.LocalPort
            }
        }

        Start-Sleep -Milliseconds 5000
    }
}

$statePath = Join-Path $PSScriptRoot 'install-state.json'
$defaultToastAppId = 'com.squirrel.Discord.Discord'
$toastAppId = $defaultToastAppId

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $notificationState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$notificationState.discord_app_user_model_id)) {
            $toastAppId = [string]$notificationState.discord_app_user_model_id
        }
    }
    catch {
        $toastAppId = $defaultToastAppId
    }
}

$showToastInCurrentProcess = $true

if (-not $ElevatedWorker -and -not (Test-Administrator)) {
    $workerSucceeded = $false
    try {
        $workerProcess = Start-ElevatedCopy
        $workerProcess.WaitForExit()
        $workerSucceeded = $workerProcess.ExitCode -eq 0
    }
    catch {
        $workerSucceeded = $false
    }

    $workerNotificationMessage = if ($workerSucceeded) {
        'Discord has been successfully open using the proxied location'
    }
    else {
        'An error happened so Discord might have been opened locally'
    }

    try {
        Show-NativeToast -AppUserModelId $toastAppId -Message $workerNotificationMessage
    }
    catch {
        try {
            $toastLogPath = Join-Path $PSScriptRoot 'launcher-error.log'
            $toastLogLine = '{0:u} Native notification failed: {1}{2}' -f [DateTime]::Now, $_.Exception.Message, [Environment]::NewLine
            [IO.File]::AppendAllText($toastLogPath, $toastLogLine)
        }
        catch {
            # Nothing else can be displayed from the hidden launcher.
        }
    }
    exit
}

if (-not (Test-Administrator)) {
    exit 1
}

if ($ElevatedWorker) {
    $showToastInCurrentProcess = $false
}

$singBoxProcess = $null
$failureMessage = $null
$succeeded = $false

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
    $rpcPort = Wait-ForDiscordRpcPort -SingBoxProcess $singBoxProcess
    $succeeded = $true
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    if ($null -ne $singBoxProcess) {
        try {
            if (-not $singBoxProcess.HasExited) {
                Stop-Process -Id $singBoxProcess.Id -Force -ErrorAction Stop
                if (-not $singBoxProcess.WaitForExit(5000)) {
                    throw 'sing-box did not stop within five seconds.'
                }
            }
        }
        catch {
            $succeeded = $false
            $failureMessage = "Could not stop sing-box cleanly: $($_.Exception.Message)"
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
    try {
        $launcherLogPath = Join-Path $PSScriptRoot 'launcher-error.log'
        $logLine = '{0:u} {1}{2}' -f [DateTime]::Now, $failureMessage, [Environment]::NewLine
        [IO.File]::AppendAllText($launcherLogPath, $logLine)
    }
    catch {
        # Logging is best effort because the launcher has no visible console.
    }
}

$notificationMessage = if ($succeeded) {
    'Discord has been successfully open using the proxied location'
}
else {
    'An error happened so Discord might have been opened locally'
}

if ($showToastInCurrentProcess) {
    try {
        Show-NativeToast -AppUserModelId $toastAppId -Message $notificationMessage
    }
    catch {
        try {
            $toastLogPath = Join-Path $PSScriptRoot 'launcher-error.log'
            $toastLogLine = '{0:u} Native notification failed: {1}{2}' -f [DateTime]::Now, $_.Exception.Message, [Environment]::NewLine
            [IO.File]::AppendAllText($toastLogPath, $toastLogLine)
        }
        catch {
            # Nothing else can be displayed from the hidden launcher.
        }
    }
}

if ($succeeded) {
    exit 0
}
exit 1
