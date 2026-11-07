@echo off
REM Installs the Claude <-> Lightroom Classic bridge.
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 install.py
  goto :eof
)
where python >nul 2>nul
if %errorlevel%==0 (
  python install.py
  goto :eof
)
echo Python is not installed.
echo Install it from https://www.python.org/downloads/ and tick "Add python.exe to PATH", then run this again.
pause
