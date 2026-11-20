@echo off
cd /d "%~dp0"
where npm.cmd >nul 2>nul
if errorlevel 1 (
  echo Install Node.js 22.12 or later, then rerun this script.
  exit /b 1
)
call npm ci
if errorlevel 1 exit /b 1
echo Visit http://127.0.0.1:4191/delete-nul/#features
call npm run dev -- --port 4191 --open "/delete-nul/#features"
