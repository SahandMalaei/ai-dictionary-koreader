#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PluginsPath = '/sdcard/koreader/plugins',
    [string]$Serial,
    [string]$AdbPath = 'adb',
    [switch]$SkipLaunch
)

$ErrorActionPreference = 'Stop'
$deviceArguments = @('-d')
if ($Serial) {
    $deviceArguments = @('-s', $Serial)
}

function Invoke-Adb {
    param([string[]]$Arguments)

    & $AdbPath @deviceArguments @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "ADB failed (exit code $LASTEXITCODE). Check the device connection, USB debugging authorization, and destination path."
    }
}

function Quote-AndroidPath {
    param([string]$Path)
    return "'" + $Path.Replace("'", "'\''") + "'"
}

function Start-KOReader {
    $package = 'org.koreader.launcher'
    # Resolve the launcher before stopping the app, so a missing launcher cannot
    # leave a running KOReader closed.
    $resolved = @(Invoke-Adb -Arguments @('shell', 'cmd', 'package', 'resolve-activity', '--brief',
        '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER', '-p', $package))
    $activities = @($resolved | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -match ('^' + [regex]::Escape($package) + '/[A-Za-z0-9_.$]+$')
    })
    if ($activities.Count -ne 1) {
        throw 'Could not resolve a unique KOReader launcher activity; the app has not been stopped.'
    }

    Write-Host 'Opening KOReader with the deployed plugin ...'
    # -S stops any existing instance, or simply launches if the app was closed.
    # -W waits for the activity to launch, not for Lua/plugin initialization.
    $launch = (Invoke-Adb -Arguments @('shell', 'am', 'start', '-W', '-S',
        '-n', $activities[0], '-a', 'android.intent.action.MAIN',
        '-c', 'android.intent.category.LAUNCHER')) -join "`n"
    if ($launch -notmatch '(?m)^\s*Status:\s*ok\s*$' -or $launch -match '(?im)^\s*Error:') {
        throw "Android did not confirm a successful KOReader launch: $launch"
    }
    Write-Host 'KOReader opened.'
}

function Copy-PluginFiles {
    param([string]$Source, [string]$Destination, [bool]$IsRoot = $true)

    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        # Never upload local credentials, reading history, or runtime caches.
        if ($item.Name -eq 'configuration.lua' -or
            ($IsRoot -and ($item.Name -in @('Lookups', 'Audio') -or $item.Name.StartsWith('.update-')))) {
            continue
        }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Deployment does not follow symbolic links or junctions: $($item.FullName)"
        }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-PluginFiles -Source $item.FullName -Destination $target -IsRoot $false
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $target
        }
    }
}

$stagingRoot = $null
$remoteStage = $null
try {
    # An already-open VS Code window may still have the PATH from before setup.
    if ($AdbPath -eq 'adb' -and -not (Get-Command $AdbPath -ErrorAction SilentlyContinue) -and $env:LOCALAPPDATA) {
        $sdkAdb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
        if (Test-Path -LiteralPath $sdkAdb -PathType Leaf) {
            $AdbPath = $sdkAdb
        }
    }
    if (-not (Get-Command $AdbPath -ErrorAction SilentlyContinue)) {
        throw 'ADB was not found. Install Android SDK Platform-Tools and add its platform-tools folder to PATH, or pass -AdbPath with the full path to adb.exe. See scripts/README.md.'
    }

    $PluginsPath = $PluginsPath.TrimEnd('/')
    if (-not $PluginsPath.StartsWith('/') -or -not $PluginsPath.EndsWith('/plugins') -or
        $PluginsPath -match '(^|/)\.\.?(/|$)' -or $PluginsPath -match '[\x00-\x1f"]') {
        throw 'PluginsPath must be an absolute Android path ending in /plugins, without dot segments, double quotes, or control characters.'
    }
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'AI_Dictionary.koplugin'
    if (-not (Test-Path -LiteralPath (Join-Path $source 'main.lua') -PathType Leaf)) {
        throw "Plugin source was not found at $source. Keep this script in the repository's scripts folder."
    }

    # -d selects a USB device; adb rejects missing, unauthorized, or ambiguous devices.
    Invoke-Adb -Arguments @('get-state') | Out-Null
    # adb shell joins arguments for the remote shell, so quote the path there too.
    $quotedPath = Quote-AndroidPath $PluginsPath
    Invoke-Adb -Arguments @('shell', "test -d $quotedPath")

    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    $stagingName = 'ai-dictionary-deploy-' + [guid]::NewGuid().ToString('N')
    $stagingRoot = Join-Path $tempRoot $stagingName
    $stagedPlugin = Join-Path $stagingRoot 'AI_Dictionary.koplugin'
    Copy-PluginFiles -Source $source -Destination $stagedPlugin
    # Android's shell requires LF line endings and no UTF-8 BOM.
    $syncScript = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'sync-android.sh')).Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText((Join-Path $stagingRoot 'sync-android.sh'), $syncScript, (New-Object System.Text.UTF8Encoding $false))

    Write-Host "Deploying to $PluginsPath/AI_Dictionary.koplugin ..."
    # Upload the complete snapshot before changing the installed plugin.
    $remoteStage = "/data/local/tmp/$stagingName"
    Invoke-Adb -Arguments @('push', $stagingRoot, '/data/local/tmp/')
    $quotedScript = Quote-AndroidPath "$remoteStage/sync-android.sh"
    $quotedPayload = Quote-AndroidPath "$remoteStage/AI_Dictionary.koplugin"
    Invoke-Adb -Arguments @('shell', "sh $quotedScript $quotedPayload $quotedPath")
    if (-not $SkipLaunch) {
        try {
            Start-KOReader
        } catch {
            throw "Plugin files were deployed, but opening KOReader failed: $($_.Exception.Message)"
        }
    }
    Write-Host 'Deployment complete.'
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($remoteStage) {
        # Only this deployment's generated Android staging directory may be removed.
        if ($remoteStage -notmatch '^/data/local/tmp/ai-dictionary-deploy-[a-f0-9]{32}$') {
            throw "Refusing to clean an unexpected Android staging path: $remoteStage"
        }
        try {
            Invoke-Adb -Arguments @('shell', ('rm -rf ' + (Quote-AndroidPath $remoteStage)))
        } catch {
            Write-Warning "Could not remove the temporary Android staging directory: $remoteStage"
        }
    }
    if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
        $resolvedStage = (Resolve-Path -LiteralPath $stagingRoot).ProviderPath
        if ((Split-Path -Parent $resolvedStage) -ne $tempRoot -or
            (Split-Path -Leaf $resolvedStage) -ne $stagingName) {
            throw "Refusing to clean an unexpected staging path: $resolvedStage"
        }
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
}
