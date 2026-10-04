param(
    # 操作类型：Gui 打开图形界面，Save 保存当前布局，Restore 恢复已保存布局，Status 查看当前状态。
    [ValidateSet('Gui', 'Save', 'Restore', 'Status', 'Recover')]
    [string]$Action = 'Gui',

    # 配置名称：保存和恢复时使用，可在图形界面里自定义。
    [ValidatePattern('^[\p{L}\p{N}_ -]+$')]
    [string]$Profile = 'default',

    # 指定时优先使用此目录，否则读取安装时选择的数据位置。
    [string]$ProfileRoot,

    # 兼容旧版：只恢复图标和窗口的位置，不切换桌面项目。
    [switch]$PositionOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StorageSettingsPath {
    return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DesktopLayoutSwitcher\storage.json'
}

function Get-DefaultProfileRoot {
    param([string]$PreferencePath = (Get-StorageSettingsPath))
    if (-not (Test-Path -LiteralPath $PreferencePath)) {
        return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DesktopLayoutSwitcher\profiles'
    }
    try {
        $raw = (Get-Content -LiteralPath $PreferencePath -Raw -Encoding UTF8).Trim()
        if (-not $raw.StartsWith('{') -or -not $raw.EndsWith('}')) { throw '设置必须是 JSON 对象。' }
        $settings = $raw | ConvertFrom-Json
        $schema = $settings.PSObject.Properties['SchemaVersion']
        $location = $settings.PSObject.Properties['ProfileRoot']
        if ($null -eq $schema -or ($schema.Value -isnot [int] -and $schema.Value -isnot [long]) -or
            $schema.Value -ne 1 -or $null -eq $location -or $location.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($location.Value)) { throw '配置目录设置格式无效。' }
        # 排除依赖当前盘符的 \folder 和 D:folder，避免目录随启动方式改变。
        $normalizedPath = $location.Value.Replace('/', '\')
        if ($normalizedPath.StartsWith('\\?\') -or $normalizedPath.StartsWith('\\.\')) {
            throw '配置目录不支持设备路径，请使用普通的盘符或共享目录路径。'
        }
        if ($location.Value -notmatch '^[A-Za-z]:[\\/]' -and $location.Value -notmatch '^[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$)') {
            throw '配置目录必须为完整的绝对路径。'
        }
        return [IO.Path]::GetFullPath($location.Value)
    }
    catch { throw "无法读取配置目录设置：$PreferencePath。请修复该文件或使用其 .bak 备份。$($_.Exception.Message)" }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw '本工具仅支持 Windows 10 / 11。'
}
if (-not [Environment]::Is64BitProcess) {
    throw '请使用 64 位 Windows PowerShell 或安装版启动器运行本工具。'
}

if (-not $PSBoundParameters.ContainsKey('ProfileRoot')) {
    $ProfileRoot = Get-DefaultProfileRoot
}
if ([string]::IsNullOrWhiteSpace($ProfileRoot)) { throw '配置目录不能为空。' }
$ProfileRoot = [IO.Path]::GetFullPath($ProfileRoot)
$script:DataRoot = Join-Path $ProfileRoot 'data'
$script:DesktopPath = [Environment]::GetFolderPath('DesktopDirectory')
$desktopRoot = [IO.Path]::GetFullPath($script:DesktopPath).TrimEnd('\')
if ($ProfileRoot.TrimEnd('\').Equals($desktopRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $ProfileRoot.StartsWith($desktopRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw '配置目录必须位于桌面之外，请在安装向导中选择其他目录。'
}
Import-Module (Join-Path $PSScriptRoot 'DesktopItems.psm1') -Force

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
        private const int GWL_STYLE = -16;
        private const long LVS_AUTOARRANGE = 0x0100;
        private const uint SHCNE_UPDATEDIR = 0x00001000;
        private const uint SHCNF_PATHW = 0x0005;
        private const uint SHCNF_FLUSHNOWAIT = 0x2000;

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
            public int iIndent;
            public int iGroupId;
            public uint cColumns;
            public IntPtr puColumns;
            public IntPtr piColFmt;
            public int iGroup;
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

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
        private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern void SHChangeNotify(uint wEventId, uint uFlags, string dwItem1, IntPtr dwItem2);

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

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool IsWow64Process(IntPtr hProcess, out bool wow64Process);

        // 在移动桌面文件之前调用，确保位置可以恢复，避免切换后才发现自动排列等问题。
        public static void ValidateRestore()
        {
            IntPtr listView = GetDesktopListView();
            IntPtr process = OpenExplorerProcess(listView);
            try
            {
                if ((GetWindowLongPtr(listView, GWL_STYLE).ToInt64() & LVS_AUTOARRANGE) != 0)
                {
                    throw new InvalidOperationException("请先右键桌面，在“查看”中取消“自动排列图标”，再恢复布局。");
                }
            }
            finally
            {
                CloseHandle(process);
            }
        }

        // Shell 通知是异步的；调用者应有限重试 Capture，等待 Explorer 完成新项目枚举。
        public static void NotifyDesktopChanged()
        {
            NotifyDesktopDirectory(Environment.SpecialFolder.DesktopDirectory);
            NotifyDesktopDirectory(Environment.SpecialFolder.CommonDesktopDirectory);
        }

        private static void NotifyDesktopDirectory(Environment.SpecialFolder folder)
        {
            string path = Environment.GetFolderPath(folder);
            if (!string.IsNullOrEmpty(path))
            {
                SHChangeNotify(SHCNE_UPDATEDIR, SHCNF_PATHW | SHCNF_FLUSHNOWAIT, path, IntPtr.Zero);
            }
        }

        private static IntPtr OpenExplorerProcess(IntPtr listView)
        {
            if (!Environment.Is64BitProcess)
            {
                throw new InvalidOperationException("请使用 64 位 PowerShell 启动此工具；32 位进程无法安全读取 Explorer 桌面图标。");
            }

            uint processId;
            if (GetWindowThreadProcessId(listView, out processId) == 0 || processId == 0)
            {
                throw new InvalidOperationException("Explorer 桌面窗口已失效，请等待桌面加载完成后重试。");
            }

            IntPtr process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE, false, processId);
            if (process == IntPtr.Zero)
            {
                throw new InvalidOperationException("无法访问 Explorer 进程，桌面图标位置读取失败。");
            }

            bool wow64;
            if (!IsWow64Process(process, out wow64) || wow64)
            {
                CloseHandle(process);
                throw new InvalidOperationException("无法确认 Explorer 使用 64 位指针布局，已停止跨进程读写以保护桌面。");
            }
            return process;
        }

        public static List<DesktopIconSnapshot> Capture()
        {
            IntPtr listView = GetDesktopListView();
            int count = SendMessage(listView, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
            IntPtr process = OpenExplorerProcess(listView);

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
            ValidateRestore();
            var saved = new List<DesktopIconSnapshot>(savedIcons);
            var current = Capture();
            var indices = MatchIconIndices(saved, current);
            IntPtr listView = GetDesktopListView();

            for (int i = 0; i < saved.Count; i++)
            {
                int index = indices[i];
                if (index < 0)
                {
                    continue;
                }

                var item = saved[i];
                // LVM_SETITEMPOSITION 只需要当前索引和目标坐标，坐标超出屏幕时由 Explorer 自己裁剪。
                if (SendMessage(listView, LVM_SETITEMPOSITION, (IntPtr)index, MakeLParam(item.X, item.Y)) == IntPtr.Zero)
                {
                    throw new InvalidOperationException("Explorer 未能恢复图标位置，请等待桌面刷新后重试。");
                }
            }

            int count = SendMessage(listView, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
            if (count > 0)
            {
                SendMessage(listView, LVM_REDRAWITEMS, IntPtr.Zero, (IntPtr)(count - 1));
            }

            InvalidateRect(listView, IntPtr.Zero, true);
            UpdateWindow(listView);
        }

        // 同显示名按枚举顺序配对，保证每个当前图标只使用一次，防止全部位置写到第一个同名图标。
        private static List<int> MatchIconIndices(IEnumerable<DesktopIconSnapshot> savedIcons, IEnumerable<DesktopIconSnapshot> currentIcons)
        {
            var indexByText = new Dictionary<string, Queue<int>>(StringComparer.OrdinalIgnoreCase);
            foreach (var item in currentIcons)
            {
                string text = item.Text ?? "";
                Queue<int> indices;
                if (!indexByText.TryGetValue(text, out indices))
                {
                    indices = new Queue<int>();
                    indexByText.Add(text, indices);
                }
                indices.Enqueue(item.Index);
            }

            var result = new List<int>();
            foreach (var item in savedIcons)
            {
                Queue<int> indices;
                result.Add(indexByText.TryGetValue(item.Text ?? "", out indices) && indices.Count > 0 ? indices.Dequeue() : -1);
            }
            return result;
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
            if (!WriteProcessMemory(process, remoteItem, itemBuffer, itemBuffer.Length, out written) || written.ToInt64() != itemBuffer.Length)
            {
                throw new InvalidOperationException("写入 Explorer 临时内存失败，已停止读取桌面布局。");
            }
            SendMessage(listView, LVM_GETITEMTEXTW, (IntPtr)index, remoteItem);

            byte[] textBuffer = new byte[textBytes];
            IntPtr read;
            if (!ReadProcessMemory(process, remoteText, textBuffer, textBuffer.Length, out read) || read.ToInt64() != textBuffer.Length)
            {
                throw new InvalidOperationException("读取 Explorer 图标名称失败，已停止保存布局。");
            }

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
            if (SendMessage(listView, LVM_GETITEMPOSITION, (IntPtr)index, remotePoint) == IntPtr.Zero)
            {
                throw new InvalidOperationException("Explorer 桌面项目正在变化，请等待桌面刷新完成后重试。");
            }
            int size = Marshal.SizeOf(typeof(POINT));
            byte[] pointBuffer = new byte[size];
            IntPtr read;
            if (!ReadProcessMemory(process, remotePoint, pointBuffer, pointBuffer.Length, out read) || read.ToInt64() != pointBuffer.Length)
            {
                throw new InvalidOperationException("读取 Explorer 图标坐标失败，已停止保存布局。");
            }
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
                // 部分 Explorer 版本或语言环境使用不同的窗口标题。
                listView = FindWindowEx(defView, IntPtr.Zero, "SysListView32", null);
            }
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

                bool samePath = !string.IsNullOrWhiteSpace(saved.ProcessPath) && SameText(saved.ProcessPath, item.ProcessPath);
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
    if ($Name.Length -gt 80 -or $Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        throw '配置名过长或为 Windows 保留名称，请换一个名称。'
    }
}

function Write-LayoutJson {
    param([string]$Path, [object]$Value)
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($true))
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporary, $Path, "$Path.bak", $true)
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function ConvertTo-SharedDesktopNames {
    param([object[]]$Names = @())
    $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $result = [Collections.Generic.List[string]]::new()
    foreach ($name in $Names) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 255 -or
            $name -eq '.' -or $name -eq '..' -or $name -match '[\\/:*?"<>|\x00-\x1f]' -or
            $name.EndsWith('.') -or $name.EndsWith(' ') -or $name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
            throw '保留名单只能填写桌面顶层项目名称（包含扩展名），不能填写路径或无效文件名。'
        }
        if ($unique.Add($name)) { $result.Add($name) }
    }
    return @($result.ToArray() | Sort-Object)
}

function Get-SharedDesktopSettingsPath {
    return Join-Path $script:DataRoot 'shared-items.json'
}

function Get-ConfiguredSharedDesktopNames {
    $path = Get-SharedDesktopSettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return @('Apps') }
    try {
        # PowerShell 5.1 会展开顶层 JSON 数组，先检查原文以避免接受单元素数组。
        $raw = (Get-Content -LiteralPath $path -Raw).Trim()
        if (-not $raw.StartsWith('{') -or -not $raw.EndsWith('}')) { throw '设置必须是 JSON 对象。' }
        $settings = $raw | ConvertFrom-Json
        if ($null -eq $settings -or $settings -is [array]) { throw '设置必须是 JSON 对象。' }
        $schema = $settings.PSObject.Properties['SchemaVersion']
        $names = $settings.PSObject.Properties['Names']
        if ($null -eq $schema -or ($schema.Value -isnot [int] -and $schema.Value -isnot [long]) -or
            $schema.Value -ne 1 -or $null -eq $names -or $names.Value -isnot [array]) {
            throw '设置格式无效，需要 SchemaVersion=1 和 Names 数组。'
        }
        return @(ConvertTo-SharedDesktopNames -Names $names.Value)
    }
    catch { throw "无法读取始终保留名单：$path。请修复该文件或使用其 .bak 备份后重试。$($_.Exception.Message)" }
}

function Set-ConfiguredSharedDesktopNames {
    param([object[]]$Names = @())
    $normalized = @(ConvertTo-SharedDesktopNames -Names $Names)
    New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
    Write-LayoutJson -Path (Get-SharedDesktopSettingsPath) -Value ([pscustomobject]@{SchemaVersion = 1; Names = $normalized})
}

function Get-AutomaticSharedDesktopNames {
    # 工具入口和正在运行的程序/配置目录在所有场景中保留。
    $names = [Collections.Generic.List[string]]::new()
    foreach ($name in @('DesktopLayoutSwitcher.lnk', '桌面布局切换工具.lnk', '启动桌面布局工具.cmd')) {
        $names.Add($name)
    }
    $prefix = $script:DesktopPath.TrimEnd('\') + '\'
    foreach ($folder in @($PSScriptRoot, $ProfileRoot)) {
        $full = [IO.Path]::GetFullPath($folder)
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $names.Add($full.Substring($prefix.Length).Split('\')[0])
        }
        elseif ($full.TrimEnd('\') -eq $script:DesktopPath.TrimEnd('\')) {
            foreach ($file in @('DesktopLayoutSwitcher.exe', 'DesktopLayoutSwitcher.ps1', 'DesktopItems.psm1', 'README.md', 'VERSION', 'profiles')) {
                $names.Add($file)
            }
        }
    }
    return $names.ToArray()
}

function Get-SharedDesktopNames {
    return @(ConvertTo-SharedDesktopNames -Names (@(Get-ConfiguredSharedDesktopNames) + @(Get-AutomaticSharedDesktopNames)))
}

function Get-SharedDesktopArchiveInfo {
    # 只读取索引中的历史位置，不进入任何真实文件夹或旧目录备份内部。
    $path = Join-Path $script:DataRoot 'items.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $catalog = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $shared = @(Get-SharedDesktopNames)
    foreach ($record in @($catalog.Items)) {
        if ($record.Kind -eq 'Directory' -or $record.Name -in $shared) {
            $archive = Join-Path (Join-Path $catalog.VaultRoot $record.Id) 'content'
            if (Test-Path -LiteralPath $archive) { [pscustomobject]@{Name = $record.Name; Path = $archive} }
        }
    }
}

function Initialize-LayoutStorage {
    New-Item -ItemType Directory -Path $ProfileRoot -Force | Out-Null
    # 规则损坏时停止，不回退成可能收纳项目的空名单。
    [void]@(Get-ConfiguredSharedDesktopNames)
    Repair-DesktopItemsTransaction -DataRoot $script:DataRoot | Out-Null
}

function Get-SavedProfileNames {
    # 从 profiles 目录读取已保存配置，界面下拉框和状态文本共用。
    if (-not (Test-Path -LiteralPath $ProfileRoot)) {
        return @()
    }

    $bootstrap = Get-StorageSettingsPath
    return @(Get-ChildItem -LiteralPath $ProfileRoot -Filter '*.json' -File |
        Where-Object { -not $_.FullName.Equals($bootstrap, [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object BaseName | ForEach-Object { $_.BaseName })
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

    $path = Get-ProfilePath -Name $Name
    New-Item -ItemType Directory -Path $ProfileRoot -Force | Out-Null

    $snapshot = [pscustomobject]@{
        SchemaVersion = 2
        SavedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Profile = $Name
        Screens = @(Get-ScreenSnapshot)
        DesktopIcons = @([DesktopLayout.DesktopIconManager]::Capture())
        Windows = @([DesktopLayout.WindowManager]::Capture())
        DesktopItems = $null
    }

    $snapshot.DesktopItems = Save-DesktopItemsSnapshot -DesktopPath $script:DesktopPath -DataRoot $script:DataRoot -SharedNames (Get-SharedDesktopNames)
    Write-LayoutJson -Path $path -Value $snapshot
    Write-Host "已保存布局：$Name -> $path"
    Write-Host "桌面图标：$($snapshot.DesktopIcons.Count) 个；窗口：$($snapshot.Windows.Count) 个。"
    Write-Host "场景文件及快捷方式：$(@($snapshot.DesktopItems.Items).Count) 个；真实文件夹仅保存图标位置。"
}

function Restore-LayoutProfile {
    param([string]$Name, [switch]$OnlyPositions)

    $path = Get-ProfilePath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "找不到布局文件：$path。先执行 Save 保存这个场景。"
    }

    $snapshot = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $hasItems = $null -ne $snapshot.PSObject.Properties['DesktopItems'] -and $null -ne $snapshot.DesktopItems
    # 必须在移动文件前确认 Explorer 可恢复位置，避免切换到一半才发现自动排列。
    [DesktopLayout.DesktopIconManager]::ValidateRestore()
    if ($hasItems -and -not $OnlyPositions) {
        $result = Restore-DesktopItemsSnapshot -DesktopPath $script:DesktopPath -DataRoot $script:DataRoot -Snapshot $snapshot.DesktopItems -SharedNames (Get-SharedDesktopNames)
        [DesktopLayout.DesktopIconManager]::NotifyDesktopChanged()
        # Explorer 异步枚举刚移回的文件，有限等待后再恢复图标位置。
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $current = @([DesktopLayout.DesktopIconManager]::Capture())
            $currentNames = @($current | ForEach-Object { $_.Text })
            # 等待本次真正恢复的文件，不等待已被用户删除的目录或额外共有项目。
            $expectedNames = @($snapshot.DesktopItems.Items | Where-Object { $_.Kind -eq 'File' } | ForEach-Object { $_.Name; [IO.Path]::GetFileNameWithoutExtension($_.Name) })
            $missing = @($snapshot.DesktopIcons | Where-Object { $_.Text -in $expectedNames -and $_.Text -notin $currentNames })
            if ($missing.Count -eq 0) { break }
            Start-Sleep -Milliseconds 150
        }
        Write-Host ($result | ConvertTo-Json -Compress)
    }
    elseif (-not $hasItems) {
        Write-Warning '这是旧版位置配置。本次只恢复位置；请重新保存一次，以启用文件及快捷方式的补齐与收纳。'
    }
    [DesktopLayout.DesktopIconManager]::Restore((New-IconList -Items @($snapshot.DesktopIcons)))
    Start-Sleep -Milliseconds 200
    [DesktopLayout.WindowManager]::Restore((New-WindowList -Items @($snapshot.Windows)))

    Write-Host "已恢复布局：$Name"
    Write-Host "来源文件：$path"
}

function Recover-DesktopItems {
    $result = Restore-AllDesktopItems -DesktopPath $script:DesktopPath -DataRoot $script:DataRoot -SharedNames (Get-SharedDesktopNames)
    $result | Out-Host
    if ($result.PreservedShared -gt 0) {
        Write-Host "保留名单中的 $($result.PreservedShared) 个历史收纳项目保持原处：$($result.VaultRoot)"
    }
    if ($result.PreservedDirectory -gt 0) {
        Write-Host "旧版的 $($result.PreservedDirectory) 个文件夹收纳存档仍保留：$($result.VaultRoot)，不会自动移回桌面。"
    }
    [DesktopLayout.DesktopIconManager]::NotifyDesktopChanged()
}

function Get-LayoutStatusText {
    # 将状态组装成文本，命令行和图形界面共用这一份状态逻辑。
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("配置目录：$ProfileRoot")
    $lines.Add("用户桌面：$script:DesktopPath")
    $lines.Add('只切换文件与快捷方式；真实文件夹仅恢复图标位置，增删直接忽略。')
    $lines.Add('不读取或备份文件夹内容；公共桌面项目、系统图标和工具入口为所有场景共有。')
    $lines.Add("安装时可选择配置目录；旧数据不会随目录选择自动迁移。")
    $configured = @(Get-ConfiguredSharedDesktopNames)
    $sharedText = if ($configured.Count -gt 0) { $configured -join '、' } else { '无（工具入口仍自动保留）' }
    $lines.Add("额外保留名单：$sharedText。所有真实文件夹均固定保留，不需要勾选。")
    $archives = @(Get-SharedDesktopArchiveInfo)
    if ($archives.Count -gt 0) { $lines.Add("保留的历史目录或共有收纳项目：$($archives.Count) 个，不会自动取回。") }
    foreach ($archive in $archives) {
        $lines.Add("保留的历史收纳项目：$($archive.Name)；位置：$($archive.Path)")
    }
    $lines.Add("备份目录：$(Join-Path $script:DataRoot 'backup')；旧版已复制的目录备份保留，不会自动删除。")
    $lines.Add('')
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

function Show-SharedDesktopSettings {
    param([System.Windows.Forms.Form]$Owner)
    $configured = @(Get-ConfiguredSharedDesktopNames)
    $automatic = @(Get-AutomaticSharedDesktopNames) + @('desktop.ini')
    # 所有真实文件夹固定只恢复位置；这里只允许选择额外保留的文件或快捷方式。
    $entries = @(Get-ChildItem -LiteralPath $script:DesktopPath -Force)
    $directoryNames = @($entries | Where-Object { $_.PSIsContainer } | ForEach-Object { $_.Name })
    $available = @($configured + @($entries | Where-Object { -not $_.PSIsContainer } | ForEach-Object { $_.Name }))
    $available = @(ConvertTo-SharedDesktopNames -Names $available | Where-Object { $_ -notin $automatic -and $_ -notin $directoryNames })
    $dialog = [System.Windows.Forms.Form]::new()
    try {
        $dialog.Text = '始终保留在桌面'
        $dialog.StartPosition = 'CenterParent'
        $dialog.ClientSize = [System.Drawing.Size]::new(540, 400)
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.MaximizeBox = $false
        $dialog.MinimizeBox = $false
        $dialog.Font = $Owner.Font

        $description = [System.Windows.Forms.Label]::new()
        $description.Text = "这里选择额外保留的文件与快捷方式，仍可恢复图标位置。`r`n所有真实文件夹只恢复图标位置，增删直接忽略。`r`n文件夹不扫描、不备份、不收纳；工具入口自动保留。"
        $description.Location = [System.Drawing.Point]::new(16, 12)
        $description.Size = [System.Drawing.Size]::new(508, 66)
        $dialog.Controls.Add($description)

        $list = [System.Windows.Forms.CheckedListBox]::new()
        $list.Location = [System.Drawing.Point]::new(16, 82)
        $list.Size = [System.Drawing.Size]::new(508, 244)
        $list.CheckOnClick = $true
        $list.HorizontalScrollbar = $true
        foreach ($name in $available) { [void]$list.Items.Add($name, ($name -in $configured)) }
        $dialog.Controls.Add($list)

        $note = [System.Windows.Forms.Label]::new()
        $note.Text = '保存只更新保留名单；下次保存或恢复布局时使用，不会立即移动文件。'
        $note.Location = [System.Drawing.Point]::new(16, 328)
        $note.Size = [System.Drawing.Size]::new(508, 22)
        $dialog.Controls.Add($note)

        $save = [System.Windows.Forms.Button]::new()
        $save.Text = '保存名单'
        $save.Location = [System.Drawing.Point]::new(316, 356)
        $save.Size = [System.Drawing.Size]::new(100, 30)
        $save.Add_Click({
            try {
                $selected = @($list.CheckedItems | ForEach-Object { [string]$_ })
                Set-ConfiguredSharedDesktopNames -Names $selected
                $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $dialog.Close()
            }
            catch { [System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, '保存名单失败', 'OK', 'Error') | Out-Null }
        })
        $dialog.Controls.Add($save)

        $cancel = [System.Windows.Forms.Button]::new()
        $cancel.Text = '取消'
        $cancel.Location = [System.Drawing.Point]::new(424, 356)
        $cancel.Size = [System.Drawing.Size]::new(100, 30)
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Controls.Add($cancel)
        $dialog.AcceptButton = $save
        $dialog.CancelButton = $cancel
        return $dialog.ShowDialog($Owner)
    }
    finally { $dialog.Dispose() }
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
    $hint.Text = "保存图标和窗口位置；切换场景时补齐、收纳文件与快捷方式。`r`n所有真实文件夹仅恢复位置，增删忽略，不扫描或备份内部内容。"
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

    $positionsCheck = [System.Windows.Forms.CheckBox]::new()
    $positionsCheck.Text = '仅恢复位置（不切换桌面项目）'
    $positionsCheck.Checked = $PositionOnly.IsPresent
    $positionsCheck.AutoSize = $true
    $positionsCheck.Location = [System.Drawing.Point]::new(350, 174)
    $form.Controls.Add($positionsCheck)

    $statusBox = [System.Windows.Forms.TextBox]::new()
    $statusBox.Multiline = $true
    $statusBox.ReadOnly = $true
    $statusBox.ScrollBars = 'Vertical'
    $statusBox.Location = [System.Drawing.Point]::new(20, 203)
    $statusBox.Size = [System.Drawing.Size]::new(700, 220)
    $statusBox.Anchor = 'Top,Bottom,Left,Right'
    $statusBox.Font = [System.Drawing.Font]::new('Consolas', 9)
    $form.Controls.Add($statusBox)

    $statusLabel = [System.Windows.Forms.Label]::new()
    $statusLabel.Text = '状态：等待操作'
    $statusLabel.AutoSize = $true
    $statusLabel.Location = [System.Drawing.Point]::new(20, 430)
    $statusLabel.Anchor = 'Bottom,Left'
    $form.Controls.Add($statusLabel)

    $openFolderButton = [System.Windows.Forms.Button]::new()
    $openFolderButton.Text = '打开配置目录'
    $openFolderButton.Location = [System.Drawing.Point]::new(500, 455)
    $openFolderButton.Size = [System.Drawing.Size]::new(105, 30)
    $openFolderButton.Anchor = 'Bottom,Right'
    $form.Controls.Add($openFolderButton)

    $recoverButton = [System.Windows.Forms.Button]::new()
    $recoverButton.Text = '取回收纳项目'
    $recoverButton.Location = [System.Drawing.Point]::new(350, 455)
    $recoverButton.Size = [System.Drawing.Size]::new(140, 30)
    $recoverButton.Anchor = 'Bottom,Right'
    $form.Controls.Add($recoverButton)
    $toolTip.SetToolTip($recoverButton, '取回文件与快捷方式；旧目录和共有存档仍保留，路径显示在状态栏。同名冲突会提示。')

    $sharedButton = [System.Windows.Forms.Button]::new()
    $sharedButton.Text = '始终保留在桌面'
    $sharedButton.Location = [System.Drawing.Point]::new(20, 455)
    $sharedButton.Size = [System.Drawing.Size]::new(150, 30)
    $sharedButton.Anchor = 'Bottom,Left'
    $form.Controls.Add($sharedButton)
    $toolTip.SetToolTip($sharedButton, '选择额外保留在原处的文件与快捷方式；所有真实文件夹均自动只恢复位置。')

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
                Restore-LayoutProfile -Name $name -OnlyPositions:$positionsCheck.Checked
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

    $sharedButton.Add_Click({
        try {
            if ((Show-SharedDesktopSettings -Owner $form) -eq [System.Windows.Forms.DialogResult]::OK) {
                Refresh-StatusBox
                $statusLabel.Text = '状态：保留名单已保存，桌面内容保持原处'
            }
        }
        catch { Show-LayoutUiError -ErrorRecord $_ }
    })

    $recoverButton.Add_Click({
        Invoke-LayoutUiAction -RunningText '正在取回收纳项目' -DoneText '收纳项目已取回' -SelectedName ([string]$profileCombo.SelectedItem) -Work {
            Recover-DesktopItems
        }
    })

    $openFolderButton.Add_Click({
        # 配置目录不存在时先创建，避免 Explorer 打开失败。
        New-Item -ItemType Directory -Path $ProfileRoot -Force | Out-Null
        Start-Process explorer.exe -ArgumentList "`"$ProfileRoot`""
    })

    $exitButton.Add_Click({ $form.Close() })
    $form.Add_Shown({
        try {
            [DesktopLayout.NativeWindowTools]::ShowAndActivate($form.Handle)
            Refresh-UiState -SelectedName ''
        }
        catch { Show-LayoutUiError -ErrorRecord $_ }
    })
    [void]$form.ShowDialog()
}

# 同一配置目录只允许一个界面/命令操作，覆盖完整的模块与布局写入过程。
$rootHash = [Security.Cryptography.SHA256]::Create()
try {
    $mutexId = [BitConverter]::ToString($rootHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProfileRoot.ToUpperInvariant()))).Replace('-', '')
}
finally { $rootHash.Dispose() }
$mutex = [Threading.Mutex]::new($false, "Local\DesktopLayoutSwitcher-$mutexId")
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw '此配置目录已有一个桌面布局工具正在运行，请先关闭另一个窗口。' }
    Initialize-LayoutStorage
    switch ($Action) {
        'Gui' { Show-LayoutToolWindow }
        'Save' { Save-LayoutProfile -Name $Profile }
        'Restore' { Restore-LayoutProfile -Name $Profile -OnlyPositions:$PositionOnly }
        'Status' { Show-LayoutStatus }
        'Recover' { Recover-DesktopItems }
    }
}
catch {
    if ($Action -eq 'Gui') {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '桌面布局切换工具', 'OK', 'Error') | Out-Null
    }
    else { [Console]::Error.WriteLine($_.Exception.Message) }
    exit 1
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
