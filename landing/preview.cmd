@echo off
where py >nul 2>nul
if errorlevel 1 (
  python -I -m http.server 4190 --bind 127.0.0.1 --directory "%~dp0."
) else (
  py -3 -I -m http.server 4190 --bind 127.0.0.1 --directory "%~dp0."
)
