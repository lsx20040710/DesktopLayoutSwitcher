param(
    # 操作类型：Gui 打开图形界面，Save 保存当前布局，Restore 恢复已保存布局，Status 查看当前状态。
    [ValidateSet('Gui', 'Save', 'Restore', 'Status')]
    [string]$Action = 'Gui',

    # 配置名称：保存和恢复时使用，可在图形界面里自定义。
    [ValidatePattern('^[\p{L}\p{N}_ -]+$')]
    [string]$Profile = 'default',

    # 配置文件目录：默认放在脚本旁边，方便整个文件夹直接移动。
    [string]$ProfileRoot = (Join-Path $PSScriptRoot 'profiles')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 加载 WinForms 和 Drawing，用于读取显示器信息并创建本地小窗口。
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 这段 C# 负责和 Windows 原生窗口交互：
# - DesktopIconManager 读取/恢复桌面图标坐标。
# - WindowManager 读取/恢复普通应用窗口坐标。
# PowerShell 只负责任务编排和 JSON 文件读写。
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace DesktopLayout
{
    // 保存单个桌面图标的位置。Text 是桌面显示名称，Index 是当次枚举序号。
    public class DesktopIconSnapshot
    {
        public string Text { get; set; }
        public int Index { get; set; }
        public int X { get; set; }
        public int Y { get; set; }
    }

    // 保存单个窗口的位置。ProcessPath + ClassName + Title 用来匹配恢复目标。
    public class WindowSnapshot
    {
        public long HWnd { get; set; }
        public int ProcessId { get; set; }
        public string ProcessName { get; set; }
        public string ProcessPath { get; set; }
        public string Title { get; set; }
        public string ClassName { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Right { get; set; }
        public int Bottom { get; set; }
        public int ShowCmd { get; set; }
    }

    // 启动器会隐藏 PowerShell 控制台，这里强制显示真正的工具窗口。
    public static class NativeWindowTools
    {
        private const int SW_SHOW = 5;

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        public static void ShowAndActivate(IntPtr hWnd)
        {
            ShowWindow(hWnd, SW_SHOW);
            SetForegroundWindow(hWnd);
        }
    }

    // 桌面图标实际存在于 Explorer 的 SysListView32 控件里，这里跨进程读取文本和坐标。
    public static class DesktopIconManager
    {
        private const int LVM_FIRST = 0x1000;
        private const int LVM_GETITEMCOUNT = LVM_FIRST + 4;
        private const int LVM_SETITEMPOSITION = LVM_FIRST + 15;
        private const int LVM_GETITEMPOSITION = LVM_FIRST + 16;
        private const int LVM_REDRAWITEMS = LVM_FIRST + 21;
        private const int LVM_GETITEMTEXTW = LVM_FIRST + 115;
        private const uint LVIF_TEXT = 0x0001;

        private const uint PROCESS_VM_OPERATION = 0x0008;
        private const uint PROCESS_VM_READ = 0x0010;
        private const uint PROCESS_VM_WRITE = 0x0020;
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint MEM_COMMIT = 0x1000;
        private const uint MEM_RESERVE = 0x2000;
        private const uint MEM_RELEASE = 0x8000;
        private const uint PAGE_READWRITE = 0x04;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct LVITEM
        {
            public uint mask;
            public int iItem;
            public int iSubItem;
            public uint state;
            public uint stateMask;
            public IntPtr pszText;
            public int cchTextMax;
            public int iImage;
            public IntPtr lParam;
        }

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        private static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);

        [DllImport("user32.dll")]
        private static extern bool UpdateWindow(IntPtr hWnd);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool VirtualFreeEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint dwFreeType);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int dwSize, out IntPtr lpNumberOfBytesRead);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out IntPtr lpNumberOfBytesWritten);

        public static List<DesktopIconSnapshot> Capture()
        {
            IntPtr listView = GetDesktopListView();
            int count = SendMessage(listView, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
            uint processId;
            GetWindowThreadProcessId(listView, out processId);

            IntPtr process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE, false, processId);
            if (process == IntPtr.Zero)
            {
                throw new InvalidOperationException("无法打开 Explorer 进程，桌面图标位置读取失败。");
            }

            IntPtr remoteText = IntPtr.Zero;
            IntPtr remoteItem = IntPtr.Zero;
            IntPtr remotePoint = IntPtr.Zero;

            try
            {
                int textBytes = 1024;
                int itemBytes = Marshal.SizeOf(typeof(LVITEM));
                int pointBytes = Marshal.SizeOf(typeof(POINT));

                remoteText = VirtualAllocEx(process, IntPtr.Zero, (UIntPtr)textBytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
                remoteItem = VirtualAllocEx(process, IntPtr.Zero, (UIntPtr)itemBytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
                remotePoint = VirtualAllocEx(process, IntPtr.Zero, (UIntPtr)pointBytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);

                if (remoteText == IntPtr.Zero || remoteItem == IntPtr.Zero || remotePoint == IntPtr.Zero)
                {
                    throw new InvalidOperationException("无法在 Explorer 进程中分配临时内存。");
                }

                var result = new List<DesktopIconSnapshot>();
                for (int i = 0; i < count; i++)
                {
                    string text = ReadIconText(listView, process, remoteItem, remoteText, textBytes, i);
                    POINT point = ReadIconPoint(listView, process, remotePoint, i);

                    result.Add(new DesktopIconSnapshot
                    {
                        Text = text,
                        Index = i,
                        X = point.X,
                        Y = point.Y
                    });
                }

                return result;
            }
            finally
            {
                if (remoteText != IntPtr.Zero) VirtualFreeEx(process, remoteText, UIntPtr.Zero, MEM_RELEASE);
                if (remoteItem != IntPtr.Zero) VirtualFreeEx(process, remoteItem, UIntPtr.Zero, MEM_RELEASE);
                if (remotePoint != IntPtr.Zero) VirtualFreeEx(process, remotePoint, UIntPtr.Zero, MEM_RELEASE);
                CloseHandle(process);
            }
        }

        public static void Restore(IEnumerable<DesktopIconSnapshot> savedIcons)
        {
            IntPtr listView = GetDesktopListView();
            var current = Capture();
            var indexByText = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

            foreach (var item in current)
            {
                if (!indexByText.ContainsKey(item.Text))
                {
                    indexByText[item.Text] = item.Index;
                }
            }

            foreach (var item in savedIcons)
            {
                int index;
                if (!indexByText.TryGetValue(item.Text, out index))
                {
                    continue;
                }

                // LVM_SETITEMPOSITION 只需要当前索引和目标坐标，坐标超出屏幕时由 Explorer 自己裁剪。
                SendMessage(listView, LVM_SETITEMPOSITION, (IntPtr)index, MakeLParam(item.X, item.Y));
            }

            int count = SendMessage(listView, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
            if (count > 0)
            {
                SendMessage(listView, LVM_REDRAWITEMS, IntPtr.Zero, (IntPtr)(count - 1));
            }

            InvalidateRect(listView, IntPtr.Zero, true);
            UpdateWindow(listView);
        }

        private static string ReadIconText(IntPtr listView, IntPtr process, IntPtr remoteItem, IntPtr remoteText, int textBytes, int index)
        {
            var item = new LVITEM
            {
                mask = LVIF_TEXT,
                iItem = index,
                iSubItem = 0,
                pszText = remoteText,
                cchTextMax = textBytes / 2
            };

            byte[] itemBuffer = StructureToBytes(item);
            IntPtr written;
            WriteProcessMemory(process, remoteItem, itemBuffer, itemBuffer.Length, out written);
            SendMessage(listView, LVM_GETITEMTEXTW, (IntPtr)index, remoteItem);

            byte[] textBuffer = new byte[textBytes];
            IntPtr read;
            ReadProcessMemory(process, remoteText, textBuffer, textBuffer.Length, out read);

            int charCount = 0;
            while (charCount < textBytes / 2)
            {
                int offset = charCount * 2;
                if (textBuffer[offset] == 0 && textBuffer[offset + 1] == 0)
                {
                    break;
                }
                charCount++;
            }

            return Encoding.Unicode.GetString(textBuffer, 0, charCount * 2);
        }

        private static POINT ReadIconPoint(IntPtr listView, IntPtr process, IntPtr remotePoint, int index)
        {
            SendMessage(listView, LVM_GETITEMPOSITION, (IntPtr)index, remotePoint);
            int size = Marshal.SizeOf(typeof(POINT));
            byte[] pointBuffer = new byte[size];
            IntPtr read;
            ReadProcessMemory(process, remotePoint, pointBuffer, pointBuffer.Length, out read);
            return BytesToStructure<POINT>(pointBuffer);
        }

        private static IntPtr GetDesktopListView()
        {
            IntPtr progman = FindWindow("Progman", null);
            IntPtr defView = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);

            if (defView == IntPtr.Zero)
            {
                EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
                {
                    IntPtr child = FindWindowEx(hWnd, IntPtr.Zero, "SHELLDLL_DefView", null);
                    if (child != IntPtr.Zero)
                    {
                        defView = child;
                        return false;
                    }
                    return true;
                }, IntPtr.Zero);
            }

            if (defView == IntPtr.Zero)
            {
                throw new InvalidOperationException("找不到桌面 SHELLDLL_DefView 窗口。");
            }

            IntPtr listView = FindWindowEx(defView, IntPtr.Zero, "SysListView32", "FolderView");
            if (listView == IntPtr.Zero)
            {
                throw new InvalidOperationException("找不到桌面图标 SysListView32 控件。");
            }

            return listView;
        }

        private static IntPtr MakeLParam(int low, int high)
        {
            unchecked
            {
                int value = ((high & 0xFFFF) << 16) | (low & 0xFFFF);
                return (IntPtr)value;
            }
        }

        private static byte[] StructureToBytes<T>(T value) where T : struct
        {
            int size = Marshal.SizeOf(typeof(T));
            byte[] buffer = new byte[size];
            IntPtr pointer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(value, pointer, false);
                Marshal.Copy(pointer, buffer, 0, size);
                return buffer;
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }
        }

        private static T BytesToStructure<T>(byte[] buffer) where T : struct
        {
            int size = Marshal.SizeOf(typeof(T));
            IntPtr pointer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.Copy(buffer, 0, pointer, size);
                return (T)Marshal.PtrToStructure(pointer, typeof(T));
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }
        }
    }

    // 读取和恢复普通应用窗口坐标，过滤桌面、隐藏窗口和无标题窗口。
    public static class WindowManager
    {
        private const int SW_SHOWMINIMIZED = 2;
        private const int SW_SHOWNORMAL = 1;
        private const int DWMWA_CLOAKED = 14;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WINDOWPLACEMENT
        {
            public int length;
            public int flags;
            public int showCmd;
            public POINT ptMinPosition;
            public POINT ptMaxPosition;
            public RECT rcNormalPosition;
        }

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern IntPtr GetShellWindow();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        private static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);

        [DllImport("user32.dll")]
        private static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);

        [DllImport("dwmapi.dll")]
        private static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

        public static List<WindowSnapshot> Capture()
        {
            var windows = new List<WindowSnapshot>();
            IntPtr shellWindow = GetShellWindow();

            EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
            {
                if (hWnd == shellWindow || !IsWindowVisible(hWnd))
                {
                    return true;
                }

                int titleLength = GetWindowTextLength(hWnd);
                if (titleLength <= 0)
                {
                    return true;
                }

                int cloaked;
                if (DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out cloaked, Marshal.SizeOf(typeof(int))) == 0 && cloaked != 0)
                {
                    return true;
                }

                var placement = new WINDOWPLACEMENT();
                placement.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
                if (!GetWindowPlacement(hWnd, ref placement))
                {
                    return true;
                }

                uint processId;
                GetWindowThreadProcessId(hWnd, out processId);

                var snapshot = new WindowSnapshot
                {
                    HWnd = hWnd.ToInt64(),
                    ProcessId = (int)processId,
                    Title = ReadWindowTitle(hWnd, titleLength),
                    ClassName = ReadClassName(hWnd),
                    Left = placement.rcNormalPosition.Left,
                    Top = placement.rcNormalPosition.Top,
                    Right = placement.rcNormalPosition.Right,
                    Bottom = placement.rcNormalPosition.Bottom,
                    ShowCmd = placement.showCmd
                };

                FillProcessInfo(snapshot, processId);
                windows.Add(snapshot);
                return true;
            }, IntPtr.Zero);

            return windows;
        }

        public static void Restore(IEnumerable<WindowSnapshot> savedWindows)
        {
            var current = Capture();
            var usedHandles = new HashSet<long>();

            foreach (var saved in savedWindows)
            {
                WindowSnapshot target = FindBestMatch(saved, current, usedHandles);
                if (target == null)
                {
                    continue;
                }

                var placement = new WINDOWPLACEMENT();
                placement.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
                IntPtr targetHandle = new IntPtr(target.HWnd);

                if (!GetWindowPlacement(targetHandle, ref placement))
                {
                    continue;
                }

                placement.rcNormalPosition.Left = saved.Left;
                placement.rcNormalPosition.Top = saved.Top;
                placement.rcNormalPosition.Right = saved.Right;
                placement.rcNormalPosition.Bottom = saved.Bottom;

                // 保存时最小化的窗口恢复为普通状态，避免恢复后窗口仍藏在任务栏。
                placement.showCmd = saved.ShowCmd == SW_SHOWMINIMIZED ? SW_SHOWNORMAL : saved.ShowCmd;
                SetWindowPlacement(targetHandle, ref placement);
                usedHandles.Add(target.HWnd);
            }
        }

        private static WindowSnapshot FindBestMatch(WindowSnapshot saved, List<WindowSnapshot> current, HashSet<long> usedHandles)
        {
            WindowSnapshot fallback = null;

            foreach (var item in current)
            {
                if (usedHandles.Contains(item.HWnd))
                {
                    continue;
                }

                bool samePath = SameText(saved.ProcessPath, item.ProcessPath);
                bool sameProcess = SameText(saved.ProcessName, item.ProcessName);
                bool sameClass = SameText(saved.ClassName, item.ClassName);
                bool sameTitle = SameText(saved.Title, item.Title);

                if (samePath && sameClass && sameTitle)
                {
                    return item;
                }

                if (fallback == null && samePath && sameClass)
                {
                    fallback = item;
                }

                if (fallback == null && sameProcess && sameClass && sameTitle)
                {
                    fallback = item;
                }
            }

            return fallback;
        }

        private static string ReadWindowTitle(IntPtr hWnd, int titleLength)
        {
            var builder = new StringBuilder(titleLength + 1);
            GetWindowText(hWnd, builder, builder.Capacity);
            return builder.ToString();
        }

        private static string ReadClassName(IntPtr hWnd)
        {
            var builder = new StringBuilder(256);
            GetClassName(hWnd, builder, builder.Capacity);
            return builder.ToString();
        }

        private static void FillProcessInfo(WindowSnapshot snapshot, uint processId)
        {
            try
            {
                using (var process = Process.GetProcessById((int)processId))
                {
                    snapshot.ProcessName = process.ProcessName;
                    try
                    {
                        snapshot.ProcessPath = process.MainModule.FileName;
                    }
                    catch
                    {
                        snapshot.ProcessPath = "";
                    }
                }
            }
            catch
            {
                snapshot.ProcessName = "";
                snapshot.ProcessPath = "";
            }
        }

        private static bool SameText(string left, string right)
        {
            return string.Equals(left ?? "", right ?? "", StringComparison.OrdinalIgnoreCase);
        }
    }
}
"@

