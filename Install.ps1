#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$UserFolder = [Environment]::GetEnvironmentVariable('USERPROFILE')
$LocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$DesktopFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)

$ConfigPath = Join-Path $UserFolder 'discord_proxy.config.json'
$TemplatePath = Join-Path $PSScriptRoot 'discord_proxy.config.json'
$InstallRoot = Join-Path $LocalAppData 'DiscordProxied'
$PortableRoot = Join-Path $InstallRoot 'sing-box'
$PortableSingBoxPath = Join-Path $PortableRoot 'sing-box.exe'
$LauncherSourcePath = Join-Path $PSScriptRoot 'Start-DiscordProxied.ps1'
$LauncherPath = Join-Path $InstallRoot 'Start-DiscordProxied.ps1'
$StatePath = Join-Path $InstallRoot 'install-state.json'
$DiscordUpdatePath = Join-Path $LocalAppData 'Discord\Update.exe'
$ShortcutPath = Join-Path $DesktopFolder 'Discord Proxied.lnk'

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-SingBoxExecutable {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $false
        }

        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & $Path version 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        return $exitCode -eq 0
    }
    catch {
        return $false
    }
}

function Find-SingBox {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($commandName in @('sing-box.exe', 'sing-box')) {
        $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            $candidates.Add($command.Source)
        }
    }

    $candidates.Add((Join-Path $LocalAppData 'Microsoft\WinGet\Links\sing-box.exe'))
    $candidates.Add($PortableSingBoxPath)

    $wingetPackagesRoot = Join-Path $LocalAppData 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetPackagesRoot -PathType Container -ErrorAction SilentlyContinue) {
        Get-ChildItem -LiteralPath $wingetPackagesRoot -Directory -Filter 'SagerNet.sing-box_*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Filter 'sing-box.exe' -File -Recurse -ErrorAction SilentlyContinue |
                    ForEach-Object { $candidates.Add($_.FullName) }
            }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-SingBoxExecutable -Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Install-SingBoxWithWinget {
    param([Parameter(Mandatory = $true)][string]$WingetPath)

    Write-Step 'Installing sing-box with winget'
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $WingetPath install --id SagerNet.sing-box --exact --silent --accept-package-agreements --accept-source-agreements
        $exitCode = $LASTEXITCODE
    }
    catch {
        Write-Warning "winget could not be started: $($_.Exception.Message)"
        return $false
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        Write-Warning "winget returned exit code $exitCode. The installer will use the portable fallback."
        return $false
    }

    return $true
}

