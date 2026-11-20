@echo off
rem Wrapper: with no arguments scans this folder; dragged items become -PathsFile targets.
setlocal EnableExtensions
title Reserved-Name Cleaner

set "PS1=%~dp0delete-nul.ps1"
if not exist "%PS1%" (
    echo [ERROR] delete-nul.ps1 not found next to this file.
    echo Download BOTH files from https://github.com/yancongya/delete-nul
    pause
    exit /b 3
)

set "PS=powershell.exe"
where pwsh >nul 2>&1 && set "PS=pwsh"

set "LIST=%TEMP%\rn_paths_%RANDOM%.txt"
type nul > "%LIST%"
set "HASPATHS="
set "OPTS="

:args
if "%~1"=="" goto argsdone
if exist "%~1" (
    >>"%LIST%" echo(%~1
    set "HASPATHS=1"
) else (
    set "OPTS=%OPTS% %1"
)
shift
goto args
:argsdone

if defined HASPATHS (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -PathsFile "%LIST%" %OPTS%
) else (
    del "%LIST%" >nul 2>&1
    rem No drag: default to this folder (stripped trailing backslash).
    rem No drag: default target is this folder. Write it to the list file too,
    rem avoiding all trailing-backslash quoting problems.
    >>"%LIST%" echo(%~dp0
    "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -PathsFile "%LIST%" %*
)
exit /b %ERRORLEVEL%
