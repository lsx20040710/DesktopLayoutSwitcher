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

function Invoke-WithoutSharedReads([string[]]$SharedPath, [scriptblock]$Action) {
    # Guard both root identity reads and recursive fingerprints, even when the
    # shared directory is ordinary and opening its root would otherwise succeed.
    & $module {
        param($ProtectedPath)
        $script:SharedTestPaths = @($ProtectedPath)
        $script:SharedTestIdentity = ${function:Get-DIIdentity}
        $script:SharedTestFingerprint = ${function:Get-DIFingerprint}
        function script:Get-DIIdentity($Item) {
            foreach ($protected in $script:SharedTestPaths) {
                if (Test-DIInside $Item.FullName $protected) { throw '共享目录不应被扫描文件身份。' }
            }
            return & $script:SharedTestIdentity $Item
        }
        function script:Get-DIFingerprint([string]$Path) {
            foreach ($protected in $script:SharedTestPaths) {
                if (Test-DIInside $Path $protected) { throw '共享目录不应被扫描内容指纹。' }
            }
            return & $script:SharedTestFingerprint $Path
        }
    } $SharedPath
    try { return & $Action }
    finally {
        & $module {
            Set-Item -Path Function:script:Get-DIIdentity -Value $script:SharedTestIdentity
            Set-Item -Path Function:script:Get-DIFingerprint -Value $script:SharedTestFingerprint
            Remove-Variable -Scope Script -Name SharedTestPaths, SharedTestIdentity, SharedTestFingerprint
        }
    }
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
    Assert-Equal 3 $big.Items.Count '大屏集合包含快捷方式、URL 和文件夹'
    $result = Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $small -SharedNames $shared
    Assert-Equal 2 $result.Stashed '小屏收纳多余两个项目'
    Assert-True (-not (Test-Path -LiteralPath $folder)) '目录已离开桌面'
    Assert-True (Test-Path -LiteralPath (Join-Path $area.Desktop 'desktop.ini')) '保留 desktop.ini'
    Assert-True (Test-Path -LiteralPath (Join-Path $area.Desktop 'DesktopLayoutSwitcher.lnk')) '保留工具入口'
    $result = Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $big -SharedNames $shared
    Assert-Equal 2 $result.Restored '大屏补齐两个项目'
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
    Assert-Throws { Restore-DesktopItemsSnapshot -DesktopPath $area.Desktop -DataRoot $area.Data -Snapshot $small -SharedNames $shared } '同名.*冲突' '文件和目录同名时拒绝覆盖'
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

    # A scene saved before exclusions still contains Apps. Applying the global
    # list must leave it intact while restoring/stashing all ordinary entries.
    $legacyShared = New-Area 'legacy-shared-scene'
    $legacyApps = Join-Path $legacyShared.Desktop 'Apps'
    $projectModules = Join-Path (Join-Path $legacyApps 'diet-tracker') 'node_modules'
    [IO.Directory]::CreateDirectory($projectModules) | Out-Null
    Write-Text (Join-Path $legacyApps 'project.txt') 'original project'
    $legacyCommon = Join-Path $legacyShared.Desktop 'common.lnk'
    Write-Text $legacyCommon 'original shortcut'
    $legacyScene = Save-DesktopItemsSnapshot -DesktopPath $legacyShared.Desktop -DataRoot $legacyShared.Data
    $legacySceneJson = $legacyScene | ConvertTo-Json -Depth 30
    $beforeCatalog = Read-Text (Join-Path $legacyShared.Data 'items.json') | ConvertFrom-Json
    $beforeApps = @($beforeCatalog.Items | Where-Object Name -eq 'Apps')[0]
    $oldAppsBackup = Join-Path (Join-Path (Join-Path (Join-Path $legacyShared.Data 'backup') $beforeApps.Id) $beforeApps.BackupVersion) 'content'
    Write-Text (Join-Path $legacyApps 'project.txt') 'latest project, keep on desktop'
    if ($env:OS -eq 'Windows_NT') {
        $legacyOutside = Join-Path $root 'legacy-pnpm-outside'
        [IO.Directory]::CreateDirectory($legacyOutside) | Out-Null
        Write-Text (Join-Path $legacyOutside 'sentinel.txt') 'pnpm target must remain untouched'
        $legacyLink = Join-Path $projectModules '@babel\helper-validator-identifier'
        New-TestJunction $legacyLink $legacyOutside
    }
    [IO.File]::Delete($legacyCommon)
    Write-Text (Join-Path $legacyShared.Desktop 'other.txt') 'stash this ordinary file'
    $legacyResult = Invoke-WithoutSharedReads @($legacyApps, $oldAppsBackup) {
        Restore-DesktopItemsSnapshot -DesktopPath $legacyShared.Desktop -DataRoot $legacyShared.Data -Snapshot $legacyScene -SharedNames @('aPpS')
    }
    Assert-Equal 1 $legacyResult.PreservedShared '旧快照共有条目按名称忽略大小写安全跳过'
    Assert-Equal 1 $legacyResult.Restored '跳过旧 Apps 后其他缺失快捷方式仍补齐'
    Assert-Equal 1 $legacyResult.Stashed '跳过旧 Apps 后其他多余文件仍收纳'
    Assert-Equal 'original shortcut' (Read-Text $legacyCommon) '旧场景普通快捷方式正常恢复'
    Assert-Equal 'latest project, keep on desktop' (Read-Text (Join-Path $legacyApps 'project.txt')) '旧场景不把 Apps 恢复成旧内容'
    Assert-Equal $legacySceneJson ($legacyScene | ConvertTo-Json -Depth 30) '运行时过滤不改写旧场景'
    $afterCatalog = Read-Text (Join-Path $legacyShared.Data 'items.json') | ConvertFrom-Json
    $afterApps = @($afterCatalog.Items | Where-Object Id -eq $beforeApps.Id)[0]
    Assert-Equal $beforeApps.Identity $afterApps.Identity '共有项目旧索引身份保持不变'
    Assert-Equal $beforeApps.BackupVersion $afterApps.BackupVersion '共有项目不创建新备份'
    Assert-Equal $beforeApps.Fingerprint $afterApps.Fingerprint '共有项目不更新内容指纹'
    Assert-Equal 'original project' (Read-Text (Join-Path $oldAppsBackup 'project.txt')) '已有共有项目备份保持原内容'
    $sharedCurrent = Invoke-WithoutSharedReads @($legacyApps, $oldAppsBackup) {
        Save-DesktopItemsSnapshot -DesktopPath $legacyShared.Desktop -DataRoot $legacyShared.Data -SharedNames @('APPS')
    }
    Assert-Equal 1 $sharedCurrent.Items.Count '新保存仅记录普通桌面项目'
    Assert-Equal 0 @($sharedCurrent.Items | Where-Object Name -eq 'Apps').Count '新快照排除 Apps'
    $emptySharedResult = Invoke-WithoutSharedReads @($legacyApps, $oldAppsBackup) {
        Restore-DesktopItemsSnapshot -DesktopPath $legacyShared.Desktop -DataRoot $legacyShared.Data -Snapshot $emptySnapshot -SharedNames @('apps')
    }
    Assert-Equal 1 $emptySharedResult.Stashed '空场景仅收纳普通项目'
    Assert-True (Test-Path -LiteralPath $legacyApps) '空场景不会收纳 Apps'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $afterCatalog.VaultRoot $beforeApps.Id) 'content'))) 'Apps 未进入收纳库'
    if ($env:OS -eq 'Windows_NT') {
        Assert-True (([IO.File]::GetAttributes($legacyLink) -band [IO.FileAttributes]::ReparsePoint) -ne 0) '旧场景中的 pnpm 联接保持原位置'
        Assert-Equal 'pnpm target must remain untouched' (Read-Text (Join-Path $legacyOutside 'sentinel.txt')) '旧场景共享目录的外部目标保持完整'
    }

    # An Apps copy archived by an older version stays archived, even when a
    # different Apps folder now exists on the desktop. Other archives still return.
    $sharedVault = New-Area 'shared-vault'
    $vaultApps = Join-Path $sharedVault.Desktop 'Apps'
    [IO.Directory]::CreateDirectory($vaultApps) | Out-Null
    Write-Text (Join-Path $vaultApps 'original.txt') 'archived Apps version'
    Write-Text (Join-Path $sharedVault.Desktop 'return.txt') 'return ordinary file'
    $vaultScene = Save-DesktopItemsSnapshot -DesktopPath $sharedVault.Desktop -DataRoot $sharedVault.Data
    Restore-DesktopItemsSnapshot -DesktopPath $sharedVault.Desktop -DataRoot $sharedVault.Data -Snapshot $emptySnapshot | Out-Null
    $vaultCatalog = Read-Text (Join-Path $sharedVault.Data 'items.json') | ConvertFrom-Json
    $vaultAppsRecord = @($vaultCatalog.Items | Where-Object Name -eq 'Apps')[0]
    $canonicalVaultApps = Join-Path (Join-Path $vaultCatalog.VaultRoot $vaultAppsRecord.Id) 'content'
    $vaultAppsBackup = Join-Path (Join-Path (Join-Path (Join-Path $sharedVault.Data 'backup') $vaultAppsRecord.Id) $vaultAppsRecord.BackupVersion) 'content'
    [IO.Directory]::CreateDirectory($vaultApps) | Out-Null
    Write-Text (Join-Path $vaultApps 'current.txt') 'current Apps version'
    $restoreAllResult = Invoke-WithoutSharedReads @($vaultApps, $canonicalVaultApps, $vaultAppsBackup) {
        Restore-AllDesktopItems -DesktopPath $sharedVault.Desktop -DataRoot $sharedVault.Data -SharedNames @('apps')
    }
    Assert-Equal 1 $restoreAllResult.PreservedShared '取回收纳项目汇报保留的共有档案条数'
    Assert-Equal 1 $restoreAllResult.Restored '取回收纳项目仍恢复其他档案'
    Assert-Equal 'return ordinary file' (Read-Text (Join-Path $sharedVault.Desktop 'return.txt')) '普通收纳文件完整取回'
    Assert-Equal 'current Apps version' (Read-Text (Join-Path $vaultApps 'current.txt')) '取回操作保留现有 Apps'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $vaultApps 'original.txt'))) '不补齐或合并已有 Apps 的旧内容'
    Assert-Equal 'archived Apps version' (Read-Text (Join-Path $canonicalVaultApps 'original.txt')) '共有档案仍保留在原 canonical vault 路径'
    Assert-Equal 'archived Apps version' (Read-Text (Join-Path $vaultAppsBackup 'original.txt')) '共有档案旧备份保持完整'
    $vaultCatalogAfter = Read-Text (Join-Path $sharedVault.Data 'items.json') | ConvertFrom-Json
    $vaultAppsAfter = @($vaultCatalogAfter.Items | Where-Object Id -eq $vaultAppsRecord.Id)[0]
    Assert-Equal $vaultAppsRecord.Identity $vaultAppsAfter.Identity '未取回共有档案的索引身份不变'
    Assert-Equal $vaultAppsRecord.BackupVersion $vaultAppsAfter.BackupVersion '未取回共有档案的备份版本不变'
    [IO.Directory]::Delete($vaultApps, $true)
    $skipMissingShared = Restore-DesktopItemsSnapshot -DesktopPath $sharedVault.Desktop -DataRoot $sharedVault.Data -Snapshot $vaultScene -SharedNames @('APPS')
    Assert-Equal 1 $skipMissingShared.PreservedShared '旧场景中的缺失共有项目也跳过'
    Assert-True (-not (Test-Path -LiteralPath $vaultApps)) '共有项目缺失时不自动补齐'
    Assert-Equal 'archived Apps version' (Read-Text (Join-Path $canonicalVaultApps 'original.txt')) '跳过缺失共有项目后其收纳副本仍完整'
    $historicalAliasScene = $vaultScene | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    @($historicalAliasScene.Items | Where-Object Name -eq 'Apps')[0].Name = 'FormerApps'
    $aliasResult = Restore-DesktopItemsSnapshot -DesktopPath $sharedVault.Desktop -DataRoot $sharedVault.Data -Snapshot $historicalAliasScene -SharedNames @('Apps')
    Assert-Equal 1 $aliasResult.PreservedShared '旧场景使用曾用名称时仍按共有档案身份保护'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sharedVault.Desktop 'FormerApps'))) '共有档案不会通过旧名称被取回'
    $aliasCatalog = Read-Text (Join-Path $sharedVault.Data 'items.json') | ConvertFrom-Json
    Assert-Equal 'Apps' (@($aliasCatalog.Items | Where-Object Id -eq $vaultAppsRecord.Id)[0].Name) '跳过旧名称后共有索引名称不变'
    Assert-Throws { Save-DesktopItemsSnapshot -DesktopPath $sharedVault.Desktop -DataRoot $sharedVault.Data -SharedNames @('..\Apps') } '无效.*名称' '共有名单不能接受路径穿越名称'
    Assert-Throws { Restore-DesktopItemsSnapshot -DesktopPath $sharedVault.Desktop -DataRoot $sharedVault.Data -Snapshot $malformed -SharedNames @('Apps') } '无效.*名称' '过滤共有项目时仍拒绝非法场景路径'

    if ($env:OS -eq 'Windows_NT') {
        # Native Windows identities survive real directory renames. A record
        # whose former shared name is stale must not cause its wanted current
        # ordinary directory to be omitted from the target and then stashed.
        $renamedShared = New-Area 'shared-name-renamed-back'
        $formerApps = Join-Path $renamedShared.Desktop 'FormerApps'
        $renamedApps = Join-Path $renamedShared.Desktop 'Apps'
        [IO.Directory]::CreateDirectory($formerApps) | Out-Null
        Write-Text (Join-Path $formerApps 'important.txt') 'renamed project must stay'
        $formerScene = Save-DesktopItemsSnapshot -DesktopPath $renamedShared.Desktop -DataRoot $renamedShared.Data
        [IO.Directory]::Move($formerApps, $renamedApps)
        $renamedAppsScene = Save-DesktopItemsSnapshot -DesktopPath $renamedShared.Desktop -DataRoot $renamedShared.Data
        Assert-Equal $formerScene.Items[0].Id $renamedAppsScene.Items[0].Id '真实重命名为 Apps 保持同一项目身份'
        $protectedAlias = Invoke-WithoutSharedReads $renamedApps {
            Restore-DesktopItemsSnapshot -DesktopPath $renamedShared.Desktop -DataRoot $renamedShared.Data -Snapshot $formerScene -SharedNames @('Apps')
        }
        Assert-Equal 1 $protectedAlias.PreservedShared '真实曾用名称不取回当前共有 Apps 的副本'
        Assert-Equal 0 $protectedAlias.Stashed '真实共有 Apps 不被收纳'
        Assert-True (-not (Test-Path -LiteralPath $formerApps)) 'Apps 仍共有时不以曾用名称创建副本'
        Assert-Equal 'renamed project must stay' (Read-Text (Join-Path $renamedApps 'important.txt')) '共有 Apps 项目保持原位置内容'
        [IO.Directory]::Move($renamedApps, $formerApps)
        # No save after the second rename: the catalog still says Apps here.
        $renamedBack = Restore-DesktopItemsSnapshot -DesktopPath $renamedShared.Desktop -DataRoot $renamedShared.Data -Snapshot $formerScene -SharedNames @('Apps')
        Assert-Equal 0 $renamedBack.PreservedShared '已改回普通名称的项目不再按过期索引排除'
        Assert-Equal 0 $renamedBack.Stashed '目标中已存在的改名普通目录不会被错误收纳'
        Assert-Equal 0 $renamedBack.Restored '目标中已存在的改名普通目录无需补齐'
        Assert-Equal 'renamed project must stay' (Read-Text (Join-Path $formerApps 'important.txt')) '未保存的改名目录恢复原场景后留在桌面'
        $renamedBackCatalog = Read-Text (Join-Path $renamedShared.Data 'items.json') | ConvertFrom-Json
        $renamedBackRecord = @($renamedBackCatalog.Items | Where-Object Id -eq $formerScene.Items[0].Id)[0]
        Assert-Equal 'FormerApps' $renamedBackRecord.Name '共有身份保护依据捕获后的当前名称'
        $renamedBackEmpty = Restore-DesktopItemsSnapshot -DesktopPath $renamedShared.Desktop -DataRoot $renamedShared.Data -Snapshot $emptySnapshot -SharedNames @('Apps')
        Assert-Equal 1 $renamedBackEmpty.Stashed '改回普通名称的目录仍可按场景正常收纳'
        Restore-DesktopItemsSnapshot -DesktopPath $renamedShared.Desktop -DataRoot $renamedShared.Data -Snapshot $formerScene -SharedNames @('Apps') | Out-Null
        Assert-Equal 'renamed project must stay' (Read-Text (Join-Path $formerApps 'important.txt')) '改回普通名称的目录仍可正常往返'

        # Reproduce pnpm's nested junction beneath Desktop/Apps. Initial saves
        # must not inspect identities, fingerprint or back up this directory.
        $pnpmShared = New-Area 'shared-pnpm-initial-save'
        $pnpmApps = Join-Path $pnpmShared.Desktop 'Apps'
        $pnpmPath = Join-Path $pnpmApps 'diet-tracker\node_modules\.pnpm\@babel+code-frame@7.29.7\node_modules\@babel\helper-validator-identifier'
        $pnpmOutside = Join-Path $root 'pnpm-save-outside'
        [IO.Directory]::CreateDirectory($pnpmOutside) | Out-Null
        Write-Text (Join-Path $pnpmOutside 'sentinel.txt') 'initial pnpm target'
        New-TestJunction $pnpmPath $pnpmOutside
        Write-Text (Join-Path $pnpmShared.Desktop 'regular.txt') 'regular file still backed up'
        $pnpmScene = Invoke-WithoutSharedReads $pnpmApps {
            Save-DesktopItemsSnapshot -DesktopPath $pnpmShared.Desktop -DataRoot $pnpmShared.Data -SharedNames @('Apps')
        }
        Assert-Equal 1 $pnpmScene.Items.Count '含嵌套 pnpm 联接的共有 Apps 不阻断保存'
        $pnpmCatalog = Read-Text (Join-Path $pnpmShared.Data 'items.json') | ConvertFrom-Json
        Assert-Equal 0 @($pnpmCatalog.Items | Where-Object Name -eq 'Apps').Count '共有 Apps 不扫描或写入项目身份索引'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $pnpmShared.Data 'backup') -Directory).Count '仅普通文件有备份，不复制 Apps'
        Assert-Equal 'initial pnpm target' (Read-Text (Join-Path $pnpmOutside 'sentinel.txt')) '初次保存不修改 pnpm 外部目标'
        Assert-Throws { Save-DesktopItemsSnapshot -DesktopPath $pnpmShared.Desktop -DataRoot $pnpmShared.Data } '链接.*云占位' 'Apps 未设为共有时仍保留链接保护'
        Assert-Equal 'regular file still backed up' (Read-Text (Join-Path $pnpmShared.Desktop 'regular.txt')) '非共有链接预检失败不移动普通文件'

        $links = New-Area 'junction'
        $outside = Join-Path $root 'outside-target'
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        Write-Text (Join-Path $outside 'outside.txt') 'outside must remain untouched'
        $junction = Join-Path $links.Desktop 'LinkedFolder'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        Assert-Throws { Save-DesktopItemsSnapshot -DesktopPath $links.Desktop -DataRoot $links.Data } '链接.*云占位' '备份不跟随目录联接'
        Assert-Equal 'outside must remain untouched' (Read-Text (Join-Path $outside 'outside.txt')) '链接目标未被移动或修改'
        # Remove just the junction, never recursively remove its target.
        [IO.Directory]::Delete($junction)

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
            Assert-Equal 2 $crossResult.Stashed '跨盘桌面收纳文件与目录'
            Assert-Equal $repositoryVolume ([IO.Path]::GetPathRoot($crossResult.VaultRoot)) '跨盘收纳库与桌面处于同一盘'
            Assert-True (-not $crossResult.VaultRoot.StartsWith($crossData + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) '跨盘收纳库不放在数据目录盘'
            $hiddenSibling = [IO.Path]::GetDirectoryName($crossResult.VaultRoot)
            Assert-Equal '.DesktopLayoutSwitcher-vault' ([IO.Path]::GetFileName($hiddenSibling)) '跨盘收纳库使用独立 sibling'
            Assert-True (([IO.File]::GetAttributes($hiddenSibling) -band [IO.FileAttributes]::Hidden) -ne 0) '跨盘 sibling 设置为隐藏目录'
            Restore-DesktopItemsSnapshot -DesktopPath $crossDesktop -DataRoot $crossData -Snapshot $crossBig | Out-Null
            Assert-Equal 'cross-volume shortcut bytes' (Read-Text $crossExtra) '同卷移动往返保持文件完整'
            Assert-Equal 'cross-volume folder content' (Read-Text (Join-Path $crossFolder 'result.txt')) '同卷移动往返保持目录完整'
            Assert-True (Test-Path -LiteralPath (Join-Path $crossFolder 'Empty')) '跨盘备份和移动保留空目录'
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
