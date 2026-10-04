[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InstallerPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Installer smoke testing is restricted to a disposable Windows GitHub Actions runner.'
}
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('DesktopLayoutInstaller-' + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $fixture 'installed'
$marker = Join-Path $installRoot 'profiles\keep-user-data.json'
New-Item -ItemType Directory -Path (Split-Path $marker -Parent) -Force | Out-Null
[IO.File]::WriteAllText($marker, '{"preserve":true}')
$installed = $false
try {
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=`"$installRoot`"", "/LOG=`"$(Join-Path $fixture 'install.log')`"")
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Silent installation failed with exit $($process.ExitCode)." }
    $installed = $true
    foreach ($name in @('DesktopLayoutSwitcher.exe', 'DesktopLayoutSwitcher.ps1', 'DesktopItems.psm1', 'README.md', 'VERSION')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot $name) -PathType Leaf)) { throw "Installed payload missing: $name" }
    }
    $uninstaller = Join-Path $installRoot 'unins000.exe'
    if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'Uninstaller not generated.' }
    $process = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Silent uninstallation failed with exit $($process.ExitCode)." }
    $installed = $false
    if (([IO.File]::ReadAllText($marker)) -ne '{"preserve":true}') { throw 'Uninstallation changed pre-existing user data.' }
    foreach ($name in @('DesktopLayoutSwitcher.exe', 'DesktopLayoutSwitcher.ps1', 'DesktopItems.psm1')) {
        if (Test-Path -LiteralPath (Join-Path $installRoot $name)) { throw "Uninstallation left a program file: $name" }
    }
    Write-Host 'Installer smoke passed: silent install, complete payload, silent uninstall, and preserved user data.'
}
finally {
    $uninstaller = Join-Path $installRoot 'unins000.exe'
    if ($installed -and (Test-Path -LiteralPath $uninstaller)) {
        Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait | Out-Null
    }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
