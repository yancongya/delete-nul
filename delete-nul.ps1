#Requires -Version 5.1
<#
.SYNOPSIS
    查找并删除 Windows 保留名文件 (NUL / CON / AUX / PRN / COM1-9 / LPT1-9)。
    Find and delete Windows reserved-name files (NUL / CON / AUX / PRN / COM1-9 / LPT1-9).

.DESCRIPTION
    枚举阶段不受 Win32 DOS 设备解析影响，可正常列出真实文件；按名字精确匹配 →
    列出全部结果 → 确认 → 通过 \\?\ 前缀逐条删除并复核。
    Enumeration is unaffected by Win32 DOS-device parsing: list exact-name matches,
    confirm, then delete each via the \\?\ prefix and verify.

.PARAMETER Mode
    auto（默认）：有 -Path 就定向处理，非交互时全局扫描，否则弹菜单二选一。
    global：扫描所有本地固定磁盘。select：交互式选盘/粘贴路径。
    auto (default) | global | select.

.PARAMETER StartDir
    启动目录（内部使用，用于"扫描当前目录"选项在提权后仍指向原始位置）。
    Launch directory (used internally by "scan current directory" across elevation).

.PARAMETER Path
    要扫描的根目录（可多个）。等同于"定向处理"模式。
    Root directory (or directories) to scan.

.PARAMETER PathsFile
    每行一个路径的清单文件（bat 拖拽入口内部使用），读取后自动删除。
    File with one path per line (used by the drag-and-drop bat wrapper).

.PARAMETER DryRun
    只列出，不删除。List only; never delete.

.PARAMETER Yes
    跳过确认提示（非交互）。隐含退出前不暂停。Skip confirmation (non-interactive).

.PARAMETER NoElevate
    （保留兼容，现已默认不提权。）兼容旧用法。Kept for compatibility; elevation is now opt-in.

.PARAMETER Elevate
    主动申请管理员权限。默认不提权——普通权限即可删除个人目录里的保留名文件，
    且提权会触发 UIPI 导致无法把文件拖进窗口。仅在需要删系统目录时使用。
    Request admin rights (off by default; elevation blocks drag-and-drop).

.PARAMETER IncludeExtension
    把 NUL.txt 这类带扩展名的名字也算作保留名。默认关闭（只匹配裸名 NUL）。
    Also treat NUL.txt as reserved. Off by default (bare name only).

.PARAMETER Fast
    快速模式：跳过 Windows、Program Files、node_modules、.git 等常见噪音目录，
    大幅缩短扫描时间，但不保证覆盖这些目录。
    Skip noisy directories (Windows, Program Files, node_modules, .git, ...) for speed.

.PARAMETER Mft
    NTFS 实验模式：直接解析 $MFT 索引，跳过目录遍历（快一个数量级）。
    需要管理员 + NTFS；失败自动回退原生扫描。
    Experimental NTFS MFT scan; needs admin + NTFS; falls back on failure.

.PARAMETER Log
    把完整报告追加到该文件（UTF-8）。Append the full report to this file (UTF-8).

.PARAMETER Format
    text（默认）或 json。JSON 写到 stdout，进度信息写宿主/信息流。
    text (default) or json. JSON goes to stdout; progress goes to the information stream.

.PARAMETER Quiet
    不输出扫描进度。Suppress progress messages.

.PARAMETER NoColor
    不使用任何颜色，纯文本输出（兼容特殊终端/日志）。Plain output, no colors.

.PARAMETER Spinner
    spinner 样式：auto（默认，UTF-8 控制台用 Braille，否则 ASCII）、ascii、braille。
    Spinner style: auto (default), ascii, or braille.

.PARAMETER ScanTimeout
    单个磁盘的原生扫描超时秒数（30-3600，默认 300）；超时则跳过该盘，避免卡死。
    Per-drive scan timeout in seconds (default 300).

.PARAMETER NoPause
    退出前不等待回车。Do not wait for Enter before exiting.

.EXAMPLE
    .\delete-nul.ps1

.EXAMPLE
    .\delete-nul.ps1 -Path 'D:\projects' -DryRun

.EXAMPLE
    .\delete-nul.ps1 -Yes -NoPause -Format json -Log C:\logs\nul.json
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'global', 'select')]
    [string] $Mode = 'auto',
    [string] $StartDir,
    [string[]] $Path,
    [string] $PathsFile,
    [switch] $DryRun,
    [switch] $Yes,
    [switch] $NoElevate,
    [switch] $Elevate,
    [switch] $IncludeExtension,
    [switch] $Fast,
    [switch] $Mft,
    [string] $Log,
    [ValidateSet('text', 'json')]
    [string] $Format = 'text',
    [switch] $Quiet,
    [switch] $NoColor,
    [ValidateSet('auto', 'ascii', 'braille')]
    [string] $Spinner = 'auto',
    [ValidateRange(30, 3600)]
    [int] $ScanTimeout = 300,
    [switch] $NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Remember the launch directory: an elevated child process starts in System32,
# so "scan current directory" must use the directory the user actually launched from.
$script:StartDir = if ($StartDir) { $StartDir } else { (Get-Location).ProviderPath }

# ---------------------------------------------------------------- helpers
function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# An elevated process starts in a different working directory, so path-like
# arguments must be made absolute before being forwarded.
function ConvertTo-AbsolutePath {
    param([string] $Value)
    if ($Value -and -not [System.IO.Path]::IsPathRooted($Value)) {
        try { return [System.IO.Path]::GetFullPath($Value) } catch { return $Value }
    }
    return $Value
}

# Rebuild the current invocation as an argument list for an elevated powershell.exe.
function Get-ElevationArgs {
    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add('-NoProfile')
    $list.Add('-ExecutionPolicy')
    $list.Add('Bypass')
    $list.Add('-File')
    $list.Add('"{0}"' -f $PSCommandPath)
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        $key = $kv.Key
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value) { $list.Add("-$key") }
        } elseif ($kv.Value -is [Array]) {
            foreach ($v in $kv.Value) {
                $list.Add("-$key")
                $out = if ($key -in @('Path', 'Log', 'PathsFile', 'StartDir')) { ConvertTo-AbsolutePath ([string]$v) } else { [string]$v }
                $list.Add('"{0}"' -f $out)
            }
        } else {
            $list.Add("-$key")
            $out = if ($key -in @('Path', 'Log', 'PathsFile', 'StartDir')) { ConvertTo-AbsolutePath ([string]$kv.Value) } else { [string]$kv.Value }
            $list.Add('"{0}"' -f $out)
        }
    }
    # Always forward the original launch directory (not in PSBoundParameters
    # when it was inferred), so "scan current directory" survives elevation.
    if (-not $PSBoundParameters.ContainsKey('StartDir')) {
        $list.Add('-StartDir')
        $list.Add('"{0}"' -f (ConvertTo-AbsolutePath $script:StartDir))
    }
    return $list
}

