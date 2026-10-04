[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts'),
    [string]$ISCCPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
    throw 'Build in 64-bit Windows PowerShell 5.1 on 64-bit Windows.'
}
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Use Windows PowerShell 5.1 for the release build.'
}

$version = (Get-Content -LiteralPath (Join-Path $repository 'VERSION') -Raw).Trim()
if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'VERSION must contain a numeric major.minor.patch version.' }
foreach ($part in $version.Split('.')) {
    if ([int64]$part -gt 65534) { throw 'Each VERSION component must be at most 65534 for the Windows file version.' }
}

$programFiles = @('DesktopLayoutSwitcher.ps1', 'DesktopItems.psm1', 'README.md', 'VERSION')
foreach ($name in ($programFiles + @('build/Launcher.cs', 'build/installer.iss', 'tests/DesktopItems.Tests.ps1', 'tests/Native.Tests.ps1'))) {
    if (-not (Test-Path -LiteralPath (Join-Path $repository $name) -PathType Leaf)) { throw "Required release input is missing: $name" }
}

# All required checks finish before any distributable is produced. Separate hosts
# prevent Add-Type definitions and module test state from leaking between checks.
$powershell = Join-Path $PSHOME 'powershell.exe'
$checks = @('build/Verify-Sources.ps1', 'tests/Native.Tests.ps1', 'tests/DesktopItems.Tests.ps1')
foreach ($check in $checks) {
    & $powershell -STA -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repository $check)
    if ($LASTEXITCODE -ne 0) { throw "Verification failed: $check (exit $LASTEXITCODE)." }
}

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The .NET Framework 4.x C# compiler was not found.' }
if ([string]::IsNullOrWhiteSpace($ISCCPath)) {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    $ISCCPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($ISCCPath) -or -not (Test-Path -LiteralPath $ISCCPath -PathType Leaf)) {
    throw 'Inno Setup 6 was not found. Pass -ISCCPath with the path to ISCC.exe.'
}

$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$releaseDirectory = Join-Path $OutputRoot 'release'
$stage = Join-Path $OutputRoot ('staging-' + [guid]::NewGuid().ToString('N'))
$portableDirectory = Join-Path $stage 'DesktopLayoutSwitcher'
New-Item -ItemType Directory -Path $portableDirectory, $releaseDirectory -Force | Out-Null
try {
    foreach ($name in $programFiles) {
        Copy-Item -LiteralPath (Join-Path $repository $name) -Destination (Join-Path $portableDirectory $name)
    }
    $launcherSource = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Launcher.cs') -Raw).Replace('__APP_VERSION__', $version)
    $compiledSource = Join-Path $stage 'Launcher.cs'
    [IO.File]::WriteAllText($compiledSource, $launcherSource, [Text.UTF8Encoding]::new($true))
    $executable = Join-Path $portableDirectory 'DesktopLayoutSwitcher.exe'
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ /reference:System.Windows.Forms.dll "/out:$executable" $compiledSource
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Launcher compilation failed.' }

    # Check the PE machine and subsystem rather than launching a desktop-changing
    # program on the build host. 0x8664 = x64; 2 = Windows GUI (no console).
    $image = [IO.File]::ReadAllBytes($executable)
    $header = [BitConverter]::ToInt32($image, 0x3c)
    if ([BitConverter]::ToUInt16($image, $header + 4) -ne 0x8664 -or [BitConverter]::ToUInt16($image, $header + 24 + 68) -ne 2) {
        throw 'The launcher must be an x64 Windows GUI executable.'
    }
    $expectedFiles = @($programFiles + 'DesktopLayoutSwitcher.exe' | Sort-Object)
    $actualFiles = @(Get-ChildItem -LiteralPath $portableDirectory -File | Select-Object -ExpandProperty Name | Sort-Object)
    if (@(Compare-Object $expectedFiles $actualFiles).Count -ne 0) { throw 'Portable payload does not match the explicit release whitelist.' }

    & $ISCCPath "/DAppVersion=$version" "/DSourceDir=$portableDirectory" "/DReleaseDir=$releaseDirectory" (Join-Path $PSScriptRoot 'installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    $installer = Join-Path $releaseDirectory "DesktopLayoutSwitcher-$version-Setup-x64.exe"
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'Inno Setup did not produce the expected installer.' }

    $portable = Join-Path $releaseDirectory "DesktopLayoutSwitcher-$version-Portable-x64.zip"
    Compress-Archive -LiteralPath $portableDirectory -DestinationPath $portable -CompressionLevel Optimal -Force
    $checksums = @($installer, $portable) | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant(), [IO.Path]::GetFileName($_)
    }
    [IO.File]::WriteAllText((Join-Path $releaseDirectory 'SHA256SUMS.txt'), (($checksums -join "`n") + "`n"), [Text.Encoding]::ASCII)
    Write-Host "Release $version ready: $releaseDirectory"
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "version=$version`n", [Text.UTF8Encoding]::new($false))
    }
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
