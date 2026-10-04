param(
    [string]$ScriptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'DesktopLayoutSwitcher.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this test in 64-bit Windows PowerShell.'
}

# Compile the actual embedded C# without opening a GUI or reading a CI desktop.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}
$command = $ast.Find({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.CommandAst] -or $node.GetCommandName() -ne 'Add-Type') {
        return $false
    }
    return @($node.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'TypeDefinition'
    }).Count -gt 0
}, $true)
if ($null -eq $command) {
    throw 'Embedded native TypeDefinition not found.'
}
for ($i = 0; $i -lt $command.CommandElements.Count - 1; $i++) {
    if ($command.CommandElements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
        $command.CommandElements[$i].ParameterName -eq 'TypeDefinition') {
        $nativeSource = $command.CommandElements[$i + 1].Value
        break
    }
}
Add-Type -TypeDefinition $nativeSource

# Windows LVITEMW is 88 bytes on a 64-bit process; pszText must start at byte 24.
# This catches unsafe process-pointer or packing changes before a Release ships.
$manager = [DesktopLayout.DesktopIconManager]
$binding = [System.Reflection.BindingFlags]'NonPublic,Static'
$itemType = $manager.GetNestedType('LVITEM', [System.Reflection.BindingFlags]::NonPublic)
if ([System.Runtime.InteropServices.Marshal]::SizeOf($itemType) -ne 88 -or
    [System.Runtime.InteropServices.Marshal]::OffsetOf($itemType, 'pszText').ToInt64() -ne 24) {
    throw 'LVITEMW does not match the 64-bit Windows ABI.'
}

# Regression: identical visible names used to move the same first icon repeatedly.
$current = [System.Collections.Generic.List[DesktopLayout.DesktopIconSnapshot]]::new()
foreach ($index in @(4, 8)) {
    $icon = [DesktopLayout.DesktopIconSnapshot]::new()
    $icon.Text = 'Project'
    $icon.Index = $index
    $current.Add($icon)
}
$saved = [System.Collections.Generic.List[DesktopLayout.DesktopIconSnapshot]]::new()
foreach ($name in @('project', 'Project', 'Project', 'Missing')) {
    $icon = [DesktopLayout.DesktopIconSnapshot]::new()
    $icon.Text = $name
    $saved.Add($icon)
}
$arguments = [object[]]::new(2)
$arguments[0] = $saved
$arguments[1] = $current
$indices = $manager.GetMethod('MatchIconIndices', $binding).Invoke($null, $arguments)
if (($indices -join ',') -ne '4,8,-1,-1') {
    throw "Duplicate icon names did not match each current icon once: $($indices -join ',')"
}

Write-Host 'Native compilation, 64-bit LVITEMW ABI, and duplicate-name regression passed.'