function Get-ProfilePath {
    param([string]$Name)

    # 每个配置一个 JSON 文件，文件名限制为安全字符，避免误写到目录外。
    Assert-ProfileName -Name $Name
    return Join-Path $ProfileRoot "$Name.json"
}

function Assert-ProfileName {
    param([string]$Name)

    # 配置名允许中文、英文、数字、空格、横线和下划线，覆盖日常命名并避免非法文件名。
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw '配置名不能为空。'
    }

    if ($Name.Trim() -ne $Name) {
        throw '配置名前后不能有空格。'
    }

    if ($Name -notmatch '^[\p{L}\p{N}_ -]+$') {
        throw '配置名只能包含中文、英文、数字、空格、横线和下划线。'
    }
}

function Get-SavedProfileNames {
    # 从 profiles 目录读取已保存配置，界面下拉框和状态文本共用。
    if (-not (Test-Path -LiteralPath $ProfileRoot)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $ProfileRoot -Filter '*.json' -File | Sort-Object BaseName | ForEach-Object { $_.BaseName })
}

function Get-ScreenSnapshot {
    # 记录当前显示器结构，方便确认保存时是在 24 寸外屏还是 16 寸内屏。
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        [pscustomobject]@{
            DeviceName = $screen.DeviceName
            Primary = $screen.Primary
            Bounds = [pscustomobject]@{
                X = $screen.Bounds.X
                Y = $screen.Bounds.Y
                Width = $screen.Bounds.Width
                Height = $screen.Bounds.Height
            }
            WorkingArea = [pscustomobject]@{
                X = $screen.WorkingArea.X
                Y = $screen.WorkingArea.Y
                Width = $screen.WorkingArea.Width
                Height = $screen.WorkingArea.Height
            }
        }
    }
}

