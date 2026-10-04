[CmdletBinding()]
param(
    [string]$ScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'DesktopLayoutSwitcher.ps1'
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class SharedSettingsTestDialogs {
    delegate bool WindowCallback(IntPtr window, IntPtr state);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool EnumThreadWindows(uint thread, WindowCallback callback, IntPtr state);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    public static void CloseModalMessages() {
        WindowCallback callback = delegate(IntPtr window, IntPtr state) {
            var name = new StringBuilder(256);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() == "#32770") PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
            return true;
        };
        // Only this isolated test host's UI thread; never enumerate the desktop.
        EnumThreadWindows(GetCurrentThreadId(), callback, IntPtr.Zero);
        GC.KeepAlive(callback);
    }
}
'@
$script:checks = 0
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('SharedSettings-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    Assert-True ($Expected -ceq $Actual) "$Message; expected '$Expected', got '$Actual'"
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $caught = $false
    try { & $Action | Out-Null }
    catch { $caught = $true }
    Assert-True $caught "$Message; expected an error"
}

function Read-Text([string]$Path) {
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($true))
}

function Select-Fixture([string]$Name) {
    $script:ProfileRoot = Join-Path (Join-Path $testRoot $Name) 'profiles'
    $script:DataRoot = Join-Path $script:ProfileRoot 'data'
    [IO.Directory]::CreateDirectory($script:ProfileRoot) | Out-Null
}

function Invoke-SettingsDialogProbe([System.Windows.Forms.Form]$Owner, [string]$Mode) {
    # A Forms timer runs on the modal dialog's UI thread, so this exercises its
    # actual click handlers and PowerShell variable scope without user input.
    $script:dialogProbe = [pscustomobject]@{Mode = $Mode; Ticks = 0; Acted = $false; Failure = ''}
    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 100
    $timer.Add_Tick({
        $script:dialogProbe.Ticks++
        if ($script:dialogProbe.Ticks -gt 100) {
            $script:dialogProbe.Failure = 'Settings dialog did not close within ten seconds.'
            [SharedSettingsTestDialogs]::CloseModalMessages()
            foreach ($openForm in @([System.Windows.Forms.Application]::OpenForms)) {
                if ($openForm.Visible) { $openForm.Close() }
            }
            return
        }
        $dialogs = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq '始终保留在桌面' })
        if ($dialogs.Count -eq 0) { return }
        $targetDialog = $dialogs[0]
        try {
            if ($script:dialogProbe.Acted) { return }
            $script:dialogProbe.Acted = $true
            $lists = @($targetDialog.Controls | Where-Object { $_ -is [System.Windows.Forms.CheckedListBox] })
            Assert-Equal 1 $lists.Count 'settings dialog contains one checkable desktop list'
            $control = $lists[0]
            $appsIndex = $control.Items.IndexOf('Apps')
            $notesIndex = $control.Items.IndexOf('Notes.txt')
            Assert-Equal -1 $appsIndex 'Apps is a real directory and is always protected outside the optional list'
            Assert-Equal -1 $control.Items.IndexOf('Other Research') 'every real directory is protected outside the optional list'
            Assert-True ($notesIndex -ge 0) 'settings dialog lists optional top-level desktop files'
            Assert-Equal -1 $control.Items.IndexOf('desktop.ini') 'desktop.ini is automatically protected, outside the configurable list'
            Assert-Equal -1 $control.Items.IndexOf('DesktopLayoutSwitcher.lnk') 'the tool shortcut is automatically protected, outside the configurable list'
            $description = ($targetDialog.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] } | ForEach-Object { $_.Text }) -join "`n"
            Assert-True ($description -match '所有(?:真实)?文件夹' -and $description -match '位置') 'the dialog explains that folders always remain and only their icon positions change'
            if ($script:dialogProbe.Mode -eq 'Save') {
                Assert-True (-not $control.GetItemChecked($notesIndex)) 'ordinary desktop entries are initially unchecked'
                $control.SetItemChecked($notesIndex, $true)
                $buttonText = '保存名单'
            }
            else {
                Assert-True $control.GetItemChecked($notesIndex) 'saved selected entries are checked on reopening'
                $control.SetItemChecked($notesIndex, $false)
                $buttonText = '取消'
            }
            $buttons = @($targetDialog.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq $buttonText })
            Assert-Equal 1 $buttons.Count 'the expected settings action is available'
            $buttons[0].PerformClick()
        }
        catch {
            $script:dialogProbe.Failure = $_.Exception.Message
            # Also closes a dialog-owned error message after a failed save. The
            # timer continues in nested modal loops to keep failure bounded.
            $targetDialog.Close()
        }
    })
    try {
        $timer.Start()
        $result = Show-SharedDesktopSettings -Owner $Owner
        if (-not [string]::IsNullOrEmpty($script:dialogProbe.Failure)) { throw $script:dialogProbe.Failure }
        Assert-True $script:dialogProbe.Acted 'the settings dialog was exercised by the timer'
        return $result
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
    }
}

