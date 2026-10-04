# Windows PowerShell 5.1 compatible. 桌面项目只收纳，不永久删除。
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-DIFullPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full -eq $root) { return $root }
    return $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-DIInside([string]$Path, [string]$Root) {
    $p = Get-DIFullPath $Path
    $r = Get-DIFullPath $Root
    return $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DIHashText([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-DIVaultRoot([string]$DesktopPath, [string]$DataRoot) {
    if ([IO.Path]::GetPathRoot($DesktopPath).Equals([IO.Path]::GetPathRoot($DataRoot), [StringComparison]::OrdinalIgnoreCase)) {
        return Join-Path $DataRoot 'vault'
    }
    # Desktop may be on D: while LocalAppData is on C:. Keep moves on its original volume.
    $sibling = Join-Path ([IO.Path]::GetDirectoryName($DesktopPath)) '.DesktopLayoutSwitcher-vault'
    return Join-Path $sibling (Get-DIHashText $DataRoot.ToUpperInvariant()).Substring(0, 16)
}

function Assert-DIName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -eq '.' -or $Name -eq '..' -or $Name -match '[\\/:*?"<>|]' -or $Name.EndsWith('.') -or $Name.EndsWith(' ')) {
        throw "无效的桌面项目名称：$Name"
    }
}

function Assert-DIId([string]$Id) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Id, [ref]$parsed) -or $parsed.ToString('N') -ne $Id) { throw "无效的项目 ID：$Id" }
}

function Assert-DINotReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "为保护原始数据，暂不处理链接或云占位项目：$Path。可将其桌面顶层文件夹加入始终保留在桌面名单，或使用完整下载的普通文件副本。"
    }
    return $item
}

function Assert-DITreeSafe([string]$Path) {
    $item = Assert-DINotReparse $Path
    if ($item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) { Assert-DITreeSafe $child.FullName }
    }
}

function New-DIDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Assert-DINotReparse $Path
        if (-not $item.PSIsContainer) { throw "存储路径不是目录：$Path" }
    } else { [IO.Directory]::CreateDirectory($Path) | Out-Null }
}

