[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InstallerPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Installer smoke testing is restricted to a disposable Windows GitHub Actions runner.'
}
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
$repository = Split-Path $PSScriptRoot -Parent
$id = [Guid]::NewGuid().ToString('N')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('DesktopLayoutInstaller-' + $id)
# The repository normally lives on D: while installer/AppData fixtures live on C:.
# Keep this unique data fixture on the repository drive, including Unicode/spaces.
$dataFixture = Join-Path $repository ('artifacts\installer-data-' + $id)
$selectedRoot = Join-Path $dataFixture '布局 数据'
$oldRoot = Join-Path $fixture '原来 数据'
$installRoot = Join-Path $fixture 'installed'
$legacyMarker = Join-Path $installRoot 'profiles\keep-user-data.json'
$selectedMarker = Join-Path $selectedRoot '实验室.json'
$backupMarker = Join-Path $selectedRoot 'data\backups\keep.bin'
$oldMarker = Join-Path $oldRoot 'keep-old-data.json'
$bootstrapRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DesktopLayoutSwitcher'
$bootstrap = Join-Path $bootstrapRoot 'storage.json'
$bootstrapBackup = $bootstrap + '.bak'
$hadBootstrapRoot = Test-Path -LiteralPath $bootstrapRoot -PathType Container
$hadBootstrap = Test-Path -LiteralPath $bootstrap -PathType Leaf
$hadBootstrapBackup = Test-Path -LiteralPath $bootstrapBackup -PathType Leaf
[byte[]]$originalBootstrap = if ($hadBootstrap) { [IO.File]::ReadAllBytes($bootstrap) } else { @() }
[byte[]]$originalBootstrapBackup = if ($hadBootstrapBackup) { [IO.File]::ReadAllBytes($bootstrapBackup) } else { @() }
$installed = $false
$junction = Join-Path $fixture 'linked-data'
$journal = Join-Path $selectedRoot 'data\transaction.json'