$script:LogLines = [System.Collections.Generic.List[string]]::new()
function Emit {
    param([string]$Message, [string]$Color)
    # JSON mode keeps stdout clean: only the JSON object goes there.
    if ($Format -eq 'json') { return }
    if ($Color -and -not $NoColor) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
    $script:LogLines.Add($Message)
}

# ---------------------------------------------------------------- live progress
# In-place status line via [Console]::Write + carriage return. No external
# modules, no Add-Type (AV-friendly), and automatically off when redirected or
# when stdout must stay machine-readable (JSON / Quiet).
$script:ProgressEnabled = ($Format -ne 'json' -and -not $Quiet -and -not [Console]::IsOutputRedirected)
$script:NativeMode = $false
$script:ProgressLast = [datetime]::MinValue
$script:ProgressWidth = 0
$script:SpinnerIndex = 0
$script:SavedFg = [Console]::ForegroundColor

# Braille frames are smoother but require a UTF-8 console (PS7 or codepage 65001).
# On legacy GBK consoles they would render as mojibake, so fall back to ASCII.
$script:UnicodeOk = ($PSVersionTable.PSVersion.Major -ge 7) -or ([Console]::OutputEncoding.CodePage -eq 65001)
$script:SpinnerAscii = @('|', '/', '-', '\')
$script:SpinnerBraille = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
$script:UseBraille = if ($Spinner -eq 'braille') {
    if ($script:UnicodeOk) { $true } else {
        if ($Format -ne 'json') { Write-Warning '当前控制台编码不支持 UTF-8，spinner 已回退为 ASCII。' }
        $false
    }
} elseif ($Spinner -eq 'auto') {
    [bool]$script:UnicodeOk
} else {
    $false
}
$script:SpinnerFrames = if ($script:UseBraille) { $script:SpinnerBraille } else { $script:SpinnerAscii }

function Get-SpinnerFrame {
    $frame = $script:SpinnerFrames[($script:SpinnerIndex % $script:SpinnerFrames.Count)]
    $script:SpinnerIndex++
    return $frame
}

function Write-InPlace {
    param([string]$Line, [ConsoleColor]$Color = [ConsoleColor]::DarkCyan)
    if (-not $script:ProgressEnabled) { return }
    try {
        if (-not $NoColor) { [Console]::ForegroundColor = $Color }
        [Console]::Write("`r" + $Line)
        if ($Line.Length -lt $script:ProgressWidth) {
            [Console]::Write((' ' * ($script:ProgressWidth - $Line.Length)))
        }
        $script:ProgressWidth = $Line.Length
    } catch { } finally {
        if (-not $NoColor) { [Console]::ForegroundColor = $script:SavedFg }
    }
}

function Clear-ScanProgress {
    if (-not $script:ProgressEnabled -or $script:ProgressWidth -eq 0) { return }
    try {
        [Console]::Write("`r" + (' ' * ($script:ProgressWidth + 4)) + "`r")
    } catch { }
    $script:ProgressWidth = 0
}

# Animated "working on it" line for the privilege / UAC flow.
function Show-Spinner {
    param([string]$Message, [int]$DurationMs = 1500, [int]$FrameMs = 110)
    if (-not $script:ProgressEnabled -or -not [Environment]::UserInteractive) {
        Emit $Message
        return
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $DurationMs) {
        Write-InPlace ("  {0} {1}" -f (Get-SpinnerFrame), $Message)
        Start-Sleep -Milliseconds $FrameMs
    }
    Clear-ScanProgress
}

function Write-ScanProgress {
    param([string]$RootName, [long]$Scanned, [int]$Found, [double]$Elapsed, [switch]$Force)

    if (-not $script:ProgressEnabled) { return }
    $now = [datetime]::UtcNow
    # ~16 fps; a newly found item forces an immediate refresh.
    if (-not $Force -and ($now - $script:ProgressLast).TotalMilliseconds -lt 60) { return }
    $script:ProgressLast = $now

    $spin = Get-SpinnerFrame
    $dots = ('.' * (($script:SpinnerIndex - 1) % 4)).PadRight(3)

    # Indeterminate animation (total is unknown without a 2nd scan).
    $barWidth = 12
    $bar = ''
    if ($script:UseBraille) {
        $pos = [int](($Elapsed * 8) % $barWidth)
        for ($i = 0; $i -lt $barWidth; $i++) {
            $d = [math]::Abs($i - $pos)
            if ($d -le 1 -or $d -ge ($barWidth - 1)) { $bar += '#' } else { $bar += '.' }
        }
    } else {
        # ASCII "loading": bouncing '===>' head + a travelling background wave.
        $span = $barWidth - 4
        $t = [int]($Elapsed * 5)
        $p = $t % $span
        if (($t % 2) -eq 1) { $p = $span - 1 - $p }
        $wave = @('.', ':', ':', '.')
        for ($i = 0; $i -lt $barWidth; $i++) {
            if ($i -eq ($p + 3)) { $bar += '>' }
            elseif ($i -ge $p -and $i -lt ($p + 3)) { $bar += '=' }
            else { $bar += $wave[($i + [int]($Elapsed * 4)) % 4] }
        }
    }

    if ($script:NativeMode) {
        $line = ("  {0} SCAN{1} {2}  native scan  {3} found  {4:N1}s  [{5}]" -f `
            $spin, $dots, $RootName, $Found, $Elapsed, $bar)
    } else {
        $line = ("  {0} SCAN{1} {2}  {3:N0} dirs  {4} found  {5:N1}s  [{6}]" -f `
            $spin, $dots, $RootName, $Scanned, $Found, $Elapsed, $bar)
    }
    Write-InPlace $line
}

function Tick-Scan {
    param([string]$RootName, $Result, $Counter, [switch]$Force)
    Write-ScanProgress -RootName $RootName -Scanned $Counter.Value -Found $Result.Count `
        -Elapsed $stopwatch.Elapsed.TotalSeconds -Force:$Force
}

# Keep the live line short enough for an 80-column console.
function Get-DisplayRoot {
    param([string]$Path)
    if ($Path -match '^[A-Za-z]:\\?$') { return $Path }
    try {
        $drive = [System.IO.Path]::GetPathRoot($Path)
        $leaf = [System.IO.Path]::GetFileName($Path.TrimEnd('\'))
        if ($leaf.Length -gt 10) { $leaf = $leaf.Substring(0, 10) + '...' }
        return ($drive + '...\' + $leaf)
    } catch { return $Path }
}

# Avoid duplicates when a quick pre-check and the full scan both see the same file.
function Add-Found {
    param($List, [string] $Path)
    if (-not $List.Contains($Path)) { $List.Add($Path) }
}

# Quickly check the root and the first two levels of every target. This catches
# obvious root-level reserved names BEFORE a long full scan (or its timeout).
function Find-ReservedItemsShallow {
    param([string[]] $Roots, [string] $Pattern, $Result)
    foreach ($r in $Roots) {
        $full = $r  # keep literal; GetFullPath would turn "...\NUL" into a \\.\ device path
        if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
        # If the target itself is a reserved-name entry, record it directly.
        if ([System.IO.Path]::GetFileName($full) -match $Pattern -and (Test-LiteralEntry $full)) {
            Add-Found $Result $full
            continue
        }
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($full)
        for ($depth = 0; $depth -lt 3 -and $queue.Count -gt 0; $depth++) {
            $levelCount = $queue.Count
            for ($i = 0; $i -lt $levelCount; $i++) {
                $dir = $queue.Dequeue()
                # Names first (one enumeration), then subdirectories for the next
                # level (one enumeration). Avoids a GetAttributes syscall per entry.
                try {
                    foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries($dir)) {
                        if ([System.IO.Path]::GetFileName($e) -match $Pattern) { Add-Found $Result $e }
                    }
                } catch { }
                try {
                    foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                        if ([System.IO.Path]::GetFileName($sub) -notmatch $Pattern) { $queue.Enqueue($sub) }
                    }
                } catch { }
            }
        }
    }
}

# ---------------------------------------------------------------- NTFS MFT scanner
# Reads $MFT directly instead of walking directories. Compiled only when -Mft is
# used; all failures are caught by the caller, which falls back to the native scan.
function Initialize-MftScanner {
    if ('MftScanner' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class MftScanner
{
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint count, out uint read, IntPtr ovl);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetFilePointerEx(IntPtr h, long dist, out long newPos, uint method);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);

    struct Entry { public long Parent; public string Name; public int Namespace; }

    public static List<string> Scan(char letter)
    {
        IntPtr h = CreateFileW(@"\\.\" + letter + ":", 0x80000000u, 1u|2u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
        if (h == IntPtr.Zero || h == new IntPtr(-1))
            throw new Exception("CreateFile err=" + Marshal.GetLastWin32Error());
        try
        {
            byte[] boot = new byte[512]; uint got;
            if (!ReadFile(h, boot, 512, out got, IntPtr.Zero)) throw new Exception("boot read failed");
            int bps = BitConverter.ToUInt16(boot, 11);
            int spc = boot[13];
            long mftLcn = BitConverter.ToInt64(boot, 48);
            int mftSectors = BitConverter.ToInt32(boot, 64);
            int recSize = mftSectors > 0 ? mftSectors * bps : 1 << (-mftSectors);
            long mftOff = mftLcn * spc * bps;
            long dummy;
            if (!SetFilePointerEx(h, mftOff, out dummy, 0)) throw new Exception("seek failed");

            var entries = new Dictionary<int, Entry>();
            const int chunk = 512;
            byte[] buf = new byte[chunk * recSize];
            for (int baseRec = 0; ; baseRec += chunk)
            {
                if (!ReadFile(h, buf, (uint)buf.Length, out got, IntPtr.Zero) || got == 0) break;
                int n = (int)(got / recSize);
                for (int i = 0; i < n; i++)
                {
                    byte[] rec = new byte[recSize];
                    Buffer.BlockCopy(buf, i * recSize, rec, 0, recSize);
                    if (BitConverter.ToUInt32(rec, 0) != 0x454C4946u) continue;
                    int usaOff = BitConverter.ToUInt16(rec, 0x30);
                    int usaCnt = BitConverter.ToUInt16(rec, 0x32);
                    if (usaCnt > 1 && usaOff + usaCnt * 2 <= recSize)
                        for (int k = 1; k < usaCnt; k++)
                        {
                            int pos = k * bps - 2;
                            if (pos + 2 <= recSize) Buffer.BlockCopy(rec, usaOff + k * 2, rec, pos, 2);
                        }
                    int off = BitConverter.ToUInt16(rec, 0x14);
                    Entry best = new Entry { Namespace = 99 };
                    while (off + 16 <= recSize)
                    {
                        uint type = BitConverter.ToUInt32(rec, off);
                        if (type == 0xFFFFFFFFu) break;
                        int len = BitConverter.ToInt32(rec, off + 4);
                        if (len <= 0 || off + len > recSize) break;
                        if (type == 0x30u && rec[off + 8] == 0)
                        {
                            int vo = BitConverter.ToUInt16(rec, off + 20);
                            if (off + vo + 66 <= recSize)
                            {
                                int nl = rec[off + vo + 64];
                                byte ns = rec[off + vo + 65];
                                if (nl > 0 && off + vo + 66 + nl * 2 <= recSize)
                                {
                                    string name = Encoding.Unicode.GetString(rec, off + vo + 66, nl * 2);
                                    if (ns < best.Namespace)
                                        best = new Entry { Parent = BitConverter.ToInt64(rec, off + vo) & 0xFFFFFFFFFFFFL, Name = name, Namespace = ns };
                                }
                            }
                        }
                        off += len;
                    }
                    if (best.Name != null) entries[baseRec + i] = best;
                }
                if (n < chunk) break;
            }

            var result = new List<string>();
            foreach (var kv in entries)
            {
                string name = kv.Value.Name.ToUpperInvariant();
                bool match = name == "NUL" || name == "CON" || name == "PRN" || name == "AUX" ||
                    (name.Length == 4 && ((name.StartsWith("COM") || name.StartsWith("LPT")) && name[3] >= '1' && name[3] <= '9'));
                if (!match) continue;
                var parts = new List<string>();
                long parent = kv.Value.Parent;
                int guard = 0;
                while (parent != 5 && guard++ < 64)
                {
                    Entry e;
                    if (!entries.TryGetValue((int)parent, out e)) break;
                    parts.Add(e.Name);
                    parent = e.Parent;
                }
                parts.Reverse();
                result.Add(letter + @":\" + string.Join(@"\", parts.ToArray()) + @"\" + kv.Value.Name);
            }
            return result;
        }
        finally { CloseHandle(h); }
    }
}
'@ -ErrorAction Stop
        return $true
    } catch {
        Write-Warning ('MFT 解析器初始化失败，将回退原生扫描: ' + $_.Exception.Message)
        return $false
    }
}

function Find-ReservedItemsMft {
    param([string[]] $Roots, [string] $Pattern, $Result)
    foreach ($r in $Roots) {
        $full = [System.IO.Path]::GetFullPath($r)
        if ($full -notmatch '^([A-Za-z]):') { continue }
        $letter = [char]::ToUpper($Matches[1][0])
        $prefix = $full.TrimEnd('\') + '\'
        foreach ($path in [MftScanner]::Scan($letter)) {
            if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ([System.IO.Path]::GetFileName($path) -match $Pattern) { Add-Found $Result $path }
        }
    }
}

# Fastest practical scanner: one native `dir /s /b /a` process per root, whose
# output is filtered by `findstr` in native code. Measured ~4x faster than a
# PowerShell-level directory walk on large trees (1.9s vs 8.6s / 14k dirs).
# The command runs asynchronously so the loading animation keeps rendering.
function Find-ReservedItemsNative {
    param([string]$Root, [string]$Pattern, $Result, [string]$RootName,
          [switch]$IncludeExtension)

    # A drive root must stay "C:\" -- TrimEnd would turn it into "C:", which
    # cmd resolves as a drive-relative path (the current directory on that drive).
    $scanRoot = $Root
    if ($scanRoot -match '^[A-Za-z]:$') { $scanRoot += '\' }

    $stems = @('NUL', 'CON', 'PRN', 'AUX') +
             (1..9 | ForEach-Object { 'COM' + $_ }) +
             (1..9 | ForEach-Object { 'LPT' + $_ })
    $findParts = if ($IncludeExtension) {
        # match both bare "NUL" and "NUL.txt"; the PowerShell regex does exact filtering
        $stems | ForEach-Object { '/c:"\\' + $_ + '$"', '/c:"\\' + $_ + '\."' }
    } else {
        $stems | ForEach-Object { '/c:"\\' + $_ + '$"' }
    }
    $findArgs = '/r /i ' + ($findParts -join ' ')
    $tmpOut = Join-Path $env:TEMP ('rn_scan_' + [guid]::NewGuid().ToString('N') + '.txt')
    $cmdline = '/c dir /s /b /a "' + $scanRoot + '" 2>nul | findstr ' +
               $findArgs + ' > "' + $tmpOut + '" 2>nul'
    $proc = $null
    try {
        $proc = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdline -PassThru -WindowStyle Hidden
        $scanWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $timedOut = $false
        while (-not $proc.HasExited) {
            if ($scanWatch.Elapsed.TotalSeconds -ge $ScanTimeout) {
                $timedOut = $true
                try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch { }
                break
            }
            Write-ScanProgress -RootName $RootName -Scanned 0 -Found $Result.Count `
                -Elapsed $stopwatch.Elapsed.TotalSeconds
            Start-Sleep -Milliseconds 80
        }
        # Read whatever was produced -- even on timeout this preserves partial results.
        foreach ($line in [System.IO.File]::ReadLines($tmpOut)) {
            if ([System.IO.Path]::GetFileName($line) -match $Pattern) { Add-Found $Result $line }
        }
        if ($timedOut) {
            throw "扫描超时（$ScanTimeout 秒），已跳过 $RootName 的剩余部分"
        }
    } finally {
        if ($proc -and -not $proc.HasExited) {
            try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch { }
        }
        Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
    }
}