function Write-DIJson([string]$Path, $Value) {
    New-DIDirectory ([IO.Path]::GetDirectoryName($Path))
    $temporary = $Path + '.tmp.' + [guid]::NewGuid().ToString('N')
    $bytes = (New-Object Text.UTF8Encoding($true)).GetBytes(($Value | ConvertTo-Json -Depth 30))
    $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    # PowerShell binds $null to an empty string for a .NET string parameter.
    # NullString passes an actual null backup name to File.Replace on both 5.1 and 7.
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Read-DIJson([string]$Path) {
    return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Enter-DILock([string]$DataRoot) {
    New-DIDirectory $DataRoot
    $lockPath = Join-Path $DataRoot '.lock'
    try { return New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw "此数据目录正在被另一个切换器使用，或无权访问：$DataRoot。请关闭另一实例后重试。" }
}

function Get-DIState([string]$DesktopPath, [string]$DataRoot) {
    $DesktopPath = Get-DIFullPath $DesktopPath
    $DataRoot = Get-DIFullPath $DataRoot
    $desktop = Assert-DINotReparse $DesktopPath
    if (-not $desktop.PSIsContainer) { throw "桌面路径不是目录：$DesktopPath" }
    if (Test-DIInside $DataRoot $DesktopPath) { throw '数据目录必须放在桌面之外，避免将备份再次收纳。' }
    $vaultRoot = Get-DIVaultRoot $DesktopPath $DataRoot
    New-DIDirectory $vaultRoot
    New-DIDirectory (Join-Path $DataRoot 'backup')
    if ($env:OS -eq 'Windows_NT' -and -not (Test-DIInside $vaultRoot $DataRoot)) {
        $hiddenRoot = [IO.Path]::GetDirectoryName($vaultRoot)
        [IO.File]::SetAttributes($hiddenRoot, ([IO.File]::GetAttributes($hiddenRoot) -bor [IO.FileAttributes]::Hidden))
    }
    $catalogPath = Join-Path $DataRoot 'items.json'
    if (Test-Path -LiteralPath $catalogPath) {
        $catalog = Read-DIJson $catalogPath
        if ($catalog.Version -ne 1 -or -not (Get-DIFullPath $catalog.DesktopPath).Equals($DesktopPath, [StringComparison]::OrdinalIgnoreCase) -or -not (Get-DIFullPath $catalog.VaultRoot).Equals($vaultRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw '项目索引与桌面路径不一致。请使用原数据目录或恢复原桌面路径，不要覆盖现有索引。'
        }
    } else { $catalog = [pscustomobject]@{Version = 1; DesktopPath = $DesktopPath; VaultRoot = $vaultRoot; Items = @()} }
    foreach ($item in @($catalog.Items)) {
        Assert-DIId $item.Id
        Assert-DIName $item.Name
        if ($item.Kind -notin @('File', 'Directory')) { throw '项目索引包含无效类型。' }
        if (-not [string]::IsNullOrEmpty($item.BackupVersion)) { Assert-DIId $item.BackupVersion }
    }
    return [pscustomobject]@{DesktopPath = $DesktopPath; DataRoot = $DataRoot; VaultRoot = $vaultRoot; CatalogPath = $catalogPath; Catalog = $catalog}
}

function Initialize-DIIdentityType {
    if ('DesktopItemsNative.Identity' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace DesktopItemsNative {
    public static class Identity {
        [StructLayout(LayoutKind.Sequential)] struct Info {
            public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation;
            public System.Runtime.InteropServices.ComTypes.FILETIME Access;
            public System.Runtime.InteropServices.ComTypes.FILETIME Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h, out Info info);
        public static string Read(string path) {
            using(var h = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                Info i;
                if (h.IsInvalid || !GetFileInformationByHandle(h, out i)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                return i.Volume.ToString("x8") + ":" + i.IndexHigh.ToString("x8") + i.IndexLow.ToString("x8") + ":" + i.Creation.dwHighDateTime.ToString("x8") + i.Creation.dwLowDateTime.ToString("x8");
            }
        }
    }
}
'@
}

function Get-DIIdentity($Item) {
    if ($env:OS -eq 'Windows_NT') {
        Initialize-DIIdentityType
        return [DesktopItemsNative.Identity]::Read($Item.FullName)
    }
    # Only used by portable mock-desktop tests; real Windows uses volume + file ID.
    return 'test:' + $Item.CreationTimeUtc.Ticks + ':' + $Item.Name
}

function Get-DISharedSet([string[]]$SharedNames) {
    $set = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$set.Add('desktop.ini')
    foreach ($name in @($SharedNames)) { if (-not [string]::IsNullOrWhiteSpace($name)) { Assert-DIName $name; [void]$set.Add($name) } }
    return ,$set
}

function Get-DIDesktopEntries($State, $SharedSet) {
    return @(Get-ChildItem -LiteralPath $State.DesktopPath -Force -ErrorAction Stop | Where-Object { -not $SharedSet.Contains($_.Name) })
}

function Get-DIFileHash([string]$Path) {
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Add-DIFingerprintEntries([string]$Path, [string]$RelativePath, $Lines) {
    $item = Assert-DINotReparse $Path
    if ($item.PSIsContainer) {
        [void]$Lines.Add('D:' + $RelativePath)
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Sort-Object Name)) {
            Add-DIFingerprintEntries $child.FullName ($RelativePath + '/' + $child.Name) $Lines
        }
    } else { [void]$Lines.Add('F:' + $RelativePath + ':' + $item.Length + ':' + (Get-DIFileHash $Path)) }
}

function Get-DIFingerprint([string]$Path) {
    $lines = New-Object 'Collections.Generic.List[string]'
    Add-DIFingerprintEntries $Path '' $lines
    return Get-DIHashText ([string]::Join("`n", $lines.ToArray()))
}

function Copy-DIItem([string]$Source, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) { throw "拒绝覆盖已有项目：$Destination" }
    $item = Assert-DINotReparse $Source
    New-DIDirectory ([IO.Path]::GetDirectoryName($Destination))
    if ($item.PSIsContainer) {
        New-DIDirectory $Destination
        foreach ($child in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) { Copy-DIItem $child.FullName (Join-Path $Destination $child.Name) }
        [IO.Directory]::SetCreationTimeUtc($Destination, $item.CreationTimeUtc)
        [IO.Directory]::SetLastWriteTimeUtc($Destination, $item.LastWriteTimeUtc)
    } else {
        # Hold a read-only sharing lock while CopyFile preserves streams and attributes.
        $readLock = New-Object IO.FileStream($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { [IO.File]::Copy($Source, $Destination, $false) }
        finally { $readLock.Dispose() }
    }
    [IO.File]::SetAttributes($Destination, $item.Attributes)
}

function Move-DIItem([string]$Source, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) { throw "拒绝覆盖已有项目：$Destination" }
    $item = Assert-DINotReparse $Source
    New-DIDirectory ([IO.Path]::GetDirectoryName($Destination))
    if ($item.PSIsContainer) { [IO.Directory]::Move($Source, $Destination) }
    else { [IO.File]::Move($Source, $Destination) }
}

function Get-DIVaultPath($State, [string]$Id) {
    Assert-DIId $Id
    return Join-Path (Join-Path $State.VaultRoot $Id) 'content'
}

function Get-DIBackupPath($State, $Item) {
    Assert-DIId $Item.Id
    Assert-DIId $Item.BackupVersion
    return Join-Path (Join-Path (Join-Path (Join-Path $State.DataRoot 'backup') $Item.Id) $Item.BackupVersion) 'content'
}

function Save-DICore($State, $SharedSet) {
    $entries = @(Get-DIDesktopEntries $State $SharedSet)
    # Validate all trees before creating a backup; never follow a directory junction.
    foreach ($entry in $entries) { Assert-DIName $entry.Name; Assert-DITreeSafe $entry.FullName }
    $identityByPath = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $presentIdentities = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        $physicalIdentity = Get-DIIdentity $entry
        $identityByPath.Add($entry.FullName, $physicalIdentity)
        [void]$presentIdentities.Add($physicalIdentity)
    }
    $captured = New-Object 'Collections.Generic.List[object]'
    foreach ($entry in $entries) {
        $kind = if ($entry.PSIsContainer) { 'Directory' } else { 'File' }
        $identity = $identityByPath[$entry.FullName]
        $existing = @($State.Catalog.Items | Where-Object { $_.Identity -eq $identity -and $_.Kind -eq $kind })
        if ($existing.Count -eq 0) {
            # Editors often replace a document atomically. Keep its logical scene identity
            # when the old physical item is gone and there is no independent vaulted copy.
            $sameName = @($State.Catalog.Items | Where-Object { $_.Name -eq $entry.Name -and $_.Kind -eq $kind -and -not $presentIdentities.Contains($_.Identity) -and -not (Test-Path -LiteralPath (Get-DIVaultPath $State $_.Id)) })
            if ($sameName.Count -eq 1) { $existing = $sameName }
        }
        if ($existing.Count -gt 1) { throw '项目索引包含重复身份，已暂停以保护数据。' }
        if ($existing.Count -eq 1) { $record = $existing[0] }
        else {
            $record = [pscustomobject]@{Id = [guid]::NewGuid().ToString('N'); Name = $entry.Name; Kind = $kind; Identity = $identity; BackupVersion = ''; Fingerprint = ''}
            $State.Catalog.Items = @($State.Catalog.Items) + @($record)
        }
        $record.Name = $entry.Name
        $record.Identity = $identity
        if (@($captured | Where-Object { $_.Id -eq $record.Id }).Count -gt 0) { throw "桌面多个名称指向同一实体，已暂停以保护数据：$($entry.Name)" }
        $fingerprint = Get-DIFingerprint $entry.FullName
        $backupAvailable = (-not [string]::IsNullOrEmpty($record.BackupVersion)) -and (Test-Path -LiteralPath (Get-DIBackupPath $State $record))
        if (-not $backupAvailable -or $record.Fingerprint -ne $fingerprint) {
            $version = [guid]::NewGuid().ToString('N')
            $backupPath = Join-Path (Join-Path (Join-Path (Join-Path $State.DataRoot 'backup') $record.Id) $version) 'content'
            Copy-DIItem $entry.FullName $backupPath
            if ((Get-DIFingerprint $entry.FullName) -ne $fingerprint -or (Get-DIFingerprint $backupPath) -ne $fingerprint) {
                throw "备份期间项目内容发生变化，已暂停。原始项目与临时副本均已保留：$($entry.Name)"
            }
            $record.BackupVersion = $version
            $record.Fingerprint = $fingerprint
        }
        [void]$captured.Add([pscustomobject]@{Id = $record.Id; Name = $entry.Name; Kind = $kind})
    }
    Write-DIJson $State.CatalogPath $State.Catalog
    return [pscustomobject]@{Version = 2; Items = @($captured.ToArray())}
}

function Assert-DIJournal($State, $Journal) {
    if ($Journal.Version -ne 1 -or -not (Get-DIFullPath $Journal.DesktopPath).Equals($State.DesktopPath, [StringComparison]::OrdinalIgnoreCase) -or -not (Get-DIFullPath $Journal.VaultRoot).Equals($State.VaultRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw '未完成事务的路径校验失败。保留所有文件与 transaction.json，请勿手动删除收纳库。'
    }
    Assert-DIId $Journal.Id
    foreach ($operation in @($Journal.Operations)) {
        $sourceOnDesktop = (Get-DIFullPath ([IO.Path]::GetDirectoryName($operation.Source))).Equals($State.DesktopPath, [StringComparison]::OrdinalIgnoreCase)
        $destinationOnDesktop = (Get-DIFullPath ([IO.Path]::GetDirectoryName($operation.Destination))).Equals($State.DesktopPath, [StringComparison]::OrdinalIgnoreCase)
        $sourceInVault = Test-DIInside $operation.Source $State.VaultRoot
        $destinationInVault = Test-DIInside $operation.Destination $State.VaultRoot
        $sourceInBackup = Test-DIInside $operation.Source (Join-Path $State.DataRoot 'backup')
        if (($operation.Mode -eq 'Move' -and -not (($sourceOnDesktop -and $destinationInVault) -or ($sourceInVault -and $destinationOnDesktop))) -or ($operation.Mode -eq 'Copy' -and -not ($sourceInBackup -and $destinationOnDesktop)) -or $operation.Mode -notin @('Move', 'Copy')) {
            throw '未完成事务包含无效的文件操作，已暂停。'
        }
        if (-not (Test-DIInside $operation.RecoveryPath (Join-Path $State.VaultRoot 'recovery'))) { throw '事务恢复路径无效。' }
    }
}

function Undo-DITransaction($State, $Journal) {
    Assert-DIJournal $State $Journal
    if ($Journal.Status -eq 'Committed') {
        [IO.File]::Delete((Join-Path $State.DataRoot 'transaction.json'))
        return
    }
    $operations = @($Journal.Operations)
    for ($index = $operations.Count - 1; $index -ge 0; $index--) {
        $operation = $operations[$index]
        if ($operation.State -in @('Pending', 'RolledBack', 'Failed')) { continue }
        $sourceExists = Test-Path -LiteralPath $operation.Source
        $destinationExists = Test-Path -LiteralPath $operation.Destination
        if ($operation.Mode -eq 'Move') {
            if ($sourceExists -and $destinationExists) { throw "事务恢复遇到同名冲突，两个版本均保留：$($operation.Source)；$($operation.Destination)" }
            if (-not $sourceExists -and $destinationExists) { Move-DIItem $operation.Destination $operation.Source }
            elseif (-not $sourceExists -and -not $destinationExists) { throw "事务项目的源和目标均不存在，请检查备份：$($operation.Source)" }
        } elseif ($destinationExists) {
            # An interrupted restored copy might have since been edited. Keep it rather than delete.
            Move-DIItem $operation.Destination $operation.RecoveryPath
        }
        $operation.State = 'RolledBack'
        Write-DIJson (Join-Path $State.DataRoot 'transaction.json') $Journal
    }
    Write-DIJson $State.CatalogPath $Journal.CatalogBefore
    $State.Catalog = $Journal.CatalogBefore
    [IO.File]::Delete((Join-Path $State.DataRoot 'transaction.json'))
}

function Repair-DICore($State) {
    $journalPath = Join-Path $State.DataRoot 'transaction.json'
    if (Test-Path -LiteralPath $journalPath) { Undo-DITransaction $State (Read-DIJson $journalPath); return $true }
    return $false
}

function Invoke-DITransaction($State, $Operations, $SharedSet = $null) {
    if (@($Operations).Count -eq 0) { return }
    $transactionId = [guid]::NewGuid().ToString('N')
    $index = 0
    foreach ($operation in @($Operations)) {
        $operation | Add-Member -NotePropertyName RecoveryPath -NotePropertyValue (Join-Path (Join-Path (Join-Path $State.VaultRoot 'recovery') $transactionId) ([string]$index))
        $index++
    }
    $catalogBefore = $State.Catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $journal = [pscustomobject]@{Version = 1; Id = $transactionId; DesktopPath = $State.DesktopPath; VaultRoot = $State.VaultRoot; Status = 'Pending'; CatalogBefore = $catalogBefore; Operations = @($Operations)}
    $journalPath = Join-Path $State.DataRoot 'transaction.json'
    Write-DIJson $journalPath $journal
    try {
        foreach ($operation in @($Operations)) {
            # Recheck immediately before intent. A pre-existing obstacle was never created
            # by this transaction, so this operation must stay Pending during rollback.
            if (-not (Test-Path -LiteralPath $operation.Source)) { throw "项目在切换前已消失：$($operation.Source)" }
            if (Test-Path -LiteralPath $operation.Destination) { throw "拒绝覆盖已有项目：$($operation.Destination)" }
            $operation.State = 'Started'
            Write-DIJson $journalPath $journal
            if ($operation.Mode -eq 'Move') {
                try { Move-DIItem $operation.Source $operation.Destination }
                catch {
                    # The non-overwriting move failed before moving its source. An unrelated
                    # destination must remain in place while earlier successful moves roll back.
                    if ((Test-Path -LiteralPath $operation.Source) -or -not (Test-Path -LiteralPath $operation.Destination)) {
                        $operation.State = 'Failed'
                        Write-DIJson $journalPath $journal
                    }
                    throw
                }
            }
            else {
                Copy-DIItem $operation.Source $operation.Destination
                if ((Get-DIFingerprint $operation.Source) -ne (Get-DIFingerprint $operation.Destination)) { throw '恢复副本校验失败。' }
            }
            $operation.State = 'Done'
            Write-DIJson $journalPath $journal
        }
        foreach ($record in @($State.Catalog.Items)) {
            # Shared records can predate the exclusion list. Keep their vault copies and
            # metadata untouched, and never open the shared desktop item for identity.
            if ($null -ne $SharedSet -and $SharedSet.Contains($record.Name)) { continue }
            $desktopItemPath = Join-Path $State.DesktopPath $record.Name
            $vaultItemPath = Get-DIVaultPath $State $record.Id
            if (Test-Path -LiteralPath $vaultItemPath) { $record.Identity = Get-DIIdentity (Get-Item -LiteralPath $vaultItemPath -Force) }
            elseif (Test-Path -LiteralPath $desktopItemPath) {
                $desktopItem = Get-Item -LiteralPath $desktopItemPath -Force
                $currentIdentity = Get-DIIdentity $desktopItem
                # Only refresh IDs that were actually restored; unrelated same-name objects keep their identity.
                $restored = @($Operations | Where-Object { $_.Destination -eq $desktopItemPath -and $_.ItemId -eq $record.Id })
                if ($restored.Count -gt 0) { $record.Identity = $currentIdentity }
            }
        }
        Write-DIJson $State.CatalogPath $State.Catalog
        $journal.Status = 'Committed'
        Write-DIJson $journalPath $journal
        [IO.File]::Delete($journalPath)
    } catch {
        $originalError = $_.Exception.Message
        try { Undo-DITransaction $State (Read-DIJson $journalPath) }
        catch { throw "切换已暂停：$originalError。自动恢复未完成：$($_.Exception.Message)。所有数据及事务记录已保留，下次启动将重试。中断副本目录：$(Join-Path $State.VaultRoot 'recovery')" }
        throw "切换已暂停并恢复原桌面：$originalError"
    }
}

function Restore-DICore($State, $Snapshot, $SharedSet, [bool]$MergeOnly) {
    if ($null -eq $Snapshot -or $Snapshot.Version -ne 2) { throw '只有含 Version=2 桌面集合的场景才能修改桌面项目。' }
    $wantedByName = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $wantedIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $wantedItems = New-Object 'Collections.Generic.List[object]'
    $preservedShared = 0
    foreach ($wanted in @($Snapshot.Items)) {
        # Older scenes may contain a now-shared folder. Validate the name before
        # skipping it, without resolving its ID, traversing it or preparing a copy.
        Assert-DIName $wanted.Name
        if ($SharedSet.Contains($wanted.Name)) { $preservedShared++; continue }
        Assert-DIId $wanted.Id
        if ($wanted.Kind -notin @('File', 'Directory') -or $wantedByName.ContainsKey($wanted.Name) -or -not $wantedIds.Add($wanted.Id)) { throw '场景包含重复项目名称、身份或无效类型。' }
        $wantedByName.Add($wanted.Name, $wanted)
        [void]$wantedItems.Add($wanted)
    }
    $current = Save-DICore $State $SharedSet
    # Capture first so an ordinary item renamed back from a shared name updates
    # its catalog name before deciding which historical IDs remain shared.
    $sharedIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($State.Catalog.Items)) {
        if ($SharedSet.Contains($record.Name)) { [void]$sharedIds.Add($record.Id) }
    }
    $currentByName = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($current.Items)) { $currentByName.Add($item.Name, $item) }
    # Resolve every incoming item and conflict before moving anything.
    $incoming = New-Object 'Collections.Generic.List[object]'
    foreach ($wanted in $wantedItems) {
        # A historical scene may use the former name of a currently shared record.
        # Keep its archived copy and current catalog name untouched.
        if ($sharedIds.Contains($wanted.Id)) { $preservedShared++; continue }
        $records = @($State.Catalog.Items | Where-Object { $_.Id -eq $wanted.Id })
        if ($records.Count -ne 1 -or $records[0].Kind -ne $wanted.Kind) { throw "场景项目在收纳索引中不存在或类型不符：$($wanted.Name)。请找回原数据目录。" }
        $record = $records[0]
        if ($currentByName.ContainsKey($wanted.Name)) {
            $present = $currentByName[$wanted.Name]
            if ($present.Id -ne $wanted.Id -or $present.Kind -ne $wanted.Kind) { throw "同名项目发生冲突，拒绝覆盖：$($wanted.Name)。请先重命名当前桌面的项目后重试。" }
            continue
        }
        $sameIdAtOtherName = @($current.Items | Where-Object { $_.Id -eq $wanted.Id })
        if ($sameIdAtOtherName.Count -gt 0) { throw "项目已在桌面重命名，请先保存新场景或恢复原名称：$($wanted.Name)。" }
        $source = Get-DIVaultPath $State $wanted.Id
        if (-not (Test-Path -LiteralPath $source)) {
            $backupSource = Get-DIBackupPath $State $record
            if (-not (Test-Path -LiteralPath $backupSource)) { throw "收纳项目及备份均不存在，已暂停：$($wanted.Name)" }
            # Prepare on the desktop's volume first. The transaction itself then uses atomic moves only.
            $source = Join-Path (Join-Path (Join-Path $State.VaultRoot 'recovery') ([guid]::NewGuid().ToString('N'))) 'content'
            Copy-DIItem $backupSource $source
            if ((Get-DIFingerprint $backupSource) -ne (Get-DIFingerprint $source)) { throw "恢复副本校验失败，原始备份与准备副本均已保留。准备副本：$source" }
        }
        if (-not (Test-Path -LiteralPath $source)) { throw "收纳项目及备份均不存在，已暂停：$($wanted.Name)" }
        Assert-DITreeSafe $source
        $record.Name = $wanted.Name
        [void]$incoming.Add([pscustomobject]@{Mode = 'Move'; ItemId = $wanted.Id; Source = $source; Destination = (Join-Path $State.DesktopPath $wanted.Name); State = 'Pending'})
    }
    $operations = New-Object 'Collections.Generic.List[object]'
    $stashedCount = 0
    if (-not $MergeOnly) {
        foreach ($present in @($current.Items)) {
            if (-not $wantedIds.Contains($present.Id)) {
                $target = Get-DIVaultPath $State $present.Id
                if (Test-Path -LiteralPath $target) { throw "收纳库已有同一项目的另一份内容，已暂停并保留双方：$($present.Name)" }
                [void]$operations.Add([pscustomobject]@{Mode = 'Move'; ItemId = $present.Id; Source = (Join-Path $State.DesktopPath $present.Name); Destination = $target; State = 'Pending'})
                $stashedCount++
            }
        }
    }
    foreach ($operation in $incoming) { [void]$operations.Add($operation) }
    Invoke-DITransaction $State $operations.ToArray() $SharedSet
    return [pscustomobject]@{Stashed = $stashedCount; Restored = $incoming.Count; PreservedShared = $preservedShared; VaultRoot = $State.VaultRoot; RecoveryRoot = (Join-Path $State.VaultRoot 'recovery')}
}

function Save-DesktopItemsSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$DesktopPath, [Parameter(Mandatory=$true)][string]$DataRoot, [string[]]$SharedNames = @())
    $DataRoot = Get-DIFullPath $DataRoot
    $lock = Enter-DILock $DataRoot
    try { $state = Get-DIState $DesktopPath $DataRoot; [void](Repair-DICore $state); return Save-DICore $state (Get-DISharedSet $SharedNames) }
    finally { $lock.Dispose() }
}

