@echo off
setlocal DisableDelayedExpansion
title Reserved-Name File Cleaner (NUL/CON/AUX...)

net session >nul 2>&1
if errorlevel 1 (
    echo [NOTE] Not running as Administrator.
    echo Some system folders may be inaccessible or undeletable.
    echo For best result: right-click this bat, choose "Run as administrator".
    echo.
    ping -n 5 127.0.0.1 >nul
)

set "LIST=%TEMP%\reserved_name_files.txt"
type nul > "%LIST%"

echo ==================================================
echo  Scanning all local drives for reserved-name files
echo  (NUL CON PRN AUX COM1-9 LPT1-9). Please wait...
echo ==================================================
echo.

for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do call :scan %%D

set "COUNT=0"
for /f %%C in ('type "%LIST%" ^| find /c /v ""') do set "COUNT=%%C"
echo.
if "%COUNT%"=="0" goto none

echo Found %COUNT% reserved-name file(s):
echo --------------------------------------------------
type "%LIST%"
echo --------------------------------------------------
echo.
choice /c YN /n /m "Delete ALL listed files? [Y=yes / N=no] "
if errorlevel 2 goto cancel

echo.
for /f "usebackq delims=" %%P in ("%LIST%") do call :delpath %%P
echo.
echo Finished. Items marked FAILED are locked or access denied.
del "%LIST%" >nul 2>&1
pause
exit /b 0

:none
echo No reserved-name files found. Nothing to delete.
del "%LIST%" >nul 2>&1
pause
exit /b 0

:cancel
echo Cancelled. Nothing was changed.
del "%LIST%" >nul 2>&1
pause
exit /b 0

:scan
if not exist %1:\ goto :eof
echo Scanning %1:\ ...
for /f "delims=" %%F in ('dir /s /b /a "%1:\" 2^>nul') do call :check "%%F"
goto :eof

:check
set "n=%~nx1"
if /i "%n%"=="nul" goto add
if /i "%n%"=="con" goto add
if /i "%n%"=="prn" goto add
if /i "%n%"=="aux" goto add
if /i "%n%"=="com1" goto add
if /i "%n%"=="com2" goto add
if /i "%n%"=="com3" goto add
if /i "%n%"=="com4" goto add
if /i "%n%"=="com5" goto add
if /i "%n%"=="com6" goto add
if /i "%n%"=="com7" goto add
if /i "%n%"=="com8" goto add
if /i "%n%"=="com9" goto add
if /i "%n%"=="lpt1" goto add
if /i "%n%"=="lpt2" goto add
if /i "%n%"=="lpt3" goto add
if /i "%n%"=="lpt4" goto add
if /i "%n%"=="lpt5" goto add
if /i "%n%"=="lpt6" goto add
if /i "%n%"=="lpt7" goto add
if /i "%n%"=="lpt8" goto add
if /i "%n%"=="lpt9" goto add
goto :eof
:add
>>"%LIST%" echo("%~1"
goto :eof

:delpath
del /f /a /q "\\?\%~1" >nul 2>&1
rd /s /q "\\?\%~1" >nul 2>&1
if exist "\\?\%~1" (echo [FAILED] %~1) else (echo [DELETED] %~1)
goto :eof