# Fallback / -Fast scanner. Reserved names are a fixed, tiny set. Instead of enumerating EVERY file and
# testing each name, ask the filesystem for six wildcard patterns per directory
# (FindFirstFile filters inside the directory index). A wildcard is essential:
# an exact "NUL" pattern also matches the DOS-device pseudo-entry present in
# every directory and would produce a flood of false positives.
function Find-ReservedItems {
    param(
        [string[]] $Roots,
        [string] $Pattern,
        [System.Collections.Generic.List[string]] $Result,
        $Counter,
        [string] $RootName,
        [switch] $Fast
    )
    $scanPatterns = @('NUL*', 'CON*', 'PRN*', 'AUX*', 'COM*', 'LPT*')
    $skipNames = if ($Fast) {
        @('windows', 'program files', 'program files (x86)', 'programdata',
          '$recycle.bin', 'system volume information', 'node_modules', '.git',
          '.svn', '__pycache__', '.gradle', '.m2', '.npm', '.yarn', '.vs', '.idea')
    } else { @() }

    $stack = [System.Collections.Generic.Stack[string]]::new()
    foreach ($r in $Roots) {
        try {
            $full = [System.IO.Path]::GetFullPath($r)
            if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
            $stack.Push($full)
        } catch { }
    }
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        if ([string]::IsNullOrEmpty($dir)) { continue }
        $Counter.Value++
        if (($Counter.Value -band 63) -eq 0) {
            Tick-Scan -RootName $RootName -Result $Result -Counter $Counter
        }

        # Name-based lookup: only entries whose name starts with a reserved stem.
        foreach ($sp in $scanPatterns) {
            try {
                foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($dir, $sp)) {
                    if ([System.IO.Path]::GetFileName($entry) -match $Pattern) {
                        Add-Found $Result $entry
                        Tick-Scan -RootName $RootName -Result $Result -Counter $Counter -Force
                    }
                }
            } catch { }
        }

        # Recurse into subdirectories, skipping reparse points (symlink loops).
        try {
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                $name = [System.IO.Path]::GetFileName($sub)
                if ($name -match $Pattern) { continue }   # already reported above
                if ($Fast -and $skipNames -contains $name.ToLowerInvariant()) { continue }
                try {
                    $attrs = [System.IO.File]::GetAttributes($sub)
                    if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $stack.Push($sub)
                    }
                } catch { }
            }
        } catch { }
    }
}

