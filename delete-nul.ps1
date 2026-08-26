# 全盘查找并删除保留名文件 (NUL/CON/AUX/PRN/COM1-9/LPT1-9)
$ErrorActionPreference = 'SilentlyContinue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
        Write-Host '已在新的管理员窗口中继续运行，本窗口可以关闭。'
        Start-Sleep -Seconds 2
        exit
    } catch {
        Write-Host '[提示] 未获得管理员权限，将以普通权限继续，部分目录可能无法访问或删除。' -ForegroundColor Yellow
    }
}

Write-Host '=================================================='
Write-Host ' 扫描所有本地磁盘的保留名文件 (NUL/CON/AUX/PRN...)'
Write-Host ' 全盘扫描可能需要几分钟，请耐心等待...'
Write-Host '=================================================='
Write-Host ''

$pattern = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.[^.]+)?$'
$found = New-Object System.Collections.Generic.List[string]

$drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -ne 'Network' -and $_.DriveType -ne 'CDRom' }

foreach ($d in $drives) {
    Write-Host ("正在扫描 {0} ..." -f $d.Name) -ForegroundColor Cyan
    Get-ChildItem -LiteralPath $d.RootDirectory.FullName -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } |
        ForEach-Object { $found.Add($_.FullName) }
}

Write-Host ''
if ($found.Count -eq 0) {
    Write-Host '未发现任何保留名文件，无需删除。' -ForegroundColor Green
    Read-Host '按回车键退出'
    exit
}

Write-Host ("发现 {0} 个保留名文件：" -f $found.Count) -ForegroundColor Yellow
Write-Host '--------------------------------------------------'
$i = 0
foreach ($f in $found) { $i++; Write-Host ("[{0}] {1}" -f $i, $f) }
Write-Host '--------------------------------------------------'
Write-Host ''

$ans = Read-Host '确认删除以上全部文件吗？(Y=删除 / N=取消)'
if ($ans -notmatch '^[Yy]') {
    Write-Host '已取消，未做任何修改。'
    Read-Host '按回车键退出'
    exit
}

$ok = 0; $fail = 0
foreach ($f in $found) {
    $q = '\\?\' + $f
    Remove-Item -LiteralPath $q -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $q) {
        Write-Host ("[失败] {0}" -f $f) -ForegroundColor Red
        $fail++
    } else {
        Write-Host ("[已删] {0}" -f $f) -ForegroundColor Green
        $ok++
    }
}

Write-Host ''
Write-Host ("处理完成：成功 {0} 个，失败 {1} 个。" -f $ok, $fail)
Read-Host '按回车键退出'
