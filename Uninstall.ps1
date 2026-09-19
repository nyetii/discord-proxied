#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$UserFolder = [Environment]::GetEnvironmentVariable('USERPROFILE')
$LocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$DesktopFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)

$ConfigPath = Join-Path $UserFolder 'discord_proxy.config.json'
$ShortcutPath = Join-Path $DesktopFolder 'Discord Proxied.lnk'
$InstallRoot = Join-Path $LocalAppData 'DiscordProxied'
$PortableSingBoxPath = Join-Path $InstallRoot 'sing-box\sing-box.exe'
$StatePath = Join-Path $InstallRoot 'install-state.json'

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

try {
    if ($env:OS -ne 'Windows_NT') {
        throw 'This uninstaller only supports Windows.'
    }

    $installMethod = $null
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            $installMethod = [string]$state.sing_box_install_method
        }
        catch {
            Write-Warning "The installation state could not be read: $($_.Exception.Message)"
        }
    }

    Write-Step 'Removing the Discord proxy shortcut and configuration'
    foreach ($path in @($ShortcutPath, $ConfigPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            Write-Host "Removed: $path"
        }
    }

    $winget = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $winget) {
        Write-Step 'Uninstalling sing-box with winget'
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $winget.Source uninstall --id SagerNet.sing-box --exact --silent --accept-source-agreements
            $wingetExitCode = $LASTEXITCODE
        }
        catch {
            $wingetExitCode = 1
            Write-Warning "winget could not be started: $($_.Exception.Message)"
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($wingetExitCode -ne 0 -and $installMethod -eq 'Winget') {
            Write-Warning "winget could not uninstall sing-box (exit code $wingetExitCode)."
        }
    }
    elseif ($installMethod -eq 'Winget') {
        Write-Warning 'winget is unavailable, so its sing-box package could not be uninstalled.'
    }

    if ($installMethod -eq 'Portable' -or (Test-Path -LiteralPath $PortableSingBoxPath -PathType Leaf)) {
        Write-Step 'Removing the portable sing-box installation'
    }

    $expectedInstallRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'DiscordProxied'
    if (-not ([IO.Path]::GetFullPath($InstallRoot).TrimEnd('\').Equals(
                [IO.Path]::GetFullPath($expectedInstallRoot).TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase))) {
        throw "Refusing to remove the unexpected installation path '$InstallRoot'."
    }

    if (Test-Path -LiteralPath $InstallRoot -PathType Container) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
        Write-Host "Removed: $InstallRoot"
    }

    Write-Host "`nUninstallation complete." -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