# .NET APIs handle \\?\ paths directly; fall back to cmd.exe del+rd if needed.
function Remove-ReservedPath {
    param([string] $LiteralPath)
    $q = '\\?\' + $LiteralPath
    try {
        if ([System.IO.Directory]::Exists($q)) {
            [System.IO.Directory]::Delete($q, $true)
        } else {
            [System.IO.File]::Delete($q)
        }
    } catch {
        try {
            $cmdLine = '/c del /f /a /q "{0}" & rd /s /q "{0}"' -f $q
            $null = & $env:ComSpec $cmdLine
        } catch { }
    }
    return -not ([System.IO.File]::Exists($q) -or [System.IO.Directory]::Exists($q))
}

# ---------------------------------------------------------------- privilege / elevation
function Exit-WithPause {
    param([int]$Code)
    if (-not $NoPause -and $Format -ne 'json' -and [Environment]::UserInteractive) {
        Read-Host '按回车键退出' | Out-Null
    }
    exit $Code
}

# ---------------------------------------------------------------- mode selection
# Read-Host echoes piped stdin into stdout; in JSON mode that would corrupt the
# machine-readable output. Route prompts to stderr there instead.
function Read-Answer {
    param([string] $Prompt)
    if ($Format -eq 'json') {
        [Console]::Error.Write($Prompt + ': ')
        try { return [Console]::ReadLine() } catch { return '' }
    }
    try { return Read-Host $Prompt } catch { return '' }
}

