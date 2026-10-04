# 无 Pester 依赖；可用 Windows PowerShell 5.1 执行。
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DesktopItems.psm1') -Force
$module = Get-Module DesktopItems
$script:checks = 0
$root = Join-Path ([IO.Path]::GetTempPath()) ('DesktopItems-tests-' + [guid]::NewGuid().ToString('N'))
$crossRoot = $null
$junctions = New-Object 'Collections.Generic.List[string]'
[IO.Directory]::CreateDirectory($root) | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "断言失败：$Message" }
    $script:checks++
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    Assert-True ($Expected -eq $Actual) "$Message；预期 '$Expected'，实际 '$Actual'"
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = $false
    try { & $Action | Out-Null }
    catch {
        $caught = $true
        Assert-True ($_.Exception.Message -match $Pattern) "$Message；错误消息：$($_.Exception.Message)"
    }
    Assert-True $caught "$Message；应当抛出错误"
}

function New-Area([string]$Name) {
    $area = Join-Path $root $Name
    $desktop = Join-Path $area 'Desktop'
    [IO.Directory]::CreateDirectory($desktop) | Out-Null
    return [pscustomobject]@{Desktop = $desktop; Data = (Join-Path $area 'data')}
}

function Write-Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }
function Read-Text([string]$Path) { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }

function New-TestJunction([string]$Path, [string]$Target) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
    [void]$junctions.Add($Path)
}

function Invoke-WithoutDirectoryReads([string[]]$ProtectedPaths, [scriptblock]$Action) {
    # Guard both root identity reads and recursive fingerprints, even when the
    # directory is ordinary and opening its root would otherwise succeed.
    & $module {
        param($ProtectedPath)
        $script:DirectoryTestPaths = @($ProtectedPath)
        $script:DirectoryTestIdentity = ${function:Get-DIIdentity}
        $script:DirectoryTestFingerprint = ${function:Get-DIFingerprint}
        function script:Get-DIIdentity($Item) {
            foreach ($protected in $script:DirectoryTestPaths) {
                if (Test-DIInside $Item.FullName $protected) { throw '目录不应被扫描文件身份。' }
            }
            return & $script:DirectoryTestIdentity $Item
        }
        function script:Get-DIFingerprint([string]$Path) {
            foreach ($protected in $script:DirectoryTestPaths) {
                if (Test-DIInside $Path $protected) { throw '目录不应被扫描内容指纹。' }
            }
            return & $script:DirectoryTestFingerprint $Path
        }
    } $ProtectedPaths
    try { return & $Action }
    finally {
        & $module {
            Set-Item -Path Function:script:Get-DIIdentity -Value $script:DirectoryTestIdentity
            Set-Item -Path Function:script:Get-DIFingerprint -Value $script:DirectoryTestFingerprint
            Remove-Variable -Scope Script -Name DirectoryTestPaths, DirectoryTestIdentity, DirectoryTestFingerprint
        }
    }
}


function New-LegacyDirectory($Area, [string]$Name) {
    return & $module {
        param($DesktopPath, $DataRoot, $Name)
        $state = Get-DIState $DesktopPath $DataRoot
        $record = [pscustomobject]@{Id=[guid]::NewGuid().ToString('N'); Name=$Name; Kind='Directory'; Identity='legacy-directory-identity'; BackupVersion=[guid]::NewGuid().ToString('N'); Fingerprint='legacy-directory-fingerprint'}
        $backup = Get-DIBackupPath $state $record
        $vault = Get-DIVaultPath $state $record.Id
        [IO.Directory]::CreateDirectory($backup) | Out-Null
        [IO.Directory]::CreateDirectory($vault) | Out-Null
        [IO.File]::WriteAllText((Join-Path $backup 'backup.txt'), 'original directory backup')
        [IO.File]::WriteAllText((Join-Path $vault 'archive.txt'), 'original directory archive')
        $state.Catalog.Items = @($state.Catalog.Items) + @($record)
        Write-DIJson $state.CatalogPath $state.Catalog
        return [pscustomobject]@{Record=$record; Backup=$backup; Vault=$vault; SnapshotItem=[pscustomobject]@{Id=$record.Id; Name=$Name; Kind='Directory'}}
    } $Area.Desktop $Area.Data $Name
}