function Restore-DesktopItemsSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$DesktopPath, [Parameter(Mandatory=$true)][string]$DataRoot, [Parameter(Mandatory=$true)]$Snapshot, [string[]]$SharedNames = @())
    $DataRoot = Get-DIFullPath $DataRoot
    $lock = Enter-DILock $DataRoot
    $state = $null
    try { $state = Get-DIState $DesktopPath $DataRoot; [void](Repair-DICore $state); return Restore-DICore $state $Snapshot (Get-DISharedSet $SharedNames) $false }
    catch {
        if ($null -ne $state) { throw "$($_.Exception.Message)；收纳目录：$($state.VaultRoot)；中断副本目录：$(Join-Path $state.VaultRoot 'recovery')" }
        throw
    }
    finally { $lock.Dispose() }
}

function Repair-DesktopItemsTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$DataRoot)
    $DataRoot = Get-DIFullPath $DataRoot
    $lock = Enter-DILock $DataRoot
    try {
        $catalogPath = Join-Path $DataRoot 'items.json'
        if (-not (Test-Path -LiteralPath $catalogPath)) {
            if (Test-Path -LiteralPath (Join-Path $DataRoot 'transaction.json')) { throw '事务存在但项目索引缺失，所有文件已保留。请恢复 items.json 后重试。' }
            return $false
        }
        $catalog = Read-DIJson $catalogPath
        return Repair-DICore (Get-DIState $catalog.DesktopPath $DataRoot)
    } finally { $lock.Dispose() }
}

function Restore-AllDesktopItems {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$DesktopPath, [Parameter(Mandatory=$true)][string]$DataRoot, [string[]]$SharedNames = @())
    $DataRoot = Get-DIFullPath $DataRoot
    $lock = Enter-DILock $DataRoot
    try {
        $state = Get-DIState $DesktopPath $DataRoot
        [void](Repair-DICore $state)
        $items = @($state.Catalog.Items | Where-Object { Test-Path -LiteralPath (Get-DIVaultPath $state $_.Id) } | ForEach-Object { [pscustomobject]@{Id = $_.Id; Name = $_.Name; Kind = $_.Kind} })
        return Restore-DICore $state ([pscustomobject]@{Version = 2; Items = $items}) (Get-DISharedSet $SharedNames) $true
    } finally { $lock.Dispose() }
}

Export-ModuleMember -Function Save-DesktopItemsSnapshot, Restore-DesktopItemsSnapshot, Repair-DesktopItemsTransaction, Restore-AllDesktopItems
