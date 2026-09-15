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

REM Resolve a WORKING Python 3. Prefer the 'py' launcher (most reliable on
REM Windows); fall back to 'python' but reject the Microsoft Store stub.
call :find_python
if not defined PY (
  echo ERROR: No working Python 3 was found.
  echo.
  echo   * If you see a Microsoft Store window when you type 'python', that is a
  echo     placeholder, NOT Python. Install real Python from https://python.org
  echo     and tick "Add python.exe to PATH" (and keep "pip" checked^).
  echo   * Then open a NEW terminal and run this script again.
  echo   * Tip: after installing, 'py --version' should print a 3.x version.
  exit /b 1
)

REM Parse options.
set "USERFLAG="
set "MAKEVENV="
set "WHEELS="
set "INDEX_URL="
:parse
if "%~1"=="" goto afterparse
if /I "%~1"=="-h" goto help
if /I "%~1"=="--help" goto help
if /I "%~1"=="--user" ( set "USERFLAG=--user" & shift & goto parse )
if /I "%~1"=="--venv" ( set "MAKEVENV=1" & shift & goto parse )
if /I "%~1"=="--wheels" (
  if "%~2"=="" ( echo ERROR: --wheels requires a directory argument. & exit /b 2 )
  set "WHEELS=%~2" & shift & shift & goto parse
)
if /I "%~1"=="--index-url" (
  if "%~2"=="" ( echo ERROR: --index-url requires a URL argument. & exit /b 2 )
  set "INDEX_URL=%~2" & shift & shift & goto parse
)
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

REM Make sure pip is available; bootstrap it if the environment lacks it.
call :ensure_pip || exit /b 1
REM Best-effort: keep pip current (ignore failures).
%PY% -m pip install --upgrade pip >nul 2>&1

echo ==^> Installing dependencies from requirements.txt ...
if defined WHEELS (
  if not exist "%WHEELS%" ( echo ERROR: wheels dir not found: %WHEELS% & exit /b 1 )
  echo     (offline: --no-index --find-links "%WHEELS%")
  %PY% -m pip install --no-index --find-links "%WHEELS%" -r "%REQ%" || ( echo ERROR: install failed. & exit /b 1 )
) else (
  if defined PIP_NO_INDEX echo ==^> WARNING: PIP_NO_INDEX is set -- pip will run OFFLINE and likely fail. Unset it or use --wheels DIR.
  if not defined INDEX_URL set "INDEX_URL=https://pypi.org/simple"
  %PY% -m pip install --index-url "%INDEX_URL%" %USERFLAG% -r "%REQ%" || ( echo ERROR: install failed. & exit /b 1 )
)

echo ==^> Done.
echo ==^> Verify with:  %PY% "%~dp0check-deps.py"
if defined MAKEVENV echo ==^> Activate first:  "%~dp0.venv\Scripts\activate.bat"
exit /b 0

:help
echo install-deps.bat - Install the Python dependencies find-subs needs (Windows).
echo.
echo Usage:
echo   install-deps.bat              pip install -r requirements.txt
echo   install-deps.bat --user       install into the user site (no admin)
echo   install-deps.bat --venv       create .venv and install into it
echo   install-deps.bat --wheels DIR OFFLINE install from a wheels folder
echo   install-deps.bat --index-url URL   use a custom package index / mirror
echo.
echo Notes:
echo   * pip is bootstrapped automatically if the machine lacks it.
echo   * If 'python' opens the Microsoft Store, install real Python from
echo     https://python.org (tick "Add to PATH"), then use a NEW terminal.
echo   * Verify afterwards with:  python check-deps.py
exit /b 0

:ensure_pip
REM Verify pip; if missing, bootstrap via ensurepip, then get-pip.py.
%PY% -m pip --version >nul 2>&1
if not errorlevel 1 ( echo ==^> pip is present. & exit /b 0 )
echo ==^> pip not found -- bootstrapping it...
%PY% -m ensurepip --upgrade
%PY% -m pip --version >nul 2>&1
if not errorlevel 1 exit /b 0
echo ==^> ensurepip unavailable -- trying get-pip.py ...
%PY% -c "import urllib.request; urllib.request.urlretrieve('https://bootstrap.pypa.io/get-pip.py', r'%TEMP%\get-pip.py')" 2>nul
%PY% "%TEMP%\get-pip.py" 2>nul
del /q "%TEMP%\get-pip.py" 2>nul
%PY% -m pip --version >nul 2>&1
if not errorlevel 1 exit /b 0
echo ERROR: could not install pip automatically.
echo        Reinstall Python from https://python.org and tick "pip" in the installer.
exit /b 1

:find_python
REM Sets PY to a launcher that actually runs Python 3. Tries py -3, then
REM python / python3, verifying each really is Python 3 (not the Store stub).
set "PY="
py -3 -c "import sys;assert sys.version_info[0]==3" >nul 2>&1
if not errorlevel 1 ( set "PY=py -3" & exit /b 0 )
python -c "import sys;assert sys.version_info[0]==3" >nul 2>&1
if not errorlevel 1 ( set "PY=python" & exit /b 0 )
python3 -c "import sys;assert sys.version_info[0]==3" >nul 2>&1
if not errorlevel 1 ( set "PY=python3" & exit /b 0 )
exit /b 0