function Install-SingBoxPortable {
    Write-Step 'Installing sing-box from the official GitHub release'

    # Windows PowerShell 5.1 can otherwise default to protocols rejected by GitHub.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $architecture = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        'X64' { 'amd64' }
        'Arm64' { 'arm64' }
        'X86' { '386' }
        default { throw "Unsupported Windows architecture: $($_)" }
    }

    $headers = @{ 'User-Agent' = 'Discord-Proxied-Installer' }
    $releaseUri = 'https://api.github.com/repos/SagerNet/sing-box/releases/latest'
    $release = Invoke-RestMethod -Uri $releaseUri -Headers $headers -UseBasicParsing
    $assetPattern = '^sing-box-.+-windows-{0}\.zip$' -f [regex]::Escape($architecture)
    $asset = @($release.assets | Where-Object { $_.name -match $assetPattern }) | Select-Object -First 1

    if ($null -eq $asset) {
        throw "The latest sing-box release has no Windows $architecture archive."
    }

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("DiscordProxied-{0}" -f [guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $temporaryRoot $asset.name
    $extractPath = Join-Path $temporaryRoot 'extracted'

    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archivePath -Headers $headers -UseBasicParsing

        $expectedHash = $null
        if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
            $expectedHash = $Matches[1]
        }

        if ([string]::IsNullOrWhiteSpace($expectedHash)) {
            $checksumAsset = @($release.assets | Where-Object { $_.name -match 'checksums?\.txt$' }) | Select-Object -First 1
            if ($null -ne $checksumAsset) {
                $checksumResponse = Invoke-WebRequest -Uri $checksumAsset.browser_download_url -Headers $headers -UseBasicParsing
                $escapedAssetName = [regex]::Escape($asset.name)
                if ($checksumResponse.Content -match "(?im)^([0-9a-f]{64})\s+\*?$escapedAssetName\s*$") {
                    $expectedHash = $Matches[1]
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($expectedHash)) {
            throw 'The release archive has no SHA-256 digest; refusing to install an unverified download.'
        }

        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        if (-not $actualHash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The sing-box archive SHA-256 hash does not match the published digest."
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
        $extractedExecutable = Get-ChildItem -LiteralPath $extractPath -Filter 'sing-box.exe' -File -Recurse |
            Select-Object -First 1
        if ($null -eq $extractedExecutable) {
            throw 'sing-box.exe was not found in the downloaded archive.'
        }

        if (Test-Path -LiteralPath $PortableRoot) {
            Remove-Item -LiteralPath $PortableRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $PortableRoot -Force | Out-Null

        Get-ChildItem -LiteralPath $extractedExecutable.DirectoryName -Force |
            Copy-Item -Destination $PortableRoot -Recurse -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-SingBoxExecutable -Path $PortableSingBoxPath)) {
        throw 'The downloaded sing-box executable could not be started.'
    }

    return $PortableSingBoxPath
}

function Read-RequiredValue {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    do {
        $value = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Warning 'A value is required.'
        }
    } while ([string]::IsNullOrWhiteSpace($value))

    return $value.Trim()
}

function Read-ServerAddress {
    do {
        $value = Read-RequiredValue -Prompt 'Server IP address'
        $parsedAddress = $null
        if ([Net.IPAddress]::TryParse($value, [ref]$parsedAddress)) {
            return $parsedAddress.ToString()
        }
        Write-Warning 'Enter a valid IPv4 or IPv6 address.'
    } while ($true)
}

function Test-WireGuardKey {
    param([Parameter(Mandatory = $true)][string]$Value)

    try {
        return [Convert]::FromBase64String($Value).Length -eq 32
    }
    catch {
        return $false
    }
}

function Read-WireGuardPublicKey {
    do {
        $value = Read-RequiredValue -Prompt 'Server public key'
        if (Test-WireGuardKey -Value $value) {
            return $value
        }
        Write-Warning 'The public key must be a base64-encoded 32-byte WireGuard key.'
    } while ($true)
}

function Read-WireGuardPrivateKey {
    do {
        $secureValue = Read-Host 'User private key' -AsSecureString
        $bstr = [IntPtr]::Zero
        try {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
            $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            if ($bstr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }

        if (Test-WireGuardKey -Value $value) {
            return $value
        }
        Write-Warning 'The private key must be a base64-encoded 32-byte WireGuard key.'
    } while ($true)
}

function New-DiscordProxyConfig {
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "The configuration template was not found at '$TemplatePath'."
    }

    Write-Step 'Creating the Discord proxy configuration'
    $serverAddress = Read-ServerAddress
    $serverPublicKey = Read-WireGuardPublicKey
    $userPrivateKey = Read-WireGuardPrivateKey

    $createdFile = $false
    try {
        Copy-Item -LiteralPath $TemplatePath -Destination $ConfigPath -Force
        $createdFile = $true

        $configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        $endpoint = @($configuration.endpoints | Where-Object {
                $null -ne $_.PSObject.Properties['private_key'] -and
                $null -ne $_.PSObject.Properties['peers']
            }) | Select-Object -First 1

        if ($null -eq $endpoint -or @($endpoint.peers).Count -eq 0) {
            throw 'The template has no endpoint containing private_key and peers.'
        }

        $endpoint.private_key = $userPrivateKey
        $endpoint.peers[0].address = $serverAddress
        $endpoint.peers[0].public_key = $serverPublicKey

        $json = $configuration | ConvertTo-Json -Depth 100
        $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($ConfigPath, $json + [Environment]::NewLine, $utf8WithoutBom)
    }
    catch {
        if ($createdFile -and (Test-Path -LiteralPath $ConfigPath)) {
            Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Test-DiscordProxyConfig {
    param(
        [Parameter(Mandatory = $true)][string]$SingBoxPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Write-Step 'Checking the sing-box configuration'
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $checkOutput = @(& $SingBoxPath check -c $Path 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $checkOutput = @($_.Exception.Message)
        $exitCode = 1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($checkOutput.Count -gt 0) {
        $checkOutput | ForEach-Object { Write-Host $_ }
    }

    if ($exitCode -ne 0) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "sing-box rejected the configuration (exit code $exitCode). '$Path' was removed."
    }
}

function New-DiscordProxyShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetScript
    )

    $windowsPowerShell = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "Windows PowerShell was not found at '$windowsPowerShell'."
    }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $windowsPowerShell
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $TargetScript
        $shortcut.WorkingDirectory = Split-Path -Parent $TargetScript
        $shortcut.IconLocation = "$DiscordUpdatePath,0"
        $shortcut.Description = 'Start Discord through the sing-box proxy'
        $shortcut.Save()
    }
    finally {
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

try {
    if ($env:OS -ne 'Windows_NT') {
        throw 'This installer only supports Windows.'
    }
    if ([string]::IsNullOrWhiteSpace($UserFolder) -or [string]::IsNullOrWhiteSpace($LocalAppData)) {
        throw 'The user profile folders could not be resolved.'
    }
    if (-not (Test-Path -LiteralPath $DiscordUpdatePath -PathType Leaf)) {
        throw "Discord's updater was not found at '$DiscordUpdatePath'. Install Discord before running this installer."
    }
    if (-not (Test-Path -LiteralPath $LauncherSourcePath -PathType Leaf)) {
        throw "The launcher script was not found at '$LauncherSourcePath'."
    }

    $singBoxPath = Find-SingBox
    $singBoxInstallMethod = 'Existing'

    if ([string]::IsNullOrWhiteSpace($singBoxPath)) {
        $winget = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $installedWithWinget = $false
        if ($null -ne $winget) {
            $installedWithWinget = Install-SingBoxWithWinget -WingetPath $winget.Source
            if ($installedWithWinget) {
                $singBoxPath = Find-SingBox
            }
        }

        if ([string]::IsNullOrWhiteSpace($singBoxPath)) {
            $singBoxPath = Install-SingBoxPortable
            $singBoxInstallMethod = 'Portable'
        }
        else {
            $singBoxInstallMethod = 'Winget'
        }
    }
    else {
        Write-Step "Using the installed sing-box at '$singBoxPath'"
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        New-DiscordProxyConfig
    }
    else {
        Write-Step "Using the existing configuration at '$ConfigPath'"
    }

    Test-DiscordProxyConfig -SingBoxPath $singBoxPath -Path $ConfigPath

    Write-Step 'Installing the launcher and shortcut'
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Copy-Item -LiteralPath $LauncherSourcePath -Destination $LauncherPath -Force

    $state = [ordered]@{
        schema_version          = 1
        config_path             = $ConfigPath
        discord_update_path     = $DiscordUpdatePath
        sing_box_path           = $singBoxPath
        sing_box_install_method = $singBoxInstallMethod
        shortcut_path           = $ShortcutPath
    }
    $stateJson = $state | ConvertTo-Json
    $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($StatePath, $stateJson + [Environment]::NewLine, $utf8WithoutBom)

    New-DiscordProxyShortcut -Path $ShortcutPath -TargetScript $LauncherPath

    Write-Host "`nInstallation complete." -ForegroundColor Green
    Write-Host "Shortcut: $ShortcutPath"
    Write-Host "Configuration: $ConfigPath"
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