function New-IconList {
    param([object[]]$Items)

    # ConvertFrom-Json 得到的是 PSCustomObject，这里转回 C# 类型后再交给原生恢复逻辑。
    $list = [System.Collections.Generic.List[DesktopLayout.DesktopIconSnapshot]]::new()
    foreach ($item in @($Items)) {
        $icon = [DesktopLayout.DesktopIconSnapshot]::new()
        $icon.Text = [string]$item.Text
        $icon.Index = [int]$item.Index
        $icon.X = [int]$item.X
        $icon.Y = [int]$item.Y
        $list.Add($icon)
    }
    # 逗号前缀用于阻止 PowerShell 把泛型列表展开成普通数组。
    return ,$list
}

function New-WindowList {
    param([object[]]$Items)

    # 窗口恢复只移动当前仍然打开的程序；未打开的程序不会被强行启动。
    $list = [System.Collections.Generic.List[DesktopLayout.WindowSnapshot]]::new()
    foreach ($item in @($Items)) {
        $window = [DesktopLayout.WindowSnapshot]::new()
        $window.HWnd = [long]$item.HWnd
        $window.ProcessId = [int]$item.ProcessId
        $window.ProcessName = [string]$item.ProcessName
        $window.ProcessPath = [string]$item.ProcessPath
        $window.Title = [string]$item.Title
        $window.ClassName = [string]$item.ClassName
        $window.Left = [int]$item.Left
        $window.Top = [int]$item.Top
        $window.Right = [int]$item.Right
        $window.Bottom = [int]$item.Bottom
        $window.ShowCmd = [int]$item.ShowCmd
        $list.Add($window)
    }
    # 逗号前缀用于阻止 PowerShell 把泛型列表展开成普通数组。
    return ,$list
}