try {
    # Load only the actual helpers from the application's AST. Running the entry
    # point would initialize native desktop access, a mutex and the WinForms UI.
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
    $helperNames = @(
        'Get-StorageSettingsPath',
        'Get-DefaultProfileRoot',
        'Write-LayoutJson',
        'ConvertTo-SharedDesktopNames',
        'Get-SharedDesktopSettingsPath',
        'Get-ConfiguredSharedDesktopNames',
        'Set-ConfiguredSharedDesktopNames',
        'Get-AutomaticSharedDesktopNames',
        'Show-SharedDesktopSettings',
        'Initialize-LayoutStorage',
        'Get-SavedProfileNames'
    )
    $definitions = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true))
    foreach ($name in $helperNames) {
        $matching = @($definitions | Where-Object { $_.Name -eq $name })
        if ($matching.Count -ne 1) { throw "Expected one application helper named $name." }
        # Compiling the original body retains its source-file metadata, including
        # PSScriptRoot used by migration and automatic program-folder exclusions.
        $body = [System.Management.Automation.Language.ScriptBlockAst]$matching[0].Body.Copy()
        Set-Item -Path "Function:$name" -Value ($body.GetScriptBlock())
    }

    # The bootstrap chooses a data directory without reading or writing a real
    # user's preferences. A corrupt preference must not silently choose a new
    # directory and strand layouts, backups or a pending desktop transaction.
    $expectedStoragePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DesktopLayoutSwitcher\storage.json'
    $expectedDefaultRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DesktopLayoutSwitcher\profiles'
    Assert-Equal $expectedStoragePath (Get-StorageSettingsPath) 'storage preference has a fixed per-user bootstrap location'
    $preferenceArea = Join-Path $testRoot 'storage-preference'
    $preferencePath = Join-Path $preferenceArea 'storage.json'
    Assert-Equal $expectedDefaultRoot (Get-DefaultProfileRoot -PreferencePath $preferencePath) 'a missing preference retains the established default data directory'
    Assert-True (-not (Test-Path -LiteralPath $preferencePath)) 'reading the default does not create a preference file'
    Assert-True (-not (Test-Path -LiteralPath $preferenceArea)) 'reading the default does not create any directories'
    [IO.Directory]::CreateDirectory($preferenceArea) | Out-Null
    $customRoot = 'D:\科研 数据\桌面布局 profiles'
    $customPreferenceText = ([pscustomobject]@{SchemaVersion = 1; ProfileRoot = $customRoot}) | ConvertTo-Json
    Write-Text $preferencePath $customPreferenceText
    Write-Text "$preferencePath.bak" 'previous bootstrap preferences must stay untouched'
    Assert-Equal ([IO.Path]::GetFullPath($customRoot)) (Get-DefaultProfileRoot -PreferencePath $preferencePath) 'a saved absolute drive path supports Unicode and spaces'
    Assert-Equal $customPreferenceText (Read-Text $preferencePath) 'reading a custom storage directory does not rewrite preferences'
    Assert-Equal 'previous bootstrap preferences must stay untouched' (Read-Text "$preferencePath.bak") 'reading storage preferences does not replace the backup'
    # Inno Setup may persist UTF-8 without a BOM. Windows PowerShell 5.1 must
    # decode it explicitly instead of interpreting the path using its ANSI default.
    [IO.File]::WriteAllText($preferencePath, $customPreferenceText, [Text.UTF8Encoding]::new($false))
    $preferenceBytes = [IO.File]::ReadAllBytes($preferencePath)
    Assert-True (-not ($preferenceBytes[0] -eq 0xef -and $preferenceBytes[1] -eq 0xbb -and $preferenceBytes[2] -eq 0xbf)) 'the Unicode storage fixture is actually UTF-8 without a BOM'
    Assert-Equal ([IO.Path]::GetFullPath($customRoot)) (Get-DefaultProfileRoot -PreferencePath $preferencePath) 'UTF-8 without a BOM preserves the selected Unicode storage path'
    Assert-Equal $customPreferenceText (Read-Text $preferencePath) 'reading BOM-less preferences leaves the original file unchanged'
    $uncRoot = '\\server\share\Research Profiles'
    Write-Text $preferencePath (([pscustomobject]@{SchemaVersion = 1; ProfileRoot = $uncRoot}) | ConvertTo-Json)
    Assert-Equal ([IO.Path]::GetFullPath($uncRoot)) (Get-DefaultProfileRoot -PreferencePath $preferencePath) 'a saved UNC path resolves without accessing the network share'
    $normalizedRoot = 'D:\Research Profiles\prior\..\current'
    Write-Text $preferencePath (([pscustomobject]@{SchemaVersion = 1; ProfileRoot = $normalizedRoot}) | ConvertTo-Json)
    Assert-Equal ([IO.Path]::GetFullPath($normalizedRoot)) (Get-DefaultProfileRoot -PreferencePath $preferencePath) 'storage reader normalizes a rooted path without creating it'
    $badPreferences = @(
        '{ broken JSON',
        'null',
        '[]',
        '[{"SchemaVersion":1,"ProfileRoot":"D:\\Layouts"}]',
        '{}',
        '{"SchemaVersion":1}',
        '{"ProfileRoot":"D:\\Layouts"}',
        '{"SchemaVersion":2,"ProfileRoot":"D:\\Layouts"}',
        '{"SchemaVersion":"1","ProfileRoot":"D:\\Layouts"}',
        '{"SchemaVersion":1.5,"ProfileRoot":"D:\\Layouts"}',
        '{"SchemaVersion":1,"ProfileRoot":null}',
        '{"SchemaVersion":1,"ProfileRoot":42}',
        '{"SchemaVersion":1,"ProfileRoot":[]}',
        '{"SchemaVersion":1,"ProfileRoot":""}',
        '{"SchemaVersion":1,"ProfileRoot":" "}',
        '{"SchemaVersion":1,"ProfileRoot":"relative\\Layouts"}',
        '{"SchemaVersion":1,"ProfileRoot":"D:relative"}',
        '{"SchemaVersion":1,"ProfileRoot":"C:"}',
        '{"SchemaVersion":1,"ProfileRoot":"\\Layouts"}',
        '{"SchemaVersion":1,"ProfileRoot":"/var/layouts"}'
    )
    # Device path aliases can bypass ordinary desktop-root comparisons. Normalize
    # slash variants before rejecting them, and retain the preference on failure.
    foreach ($deviceRoot in @('\\?\C:\data', '\\.\C:\data', '//?/C:/data', '//./C:/data', '\/?\C:/data', '\/.\C:\data')) {
        $badPreferences += ([pscustomobject]@{SchemaVersion = 1; ProfileRoot = $deviceRoot}) | ConvertTo-Json
    }
    foreach ($document in $badPreferences) {
        Write-Text $preferencePath $document
        Assert-Throws { Get-DefaultProfileRoot -PreferencePath $preferencePath } 'corrupt or relative storage preferences stop startup'
        Assert-Equal $document (Read-Text $preferencePath) 'failed storage reads preserve the original preference'
        Assert-Equal 'previous bootstrap preferences must stay untouched' (Read-Text "$preferencePath.bak") 'failed storage reads preserve the preference backup'
    }
    Assert-Equal 2 @(Get-ChildItem -LiteralPath $preferenceArea -Force).Count 'storage preference reads create no migrations or replacement files'

    # Exercise only the entry point's actual preference-resolution guard. The
    # parameter binder supplies PSBoundParameters exactly as the full script does;
    # no OS initialization, desktop access, import or application startup runs.
    $resolutionGuards = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        $_.Extent.Text -match 'Get-DefaultProfileRoot'
    })
    Assert-Equal 1 $resolutionGuards.Count 'the application has one storage preference resolution guard'
    $resolveEntryPreference = [scriptblock]::Create("param([string]`$ProfileRoot)`n" + $resolutionGuards[0].Extent.Text + "`n`$ProfileRoot")
    $defaultProfileReader = (Get-Item -LiteralPath Function:Get-DefaultProfileRoot).ScriptBlock
    $script:storageReaderCalls = 0
    $script:storageReaderValue = $customRoot
    try {
        function Get-DefaultProfileRoot {
            $script:storageReaderCalls++
            return $script:storageReaderValue
        }
        $explicitRoot = 'E:\Explicit Profiles\研究'
        Assert-Equal $explicitRoot (& $resolveEntryPreference -ProfileRoot $explicitRoot) 'an explicit ProfileRoot overrides saved storage preferences'
        Assert-Equal 0 $script:storageReaderCalls 'an explicit ProfileRoot avoids reading storage preferences'
        Assert-Equal $customRoot (& $resolveEntryPreference) 'an omitted ProfileRoot uses the saved storage location'
        Assert-Equal 1 $script:storageReaderCalls 'an omitted ProfileRoot reads storage preferences once'
    }
    finally { Set-Item -LiteralPath Function:Get-DefaultProfileRoot -Value $defaultProfileReader }

    Select-Fixture 'default'
    $settingsPath = Get-SharedDesktopSettingsPath
    Assert-Equal (Join-Path $script:DataRoot 'shared-items.json') $settingsPath 'settings live beneath data, outside the profile list'
    $defaults = @(Get-ConfiguredSharedDesktopNames)
    Assert-Equal 1 $defaults.Count 'a fresh installation has one default shared directory'
    Assert-Equal 'Apps' $defaults[0] 'Apps is the default shared directory'
    Assert-True (-not (Test-Path -LiteralPath $settingsPath)) 'reading defaults does not create settings'
    Assert-True (-not (Test-Path -LiteralPath $script:DataRoot)) 'reading defaults does not create a data directory'
    Assert-Equal 'Apps' (@(Get-ConfiguredSharedDesktopNames)[0]) 'repeated reads retain defaults without writing'

    # Case-insensitive deduplication must preserve only top-level names, in sorted
    # order, and serialize one JSON array even when it has zero or one member.
    $normalized = @(ConvertTo-SharedDesktopNames -Names @('Research', 'apps', 'APPS', 'Dev Files', 'research'))
    Assert-Equal 3 $normalized.Count 'case variants are one configured name'
    Assert-Equal 'apps,dev files,research' (($normalized | ForEach-Object { $_.ToLowerInvariant() }) -join ',') 'configured names are sorted'
    Set-ConfiguredSharedDesktopNames -Names @('Research', 'apps', 'APPS', 'Dev Files', 'research') | Out-Null
    Assert-True (Test-Path -LiteralPath $settingsPath -PathType Leaf) 'saving creates the settings file'
    $customText = Read-Text $settingsPath
    $custom = $customText | ConvertFrom-Json
    Assert-Equal 1 $custom.SchemaVersion 'settings serialize their schema version'
    Assert-True ($custom.Names -is [array]) 'settings names serialize as an array'
    Assert-Equal 'apps,dev files,research' (($custom.Names | ForEach-Object { $_.ToLowerInvariant() }) -join ',') 'persisted custom list is normalized'
    $loaded = @(Get-ConfiguredSharedDesktopNames)
    Assert-Equal 'apps,dev files,research' (($loaded | ForEach-Object { $_.ToLowerInvariant() }) -join ',') 'custom settings survive reload'
    Assert-Equal $customText (Read-Text $settingsPath) 'reading custom settings leaves the file unchanged'
    Assert-True (-not (Test-Path -LiteralPath "$settingsPath.bak")) 'first save has no previous settings to back up'

    Set-ConfiguredSharedDesktopNames -Names @() | Out-Null
    $emptyText = Read-Text $settingsPath
    $empty = $emptyText | ConvertFrom-Json
    Assert-True ($empty.Names -is [array]) 'an empty list remains a JSON array'
    Assert-Equal 0 @($empty.Names).Count 'saving an empty list disables user-configured exclusions'
    Assert-Equal 0 @(Get-ConfiguredSharedDesktopNames).Count 'an explicit empty list does not reinstate Apps'
    Assert-Equal $customText (Read-Text "$settingsPath.bak") 'atomic replacement preserves the previous settings in .bak'

    Set-ConfiguredSharedDesktopNames -Names @('科研项目') | Out-Null
    $singleText = Read-Text $settingsPath
    $single = $singleText | ConvertFrom-Json
    Assert-True ($single.Names -is [array]) 'a single configured name remains a JSON array'
    Assert-Equal '科研项目' (@(Get-ConfiguredSharedDesktopNames)[0]) 'Unicode desktop names survive persistence'
    Assert-Equal $emptyText (Read-Text "$settingsPath.bak") 'a later save backs up the immediately previous settings'

    # Bad input must fail before replacing either the current file or its backup.
    $unsafeNames = @(
        $null, '', ' ', '.', '..', '../Apps', '..\Apps', 'C:\Apps',
        'Apps\Nested', 'Apps/Nested', 'CON', 'con.txt', 'NUL', 'LPT1.log',
        'Apps.', 'Apps ', 'bad:name', 'bad*name', 'bad?name', 'bad"name',
        'bad<name', 'bad>name', 'bad|name',
        ('line' + [char]10 + 'break'), ('null' + [char]0 + 'byte'),
        ('x' * 256), 42, $true, ([pscustomobject]@{Name = 'Apps'})
    )
    foreach ($unsafeName in $unsafeNames) {
        Assert-Throws { ConvertTo-SharedDesktopNames -Names @($unsafeName) } 'unsafe top-level desktop name is rejected'
        Assert-Throws { Set-ConfiguredSharedDesktopNames -Names @($unsafeName) } 'unsafe settings cannot replace saved settings'
        Assert-Equal $singleText (Read-Text $settingsPath) 'invalid input preserves current settings'
        Assert-Equal $emptyText (Read-Text "$settingsPath.bak") 'invalid input preserves previous settings backup'
    }
    Write-Text (Join-Path $script:ProfileRoot 'laboratory.json') '{}'
    Write-Text (Join-Path $script:ProfileRoot '宿舍.json') '{}'
    $profiles = @(Get-SavedProfileNames)
    Assert-Equal 2 $profiles.Count 'shared settings and their backup are not layout profiles'
    Assert-True ($profiles -contains 'laboratory' -and $profiles -contains '宿舍') 'only real profile files are listed'
    Assert-True ($profiles -notcontains 'shared-items') 'settings are absent from the profile dropdown'

    # A user may choose the bootstrap preference's parent as the profile root.
    # Its storage.json must still be excluded from saved layouts; mock the path
    # so this edge case never reads or changes a real user's bootstrap settings.
    $storagePathHelper = (Get-Item -LiteralPath Function:Get-StorageSettingsPath).ScriptBlock
    $script:profileBootstrapFixturePath = Join-Path $script:ProfileRoot 'storage.json'
    Write-Text $script:profileBootstrapFixturePath (([pscustomobject]@{SchemaVersion = 1; ProfileRoot = $script:ProfileRoot}) | ConvertTo-Json)
    try {
        function Get-StorageSettingsPath { return $script:profileBootstrapFixturePath }
        $bootstrapProfiles = @(Get-SavedProfileNames)
        Assert-Equal 2 $bootstrapProfiles.Count 'a bootstrap file inside the chosen profile directory is not a layout'
        Assert-True ($bootstrapProfiles -contains 'laboratory' -and $bootstrapProfiles -contains '宿舍') 'real profiles remain available beside the bootstrap file'
        Assert-True ($bootstrapProfiles -notcontains 'storage') 'the bootstrap preference is absent from the layout dropdown'
    }
    finally {
        Set-Item -LiteralPath Function:Get-StorageSettingsPath -Value $storagePathHelper
        [IO.File]::Delete($script:profileBootstrapFixturePath)
        Remove-Variable -Scope Script -Name profileBootstrapFixturePath
    }

    # A damaged or incompatible settings file must never silently revert to Apps
    # or overwrite the original. A user can repair the retained file deliberately.
    $badDocuments = @(
        '{ broken JSON',
        'null',
        '[]',
        '[{"SchemaVersion":1,"Names":["Apps"]}]',
        '{}',
        '{"SchemaVersion":1}',
        '{"Names":["Apps"]}',
        '{"SchemaVersion":2,"Names":["Apps"]}',
        '{"SchemaVersion":"1","Names":["Apps"]}',
        '{"SchemaVersion":1.5,"Names":["Apps"]}',
        '{"SchemaVersion":1,"Names":null}',
        '{"SchemaVersion":1,"Names":"Apps"}',
        '{"SchemaVersion":1,"Names":{"name":"Apps"}}',
        '{"SchemaVersion":1,"Names":[null]}',
        '{"SchemaVersion":1,"Names":[42]}',
        '{"SchemaVersion":1,"Names":[true]}',
        '{"SchemaVersion":1,"Names":[["Apps"]]}',
        '{"SchemaVersion":1,"Names":["..\\Apps"]}',
        '{"SchemaVersion":1,"Names":["CON.txt"]}',
        '{"SchemaVersion":1,"Names":["Apps "]}'
    )
    foreach ($document in $badDocuments) {
        Write-Text $settingsPath $document
        Assert-Throws { Get-ConfiguredSharedDesktopNames } 'malformed or incompatible settings produce an error'
        Assert-Equal $document (Read-Text $settingsPath) 'failed reads retain the original malformed settings'
        Assert-Equal $emptyText (Read-Text "$settingsPath.bak") 'failed reads retain the settings backup'
    }
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:DataRoot -Filter '*.tmp' -File).Count 'validation and reads leave no pending replacement files'

    # Startup validates settings before any pending desktop transaction repair.
    # Stub only that boundary; the application initialization helper remains real.
    $script:repairCalls = 0
    function Repair-DesktopItemsTransaction {
        param([string]$DataRoot)
        $script:repairCalls++
        return $false
    }
    Assert-Throws { Initialize-LayoutStorage } 'invalid settings stop application initialization'
    Assert-Equal 0 $script:repairCalls 'invalid settings stop before desktop transaction repair'
    Assert-Equal $badDocuments[-1] (Read-Text $settingsPath) 'startup validation preserves the malformed settings'
    Write-Text $settingsPath $singleText
    Initialize-LayoutStorage
    Assert-Equal 1 $script:repairCalls 'valid settings allow initialization to continue to transaction repair'
    Assert-Equal $singleText (Read-Text $settingsPath) 'valid startup reads do not rewrite settings'

    Select-Fixture 'dialog'
    $script:DesktopPath = Join-Path (Join-Path $testRoot 'dialog') 'Desktop'
    $appsDirectory = Join-Path $script:DesktopPath 'Apps'
    [IO.Directory]::CreateDirectory((Join-Path $appsDirectory 'project')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $script:DesktopPath 'Other Research')) | Out-Null
    $projectFile = Join-Path (Join-Path $appsDirectory 'project') 'keep.txt'
    $notesFile = Join-Path $script:DesktopPath 'Notes.txt'
    Write-Text $projectFile 'project content must stay untouched'
    Write-Text $notesFile 'desktop notes must stay untouched'
    Write-Text (Join-Path $script:DesktopPath 'desktop.ini') 'system desktop metadata'
    Write-Text (Join-Path $script:DesktopPath 'DesktopLayoutSwitcher.lnk') 'tool shortcut'
    $owner = [System.Windows.Forms.Form]::new()
    try {
        $saveResult = Invoke-SettingsDialogProbe -Owner $owner -Mode 'Save'
        Assert-Equal ([System.Windows.Forms.DialogResult]::OK) $saveResult 'the save button completes the settings dialog'
        Assert-Equal 'Notes.txt' (@(Get-ConfiguredSharedDesktopNames) -join ',') 'actual CheckedItems are persisted by the save handler'
        $dialogSettingsPath = Get-SharedDesktopSettingsPath
        $dialogSettingsText = Read-Text $dialogSettingsPath
        $cancelResult = Invoke-SettingsDialogProbe -Owner $owner -Mode 'Cancel'
        Assert-Equal ([System.Windows.Forms.DialogResult]::Cancel) $cancelResult 'the cancel button closes the settings dialog'
        Assert-Equal $dialogSettingsText (Read-Text $dialogSettingsPath) 'canceling changed checks preserves saved settings'
        Assert-True (-not (Test-Path -LiteralPath "$dialogSettingsPath.bak")) 'canceling does not replace or back up settings'
        Assert-Equal 'project content must stay untouched' (Read-Text $projectFile) 'editing exclusions leaves folder contents unchanged'
        Assert-Equal 'desktop notes must stay untouched' (Read-Text $notesFile) 'editing exclusions leaves desktop files unchanged'
        Assert-Equal 5 @(Get-ChildItem -LiteralPath $script:DesktopPath -Force).Count 'editing exclusions does not move desktop entries'
    }
    finally { $owner.Dispose() }

    Write-Host "PASS: $script:checks checks; temporary settings and dialog fixtures only, no real desktop touched."
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
