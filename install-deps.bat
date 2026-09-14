@echo off
REM ==========================================================================
REM  install-deps.bat - Install the Python dependencies find-subs needs
REM                     (Windows, standalone - does NOT require bash).
REM
REM  Installs the SAME packages d3l0g3 installs (subliminal + guessit); the rest
REM  (babelfish/requests/beautifulsoup4/PyYAML/...) come in transitively.
REM
REM  Usage:
REM    install-deps.bat              pip install -r requirements.txt
REM    install-deps.bat --user       install into the user site (no admin)
REM    install-deps.bat --venv       create .venv and install into it
REM    install-deps.bat --wheels DIR OFFLINE install from a wheels folder
REM
REM  Verify afterwards with:  python check-deps.py
REM ==========================================================================
setlocal enableextensions
cd /d "%~dp0"

set "REQ=%~dp0requirements.txt"
if not exist "%REQ%" (
  echo ERROR: requirements.txt not found next to this script.
  exit /b 1
)

REM Resolve a working Python 3 launcher (prefer 'py -3', then python).
set "PY="
where py >nul 2>&1 && ( py -3 -c "import sys" >nul 2>&1 && set "PY=py -3" )
if not defined PY ( where python >nul 2>&1 && set "PY=python" )
if not defined PY (
  echo ERROR: Python 3 not found in PATH. Install it from https://python.org, then retry.
  exit /b 1
)

REM Parse options.
set "USERFLAG="
set "MAKEVENV="
set "WHEELS="
:parse
if "%~1"=="" goto afterparse
if /I "%~1"=="-h" goto help
if /I "%~1"=="--help" goto help
if /I "%~1"=="--user" ( set "USERFLAG=--user" & shift & goto parse )
if /I "%~1"=="--venv" ( set "MAKEVENV=1" & shift & goto parse )
if /I "%~1"=="--wheels" ( set "WHEELS=%~2" & shift & shift & goto parse )
echo ERROR: unknown option: %~1
exit /b 2
:afterparse

echo ==^> Using Python: %PY%
%PY% -c "import sys;print(sys.executable, sys.version.split()[0])"

if defined MAKEVENV (
  echo ==^> Creating virtual environment: "%~dp0.venv"
  %PY% -m venv "%~dp0.venv" || ( echo ERROR: failed to create venv. & exit /b 1 )
  set "PY=%~dp0.venv\Scripts\python.exe"
  set "USERFLAG="
)

%PY% -m ensurepip --upgrade >nul 2>&1
%PY% -m pip install --upgrade pip >nul 2>&1

echo ==^> Installing dependencies from requirements.txt ...
if defined WHEELS (
  if not exist "%WHEELS%" ( echo ERROR: wheels dir not found: %WHEELS% & exit /b 1 )
  echo     (offline: --no-index --find-links "%WHEELS%")
  %PY% -m pip install --no-index --find-links "%WHEELS%" -r "%REQ%" || ( echo ERROR: install failed. & exit /b 1 )
) else (
  %PY% -m pip install %USERFLAG% -r "%REQ%" || ( echo ERROR: install failed. & exit /b 1 )
)

echo ==^> Done.
echo ==^> Verify with:  %PY% "%~dp0check-deps.py"
if defined MAKEVENV echo ==^> Activate first:  "%~dp0.venv\Scripts\activate.bat"
exit /b 0

:help
REM Print the header block as help.
for /f "tokens=1,* delims=]" %%A in ('findstr /n "^REM" "%~f0"') do (
  set "line=%%B"
  setlocal enabledelayedexpansion
  set "line=!line:REM =!"
  set "line=!line:REM=!"
  echo(!line!
  endlocal
)
exit /b 0