function Save-LayoutProfile {
    param([string]$Name)

    New-Item -ItemType Directory -Path $ProfileRoot -Force | Out-Null

    $snapshot = [pscustomobject]@{
        SchemaVersion = 1
        SavedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Profile = $Name
        Screens = @(Get-ScreenSnapshot)
        DesktopIcons = @([DesktopLayout.DesktopIconManager]::Capture())
        Windows = @([DesktopLayout.WindowManager]::Capture())
    }

    $path = Get-ProfilePath -Name $Name
    $snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "已保存布局：$Name -> $path"
    Write-Host "桌面图标：$($snapshot.DesktopIcons.Count) 个；窗口：$($snapshot.Windows.Count) 个。"
}

function Restore-LayoutProfile {
    param([string]$Name)

    $path = Get-ProfilePath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "找不到布局文件：$path。先执行 Save 保存这个场景。"
    }

    $snapshot = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    [DesktopLayout.DesktopIconManager]::Restore((New-IconList -Items @($snapshot.DesktopIcons)))
    Start-Sleep -Milliseconds 200
    [DesktopLayout.WindowManager]::Restore((New-WindowList -Items @($snapshot.Windows)))

    Write-Host "已恢复布局：$Name"
    Write-Host "来源文件：$path"
}

function Get-LayoutStatusText {
    # 将状态组装成文本，命令行和图形界面共用这一份状态逻辑。
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("当前显示器：")

    foreach ($screen in @(Get-ScreenSnapshot)) {
        $mark = if ($screen.Primary) { '主屏' } else { '副屏' }
        $lines.Add(("  {0} {1} {2}x{3} @ {4},{5}" -f $mark, $screen.DeviceName, $screen.Bounds.Width, $screen.Bounds.Height, $screen.Bounds.X, $screen.Bounds.Y))
    }

    $icons = @([DesktopLayout.DesktopIconManager]::Capture())
    $windows = @([DesktopLayout.WindowManager]::Capture())
    $lines.Add("可读取桌面图标：$($icons.Count) 个；可读取窗口：$($windows.Count) 个。")

    $profiles = @(Get-SavedProfileNames)
    if ($profiles.Count -gt 0) {
        $lines.Add("已保存配置：")
        foreach ($name in $profiles) {
            $lines.Add("  $name")
        }
    }
    else {
        $lines.Add("已保存配置：无")
    }

    return ($lines -join [Environment]::NewLine)
}

