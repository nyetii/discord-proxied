#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $sourcePath = Join-Path $PSScriptRoot 'Start-DiscordProxied.ps1'
    $installFolder = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'DiscordProxied'
    $destinationPath = Join-Path $installFolder 'Start-DiscordProxied.ps1'

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "The updated launcher was not found at '$sourcePath'."
    }

    if (-not (Test-Path -LiteralPath $installFolder -PathType Container)) {
        throw "Discord Proxied is not installed at '$installFolder'. Run Install.ps1 first."
    }

    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    Write-Host "Updated: $destinationPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}