# Generic arrow-key menu. Uses only [Console] APIs (no Add-Type).
# Returns: selected index (>=0), -1 = back (Esc), -2 = home (Home key), or
# $null when the host cannot support an interactive console (text fallback).
# A letter in [X] in an item text is used as a keyboard shortcut for that item.
function Read-MenuSelection {
    param([string[]] $Items, [int] $Default = 0)
    if (-not [Environment]::UserInteractive -or [Console]::IsOutputRedirected -or
        $Format -eq 'json') { return $null }
    try {
        $startTop = [Console]::CursorTop
        $oldVisible = [Console]::CursorVisible
    } catch { return $null }

    # Derive shortcut letters from item labels like "[G] ...".
    $shortcuts = @{}
    for ($k = 0; $k -lt $Items.Count; $k++) {
        $m = [regex]::Match($Items[$k], '\[([A-Za-z0-9])\]')
        if ($m.Success) { $shortcuts[[char]::ToUpperInvariant($m.Groups[1].Value[0])] = $k }
    }

    $sel = $Default
    try {
        [Console]::CursorVisible = $false
        while ($true) {
            [Console]::SetCursorPosition(0, $startTop)
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $mark = if ($i -eq $sel) { ' > ' } else { '   ' }
                [Console]::WriteLine(($mark + $Items[$i]).PadRight(72))
            }
            $key = [Console]::ReadKey($true)
            $result = $null
            $done = $false
            switch ($key.Key) {
                'UpArrow'   { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                'DownArrow' { $sel = ($sel + 1) % $Items.Count }
                'PageUp'    { $sel = 0 }
                'PageDown'  { $sel = $Items.Count - 1 }
                'Enter'     { $result = $sel; $done = $true }
                'Escape'    { $result = -1; $done = $true }
                'Backspace' { $result = -1; $done = $true }
                'Home'      { $result = -2; $done = $true }
                default {
                    $ch = [char]::ToUpperInvariant($key.KeyChar)
                    if ($shortcuts.ContainsKey($ch)) { $result = $shortcuts[$ch]; $done = $true }
                }
            }
            if ($done) {
                [Console]::SetCursorPosition(0, $startTop + $Items.Count)
                return $result
            }
        }
    } catch {
        return $null
    } finally {
        [Console]::CursorVisible = $oldVisible
    }
}