try {
    $area = New-Area 'roundtrip'
    $common = Join-Path $area.Desktop '常用.lnk'
    $extra = Join-Path $area.Desktop '实验室.url'
    $folder = Join-Path $area.Desktop '科研资料'
    Write-Text $common 'shortcut bytes'
    Write-Text (Join-Path $area.Desktop 'desktop.ini') 'reserved'
    Write-Text (Join-Path $area.Desktop 'DesktopLayoutSwitcher.lnk') 'tool'
    $shared = @('DesktopLayoutSwitcher.lnk')
    $small = Save-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -SharedNames $shared
    Assert-Equal 1 $small.Items.Count '共享入口和 desktop.ini 不加入场景集合'
    Write-Text $extra 'url bytes'
    [IO.Directory]::CreateDirectory((Join-Path $folder '空目录')) | Out-Null
    Write-Text (Join-Path $folder '结果.txt') 'first result'
    Write-Text (Join-Path $folder '将删除.txt') 'obsolete result'
    $big = Save-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -SharedNames $shared
    Assert-Equal 2 $big.Items.Count '场景集合仅包含普通文件，目录只由主界面记住位置'
    $result = Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $small -SharedNames $shared
    Assert-Equal 1 $result.Stashed '小屏仅收纳多余文件'
    Assert-True (Test-Path -LiteralPath $folder) '普通目录始终留在桌面'
    Assert-True (Test-Path -LiteralPath (Join-Path $area.Desktop 'desktop.ini')) '保留 desktop.ini'
    Assert-True (Test-Path -LiteralPath (Join-Path $area.Desktop 'DesktopLayoutSwitcher.lnk')) '保留工具入口'
    $result = Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $big -SharedNames $shared
    Assert-Equal 1 $result.Restored '大屏仅补齐缺失文件'
    Assert-Equal 'url bytes' (Read-Text $extra) '快捷方式文件内容保持完整'
    Assert-Equal 'first result' (Read-Text (Join-Path $folder '结果.txt')) '目录内容保持完整'
    Assert-True (Test-Path -LiteralPath (Join-Path $folder '空目录')) '空目录保持完整'

    Write-Text (Join-Path $folder '结果.txt') 'latest edited result'
    Write-Text (Join-Path $folder '新结果.txt') 'added while active'
    [IO.File]::Delete((Join-Path $folder '将删除.txt'))
    Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $small -SharedNames $shared | Out-Null
    Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $big -SharedNames $shared | Out-Null
    Assert-Equal 'latest edited result' (Read-Text (Join-Path $folder '结果.txt')) '目录最新修改优先于旧备份'
    Assert-Equal 'added while active' (Read-Text (Join-Path $folder '新结果.txt')) '目录新增文件保持'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $folder '将删除.txt'))) '目录已删除子项不会由旧备份重新出现'

    # Editors replace files instead of writing in place. The scene should retain its logical ID.
    $replacement = Join-Path $area.Desktop 'replacement.tmp'
    Write-Text $replacement 'atomic editor replacement'
    [IO.File]::Delete($common)
    [IO.File]::Move($replacement, $common)
    $afterEdit = Save-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -SharedNames $shared
    $commonBefore = @($small.Items | Where-Object Name -eq '常用.lnk')[0]
    $commonAfter = @($afterEdit.Items | Where-Object Name -eq '常用.lnk')[0]
    Assert-Equal $commonBefore.Id $commonAfter.Id '编辑器原子替换沿用逻辑 ID'
    Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $small -SharedNames $shared | Out-Null
    Assert-Equal 'atomic editor replacement' (Read-Text $common) '切回旧场景保留文档新内容'

    Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $big -SharedNames $shared | Out-Null
    [IO.File]::Delete($extra)
    Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $small -SharedNames $shared | Out-Null
    Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $big -SharedNames $shared | Out-Null
    Assert-Equal 'url bytes' (Read-Text $extra) '手动删除后由备份补齐'
    $afterBackupRestore = Save-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -SharedNames $shared
    Assert-Equal (@($big.Items | Where-Object Name -eq '实验室.url')[0].Id) (@($afterBackupRestore.Items | Where-Object Name -eq '实验室.url')[0].Id) '备份恢复后的 ID 在再次保存时稳定'
    Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $small -SharedNames $shared | Out-Null
    Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $big -SharedNames $shared | Out-Null
    Assert-Equal 'url bytes' (Read-Text $extra) '备份补齐后可再次往返'

    $newItem = Join-Path $area.Desktop '临时新增.txt'
    Write-Text $newItem 'new desktop item'
    Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $small -SharedNames $shared | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $newItem)) '未保存到目标场景的新项目安全收纳'
    Restore-AllDesktopItems -DesktopPath $area.Desktop -DataRoot $area.Data -SharedNames $shared | Out-Null
    Assert-Equal 'new desktop item' (Read-Text $newItem) '可显式找回所有收纳项目'

    $emptySnapshot = [pscustomobject]@{Version = 2; Items = @()}
    Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $emptySnapshot -SharedNames $shared | Out-Null
    [IO.Directory]::CreateDirectory($common) | Out-Null
    Write-Text (Join-Path $common 'collision.txt') 'keep collision directory'
    $folderCollisionResult = Invoke-WithoutDirectoryReads $common { Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $small -SharedNames $shared }
    Assert-Equal 1 $folderCollisionResult.PreservedDirectory '旧文件名称现在是目录时安全跳过'
    Assert-Equal 'keep collision directory' (Read-Text (Join-Path $common 'collision.txt')) '同名目录仍保持完整'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $area.Data 'transaction.json'))) '预检冲突不留下半次切换'

    $sameType = New-Area 'same-type-conflict'
    $name = Join-Path $sameType.Desktop 'research.txt'
    Write-Text $name 'original research'
    $originalScene = Save-DesktopItemsSnapshot -DesktopPath $sameType.Desktop -DataRoot $sameType.Data
    Restore-DesktopItemsSnapshot -DesktopPath $sameType.Desktop -DataRoot $sameType.Data -Snapshot $emptySnapshot | Out-Null
    Write-Text $name 'independent new research'
    Assert-Throws { Restore-DesktopItemsSnapshot -DesktopPath $sameType.Desktop -DataRoot $sameType.Data -Snapshot $originalScene } '同名.*冲突' 'vault 中旧文件与新同名文件不同身份时拒绝覆盖'
    Assert-Equal 'independent new research' (Read-Text $name) '新同名文件保持完整'
    $catalog = Read-Text (Join-Path $sameType.Data 'items.json') | ConvertFrom-Json
    $originalRecord = @($catalog.Items | Where-Object Id -eq $originalScene.Items[0].Id)[0]
    Assert-Equal 'original research' (Read-Text (Join-Path (Join-Path $catalog.VaultRoot $originalRecord.Id) 'content')) '旧同名文件在 vault 保持完整'

    $renamed = New-Area 'rename-and-replace'
    $foo = Join-Path $renamed.Desktop 'foo.txt'
    $zzz = Join-Path $renamed.Desktop 'zzz.txt'
    Write-Text $foo 'original renamed file'
    $beforeRename = Save-DesktopItemsSnapshot -DesktopPath $renamed.Desktop -DataRoot $renamed.Data
    [IO.File]::Move($foo, $zzz)
    Write-Text $foo 'independent new file'
    $afterRename = Save-DesktopItemsSnapshot -DesktopPath $renamed.Desktop -DataRoot $renamed.Data
    $oldId = $beforeRename.Items[0].Id
    Assert-Equal $oldId (@($afterRename.Items | Where-Object Name -eq 'zzz.txt')[0].Id) '重命名原文件沿用原逻辑 ID'
    Assert-True ($oldId -ne @($afterRename.Items | Where-Object Name -eq 'foo.txt')[0].Id) '原实体仍存在时新同名文件取得独立 ID'
    Assert-Throws { Restore-DesktopItemsSnapshot -DesktopPath $renamed.Desktop -DataRoot $renamed.Data -Snapshot $beforeRename } '同名.*冲突' '重命名后新建同名项目不误关联旧场景'
    Assert-Equal 'original renamed file' (Read-Text $zzz) '重命名原件保持完整'
    Assert-Equal 'independent new file' (Read-Text $foo) '新同名项目保持完整'

    # Exclusive lock rejects a simultaneous instance without changing the desktop.
    $lockArea = New-Area 'locked'
    Write-Text (Join-Path $lockArea.Desktop 'a.txt') 'locked source'
    Save-DesktopItemsSnapshot -DesktopPath $lockArea.Desktop -DataRoot $lockArea.Data | Out-Null
    $lock = New-Object IO.FileStream((Join-Path $lockArea.Data '.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-Throws { Save-DesktopItemsSnapshot -DesktopPath $lockArea.Desktop -DataRoot $lockArea.Data } '另一个.*使用' '同一数据目录独占锁' }
    finally { $lock.Dispose() }
    Assert-Equal 'locked source' (Read-Text (Join-Path $lockArea.Desktop 'a.txt')) '锁冲突不更改文件'
    $sourceLock = New-Object IO.FileStream((Join-Path $lockArea.Desktop 'a.txt'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-Throws { Restore-DesktopItemsSnapshot -DesktopPath $lockArea.Desktop -DataRoot $lockArea.Data -Snapshot $emptySnapshot } '.' '文件被占用时暂停切换' }
    finally { $sourceLock.Dispose() }
    Assert-Equal 'locked source' (Read-Text (Join-Path $lockArea.Desktop 'a.txt')) '文件占用失败后原始数据保留'

    # Model a crash after the filesystem move but before its journal completion update.
    $crash = New-Area 'interrupted'
    $crashFile = Join-Path $crash.Desktop 'important.txt'
    Write-Text $crashFile 'must survive a crash'
    $crashScene = Save-DesktopItemsSnapshot -DesktopPath $crash.Desktop -DataRoot $crash.Data
    & $module {
        param($DesktopPath, $DataRoot, $Id)
        $state = Get-DIState $DesktopPath $DataRoot
        $destination = Get-DIVaultPath $state $Id
        $tid = [guid]::NewGuid().ToString('N')
        $op = [pscustomobject]@{Mode='Move'; ItemId=$Id; Source=(Join-Path $DesktopPath 'important.txt'); Destination=$destination; State='Started'; RecoveryPath=(Join-Path (Join-Path (Join-Path $state.VaultRoot 'recovery') $tid) '0')}
        $journal = [pscustomobject]@{Version=1; Id=$tid; DesktopPath=$state.DesktopPath; VaultRoot=$state.VaultRoot; Status='Pending'; CatalogBefore=$state.Catalog; Operations=@($op)}
        Write-DIJson (Join-Path $DataRoot 'transaction.json') $journal
        Move-DIItem $op.Source $op.Destination
    } $crash.Desktop $crash.Data $crashScene.Items[0].Id
    Assert-True (-not (Test-Path -LiteralPath $crashFile)) '模拟中断确实已移动文件'
    Assert-True (Repair-DesktopItemsTransaction -DataRoot $crash.Data) '启动可恢复未完成事务'
    Assert-Equal 'must survive a crash' (Read-Text $crashFile) '恢复原始桌面内容'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $crash.Data 'transaction.json'))) '恢复完成清理事务元数据'
    Assert-True (-not (Repair-DesktopItemsTransaction -DataRoot $crash.Data)) '重复恢复幂等'

    # An operation fails after an earlier move succeeds. Roll back without overwriting its obstacle.
    $failed = New-Area 'mid-transaction-failure'
    Write-Text (Join-Path $failed.Desktop 'one.txt') 'first source'
    Write-Text (Join-Path $failed.Desktop 'two.txt') 'second source'
    $failedScene = Save-DesktopItemsSnapshot -DesktopPath $failed.Desktop -DataRoot $failed.Data
    Assert-Throws {
        & $module {
            param($DesktopPath, $DataRoot, $Items)
            $state = Get-DIState $DesktopPath $DataRoot
            $ops = @()
            foreach ($item in $Items) {
                $destination = Get-DIVaultPath $state $item.Id
                $ops += [pscustomobject]@{Mode='Move'; ItemId=$item.Id; Source=(Join-Path $DesktopPath $item.Name); Destination=$destination; State='Pending'}
            }
            New-DIDirectory ([IO.Path]::GetDirectoryName($ops[1].Destination))
            [IO.File]::WriteAllText($ops[1].Destination, 'independent obstacle')
            Invoke-DITransaction $state $ops
        } $failed.Desktop $failed.Data $failedScene.Items
    } '暂停并恢复原桌面' '第二项失败时恢复第一项'
    Assert-Equal 'first source' (Read-Text (Join-Path $failed.Desktop 'one.txt')) '先前移动的第一项已回滚'
    Assert-Equal 'second source' (Read-Text (Join-Path $failed.Desktop 'two.txt')) '失败项的源保留'
    $catalog = Read-Text (Join-Path $failed.Data 'items.json') | ConvertFrom-Json
    $second = @($failedScene.Items | Where-Object Name -eq 'two.txt')[0]
    Assert-Equal 'independent obstacle' (Read-Text (Join-Path (Join-Path $catalog.VaultRoot $second.Id) 'content')) '独立目标内容未被回滚覆盖'

    $malformed = [pscustomobject]@{Version=2; Items=@([pscustomobject]@{Id=[guid]::NewGuid().ToString('N'); Name='..\outside.txt'; Kind='File'})}
    Assert-Throws { Restore-DesktopItemsSnapshot -DesktopPath $crash.Desktop -DataRoot $crash.Data -Snapshot $malformed } '无效.*名称' '拒绝路径穿越场景'
    Assert-Throws { Restore-DesktopItemsSnapshot -DesktopPath $crash.Desktop -DataRoot $crash.Data -Snapshot ([pscustomobject]@{Version=1; Items=@()}) } 'Version=2' '旧版本集合不会修改桌面'

    # Real directories are excluded without requiring SharedNames. Legacy
    # snapshots/catalogs/backup/vault are handcrafted because new saves never
    # create directory entries or directory backups.
    $directories = New-Area 'all-directories-position-only'
    $apps = Join-Path $directories.Desktop 'Apps'
    $plainFolder = Join-Path $directories.Desktop 'Research'
    [IO.Directory]::CreateDirectory((Join-Path $apps 'diet-tracker/node_modules')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $plainFolder 'Empty')) | Out-Null
    Write-Text (Join-Path $apps 'project.txt') 'untouched project'
    Write-Text (Join-Path $plainFolder 'result.txt') 'untouched research'
    Write-Text (Join-Path $directories.Desktop 'regular.txt') 'ordinary file'
    $filesOnly = Invoke-WithoutDirectoryReads @($apps, $plainFolder) {
        Save-DesktopItemsSnapshot -DesktopPath $directories.Desktop -DataRoot $directories.Data
    }
    Assert-Equal 1 $filesOnly.Items.Count '不设共有名单也仅捕获桌面文件'
    $newCatalog = Read-Text (Join-Path $directories.Data 'items.json') | ConvertFrom-Json
    Assert-Equal 0 @($newCatalog.Items | Where-Object Kind -eq 'Directory').Count '新索引没有任何目录记录'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $directories.Data 'backup') -Directory).Count '新备份仅属于普通文件'
    $onlyFilesEmpty = Invoke-WithoutDirectoryReads @($apps, $plainFolder) {
        Restore-DesktopItemsSnapshot -DesktopPath $directories.Desktop -DataRoot $directories.Data -Snapshot $emptySnapshot
    }
    Assert-Equal 1 $onlyFilesEmpty.Stashed '空场景仅收纳普通文件'
    Assert-Equal 'untouched project' (Read-Text (Join-Path $apps 'project.txt')) '空场景不移动或修改 Apps'
    Assert-True (Test-Path -LiteralPath (Join-Path $plainFolder 'Empty')) '普通空目录保持原处'
    $newFolder = Join-Path $directories.Desktop 'AddedAfterSave'
    [IO.Directory]::CreateDirectory($newFolder) | Out-Null
    Write-Text (Join-Path $newFolder 'added.txt') 'new directory remains'
    [IO.Directory]::Delete($plainFolder, $true)
    Invoke-WithoutDirectoryReads @($apps, $newFolder) {
        Restore-DesktopItemsSnapshot -DesktopPath $directories.Desktop -DataRoot $directories.Data -Snapshot $filesOnly
    } | Out-Null
    Assert-Equal 'new directory remains' (Read-Text (Join-Path $newFolder 'added.txt')) '切换忽略后来新增的目录'
    Assert-True (-not (Test-Path -LiteralPath $plainFolder)) '切换不会补齐手动删除的目录'

    $legacy = New-Area 'legacy-directory-archive'
    $legacyApps = Join-Path $legacy.Desktop 'Apps'
    [IO.Directory]::CreateDirectory($legacyApps) | Out-Null
    Write-Text (Join-Path $legacyApps 'current.txt') 'latest current directory'
    $legacyFile = Join-Path $legacy.Desktop 'common.lnk'
    Write-Text $legacyFile 'original shortcut'
    $legacyFileScene = Save-DesktopItemsSnapshot -DesktopPath $legacy.Desktop -DataRoot $legacy.Data
    $legacyDirectory = New-LegacyDirectory $legacy 'Apps'
    $legacyScene = [pscustomobject]@{Version=2; Items=@($legacyFileScene.Items) + @($legacyDirectory.SnapshotItem)}
    $legacySceneJson = $legacyScene | ConvertTo-Json -Depth 30
    $legacyDirectoryJson = $legacyDirectory.Record | ConvertTo-Json -Depth 30
    [IO.File]::Delete($legacyFile)
    Write-Text (Join-Path $legacy.Desktop 'other.txt') 'ordinary extra file'
    $legacyResult = Invoke-WithoutDirectoryReads @($legacyApps, $legacyDirectory.Backup, $legacyDirectory.Vault) {
        Restore-DesktopItemsSnapshot -DesktopPath $legacy.Desktop -DataRoot $legacy.Data -Snapshot $legacyScene
    }
    Assert-Equal 1 $legacyResult.PreservedDirectory '旧场景目录条目在运行时忽略'
    Assert-Equal 1 $legacyResult.Restored '忽略目录后旧场景普通文件仍补齐'
    Assert-Equal 1 $legacyResult.Stashed '忽略目录后普通多余文件仍收纳'
    Assert-Equal 'latest current directory' (Read-Text (Join-Path $legacyApps 'current.txt')) '旧目录快照不覆盖当前目录内容'
    Assert-Equal $legacySceneJson ($legacyScene | ConvertTo-Json -Depth 30) '不改写旧 Version=2 场景对象'
    $legacyCatalog = Read-Text (Join-Path $legacy.Data 'items.json') | ConvertFrom-Json
    $legacyAfter = @($legacyCatalog.Items | Where-Object Id -eq $legacyDirectory.Record.Id)[0]
    Assert-Equal $legacyDirectoryJson ($legacyAfter | ConvertTo-Json -Depth 30) '旧目录索引元数据完全保持'
    Assert-Equal 'original directory backup' (Read-Text (Join-Path $legacyDirectory.Backup 'backup.txt')) '旧目录备份保留原内容'
    Assert-Equal 'original directory archive' (Read-Text (Join-Path $legacyDirectory.Vault 'archive.txt')) '旧目录档案留在原 canonical vault'
    $renamedFolder = Join-Path $legacy.Desktop 'RenamedProject'
    [IO.Directory]::Move($legacyApps, $renamedFolder)
    Invoke-WithoutDirectoryReads @($renamedFolder, $legacyDirectory.Backup, $legacyDirectory.Vault) {
        Restore-DesktopItemsSnapshot -DesktopPath $legacy.Desktop -DataRoot $legacy.Data -Snapshot $legacyScene
    } | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $legacyApps)) '旧目录名缺失时不从档案或备份补齐'
    Assert-Equal 'latest current directory' (Read-Text (Join-Path $renamedFolder 'current.txt')) '目录重命名后仍忽略内容和位置以外操作'
    $directoryIdAsFile = [pscustomobject]@{Version=2; Items=@([pscustomobject]@{Id=$legacyDirectory.Record.Id; Name='historical-file.txt'; Kind='File'})}
    $badKindResult = Invoke-WithoutDirectoryReads @($renamedFolder, $legacyDirectory.Backup, $legacyDirectory.Vault) {
        Restore-DesktopItemsSnapshot -DesktopPath $legacy.Desktop -DataRoot $legacy.Data -Snapshot $directoryIdAsFile
    }
    Assert-Equal 1 $badKindResult.PreservedDirectory '旧目录 ID 被标记为文件时也跳过'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $legacy.Desktop 'historical-file.txt'))) '不通过伪装文件条目取回旧目录'
    $allFilesResult = Invoke-WithoutDirectoryReads @($renamedFolder, $legacyDirectory.Backup, $legacyDirectory.Vault) {
        Restore-AllDesktopItems -DesktopPath $legacy.Desktop -DataRoot $legacy.Data
    }
    Assert-Equal 1 $allFilesResult.PreservedDirectory '取回操作汇报保留的旧目录档案'
    Assert-Equal 2 $allFilesResult.Restored '取回操作只恢复普通文件档案'
    Assert-True (-not (Test-Path -LiteralPath $legacyApps)) '取回操作不会恢复旧目录'
    Assert-Equal 'original directory archive' (Read-Text (Join-Path $legacyDirectory.Vault 'archive.txt')) '取回后旧目录档案仍留原处'
    Write-Text $legacyApps 'new independent file with old directory name'
    $independentFileScene = Invoke-WithoutDirectoryReads @($renamedFolder, $legacyDirectory.Backup, $legacyDirectory.Vault) {
        Save-DesktopItemsSnapshot -DesktopPath $legacy.Desktop -DataRoot $legacy.Data
    }
    $independentFile = @($independentFileScene.Items | Where-Object Name -eq 'Apps')[0]
    Assert-True ($independentFile.Id -ne $legacyDirectory.Record.Id) '旧目录名称的新文件有独立身份'
    Invoke-WithoutDirectoryReads @($renamedFolder, $legacyDirectory.Backup, $legacyDirectory.Vault) {
        Restore-DesktopItemsSnapshot -DesktopPath $legacy.Desktop -DataRoot $legacy.Data -Snapshot $independentFileScene
    } | Out-Null
    Assert-Equal 'new independent file with old directory name' (Read-Text $legacyApps) '旧目录索引不会干扰同名新文件的场景'

    # A historical file target that is now a real directory is ignored silently.
    # Other archived files still return and no identity read opens that directory.
    $shadow = New-Area 'file-target-now-directory'
    $shadowPath = Join-Path $shadow.Desktop 'old-file.txt'
    Write-Text $shadowPath 'old file bytes'
    $shadowScene = Save-DesktopItemsSnapshot -DesktopPath $shadow.Desktop -DataRoot $shadow.Data
    Restore-DesktopItemsSnapshot -DesktopPath $shadow.Desktop -DataRoot $shadow.Data -Snapshot $emptySnapshot | Out-Null
    [IO.Directory]::CreateDirectory($shadowPath) | Out-Null
    Write-Text (Join-Path $shadowPath 'keep.txt') 'new directory contents'
    $caseShadow = $shadowScene | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $caseShadow.Items[0].Name = 'OLD-FILE.TXT'
    $shadowResult = Invoke-WithoutDirectoryReads $shadowPath {
        Restore-DesktopItemsSnapshot -DesktopPath $shadow.Desktop -DataRoot $shadow.Data -Snapshot $caseShadow
    }
    Assert-Equal 1 $shadowResult.PreservedDirectory '文件目标与目录名称冲突忽略大小写并跳过'
    Assert-Equal 0 $shadowResult.Restored '当前目录不会被历史文件替换'
    Write-Text (Join-Path $shadow.Desktop 'extra.txt') 'extra file still managed'
    Invoke-WithoutDirectoryReads $shadowPath {
        Restore-DesktopItemsSnapshot -DesktopPath $shadow.Desktop -DataRoot $shadow.Data -Snapshot $emptySnapshot
    } | Out-Null
    $shadowAll = Invoke-WithoutDirectoryReads $shadowPath {
        Restore-AllDesktopItems -DesktopPath $shadow.Desktop -DataRoot $shadow.Data
    }
    Assert-Equal 1 $shadowAll.PreservedDirectory '取回档案也跳过当前目录名称冲突'
    Assert-Equal 1 $shadowAll.Restored '目录名称冲突不阻断其他文件取回'
    Assert-Equal 'new directory contents' (Read-Text (Join-Path $shadowPath 'keep.txt')) '当前目录内容始终保留'
    $shadowCatalog = Read-Text (Join-Path $shadow.Data 'items.json') | ConvertFrom-Json
    $shadowVault = Join-Path (Join-Path $shadowCatalog.VaultRoot $shadowScene.Items[0].Id) 'content'
    Assert-Equal 'old file bytes' (Read-Text $shadowVault) '历史同名文件仍留收纳库'

    # Complete a pending old-version directory transaction once. The rollback
    # exception restores original paths; it never creates a new folder operation.
    $oldCrash = New-Area 'old-directory-transaction'
    $oldDirectory = New-LegacyDirectory $oldCrash 'OldProjects'
    [IO.Directory]::Delete($oldDirectory.Vault, $true)
    $oldDesktopFolder = Join-Path $oldCrash.Desktop 'OldProjects'
    [IO.Directory]::CreateDirectory($oldDesktopFolder) | Out-Null
    Write-Text (Join-Path $oldDesktopFolder 'important.txt') 'original moved directory'
    & $module {
        param($DesktopPath, $DataRoot, $Id, $Destination)
        $state = Get-DIState $DesktopPath $DataRoot
        $tid = [guid]::NewGuid().ToString('N')
        $op = [pscustomobject]@{Mode='Move'; ItemId=$Id; Source=(Join-Path $DesktopPath 'OldProjects'); Destination=$Destination; State='Started'; RecoveryPath=(Join-Path (Join-Path (Join-Path $state.VaultRoot 'recovery') $tid) '0')}
        $journal = [pscustomobject]@{Version=1; Id=$tid; DesktopPath=$state.DesktopPath; VaultRoot=$state.VaultRoot; Status='Pending'; CatalogBefore=$state.Catalog; Operations=@($op)}
        Write-DIJson (Join-Path $DataRoot 'transaction.json') $journal
        [IO.Directory]::Move($op.Source, $op.Destination)
    } $oldCrash.Desktop $oldCrash.Data $oldDirectory.Record.Id $oldDirectory.Vault
    Assert-True (Repair-DesktopItemsTransaction -DataRoot $oldCrash.Data) '旧版本未完成目录移动可回滚一次'
    Assert-Equal 'original moved directory' (Read-Text (Join-Path $oldDesktopFolder 'important.txt')) '旧目录事务回滚恢复原始内容和路径'
    Assert-True (-not (Repair-DesktopItemsTransaction -DataRoot $oldCrash.Data)) '旧目录事务回滚完成后幂等'
    $postRepair = Invoke-WithoutDirectoryReads @($oldDesktopFolder, $oldDirectory.Backup) {
        Restore-DesktopItemsSnapshot -DesktopPath $oldCrash.Desktop -DataRoot $oldCrash.Data -Snapshot $emptySnapshot
    }
    Assert-Equal 0 $postRepair.Stashed '旧事务修复后不会再次管理该目录'
    Assert-Equal 'original moved directory' (Read-Text (Join-Path $oldDesktopFolder 'important.txt')) '修复后切换仍保留目录原处'
    Assert-Throws { & $module { param($Path) Get-DIFingerprint $Path } $oldDesktopFolder } '文件夹.*不处理' '底层内容指纹拒绝目录'
    Assert-Throws { & $module { param($Source,$Destination) Copy-DIItem $Source $Destination } $oldDesktopFolder (Join-Path $root 'forbidden-copy') } '文件夹.*不处理' '底层复制拒绝目录'
    Assert-Throws { & $module { param($Source,$Destination) Move-DIItem $Source $Destination } $oldDesktopFolder (Join-Path $root 'forbidden-move') } '文件夹.*不移动' '新事务底层移动拒绝目录'
    Assert-True (Test-Path -LiteralPath $oldDesktopFolder) '底层目录防护失败时保留原处'

    $orphanDirectoryScene = [pscustomobject]@{Version=2; Items=@([pscustomobject]@{Id=[guid]::NewGuid().ToString('N'); Name='DeletedFolder'; Kind='Directory'})}
    $orphanResult = Restore-DesktopItemsSnapshot -DesktopPath $oldCrash.Desktop -DataRoot $oldCrash.Data -Snapshot $orphanDirectoryScene
    Assert-Equal 1 $orphanResult.PreservedDirectory '旧目录条目索引缺失时仍忽略而不报错'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $oldCrash.Desktop 'DeletedFolder'))) '旧目录条目索引缺失时不创建目录'
    $malformedDirectory = [pscustomobject]@{Version=2; Items=@([pscustomobject]@{Id=$oldDirectory.Record.Id; Name='..\outside'; Kind='Directory'})}
    Assert-Throws { Restore-DesktopItemsSnapshot -DesktopPath $oldCrash.Desktop -DataRoot $oldCrash.Data -Snapshot $malformedDirectory } '无效.*名称' '忽略目录条目前仍验证路径名称'

    $oldCopyPath = Join-Path $oldCrash.Desktop 'InterruptedDirectoryCopy'
    [IO.Directory]::CreateDirectory($oldCopyPath) | Out-Null
    Write-Text (Join-Path $oldCopyPath 'edited.txt') 'edited interrupted directory copy'
    $oldCopyRecovery = & $module {
        param($DesktopPath, $DataRoot, $Id, $Source, $Destination)
        $state = Get-DIState $DesktopPath $DataRoot
        $tid = [guid]::NewGuid().ToString('N')
        $recovery = Join-Path (Join-Path (Join-Path $state.VaultRoot 'recovery') $tid) '0'
        $op = [pscustomobject]@{Mode='Copy'; ItemId=$Id; Source=$Source; Destination=$Destination; State='Started'; RecoveryPath=$recovery}
        $journal = [pscustomobject]@{Version=1; Id=$tid; DesktopPath=$state.DesktopPath; VaultRoot=$state.VaultRoot; Status='Pending'; CatalogBefore=$state.Catalog; Operations=@($op)}
        Write-DIJson (Join-Path $DataRoot 'transaction.json') $journal
        return $recovery
    } $oldCrash.Desktop $oldCrash.Data $oldDirectory.Record.Id $oldDirectory.Backup $oldCopyPath
    Assert-True (Repair-DesktopItemsTransaction -DataRoot $oldCrash.Data) '旧版本未完成目录复制也能安全回滚'
    Assert-True (-not (Test-Path -LiteralPath $oldCopyPath)) '旧复制事务的未完成副本离开桌面'
    Assert-Equal 'edited interrupted directory copy' (Read-Text (Join-Path $oldCopyRecovery 'edited.txt')) '旧复制回滚保留副本后来编辑在 recovery'
    Assert-Equal 'original directory backup' (Read-Text (Join-Path $oldDirectory.Backup 'backup.txt')) '旧复制回滚保留原目录备份'

    if ($env:OS -eq 'Windows_NT') {
        # Nested pnpm junctions and top-level directory junctions are both ignored.
        $pnpmShared = New-Area 'pnpm-directories-position-only'
        $pnpmApps = Join-Path $pnpmShared.Desktop 'Apps'
        $pnpmPath = Join-Path $pnpmApps 'diet-tracker\node_modules\.pnpm\@babel+code-frame@7.29.7\node_modules\@babel\helper-validator-identifier'
        $pnpmOutside = Join-Path $root 'pnpm-save-outside'
        [IO.Directory]::CreateDirectory($pnpmOutside) | Out-Null
        Write-Text (Join-Path $pnpmOutside 'sentinel.txt') 'pnpm target untouched'
        New-TestJunction $pnpmPath $pnpmOutside
        Write-Text (Join-Path $pnpmShared.Desktop 'regular.txt') 'regular file still backed up'
        $pnpmScene = Invoke-WithoutDirectoryReads @($pnpmApps, $pnpmOutside) {
            Save-DesktopItemsSnapshot -DesktopPath $pnpmShared.Desktop -DataRoot $pnpmShared.Data
        }
        Assert-Equal 1 $pnpmScene.Items.Count '未设共有名单的 pnpm 目录不阻断保存'
        $pnpmCatalog = Read-Text (Join-Path $pnpmShared.Data 'items.json') | ConvertFrom-Json
        Assert-Equal 0 @($pnpmCatalog.Items | Where-Object Kind -eq 'Directory').Count 'pnpm 目录不写入内容索引'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $pnpmShared.Data 'backup') -Directory).Count 'pnpm 目录不创建备份'
        Invoke-WithoutDirectoryReads @($pnpmApps, $pnpmOutside) {
            Restore-DesktopItemsSnapshot -DesktopPath $pnpmShared.Desktop -DataRoot $pnpmShared.Data -Snapshot $emptySnapshot
        } | Out-Null
        Assert-True (([IO.File]::GetAttributes($pnpmPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) '嵌套 pnpm 联接保持原位置'
        Assert-Equal 'pnpm target untouched' (Read-Text (Join-Path $pnpmOutside 'sentinel.txt')) 'pnpm 外部目标保持完整'

        $links = New-Area 'junction'
        $outside = Join-Path $root 'outside-target'
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        Write-Text (Join-Path $outside 'outside.txt') 'outside must remain untouched'
        $junction = Join-Path $links.Desktop 'LinkedFolder'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        $junctionScene = Invoke-WithoutDirectoryReads @($junction, $outside) { Save-DesktopItemsSnapshot -DesktopPath $links.Desktop -DataRoot $links.Data }
        Assert-Equal 0 $junctionScene.Items.Count '顶层目录联接也只保存位置，不作为文件处理'
        Invoke-WithoutDirectoryReads @($junction, $outside) { Restore-DesktopItemsSnapshot -DesktopPath $links.Desktop -DataRoot $links.Data -Snapshot $emptySnapshot } | Out-Null
        Assert-True (Test-Path -LiteralPath $junction) '空场景保留顶层目录联接'
        Assert-Equal 'outside must remain untouched' (Read-Text (Join-Path $outside 'outside.txt')) '链接目标未被移动或修改'
        # Remove just the junction, never recursively remove its target.
        [IO.Directory]::Delete($junction)

        # File symbolic links retain the preflight protection; ordinary .lnk/.url
        # shortcut files remain managed and never lead to target-directory scans.
        $fileLinkArea = New-Area 'file-symbolic-link-protection'
        $fileLink = Join-Path $fileLinkArea.Desktop 'linked-file.txt'
        $linkTarget = Join-Path $outside 'outside.txt'
        New-Item -ItemType SymbolicLink -Path $fileLink -Target $linkTarget | Out-Null
        try {
            Assert-Throws { Save-DesktopItemsSnapshot -DesktopPath $fileLinkArea.Desktop -DataRoot $fileLinkArea.Data } '链接.*云占位' '顶层文件符号链接仍被预检拒绝'
            Assert-Equal 'outside must remain untouched' (Read-Text $linkTarget) '文件链接目标保持原内容'
        } finally { [IO.File]::Delete($fileLink) }

        # GitHub's Windows runner checks out on D: while Temp is on C:. Exercise
        # the actual cross-volume backup path without touching a real user desktop.
        $repositoryRoot = Split-Path $PSScriptRoot -Parent
        $repositoryVolume = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($repositoryRoot))
        $temporaryVolume = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root))
        if (-not $repositoryVolume.Equals($temporaryVolume, [StringComparison]::OrdinalIgnoreCase)) {
            $crossRoot = Join-Path (Join-Path $repositoryRoot 'artifacts') ('cross-volume-' + [guid]::NewGuid().ToString('N'))
            $crossDesktop = Join-Path $crossRoot 'Desktop'
            $crossData = Join-Path $root 'cross-volume-data'
            [IO.Directory]::CreateDirectory($crossDesktop) | Out-Null
            $crossCommon = Join-Path $crossDesktop 'common.txt'
            $crossExtra = Join-Path $crossDesktop 'large-screen.lnk'
            $crossFolder = Join-Path $crossDesktop 'Research'
            Write-Text $crossCommon 'shared cross-volume document'
            $crossSmall = Save-DesktopItemsSnapshot -DesktopPath $crossDesktop -DataRoot $crossData
            Write-Text $crossExtra 'cross-volume shortcut bytes'
            [IO.Directory]::CreateDirectory((Join-Path $crossFolder 'Empty')) | Out-Null
            Write-Text (Join-Path $crossFolder 'result.txt') 'cross-volume folder content'
            $crossBig = Save-DesktopItemsSnapshot -DesktopPath $crossDesktop -DataRoot $crossData
            $crossResult = Restore-DesktopItemsSnapshot -DesktopPath $crossDesktop -DataRoot $crossData -Snapshot $crossSmall
            Assert-Equal 1 $crossResult.Stashed '跨盘桌面仅收纳文件'
            Assert-True (Test-Path -LiteralPath $crossFolder) '跨盘目录始终保持原处'
            Assert-Equal $repositoryVolume ([IO.Path]::GetPathRoot($crossResult.VaultRoot)) '跨盘收纳库与桌面处于同一盘'
            Assert-True (-not $crossResult.VaultRoot.StartsWith($crossData + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) '跨盘收纳库不放在数据目录盘'
            $hiddenSibling = [IO.Path]::GetDirectoryName($crossResult.VaultRoot)
            Assert-Equal '.DesktopLayoutSwitcher-vault' ([IO.Path]::GetFileName($hiddenSibling)) '跨盘收纳库使用独立 sibling'
            Assert-True (([IO.File]::GetAttributes($hiddenSibling) -band [IO.FileAttributes]::Hidden) -ne 0) '跨盘 sibling 设置为隐藏目录'
            Restore-DesktopItemsSnapshot -DesktopPath $crossDesktop -DataRoot $crossData -Snapshot $crossBig | Out-Null
            Assert-Equal 'cross-volume shortcut bytes' (Read-Text $crossExtra) '同卷移动往返保持文件完整'
            Assert-Equal 'cross-volume folder content' (Read-Text (Join-Path $crossFolder 'result.txt')) '同卷移动往返保持目录完整'
            Assert-True (Test-Path -LiteralPath (Join-Path $crossFolder 'Empty')) '跨盘切换不触碰目录及空子目录'
            Write-Text (Join-Path $crossFolder 'result.txt') 'latest cross-volume folder edit'
            [IO.File]::Delete($crossExtra)
            Restore-DesktopItemsSnapshot -DesktopPath $crossDesktop -DataRoot $crossData -Snapshot $crossSmall | Out-Null
            Restore-DesktopItemsSnapshot -DesktopPath $crossDesktop -DataRoot $crossData -Snapshot $crossBig | Out-Null
            Assert-Equal 'cross-volume shortcut bytes' (Read-Text $crossExtra) '从另一盘备份复制到同卷准备目录后补齐缺失文件'
            Assert-Equal 'latest cross-volume folder edit' (Read-Text (Join-Path $crossFolder 'result.txt')) '跨盘数据目录保留目录最新内容'
            $crossRestored = Save-DesktopItemsSnapshot -DesktopPath $crossDesktop -DataRoot $crossData
            Assert-Equal (@($crossBig.Items | Where-Object Name -eq 'large-screen.lnk')[0].Id) (@($crossRestored.Items | Where-Object Name -eq 'large-screen.lnk')[0].Id) '跨盘备份补齐后逻辑 ID 稳定'
            Restore-DesktopItemsSnapshot -DesktopPath $crossDesktop -DataRoot $crossData -Snapshot $crossSmall | Out-Null
            Restore-DesktopItemsSnapshot -DesktopPath $crossDesktop -DataRoot $crossData -Snapshot $crossBig | Out-Null
            Assert-Equal 'cross-volume shortcut bytes' (Read-Text $crossExtra) '跨盘备份补齐后再次往返成功'
        } else {
            Write-Host 'SKIP: cross-volume fixture needs different repository and Temp volumes.'
        }
    }

    Write-Host "PASS: $script:checks checks; mock desktop only, no real desktop touched."
} finally {
    # Remove junction entries without descending into their targets.
    foreach ($junctionPath in $junctions) {
        if (Test-Path -LiteralPath $junctionPath) { [IO.Directory]::Delete($junctionPath) }
    }
    # The test area contains only fixtures. Real user data is never used by these tests.
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    if ($null -ne $crossRoot -and (Test-Path -LiteralPath $crossRoot)) { Remove-Item -LiteralPath $crossRoot -Recurse -Force }
}
