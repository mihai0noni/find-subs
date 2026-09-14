@echo off
REM ==========================================================================
REM  find-subs.bat - Find & download subtitles for every movie under this folder
REM                  (Windows wrapper around find-subs.sh).
REM
REM  Uses the EXACT SAME subtitle-finding logic as d3l0g3 (subliminal download +
REM  the two-tier subs-alts.py alternatives dump + Romanian diacritics strip),
REM  scanning the folder where it is deployed RECURSIVELY so movies in
REM  sub-folders are handled too. It does NOT organize/move files.
REM
REM  Usage:
REM    find-subs.bat                    scan every video under this folder
REM    find-subs.bat "D:\Movies"        scan every video under a given folder
REM    find-subs.bat "D:\Movies\a.mkv"  a single video file
REM
REM  Requirements (once):
REM    pip install -r requirements.txt   (subliminal + guessit)
REM    A bash (Git Bash or WSL) must be on PATH; this wrapper runs find-subs.sh.
REM ==========================================================================
setlocal enableextensions
cd /d "%~dp0"

REM Locate a bash interpreter (Git Bash / WSL / Cygwin).
set "BASH="
for %%B in (bash.exe) do if not defined BASH set "BASH=%%~$PATH:B"
if not defined BASH (
  echo ERROR: bash not found in PATH. Install Git for Windows or WSL, then retry.
  exit /b 1
)

REM Pass the optional target through unchanged; keep POSIX-style paths intact.
set "MSYS_NO_PATHCONV=1"
"%BASH%" "%~dp0find-subs.sh" %*
exit /b %ERRORLEVEL%