function Show-LayoutStatus {
    # status 只读，用于确认脚本能访问桌面控件和当前显示器结构。
    Write-Host (Get-LayoutStatusText)
}

function Show-LayoutToolWindow {
    # 这个窗口是给日常使用准备的入口，避免用户记命令或打开 PowerShell。
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = '桌面布局切换工具'
    $form.StartPosition = 'CenterScreen'
    $form.Size = [System.Drawing.Size]::new(760, 540)
    $form.MinimumSize = [System.Drawing.Size]::new(720, 500)
    $form.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)

    $title = [System.Windows.Forms.Label]::new()
    $title.Text = '桌面布局切换工具'
    $title.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = [System.Drawing.Point]::new(18, 15)
    $form.Controls.Add($title)

    $hint = [System.Windows.Forms.Label]::new()
    $hint.Text = '输入配置名保存当前布局；恢复时从已保存配置里选择。'
    $hint.AutoSize = $true
    $hint.Location = [System.Drawing.Point]::new(20, 52)
    $form.Controls.Add($hint)

    $nameLabel = [System.Windows.Forms.Label]::new()
    $nameLabel.Text = '配置名：'
    $nameLabel.AutoSize = $true
    $nameLabel.Location = [System.Drawing.Point]::new(20, 94)
    $form.Controls.Add($nameLabel)

    $profileInput = [System.Windows.Forms.TextBox]::new()
    $profileInput.Location = [System.Drawing.Point]::new(82, 90)
    $profileInput.Size = [System.Drawing.Size]::new(250, 25)
    $profileInput.Anchor = 'Top,Left'
    $form.Controls.Add($profileInput)

    $saveButton = [System.Windows.Forms.Button]::new()
    $saveButton.Text = '保存当前布局'
    $saveButton.Location = [System.Drawing.Point]::new(350, 86)
    $saveButton.Size = [System.Drawing.Size]::new(130, 34)
    $form.Controls.Add($saveButton)

    $savedLabel = [System.Windows.Forms.Label]::new()
    $savedLabel.Text = '已保存配置：'
    $savedLabel.AutoSize = $true
    $savedLabel.Location = [System.Drawing.Point]::new(20, 142)
    $form.Controls.Add($savedLabel)

    $profileCombo = [System.Windows.Forms.ComboBox]::new()
    $profileCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $profileCombo.Location = [System.Drawing.Point]::new(112, 138)
    $profileCombo.Size = [System.Drawing.Size]::new(220, 25)
    $form.Controls.Add($profileCombo)

    $restoreButton = [System.Windows.Forms.Button]::new()
    $restoreButton.Text = '恢复所选配置'
    $restoreButton.Location = [System.Drawing.Point]::new(350, 134)
    $restoreButton.Size = [System.Drawing.Size]::new(130, 34)
    $form.Controls.Add($restoreButton)

    $deleteButton = [System.Windows.Forms.Button]::new()
    $deleteButton.Text = '删除所选配置'
    $deleteButton.Location = [System.Drawing.Point]::new(495, 134)
    $deleteButton.Size = [System.Drawing.Size]::new(130, 34)
    $form.Controls.Add($deleteButton)

    $refreshButton = [System.Windows.Forms.Button]::new()
    $refreshButton.Text = '刷新列表'
    $refreshButton.Location = [System.Drawing.Point]::new(495, 86)
    $refreshButton.Size = [System.Drawing.Size]::new(130, 34)
    $form.Controls.Add($refreshButton)

    $toolTip = [System.Windows.Forms.ToolTip]::new()
    $toolTip.SetToolTip($refreshButton, '重新读取显示器信息和已保存配置列表，不会改变桌面布局。')

    $statusBox = [System.Windows.Forms.TextBox]::new()
    $statusBox.Multiline = $true
    $statusBox.ReadOnly = $true
    $statusBox.ScrollBars = 'Vertical'
    $statusBox.Location = [System.Drawing.Point]::new(20, 190)
    $statusBox.Size = [System.Drawing.Size]::new(700, 250)
    $statusBox.Anchor = 'Top,Bottom,Left,Right'
    $statusBox.Font = [System.Drawing.Font]::new('Consolas', 9)
    $form.Controls.Add($statusBox)

    $statusLabel = [System.Windows.Forms.Label]::new()
    $statusLabel.Text = '状态：等待操作'
    $statusLabel.AutoSize = $true
    $statusLabel.Location = [System.Drawing.Point]::new(20, 460)
    $statusLabel.Anchor = 'Bottom,Left'
    $form.Controls.Add($statusLabel)

    $openFolderButton = [System.Windows.Forms.Button]::new()
    $openFolderButton.Text = '打开配置目录'
    $openFolderButton.Location = [System.Drawing.Point]::new(500, 455)
    $openFolderButton.Size = [System.Drawing.Size]::new(105, 30)
    $openFolderButton.Anchor = 'Bottom,Right'
    $form.Controls.Add($openFolderButton)

    $exitButton = [System.Windows.Forms.Button]::new()
    $exitButton.Text = '退出'
    $exitButton.Location = [System.Drawing.Point]::new(615, 455)
    $exitButton.Size = [System.Drawing.Size]::new(105, 30)
    $exitButton.Anchor = 'Bottom,Right'
    $form.Controls.Add($exitButton)

    function Refresh-StatusBox {
        # 每次操作后刷新状态，用户能直接确认当前显示器和已保存配置。
        $statusBox.Text = Get-LayoutStatusText
        $statusBox.SelectionStart = 0
        $statusBox.SelectionLength = 0
    }

    function Refresh-ProfileList {
        param([string]$SelectedName)

        # 下拉框只显示 profiles 目录里的配置文件名，避免固定死家里/工位两个场景。
        $profileCombo.Items.Clear()
        $profiles = @(Get-SavedProfileNames)
        foreach ($name in $profiles) {
            [void]$profileCombo.Items.Add($name)
        }

        if ($profiles.Count -eq 0) {
            $profileCombo.SelectedIndex = -1
            return
        }

        if (-not [string]::IsNullOrWhiteSpace($SelectedName) -and $profiles -contains $SelectedName) {
            $profileCombo.SelectedItem = $SelectedName
        }
        else {
            $profileCombo.SelectedIndex = 0
        }
    }

    function Refresh-UiState {
        param([string]$SelectedName)

        Refresh-ProfileList -SelectedName $SelectedName
        Refresh-StatusBox
    }

    function Get-SelectedProfileName {
        # 恢复和删除都必须先选中一个配置，避免误操作。
        if ($null -eq $profileCombo.SelectedItem) {
            throw '请先从“已保存配置”里选择一个配置。'
        }

        return [string]$profileCombo.SelectedItem
    }

    function Invoke-LayoutUiAction {
        param(
            [string]$RunningText,
            [string]$DoneText,
            [scriptblock]$Work,
            [string]$SelectedName
        )

        try {
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $statusLabel.Text = "状态：$RunningText"
            $form.Refresh()
            & $Work
            Refresh-UiState -SelectedName $SelectedName
            $statusLabel.Text = "状态：$DoneText"
        }
        catch {
            $statusLabel.Text = '状态：操作失败'
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '操作失败', 'OK', 'Error') | Out-Null
        }
        finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    function Show-LayoutUiError {
        param([object]$ErrorRecord)

        # 按钮事件里先做输入检查，错误统一弹窗，不让脚本窗口直接崩掉。
        $statusLabel.Text = '状态：操作失败'
        [System.Windows.Forms.MessageBox]::Show($ErrorRecord.Exception.Message, '操作失败', 'OK', 'Error') | Out-Null
    }

    $saveButton.Add_Click({
        try {
            $name = $profileInput.Text.Trim()
            Assert-ProfileName -Name $name
            $path = Get-ProfilePath -Name $name

            if (Test-Path -LiteralPath $path) {
                $answer = [System.Windows.Forms.MessageBox]::Show("配置[$($name)]已存在，保存会覆盖它，确认继续？", '确认保存', 'YesNo', 'Question')
                if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                    return
                }
            }

            Invoke-LayoutUiAction -RunningText "正在保存配置：$name" -DoneText "配置已保存：$name" -SelectedName $name -Work {
                Save-LayoutProfile -Name $name
            }
        }
        catch {
            Show-LayoutUiError -ErrorRecord $_
        }
    })

    $restoreButton.Add_Click({
        try {
            $name = Get-SelectedProfileName
            Invoke-LayoutUiAction -RunningText "正在恢复配置：$name" -DoneText "配置已恢复：$name" -SelectedName $name -Work {
                Restore-LayoutProfile -Name $name
            }
        }
        catch {
            Show-LayoutUiError -ErrorRecord $_
        }
    })

    $deleteButton.Add_Click({
        try {
            $name = Get-SelectedProfileName
            $answer = [System.Windows.Forms.MessageBox]::Show("确认删除配置[$($name)]？只会删除配置文件，不会改变当前桌面。", '确认删除', 'YesNo', 'Warning')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                return
            }

            Invoke-LayoutUiAction -RunningText "正在删除配置：$name" -DoneText "配置已删除：$name" -SelectedName '' -Work {
                $path = Get-ProfilePath -Name $name
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Force
                }
            }
        }
        catch {
            Show-LayoutUiError -ErrorRecord $_
        }
    })

    $refreshButton.Add_Click({
        Invoke-LayoutUiAction -RunningText '正在刷新列表' -DoneText '列表已刷新' -SelectedName ([string]$profileCombo.SelectedItem) -Work { }
    })

    $openFolderButton.Add_Click({
        # 配置目录不存在时先创建，避免 Explorer 打开失败。
        New-Item -ItemType Directory -Path $ProfileRoot -Force | Out-Null
        Start-Process explorer.exe -ArgumentList "`"$ProfileRoot`""
    })

    $exitButton.Add_Click({ $form.Close() })
    $form.Add_Shown({
        [DesktopLayout.NativeWindowTools]::ShowAndActivate($form.Handle)
        Refresh-UiState -SelectedName ''
    })
    [void]$form.ShowDialog()
}

switch ($Action) {
    'Gui' { Show-LayoutToolWindow }
    'Save' { Save-LayoutProfile -Name $Profile }
    'Restore' { Restore-LayoutProfile -Name $Profile }
    'Status' { Show-LayoutStatus }
}





