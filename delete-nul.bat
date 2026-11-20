@echo off
rem Wrapper: forwards switches; dragged paths are collected into a list file
rem (powershell.exe -File binds only one value to array parameters).
setlocal EnableExtensions
title Reserved-Name File Cleaner (NUL/CON/AUX...)

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
rem A switch starts with "-"; everything else is a target path. Do NOT use
rem "if exist": a bare NUL/CON path resolves to the DOS device and fails the test.
set "ARG=%~1"
if "%PREVNEEDSVAL%"=="1" (
    set "OPTS=%OPTS% %ARG%"
    set "PREVNEEDSVAL="
    shift
    goto args
)
if "%ARG:~0,1%"=="-" (
    set "OPTS=%OPTS% %ARG%"
    if /i "%ARG%"=="-Format" set "PREVNEEDSVAL=1"
    if /i "%ARG%"=="-Log" set "PREVNEEDSVAL=1"
    if /i "%ARG%"=="-Spinner" set "PREVNEEDSVAL=1"
    if /i "%ARG%"=="-Mode" set "PREVNEEDSVAL=1"
    if /i "%ARG%"=="-ScanTimeout" set "PREVNEEDSVAL=1"
) else (
    >>"%LIST%" echo(%ARG%
    set "HASPATHS=1"
)
shift
goto args
:argsdone

if defined HASPATHS (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -PathsFile "%LIST%" %OPTS%
) else (
    del "%LIST%" >nul 2>&1
    "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
)
exit /b %ERRORLEVEL%