# A console receives dragged files as quoted paths on the input line, e.g.
#   "C:\dir with space" "D:\file.txt"
# Extract those, otherwise fall back to ; / , separated plain paths.
# Test whether a literal filesystem entry exists, including reserved names that
# Win32 would resolve to a device. Uses the \\?\ prefix for the existence check
# only; the returned path stays in its original literal form.
function Test-LiteralEntry {
    param([string] $Path)
    if (-not $Path) { return $false }
    if ([System.IO.File]::Exists('\\?\' + $Path) -or
        [System.IO.Directory]::Exists('\\?\' + $Path)) { return $true }
    return (Test-Path -LiteralPath $Path)
}

function ConvertTo-PathList {
    param([string] $Text)
    $items = [System.Collections.Generic.List[string]]::new()
    if (-not $Text -or -not $Text.Trim()) { return @($items) }

    # 1) Quoted paths (paths with spaces that the console wrapped in quotes).
    $quoted = [regex]::Matches($Text, '"([^"]+)"')
    if ($quoted.Count -gt 0) {
        foreach ($m in $quoted) { $items.Add($m.Groups[1].Value) }
        return @($items)
    }

    # 2) Semicolon / comma separated.
    $parts = @($Text -split '[;,]')
    if ($parts.Count -gt 1) {
        foreach ($piece in $parts) {
            $t = $piece.Trim().Trim('"')
            if ($t) { $items.Add($t) }
        }
        return @($items)
    }

    # 3) A single token: either one real path, or several space-separated paths
    #    (some consoles drop quotes when the path has no spaces).
    $single = $Text.Trim()
    if (Test-Path -LiteralPath $single) { $items.Add($single); return @($items) }
    foreach ($tok in ($single -split '\s+')) {
        if ($tok) { $items.Add($tok) }
    }
    return @($items)
}

# Interactive folder browser: arrow keys move through subdirectories, Enter
# descends, "[选定] 当前目录" picks the current folder, ".." goes up, Home
# returns to the main menu. Returns a path, or the sentinel '__HOME__'.
function Select-FolderBrowser {
    param([string] $StartPath)
    # Keep drive roots ("C:\") intact -- TrimEnd would make them drive-relative ("C:").
    if ($StartPath -match '^[A-Za-z]:\\?$') { $current = $StartPath }
    else { $current = $StartPath.TrimEnd('\') }

    while ($true) {
        $subs = @()
        try {
            $subs = @([System.IO.Directory]::EnumerateDirectories($current) | Sort-Object)
        } catch { }

        # Build items and an index map so navigation is unambiguous.
        $items = [System.Collections.Generic.List[string]]::new()
        $idxSelect = 0
        $items.Add('[V] 选定当前目录  ' + $current)
        $parent = [System.IO.Path]::GetDirectoryName($current)
        $idxUp = -1
        if ($parent) { $idxUp = $items.Count; $items.Add('[..] 上一层') }
        $idxHome = $items.Count
        $items.Add('[H] 返回主页')
        $idxSubStart = $items.Count
        foreach ($s in $subs) { $items.Add('    ' + [System.IO.Path]::GetFileName($s) + '\') }

        Emit ''
        Emit '当前目录: ' + $current
        Emit '用 ↑ ↓ 选择，回车进入；V 选定当前目录，.. 上一层，Home 返回主页。'
        $sel = Read-MenuSelection -Items $items.ToArray() -Default 0
        if ($null -eq $sel) {
            # Non-interactive: fall back to typing a path.
            $text = Read-Answer '请输入目录路径（留空返回主页）'
            if (-not $text -or -not $text.Trim()) { return '__HOME__' }
            $t = $text.Trim().Trim('"')
            if (Test-LiteralEntry $t) { return $t }
            Emit ("[提示] 路径不存在: {0}" -f $t) 'Yellow'
            continue
        }
        if ($sel -eq -2) { return '__HOME__' }                 # Home key
        if ($sel -eq -1) { return '__HOME__' }                 # Esc / Backspace
        if ($sel -eq $idxSelect) { return $current }           # select current
        if ($idxUp -ge 0 -and $sel -eq $idxUp) { $current = $parent; continue }
        if ($sel -eq $idxHome) { return '__HOME__' }           # home item
        $subIndex = $sel - $idxSubStart
        if ($subIndex -ge 0 -and $subIndex -lt $subs.Count) {
            $current = $subs[$subIndex]
        }
    }
}

# Targeted mode: arrow-pick a drive, then browse folders. Returns an array of
# roots, or the sentinel '__HOME__' to go back to the main menu.
function Select-Targets {
    $readyDrives = @([System.IO.DriveInfo]::GetDrives() | Where-Object {
        $_.IsReady -and $_.DriveType -in @([System.IO.DriveType]::Fixed, [System.IO.DriveType]::Removable)
    })
    Emit ''
    Emit '选择目标磁盘 / Select a drive:'
    Emit '用 ↑ ↓ 选择，回车进入目录浏览；Home 返回主页。'
    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $readyDrives) {
        $items.Add(('[{0}] {1}  {2:N0} GB  {3}' -f $d.Name[0], $d.Name, ($d.TotalSize / 1GB), $d.VolumeLabel))
    }
    $items.Add('[H] 返回主页')

    $sel = Read-MenuSelection -Items $items.ToArray() -Default 0
    if ($null -eq $sel) {
        # Non-interactive: text fallback with drive numbers / paths.
        $text = Read-Answer '磁盘编号或目录路径（多个用分号 ; 分隔，留空返回主页）'
        if (-not $text -or -not $text.Trim()) { return '__HOME__' }
        $roots = [System.Collections.Generic.List[string]]::new()
        foreach ($t0 in (ConvertTo-PathList $text)) {
            $t = $t0.Trim()
            $num = 0
            if ([int]::TryParse($t, [ref]$num) -and $num -ge 1 -and $num -le $readyDrives.Count) {
                $roots.Add($readyDrives[$num - 1].RootDirectory.FullName); continue
            }
            if (Test-LiteralEntry $t) { $roots.Add($t) }
            else { Emit ("[提示] 路径不存在，已忽略: {0}" -f $t) 'Yellow' }
        }
        return @($roots)
    }
    if ($sel -eq -2 -or $sel -eq -1) { return '__HOME__' }
    if ($sel -ge $readyDrives.Count) { return '__HOME__' }  # home item
    $picked = Select-FolderBrowser -StartPath $readyDrives[$sel].RootDirectory.FullName
    if ($picked -eq '__HOME__') { return '__HOME__' }
    return @($picked)
}

# [D] pure CLI: paste a path (or type it), optionally separated by ; or spaces.
# No popups -- drag-and-drop into the console is limited by the terminal host
# and by UIPI when elevated, so a reliable plain-input prompt is the fallback.
function Read-ConsoleDrop {
    Emit ''
    Emit '[D] 请粘贴文件或文件夹的路径，然后回车（可多个，用空格或分号分隔）。'
    Emit '    提示：在资源管理器里按住 Shift 右键文件/文件夹 → "复制文件地址"，'
    Emit '          然后在这里 Ctrl+V 粘贴即可。'
    $text = Read-Answer '路径'
    if (-not $text -or -not $text.Trim()) {
        Emit '[提示] 没有输入路径，已取消。' 'Yellow'
        return @()
    }
    $paths = @(ConvertTo-PathList $text.Trim('"'))
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $paths) {
        if (Test-LiteralEntry $p) {
            $roots.Add($p)
        } else {
            Emit ("[提示] 路径不存在，已忽略: {0}" -f $p) 'Yellow'
        }
    }
    if ($roots.Count -eq 0) { Emit '[提示] 没有识别到有效路径。' 'Yellow' }
    return @($roots)
}

function Select-ScanMode {
    $items = @(
        '[G] 全局扫描   扫描所有本地磁盘（最全，但慢）',
        '[S] 定向处理   选磁盘 → 浏览目录',
        '[C] 扫描当前目录 ' + $script:StartDir,
        '[D] 粘贴路径   输入文件或文件夹路径（Shift+右键复制地址再粘贴）',
        '[Q] 退出'
    )
    while ($true) {
        Emit ''
        Emit '=================================================='
        Emit ' delete-nul · 选择扫描模式 / Select scan mode'
        Emit '=================================================='
        Emit ' 用 ↑ ↓ 选择，回车确认（G/S/C/D/Q）；Home 返回主页。'

        $sel = Read-MenuSelection -Items $items -Default 0
        if ($null -eq $sel) {
            # Non-interactive host (redirected / JSON): plain text fallback.
            foreach ($it in $items) { Emit ('  ' + $it) }
            Emit '--------------------------------------------------'
            $c = Read-Answer '请选择 [G/S/C/D/Q]（默认 G）'
            if (-not $c) { $c = 'G' }
            switch ($c.Trim().ToUpperInvariant()) {
                'Q' { Emit '已取消，未做任何修改。'; Exit-WithPause 1 }
                'S' {
                    $r = Select-Targets
                    if ($r -is [string] -and $r -eq '__HOME__') { continue }
                    return $r
                }
                'C' { return @($script:StartDir) }
                'D' { return Read-ConsoleDrop }
                default { return '__GLOBAL__' }
            }
        }
        switch ($sel) {
            -2 { continue }  # Home: stay on main menu
            -1 { Emit '已取消，未做任何修改。'; Exit-WithPause 1 }
            4  { Emit '已取消，未做任何修改。'; Exit-WithPause 1 }
            3  { return Read-ConsoleDrop }
            2  { return @($script:StartDir) }  # scan current directory
            1  {
                $r = Select-Targets
                if ($r -is [string] -and $r -eq '__HOME__') { continue }  # back to home
                return $r
            }
            default { return '__GLOBAL__' }
        }
    }
}

# Elevation is now OPT-IN. Reason: auto-elevating creates a high-integrity
# window that Explorer cannot drag files into (UIPI), and normal-user rights
# are enough to delete reserved-name files in the user's own directories.
$isAdmin = Test-Admin
if ($Elevate -and -not $isAdmin) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (Get-ElevationArgs) | Out-Null
        Emit '已在新的管理员窗口中继续运行，本窗口可以关闭。' 'Cyan'
        if (-not $NoPause) { Start-Sleep -Seconds 2 }
        exit 0
    } catch {
        Emit '[提示] UAC 被拒绝，将以普通权限继续。' 'Yellow'
    }
}
if (-not $isAdmin) {
    Emit '[权限] 普通用户（默认）。个人目录可直接删除；系统目录需 -Elevate。' 'Yellow'
}

# ---------------------------------------------------------------- setup
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$rootError = $null
$roots = @()
$allDrives = @([System.IO.DriveInfo]::GetDrives() | Where-Object {
    $_.IsReady -and
    $_.DriveType -notin @([System.IO.DriveType]::Network,
                          [System.IO.DriveType]::CDRom,
                          [System.IO.DriveType]::Ram)
} | ForEach-Object { $_.RootDirectory.FullName })

$isInteractive = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and
                 $Format -ne 'json' -and -not $Yes
try {
    if ($PSBoundParameters.ContainsKey('Path') -and $Path) {
        # targeted mode (explicit -Path)
        foreach ($p in $Path) { $roots += $p }  # keep literal; reserved names must not go through GetFullPath
    } elseif ($PSBoundParameters.ContainsKey('PathsFile') -and $PathsFile -and (Test-Path -LiteralPath $PathsFile)) {
        # drag-and-drop: the bat writes one path per line (powershell -File only
        # binds a single value to array params, so several paths need a list file)
        foreach ($p in [System.IO.File]::ReadAllLines($PathsFile)) {
            $t = $p.Trim()
            if (-not $t) { continue }
            # Do NOT use GetFullPath here: on a path ending in NUL/CON/etc. it
            # returns a \\.\ device path. Keep the literal path verbatim.
            $roots += $t
        }
        Remove-Item -LiteralPath $PathsFile -Force -ErrorAction SilentlyContinue
    } elseif ($Mode -eq 'select') {
        $roots = @(Select-Targets)
        if ($roots.Count -eq 0) {
            Emit '[提示] 未选择有效目标，已取消。' 'Yellow'
            Exit-WithPause 1
        }
    } elseif ($Mode -eq 'global' -or -not $isInteractive) {
        $roots = @($allDrives)
    } else {
        # auto + interactive: G returns a sentinel, S/D return an array.
        # (An empty array collapses to $null in PowerShell, so never use
        #  $null to mean "global" or a failed drop would start a full scan.)
        $chosen = Select-ScanMode
        if ($chosen -is [string] -and $chosen -eq '__GLOBAL__') {
            $roots = @($allDrives)
        } else {
            $roots = @($chosen | Where-Object { $_ })
            if ($roots.Count -eq 0) {
                Emit '[提示] 没有有效目标，已取消。' 'Yellow'
                Exit-WithPause 1
            }
        }
    }
} catch {
    $rootError = $_.Exception.Message
}

$pattern = if ($IncludeExtension) {
    '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.[^.]+)?$'
} else {
    '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
}

$adminText = if ($isAdmin) { '管理员 [已提权]' } else { '普通用户 [部分目录可能不可访问]' }
$adminColor = if ($isAdmin) { 'Green' } else { 'Yellow' }
$animText = if ($script:UseBraille) { 'Braille' } else { 'ASCII' }
Emit '=================================================='
Emit ' 保留名文件清理工具 (NUL/CON/AUX/PRN/COM1-9/LPT1-9)'
Emit (" 权限: {0}" -f $adminText) $adminColor
Emit (" 模式: {0} | 含扩展名: {1} | 动画: {2}" -f `
        $(if ($DryRun) { '仅扫描' } else { '扫描+删除' }), `
        $(if ($IncludeExtension) { '是' } else { '否' }), $animText)
Emit '=================================================='
Emit ''

if ($rootError -or $roots.Count -eq 0) {
    Emit ("[错误] 无法确定扫描根目录: {0}" -f $(if ($rootError) { $rootError } else { '没有可用的本地磁盘；请用 -Path 指定目录。' })) 'Red'
    if (-not $NoPause -and -not $Yes -and $Format -ne 'json' -and [Environment]::UserInteractive) {
        Read-Host '按回车键退出' | Out-Null
    }
    exit 3
}

# ---------------------------------------------------------------- scan
$found = [System.Collections.Generic.List[string]]::new()
$counter = [pscustomobject]@{ Value = 0 }
$script:UseMft = $false
if ($Mft) {
    if ($isAdmin) { $script:UseMft = Initialize-MftScanner }
    else { Emit '[提示] -Mft 需要管理员权限，本次使用原生扫描。' 'Yellow' }
}
$rootIndex = 0
foreach ($r in $roots) {
    $rootIndex++
    $beforeScanned = $counter.Value
    $beforeFound = $found.Count
    $displayRoot = Get-DisplayRoot $r
    $script:NativeMode = (-not $Fast -and -not $script:UseMft)
    if (-not $Quiet) {
        Emit ("[{0}/{1}] 正在扫描 {2} ..." -f $rootIndex, $roots.Count, $r) 'Cyan'
        Tick-Scan -RootName $displayRoot -Result $found -Counter $counter -Force
    }
    # Root-level quick check runs first so a timeout can never hide these.
    Find-ReservedItemsShallow -Roots @($r) -Pattern $pattern -Result $found
    if ($script:UseMft) {
        try {
            Find-ReservedItemsMft -Roots @($r) -Pattern $pattern -Result $found
        } catch {
            Emit ("[提示] MFT 扫描失败，回退原生扫描: {0}" -f $_.Exception.Message) 'Yellow'
            $script:UseMft = $false
            $script:NativeMode = $true
            Find-ReservedItemsNative -Root $r -Pattern $pattern -Result $found `
                -RootName $displayRoot -IncludeExtension:$IncludeExtension
        }
    } elseif ($Fast) {
        Find-ReservedItems -Roots @($r) -Pattern $pattern -Result $found -Counter $counter `
            -RootName $displayRoot -Fast
    } else {
        try {
            Find-ReservedItemsNative -Root $r -Pattern $pattern -Result $found `
                -RootName $displayRoot -IncludeExtension:$IncludeExtension
        } catch {
            $msg = $_.Exception.Message
            Emit ("[提示] {0}" -f $msg) 'Yellow'
            if ($msg -like '*扫描超时*') {
                # Do NOT fall back to the walker: it would hang on the same drive.
                $script:NativeMode = $true
            } else {
                $script:NativeMode = $false
                Find-ReservedItems -Roots @($r) -Pattern $pattern -Result $found -Counter $counter `
                    -RootName $displayRoot
            }
        }
    }
    if (-not $Quiet) {
        Clear-ScanProgress
        if ($script:UseMft) {
            Emit ("      完成：MFT 索引扫描，发现 {0} 个，耗时 {1:N1}s" -f `
                ($found.Count - $beforeFound), $stopwatch.Elapsed.TotalSeconds)
        } elseif ($script:NativeMode) {
            Emit ("      完成：发现 {0} 个，耗时 {1:N1}s" -f `
                ($found.Count - $beforeFound), $stopwatch.Elapsed.TotalSeconds)
        } else {
            Emit ("      完成：扫描 {0:N0} 个目录，发现 {1} 个，耗时 {2:N1}s" -f `
                ($counter.Value - $beforeScanned), ($found.Count - $beforeFound), $stopwatch.Elapsed.TotalSeconds)
        }
    }
}
$elapsed = $stopwatch.Elapsed.TotalSeconds

$summaryText = if ($script:UseMft) {
    ("扫描完成：MFT 索引扫描，耗时 {0:N1} 秒。" -f $elapsed)
} elseif ($script:NativeMode) {
    ("扫描完成：原生扫描，耗时 {0:N1} 秒。" -f $elapsed)
} else {
    ("扫描完成：扫描 {0} 个目录，耗时 {1:N1} 秒。" -f $counter.Value, $elapsed)
}
Emit ''
if ($found.Count -eq 0) {
    Emit '未发现任何保留名文件，无需删除。' 'Green'
    Emit $summaryText
} else {
    Emit ("发现 {0} 个保留名文件：" -f $found.Count) 'Yellow'
    Emit '--------------------------------------------------'
    $i = 0
    foreach ($f in $found) { $i++; Emit ("[{0}] {1}" -f $i, $f) }
    Emit '--------------------------------------------------'
    Emit $summaryText
}

# ---------------------------------------------------------------- confirm + delete
$itemList = [System.Collections.Generic.List[object]]::new()
$deleted = 0
$failed = 0
$cancelled = $false

if ($found.Count -gt 0) {
    if ($DryRun) {
        foreach ($f in $found) { $itemList.Add([pscustomobject]@{ path = $f; status = 'found' }) }
        Emit '仅扫描模式（DryRun），未删除任何文件。' 'Yellow'
        $exitCode = 0
    } else {
        $confirm = [bool]$Yes
        if (-not $confirm) {
            if ($Format -eq 'json') {
                [Console]::Error.Write('Confirm delete all? (Y/N): ')
                try { $ans = [Console]::ReadLine() } catch { $ans = 'N' }
            } else {
                try { $ans = Read-Host '确认删除以上全部文件吗？(Y=删除 / N=取消)' }
                catch { $ans = 'N' }
            }
            $confirm = $ans -match '^[Yy]'
        }
        if (-not $confirm) {
            Emit '已取消，未做任何修改。' 'Yellow'
            $cancelled = $true
            $exitCode = 1
        } else {
            foreach ($f in $found) {
                $ok = Remove-ReservedPath -LiteralPath $f
                $status = if ($ok) { 'deleted' } else { 'failed' }
                $itemList.Add([pscustomobject]@{ path = $f; status = $status })
                if ($ok) { $deleted++; Emit ("[已删] {0}" -f $f) 'Green' }
                else { $failed++; Emit ("[失败] {0}" -f $f) 'Red' }
            }
            $exitCode = if ($failed -gt 0) { 2 } else { 0 }
        }
    }
} else {
    $exitCode = 0
}

Emit ''
Emit ("处理完成：成功 {0} 个，失败 {1} 个。" -f $deleted, $failed)

# ---------------------------------------------------------------- output
$jsonObj = [ordered]@{
    admin          = [bool]$isAdmin
    roots          = @($roots)
    pattern        = $pattern
    dryRun         = [bool]$DryRun
    includeExtension = [bool]$IncludeExtension
    scanner        = if ($script:UseMft) { 'mft' } elseif ($script:NativeMode) { 'native' } else { 'walker' }
    scanned        = $counter.Value
    elapsedSeconds = [math]::Round($elapsed, 2)
    cancelled      = $cancelled
    found          = $found.Count
    deleted        = $deleted
    failed         = $failed
    items          = @($itemList)
    exitCode       = $exitCode
}

if ($Format -eq 'json') {
    $jsonObj | ConvertTo-Json -Depth 5 | Write-Output
}

if ($Log) {
    try {
        $logFull = [System.IO.Path]::GetFullPath($Log)
        $dir = [System.IO.Path]::GetDirectoryName($logFull)
        if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
            [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        }
        $content = if ($Format -eq 'json') {
            ($jsonObj | ConvertTo-Json -Depth 5)
        } else {
            ($script:LogLines -join [Environment]::NewLine)
        }
        [System.IO.File]::AppendAllText($logFull, $content + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch {
        Write-Warning ("无法写入日志文件: {0}" -f $_.Exception.Message)
    }
}

if (-not $NoPause -and -not $Yes -and $Format -ne 'json' -and [Environment]::UserInteractive) {
    Read-Host '按回车键退出' | Out-Null
}
exit $exitCode
