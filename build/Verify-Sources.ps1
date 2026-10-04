[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Source verification requires Windows.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$sources = @(Get-ChildItem -LiteralPath $repository -Recurse -File | Where-Object {
    $_.Extension -in @('.ps1', '.psm1', '.psd1') -and
    $_.FullName -notmatch '[\\/](?:\.git|artifacts|profiles)[\\/]'
})
if ($sources.Count -eq 0) { throw 'No PowerShell sources were found.' }

$definitionCount = 0
foreach ($source in $sources) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $details = ($errors | ForEach-Object { '{0}:{1}: {2}' -f $source.Name, $_.Extent.StartLineNumber, $_.Message }) -join [Environment]::NewLine
        throw "PowerShell syntax errors:`n$details"
    }

    # Test and build helpers intentionally compile dynamically extracted source.
    # Native.Tests.ps1 compiles its extracted definition in a separate host;
    # helper variables are not statically evaluable and must not fail this check.
    # Keep every source's syntax check above, then compile only the entry point.
    if ($source.FullName -ne (Join-Path $repository 'DesktopLayoutSwitcher.ps1')) { continue }

    # Compile literal Add-Type definitions without executing scripts or touching
    # Explorer/the real desktop. Dynamic definitions require a separate test.
    $commands = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-Type'
    }, $true))
    foreach ($command in $commands) {
        $elements = $command.CommandElements
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst] -or $element.ParameterName -ne 'TypeDefinition') { continue }
            $value = $element.Argument
            if ($null -eq $value -and ($index + 1) -lt $elements.Count) { $value = $elements[$index + 1] }
            if ($value -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $definition = $value.Value
            }
            elseif ($value -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $value.NestedExpressions.Count -eq 0) {
                $definition = $value.Value
            }
            else {
                throw "Cannot statically compile the Add-Type definition in $($source.Name):$($element.Extent.StartLineNumber)."
            }
            Add-Type -TypeDefinition $definition -Language CSharp -ErrorAction Stop
            $definitionCount++
        }
    }
}
if ($definitionCount -eq 0) { throw 'The embedded Windows C# implementation was not found.' }
Write-Host "Verified $($sources.Count) PowerShell sources and compiled $definitionCount embedded C# definitions."
