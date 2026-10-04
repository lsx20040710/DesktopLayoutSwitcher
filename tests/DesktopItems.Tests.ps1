# 无 Pester 依赖；可用 Windows PowerShell 5.1 执行。
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DesktopItems.psm1') -Force
$module = Get-Module DesktopItems
$script:checks = 0
$root = Join-Path ([IO.Path]::GetTempPath()) ('DesktopItems-tests-' + [guid]::NewGuid().ToString('N'))
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

    if ($env:OS -eq 'Windows_NT') {
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
    }

    Write-Host "PASS: $script:checks checks; mock desktop only, no real desktop touched."
} finally {
    # The test area contains only fixtures. Real user data is never used by these tests.
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
