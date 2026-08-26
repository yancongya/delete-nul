# delete-nul 工具集 | Windows Reserved-Name File Cleaner Toolkit

Windows 保留名文件（NUL / CON / AUX / PRN / COM1-9 / LPT1-9）的查找与删除工具。
Find and delete Windows reserved-name files that cannot be removed by normal means.

**所有版本共同行为 | Common behavior:** 先列出全部结果 → 确认（输入 Y）才删除 → 逐条报告成功/失败。只精确匹配保留名本体（如 `NUL`），不会误删 `nul.txt` 这类正常文件。
List first → confirm (Y) → delete with per-file report. Only exact reserved names are matched; normal files like `nul.txt` are never touched.

---

## 一、文件列表与下载 | Files & Downloads

> 点击文件名即可在 GitHub 上查看/下载。Click a filename to view/download it on GitHub.

| 文件 File | 用途 Purpose | 管理员 Admin | 使用方式 How to use |
|---|---|---|---|
| [delete-nul.bat](delete-nul.bat) <span title="recommended">推荐</span> | 全盘扫描+删除 Full-disk scan & delete | 建议 Recommended | 双击运行 Double-click |
| [delete-nul.ps1](delete-nul.ps1) | 全盘扫描+删除（PowerShell 版，中文界面）Same, PowerShell with Chinese UI | 自动 UAC Auto UAC | 右键 → 使用 PowerShell 运行 Right-click → Run with PowerShell |
| [delete-nul-here.bat](delete-nul-here.bat) | 只清理该 bat 所在文件夹 Cleans only its own folder | 通常不需要 Usually no | 放进目标文件夹后双击 Put it in target folder, double-click |
| [paste-to-cmd-current-dir.txt](paste-to-cmd-current-dir.txt) | 免落地：粘贴进 cmd 清理当前目录 No file needed: paste into cmd for current dir | 不需要 No | 打开 cmd → cd 到目录 → 复制粘贴 |
| [paste-to-cmd-fullscan.txt](paste-to-cmd-fullscan.txt) | 免落地：粘贴进 cmd 全盘扫描 Paste into cmd for full scan | 建议 Recommended | 管理员 cmd → 复制粘贴 |

---

## 二、为什么会有 NUL 这种文件？ | Why do NUL files exist?

`NUL`、`CON`、`PRN`、`AUX`、`COM1~9`、`LPT1~9` 是从 DOS 时代继承的**设备保留名**，但以下场景仍会产生"名叫 NUL 的真实文件"：

1. **重定向命令写错位置**：如 `copy a.txt NUL` 在某些非标准 API 下把 NUL 当真实文件名创建；
2. **跨平台解压 / Git / 网盘同步**：Linux 下 `nul`、`aux.c` 是合法文件名，同步到 Windows 被字面创建；
3. **下载/传输工具 bug**：不检查保留名直接落盘；
4. **恶意软件故意创建**：利用"删不掉"的特性对抗清理。

These names are DOS-era device names reserved by Windows. Real files named `NUL` still appear when: redirection commands misuse non-standard APIs; cross-platform archives/Git/cloud-sync bring Linux-legal names over; buggy transfer tools write them literally; or malware creates them deliberately to resist cleanup.

---

## 三、为什么普通方法删不掉？| Why can't they be deleted normally?

Win32 API 在**解析路径阶段**就把 `NUL` 识别成 DOS 设备对象而非文件——资源管理器和普通 `del NUL` 操作的都是"NUL 设备"，不是那个真实文件。

解决方法：给路径加 `\\?\` 前缀，跳过 Win32 路径规范化、直达 NT 对象管理器，此时它就是字面上的文件路径：

The Win32 path resolver treats `NUL` as a DOS device object, not a file, so Explorer and plain `del NUL` never touch the real file. Prefixing the path with `\\?\` bypasses Win32 normalization and addresses the literal file:

```bat
del /f /a /q "\\?\C:\某个目录\NUL"
```

完整流程 Full pipeline: `dir 枚举枚举不受影响，可正常列出 → 按名字精确匹配 → 记录完整路径 → 加 \\?\ 前缀删除 → 复核报告`
Enumeration works fine (`dir`), so: enumerate → match exact names → record full paths → delete via `\\?\` prefix → verify and report.

---

## 四、一行命令：远程下载并执行 | One-liner: download & run

> ⚠️ 仅当你信任脚本来源时使用；杀软可能对"下载并执行"链路报警。
> Use only with a trusted source; antivirus may flag download-and-execute chains.

```bat
curl -fsSL "https://raw.githubusercontent.com/<user>/<repo>/main/delete-nul.bat" -o "%TEMP%\delete-nul.bat" && call "%TEMP%\delete-nul.bat"
```

把 `<user>/<repo>` 替换为本仓库地址即可。Replace `<user>/<repo>` with this repo's path after pushing.

不想下载？直接全盘扫描预览（安全，只列出不删除）Or preview without downloading (safe, list only):

```bat
set "RNLIST=%TEMP%\reserved_name_files.txt" && type nul > "%RNLIST%" && (for %D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %D:\ dir /s /b /a "%D:\" 2>nul)|findstr /r /i /c:"\\nul$" /c:"\\con$" /c:"\\prn$" /c:"\\aux$" > "%RNLIST%" & type "%RNLIST%"
```

---

## 五、常见问题 | FAQ

- **闪退 / 被杀软删除？Crashed or killed by antivirus?**
  早期版本使用 Base64+PowerShell 编码技巧触发启发式误报（Trojan/PS.Encpe）；现行 bat 为纯 CMD 实现，无 PowerShell、无编码混淆。仍被拦截请将本文件夹加入白名单。
  Earlier versions used Base64-encoded PowerShell which tripped AV heuristics; current bat is pure CMD. Whitelist the folder if still flagged.
- **提示 FAILED？Items marked FAILED?**
  文件被占用或权限不足；关闭占用程序或以管理员身份重跑。Locked by a process or access denied; close the locker or rerun as administrator.
- **能恢复吗？Can deleted files be recovered?**
  删除不进回收站，务必核对列表后再按 Y。Deletion skips the Recycle Bin — always review the list before pressing Y.
- **bat 界面为什么是英文？Why is the bat UI in English?**
  为兼容任意系统代码页并避免杀软/解析问题，bat 保持纯 ASCII；中文界面请用 ps1 或 txt 版本。Bats stay pure ASCII for codepage safety; use the ps1/txt versions for Chinese UI.

---

## 六、ps1 运行方式 | Running the ps1

右键 → 使用 PowerShell 运行；或命令行：
Right-click → Run with PowerShell; or from a terminal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\delete-nul.ps1
```

---

F:\delete-nul · delete-nul toolkit · README