function Assert-FileContent([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or [IO.File]::ReadAllText($Path) -cne $Expected) {
        throw "Installer changed preserved data: $Path"
    }
}
function Read-Preference {
    return [IO.File]::ReadAllText($bootstrap) | ConvertFrom-Json
}
function Invoke-TestInstall($ConfigDir, [string]$Label, [switch]$ExpectFailure) {
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
        "/DIR=`"$installRoot`"", "/LOG=`"$(Join-Path $fixture ($Label + '.log'))`"")
    if ($null -ne $ConfigDir) { $arguments += "/CONFIGDIR=`"$ConfigDir`"" }
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru
    if ($ExpectFailure) {
        if ($process.ExitCode -eq 0) { throw "Invalid storage selection was accepted: $Label" }
    }
    elseif ($process.ExitCode -ne 0) { throw "Silent installation failed ($Label) with exit $($process.ExitCode)." }
}
function Assert-PreferenceUnchanged([string]$Expected) {
    if ([IO.File]::ReadAllText($bootstrap) -cne $Expected) { throw 'Installation changed a preference that must remain unchanged.' }
}

try {
    foreach ($path in @($legacyMarker, $selectedMarker, $backupMarker, $oldMarker)) {
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    }
    [IO.File]::WriteAllText($legacyMarker, '{"preserve":true}')
    [IO.File]::WriteAllText($selectedMarker, '{"selected":true}')
    [IO.File]::WriteAllText($backupMarker, 'preserve-backup')
    [IO.File]::WriteAllText($oldMarker, '{"old":true}')
    New-Item -ItemType Directory -Path $bootstrapRoot -Force | Out-Null
    # Exercise Inno's UTF-8 reader with an existing no-BOM Unicode preference.
    $previousPreference = [ordered]@{SchemaVersion = 1; ProfileRoot = $oldRoot} | ConvertTo-Json
    [IO.File]::WriteAllText($bootstrap, $previousPreference, [Text.UTF8Encoding]::new($false))

    Invoke-TestInstall -ConfigDir $selectedRoot -Label 'selected-folder'
    $installed = $true
    foreach ($name in @('DesktopLayoutSwitcher.exe', 'DesktopLayoutSwitcher.ps1', 'DesktopItems.psm1', 'README.md', 'VERSION')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot $name) -PathType Leaf)) { throw "Installed payload missing: $name" }
    }
    $selection = Read-Preference
    if ($selection.SchemaVersion -ne 1 -or $selection.ProfileRoot -cne $selectedRoot) {
        throw 'Installer bootstrap does not contain the selected Unicode data path.'
    }
    Assert-FileContent $bootstrapBackup $previousPreference
    Assert-FileContent $oldMarker '{"old":true}'
    Assert-FileContent $selectedMarker '{"selected":true}'
    Assert-FileContent $backupMarker 'preserve-backup'
    Assert-FileContent $legacyMarker '{"preserve":true}'

    # Execute only the installed reader function; never start the GUI or Explorer.
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $installRoot 'DesktopLayoutSwitcher.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
    $reader = $ast.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DefaultProfileRoot'
    }, $true)
    if ($null -eq $reader) { throw 'Installed Get-DefaultProfileRoot function is missing.' }
    . ([scriptblock]::Create($reader.Extent.Text))
    if ((Get-DefaultProfileRoot -PreferencePath $bootstrap) -cne $selectedRoot) {
        throw 'Installed Windows PowerShell reader did not resolve the selected Unicode folder.'
    }
    $savedPreference = [IO.File]::ReadAllText($bootstrap)

    # A pending old transaction blocks a change before the new folder is created.
    [IO.File]::WriteAllText($journal, '{"pending":true}')
    $pendingTarget = Join-Path $dataFixture 'blocked-change'
    Invoke-TestInstall -ConfigDir $pendingTarget -Label 'pending-transaction' -ExpectFailure
    Assert-PreferenceUnchanged $savedPreference
    if (Test-Path -LiteralPath $pendingTarget) { throw 'Blocked storage change created its target folder.' }
    Assert-FileContent $journal '{"pending":true}'

    # No CONFIGDIR parameter means keep the existing choice during an upgrade;
    # the old unfinished journal is left for the application's startup recovery.
    Invoke-TestInstall -ConfigDir $null -Label 'upgrade-keep-folder'
    Assert-PreferenceUnchanged $savedPreference
    Assert-FileContent $bootstrapBackup $previousPreference
    Assert-FileContent $journal '{"pending":true}'
    Remove-Item -LiteralPath $journal

    Invoke-TestInstall -ConfigDir 'relative-data' -Label 'relative-path' -ExpectFailure
    Assert-PreferenceUnchanged $savedPreference
    Invoke-TestInstall -ConfigDir (Join-Path $installRoot 'data') -Label 'program-path' -ExpectFailure
    Assert-PreferenceUnchanged $savedPreference
    $desktopRoot = [Environment]::GetFolderPath('DesktopDirectory')
    if (-not [string]::IsNullOrWhiteSpace($desktopRoot)) {
        $desktopTarget = Join-Path $desktopRoot ('DesktopLayoutForbidden-' + $id)
        Invoke-TestInstall -ConfigDir $desktopTarget -Label 'desktop-path' -ExpectFailure
        Assert-PreferenceUnchanged $savedPreference
        if (Test-Path -LiteralPath $desktopTarget) { throw 'Invalid desktop data folder was created.' }
    }

    $junctionTarget = Join-Path $fixture 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $junction -Value $junctionTarget | Out-Null
    $junctionChoice = Join-Path $junction 'new-data'
    Invoke-TestInstall -ConfigDir $junctionChoice -Label 'junction-path' -ExpectFailure
    Assert-PreferenceUnchanged $savedPreference
    if (Test-Path -LiteralPath (Join-Path $junctionTarget 'new-data')) { throw 'Invalid junction data folder was created.' }
    [IO.Directory]::Delete($junction)

    # Corrupt preferences must fail silent upgrades, preserving their exact bytes.
    [IO.File]::WriteAllText($bootstrap, '{broken', [Text.UTF8Encoding]::new($false))
    Invoke-TestInstall -ConfigDir $null -Label 'corrupt-preference' -ExpectFailure
    Assert-PreferenceUnchanged '{broken'
    [IO.File]::WriteAllText($bootstrap, $savedPreference, [Text.UTF8Encoding]::new($true))

    $uninstaller = Join-Path $installRoot 'unins000.exe'
    if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'Uninstaller not generated.' }
    $process = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Silent uninstallation failed with exit $($process.ExitCode)." }
    $installed = $false
    Assert-PreferenceUnchanged $savedPreference
    Assert-FileContent $bootstrapBackup $previousPreference
    Assert-FileContent $legacyMarker '{"preserve":true}'
    Assert-FileContent $selectedMarker '{"selected":true}'
    Assert-FileContent $backupMarker 'preserve-backup'
    Assert-FileContent $oldMarker '{"old":true}'
    foreach ($name in @('DesktopLayoutSwitcher.exe', 'DesktopLayoutSwitcher.ps1', 'DesktopItems.psm1')) {
        if (Test-Path -LiteralPath (Join-Path $installRoot $name)) { throw "Uninstallation left a program file: $name" }
    }
    Write-Host "Installer smoke passed: selected Unicode config folder $selectedRoot, installed reader, retained upgrade preference, storage guards, and preserved uninstall data."
}
finally {
    $uninstaller = Join-Path $installRoot 'unins000.exe'
    try {
        if ($installed -and (Test-Path -LiteralPath $uninstaller)) {
            Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait | Out-Null
        }
    }
    catch { Write-Warning "Fixture uninstall cleanup failed: $($_.Exception.Message)" }
    try {
        # Remove the known junction itself, never recursively follow its target.
        if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    }
    catch { Write-Warning "Fixture junction cleanup failed: $($_.Exception.Message)" }
    try {
        if ($hadBootstrap -or $hadBootstrapBackup) { [IO.Directory]::CreateDirectory($bootstrapRoot) | Out-Null }
        if ($hadBootstrap) { [IO.File]::WriteAllBytes($bootstrap, $originalBootstrap) }
        elseif (Test-Path -LiteralPath $bootstrap -PathType Leaf) { Remove-Item -LiteralPath $bootstrap }
        if ($hadBootstrapBackup) { [IO.File]::WriteAllBytes($bootstrapBackup, $originalBootstrapBackup) }
        elseif (Test-Path -LiteralPath $bootstrapBackup -PathType Leaf) { Remove-Item -LiteralPath $bootstrapBackup }
        if (-not $hadBootstrapRoot -and (Test-Path -LiteralPath $bootstrapRoot) -and @(Get-ChildItem -LiteralPath $bootstrapRoot -Force).Count -eq 0) {
            [IO.Directory]::Delete($bootstrapRoot)
        }
    }
    finally {
        foreach ($path in @($fixture, $dataFixture)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    }
}
