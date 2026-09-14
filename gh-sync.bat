@echo off
REM ============================================================================
REM gh-sync.bat  --  unified push / PR+merge worker (self-contained, Windows CMD)
REM
REM Drop into ANY repo. Reads identity from the repo git config, the 'origin'
REM remote, and ~/.ssh/config (host alias -> key).
REM
REM Flows:
REM   push : commit + push straight to the base branch (default: main)
REM   pr   : commit onto a unique branch, open a PR, then ASK whether to merge.
REM
REM Flow selection:
REM   PUSH_OR_PR_PROMPT (config below, or env GH_SYNC_PUSH_OR_PR=true/false):
REM     true  -> ask on launch: 1) push  2) pr + merge
REM     false -> default = push; use --pr for the PR flow
REM   CLI overrides: --push | --pr | --ask-flow | --no-ask-flow | --no-merge
REM
REM Full guided (interactive) mode:
REM   INTERACTIVE_MODE_PROMPT (config below, or env GH_SYNC_INTERACTIVE_MODE):
REM     true  -> walk through EVERY decision in one run: choose/create the account,
REM              set up the 'origin' remote + identity, pick push vs pr+merge, ask
REM              for a PR title. A master switch that turns on all the sub-prompts.
REM     false -> only the individually-enabled prompts run (default).
REM   CLI: --interactive | --no-interactive
REM
REM Custom PR name:
REM   PR_NAME_PROMPT (config below, or env GH_SYNC_PR_NAME_PROMPT):
REM     true  -> in pr mode, ASK for a PR title; branch = feature/<slug>-<stamp>
REM     false -> default: title "update <stamp>", branch update/<stamp>
REM   CLI: --pr-name "My title" (set directly) | --ask-name | --no-ask-name
REM
REM Per-repo account memory (which GitHub / account this repo targets):
REM   Resolved once, then remembered in .git/config (ghsync.account + ghsync.webhost):
REM     1. .git/config ghsync.account (remembered)      -> use it
REM     2. origin host alias matched in accounts.conf    -> use + remember
REM     3. otherwise ask (interactive) or fall back       -> then remember
REM   CLI: --account <name> | --forget
REM
REM Choose / create account:
REM   CHOOSE_ACCOUNT_PROMPT (config below, or env GH_SYNC_CHOOSE_ACCOUNT):
REM     true  -> menu: keep current | pick another | CREATE A NEW one (appended to
REM              accounts.conf + SSH key/config set up via gh-account-setup).
REM     false -> use the already-configured/remembered account (default).
REM   CLI: --choose-account | --no-choose-account
REM
REM First-time setup (fully script-only - no manual git commands):
REM   --setup-remote : set this repo's user.name/user.email and add the 'origin'
REM                    remote from an accounts.conf entry. Auto-runs (and prompts)
REM                    when the repo has no 'origin' yet. Pick the account via
REM                    --account <name> or the prompt; repo name via --repo <name>
REM                    or the prompt (defaults to the current directory name).
REM                    NOTE: the repo must already exist on the server.
REM
REM PR backend: gh CLI -> REST API + token (GITHUB_TOKEN/GH_TOKEN or accounts.conf)
REM             -> print compare URL (open in browser)
REM
REM Usage:
REM   gh-sync.bat [--push|--pr] [--interactive|--no-interactive]
REM               [--ask-flow|--no-ask-flow] [--no-merge]
REM               [--ask-name|--no-ask-name] [--pr-name "title"]
REM               [--account <name>] [--forget]
REM               [--choose-account|--no-choose-account]
REM               [--setup-remote] [--repo <name>] [-h|--help]
REM ============================================================================
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"

REM ---- internal config (edit to taste) --------------------------------------
set "PUSH_OR_PR_PROMPT=false"
set "INTERACTIVE_MODE_PROMPT=false"
set "PR_NAME_PROMPT=false"
set "CHOOSE_ACCOUNT_PROMPT=false"
set "DEFAULT_BASE_BRANCH=main"

set "DEFAULT_REMOTE=origin"
set "COMMIT_PREFIX=update"
REM ---------------------------------------------------------------------------

if /I "%GH_SYNC_PUSH_OR_PR%"=="true"  set "PUSH_OR_PR_PROMPT=true"
if /I "%GH_SYNC_PUSH_OR_PR%"=="1"     set "PUSH_OR_PR_PROMPT=true"
if /I "%GH_SYNC_PUSH_OR_PR%"=="false" set "PUSH_OR_PR_PROMPT=false"
if /I "%GH_SYNC_PUSH_OR_PR%"=="0"     set "PUSH_OR_PR_PROMPT=false"
if /I "%GH_SYNC_INTERACTIVE_MODE%"=="true"  set "INTERACTIVE_MODE_PROMPT=true"
if /I "%GH_SYNC_INTERACTIVE_MODE%"=="1"     set "INTERACTIVE_MODE_PROMPT=true"
if /I "%GH_SYNC_INTERACTIVE_MODE%"=="false" set "INTERACTIVE_MODE_PROMPT=false"
if /I "%GH_SYNC_INTERACTIVE_MODE%"=="0"     set "INTERACTIVE_MODE_PROMPT=false"
if /I "%GH_SYNC_PR_NAME_PROMPT%"=="true"  set "PR_NAME_PROMPT=true"
if /I "%GH_SYNC_PR_NAME_PROMPT%"=="1"     set "PR_NAME_PROMPT=true"
if /I "%GH_SYNC_PR_NAME_PROMPT%"=="false" set "PR_NAME_PROMPT=false"
if /I "%GH_SYNC_PR_NAME_PROMPT%"=="0"     set "PR_NAME_PROMPT=false"
if /I "%GH_SYNC_CHOOSE_ACCOUNT%"=="true"  set "CHOOSE_ACCOUNT_PROMPT=true"
if /I "%GH_SYNC_CHOOSE_ACCOUNT%"=="1"     set "CHOOSE_ACCOUNT_PROMPT=true"
if /I "%GH_SYNC_CHOOSE_ACCOUNT%"=="false" set "CHOOSE_ACCOUNT_PROMPT=false"
if /I "%GH_SYNC_CHOOSE_ACCOUNT%"=="0"     set "CHOOSE_ACCOUNT_PROMPT=false"


set "MODE="
set "NO_MERGE=false"
set "COMMIT_MSG="
set "PR_NAME="
set "FORGET=false"
set "ACCOUNT_OVERRIDE="
set "SETUP_REMOTE=false"
set "REPO_NAME="
set "BASE_BRANCH=%DEFAULT_BASE_BRANCH%"
set "REMOTE=%DEFAULT_REMOTE%"

:parse
if "%~1"=="" goto after_parse
if /I "%~1"=="--push"            set "MODE=push" & shift & goto parse
if /I "%~1"=="--pr"              set "MODE=pr"   & shift & goto parse
if /I "%~1"=="--interactive"     set "INTERACTIVE_MODE_PROMPT=true"  & shift & goto parse
if /I "%~1"=="--no-interactive"  set "INTERACTIVE_MODE_PROMPT=false" & shift & goto parse
if /I "%~1"=="--ask-flow"        set "PUSH_OR_PR_PROMPT=true"  & shift & goto parse
if /I "%~1"=="--no-ask-flow"     set "PUSH_OR_PR_PROMPT=false" & shift & goto parse
if /I "%~1"=="--no-merge"        set "NO_MERGE=true" & shift & goto parse
if /I "%~1"=="--ask-name"        set "PR_NAME_PROMPT=true"  & shift & goto parse
if /I "%~1"=="--no-ask-name"     set "PR_NAME_PROMPT=false" & shift & goto parse
if /I "%~1"=="--pr-name"         set "PR_NAME=%~2" & shift & shift & goto parse
if /I "%~1"=="--name"            set "PR_NAME=%~2" & shift & shift & goto parse
if /I "%~1"=="-m"                set "COMMIT_MSG=%~2" & shift & shift & goto parse
if /I "%~1"=="--message"         set "COMMIT_MSG=%~2" & shift & shift & goto parse
if /I "%~1"=="--base"            set "BASE_BRANCH=%~2" & shift & shift & goto parse
if /I "%~1"=="--remote"          set "REMOTE=%~2" & shift & shift & goto parse
if /I "%~1"=="--account"         set "ACCOUNT_OVERRIDE=%~2" & shift & shift & goto parse
if /I "%~1"=="--choose-account"    set "CHOOSE_ACCOUNT_PROMPT=true"  & shift & goto parse
if /I "%~1"=="--no-choose-account" set "CHOOSE_ACCOUNT_PROMPT=false" & shift & goto parse
if /I "%~1"=="--setup-remote"    set "SETUP_REMOTE=true" & shift & goto parse
if /I "%~1"=="--repo"            set "REPO_NAME=%~2" & shift & shift & goto parse
if /I "%~1"=="--forget"          set "FORGET=true" & shift & goto parse
if /I "%~1"=="-h"                goto show_help
if /I "%~1"=="--help"            goto show_help

echo ERROR: unknown argument: %~1 & exit /b 1

:show_help
powershell -NoProfile -Command "Get-Content -LiteralPath '%~f0' | Select-Object -Skip 2 -First 62 | ForEach-Object { $_ -replace '^REM ?','' }"
exit /b 0

:after_parse

REM Full guided mode is a master switch: turn on every sub-prompt so the user is
REM walked through all scenarios (account choose/create, remote+repo setup, flow,
REM and PR name) in a single run.
if /I "%INTERACTIVE_MODE_PROMPT%"=="true" (
  set "PUSH_OR_PR_PROMPT=true"
  set "PR_NAME_PROMPT=true"
  set "CHOOSE_ACCOUNT_PROMPT=true"
  set "SETUP_REMOTE=true"
)

where git >nul 2>&1 || (echo ERROR: git is not installed / not on PATH & exit /b 1)

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
  echo ^>^> No git repo here - initialising on branch "%BASE_BRANCH%"
  git init -b "%BASE_BRANCH%" >nul
)

REM ---- optional remote bootstrap (identity + origin) from accounts.conf -------
set "CONF_FILE=%SCRIPT_DIR%accounts.conf"
REM First-run convenience: seed accounts.conf from the committed template so a
REM fresh clone works without manual copying (real accounts.conf stays ignored).
if not exist "%CONF_FILE%" if exist "%CONF_FILE%.example" (
  copy /y "%CONF_FILE%.example" "%CONF_FILE%" >nul
  echo ^>^> Created accounts.conf from accounts.conf.example - edit it ^(or run --interactive to add an account^).
)

REM ACCOUNT FIRST (guided flow): if we'll prompt anyway, resolve the account up
REM front so the remote bootstrap reuses it (asks ONCE: account -> repo -> flow).
set "ACCT_PICKED_EARLY=false"
if not defined ACCOUNT_OVERRIDE if exist "%CONF_FILE%" (
  set "DO_EARLY=false"
  if /I "%CHOOSE_ACCOUNT_PROMPT%"=="true" set "DO_EARLY=true"
  if /I "%SETUP_REMOTE%"=="true" if /I "%PUSH_OR_PR_PROMPT%"=="true" set "DO_EARLY=true"
  if /I "!DO_EARLY!"=="true" (
    call :pick_account_early
    set "ACCT_PICKED_EARLY=true"
  )
)

git remote get-url "%REMOTE%" >nul 2>&1
if errorlevel 1 (
  call :setup_remote
) else (
  if /I "%SETUP_REMOTE%"=="true" call :setup_remote
)

if not defined MODE (
  if /I "%PUSH_OR_PR_PROMPT%"=="true" (
    echo How do you want to sync?
    echo   1^) push       - commit and push straight to '%BASE_BRANCH%'
    echo   2^) pr + merge - commit to a new branch, open a PR, then ask to merge
    set /p "choice=Choose [1/2]: "
    if "!choice!"=="2" ( set "MODE=pr" ) else ( set "MODE=push" )
  ) else (
    set "MODE=push"
  )
)
echo ^>^> Run mode: %MODE%

REM ---- locale-independent timestamp (YYYYMMDD-HHMMSS) ------------------------
for /f "usebackq delims=" %%s in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"`) do set "STAMP=%%s"
if not defined STAMP (
  REM fallback if PowerShell is unavailable (locale-dependent, best effort)
  for /f "tokens=1-6 delims=/:.- " %%a in ("%date% %time%") do set "STAMP=%%c%%b%%a-%%d%%e%%f"
  set "STAMP=!STAMP: =0!"
)

REM ---- commit ----------------------------------------------------------------
REM Safety: never publish accounts.conf. It only lives in the working tree when
REM the repo being synced IS this toolkit dir; self-heal a .gitignore entry then.
call :ignore_conf
git add -A
git diff --cached --quiet
if errorlevel 1 (
  if defined COMMIT_MSG ( set "MSG=!COMMIT_MSG!" ) else ( set "MSG=%COMMIT_PREFIX% !STAMP!" )
  git commit -m "!MSG!" >nul
  echo ^>^> Committed: !MSG!
  set "HAVE_NEW_COMMIT=true"
) else (
  echo ^>^> Nothing new to commit
  set "HAVE_NEW_COMMIT=false"
)

git remote get-url "%REMOTE%" >nul 2>&1
if errorlevel 1 (
  echo ERROR: no '%REMOTE%' remote. Add one first:
  echo        git remote add %REMOTE% git@^<host-alias^>:^<user^>/^<repo^>.git
  exit /b 1
)
for /f "delims=" %%u in ('git remote get-url "%REMOTE%"') do set "REMOTE_URL=%%u"
echo ^>^> Remote '%REMOTE%' -^> !REMOTE_URL!


REM ---- parse OWNER/REPO/HOST from a git@ALIAS:OWNER/REPO.git remote ----------
set "HOST_ALIAS="
set "OWNER="
set "REPO="
set "RP=!REMOTE_URL!"
echo !RP! | findstr /b "git@" >nul
if not errorlevel 1 (
  for /f "tokens=1,2 delims=:" %%h in ("!RP:git@=!") do (
    set "HOST_ALIAS=%%h"
    set "RP=%%i"
  )
  if "!RP:~-4!"==".git" set "RP=!RP:~0,-4!"
  for /f "tokens=1,2 delims=/" %%o in ("!RP!") do ( set "OWNER=%%o" & set "REPO=%%p" )
)
set "WEB_HOST=!HOST_ALIAS!"
echo !HOST_ALIAS! | findstr /b "github.com" >nul
if not errorlevel 1 set "WEB_HOST=github.com"

REM ===========================================================================
REM PER-REPO ACCOUNT MEMORY
REM Resolve which accounts.conf entry this repo uses, remember it in .git/config.
REM ===========================================================================
set "CONF_FILE=%SCRIPT_DIR%accounts.conf"

if /I "%FORGET%"=="true" (
  git config --local --remove-section ghsync >nul 2>&1
  echo ^>^> Forgot remembered account settings for this repo.
)

set "ACCOUNT_NAME="
set "ACCOUNT_TOKEN="
for /f "delims=" %%a in ('git config --local --get ghsync.account 2^>nul') do set "ACCOUNT_NAME=%%a"
if defined ACCOUNT_OVERRIDE set "ACCOUNT_NAME=%ACCOUNT_OVERRIDE%"

REM auto-match origin alias -> account NAME (only when nothing chosen yet)
if not defined ACCOUNT_NAME if exist "%CONF_FILE%" if defined HOST_ALIAS call :match_alias

REM choose/create account menu (keep | pick another | create new)
REM  ... unless we already resolved the account up front (guided "account first")
if /I not "%ACCT_PICKED_EARLY%"=="true" if /I "%CHOOSE_ACCOUNT_PROMPT%"=="true" if exist "%CONF_FILE%" call :choose_account

REM still unknown + interactive -> ask (list accounts first)
if not defined ACCOUNT_NAME if /I "%PUSH_OR_PR_PROMPT%"=="true" if exist "%CONF_FILE%" call :ask_account


REM resolve token for the chosen account + remember choice
if defined ACCOUNT_NAME if exist "%CONF_FILE%" call :resolve_account
goto after_account_memory

:ignore_conf
REM If accounts.conf sits inside the current repo's working tree, ensure it is
REM git-ignored (and not tracked) so it never gets published. No-op otherwise.
if not exist "%CONF_FILE%" exit /b 0
set "REPO_ROOT="
for /f "delims=" %%r in ('git rev-parse --show-toplevel 2^>nul') do set "REPO_ROOT=%%r"
if not defined REPO_ROOT exit /b 0
REM ask git (from the conf's own dir) whether it lives inside THIS repo, and where
set "CONF_DIR=%SCRIPT_DIR%"
set "CONF_TOP="
set "CONF_PREFIX="
pushd "%CONF_DIR%" >nul 2>&1 || exit /b 0
for /f "delims=" %%t in ('git rev-parse --show-toplevel 2^>nul') do set "CONF_TOP=%%t"
for /f "delims=" %%p in ('git rev-parse --show-prefix 2^>nul') do set "CONF_PREFIX=%%p"
popd >nul 2>&1
if not defined CONF_TOP exit /b 0
if /I not "%CONF_TOP%"=="%REPO_ROOT%" exit /b 0
REM REL = <prefix>accounts.conf  (prefix already uses git's forward slashes)
set "REL=%CONF_PREFIX%accounts.conf"
set "GI=%REPO_ROOT%\.gitignore"
set "HAVE_LINE="
if exist "%GI%" for /f "usebackq delims=" %%l in ("%GI%") do if /I "%%l"=="%REL%" set "HAVE_LINE=1"
if not defined HAVE_LINE (
  >>"%GI%" echo %REL%
  echo ^>^> Added '%REL%' to .gitignore ^(won't be committed^)
)
git rm --cached --quiet "%REL%" >nul 2>&1
exit /b 0


:setup_remote
REM Bootstrap identity + 'origin' from an accounts.conf entry (script-only setup)
if not exist "%CONF_FILE%" (
  echo WARNING: no accounts.conf found - cannot bootstrap a remote automatically
  exit /b 0
)
set "BS_ACCT=%ACCOUNT_OVERRIDE%"
if not defined BS_ACCT (
  echo Set up the '%REMOTE%' remote for this repo. Available accounts:
  for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do call :list_menu_line "%%k" "%%l"
  set /p "BS_ACCT=Which account? (name, blank to skip remote setup): "
)
if not defined BS_ACCT exit /b 0
REM strip a single trailing space (common when piped / typed by accident)
if "!BS_ACCT:~-1!"==" " set "BS_ACCT=!BS_ACCT:~0,-1!"
REM find index whose NAME matches BS_ACCT
set "BS_IDX="
for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do call :bs_find_name "%%k" "%%l"
if not defined BS_IDX (
  echo ERROR: account '!BS_ACCT!' not found in accounts.conf
  exit /b 1
)
set "BS_ALIAS="
set "BS_USER="
set "BS_EMAIL="
for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do (
  if /I "%%k"=="ACCOUNT_!BS_IDX!_ALIAS" set "BS_ALIAS=%%l"
  if /I "%%k"=="ACCOUNT_!BS_IDX!_USER"  set "BS_USER=%%l"
  if /I "%%k"=="ACCOUNT_!BS_IDX!_EMAIL" set "BS_EMAIL=%%l"
)
REM repo name: --repo, else prompt (default = current directory name)
if not defined REPO_NAME (
  for %%d in ("%CD%") do set "DEF_REPO=%%~nxd"
  set /p "REPO_NAME=Repository name on the server [!DEF_REPO!]: "
  if not defined REPO_NAME set "REPO_NAME=!DEF_REPO!"
)
REM set per-repo identity only if not already set
set "CUR_UNAME="
for /f "delims=" %%a in ('git config --local --get user.name 2^>nul') do set "CUR_UNAME=%%a"
if not defined CUR_UNAME if defined BS_USER (
  git config --local user.name "!BS_USER!"
  echo ^>^> Set local user.name = !BS_USER!
)
set "CUR_UEMAIL="
for /f "delims=" %%a in ('git config --local --get user.email 2^>nul') do set "CUR_UEMAIL=%%a"
if not defined CUR_UEMAIL if defined BS_EMAIL (
  git config --local user.email "!BS_EMAIL!"
  echo ^>^> Set local user.email = !BS_EMAIL!
)
set "BS_URL=git@!BS_ALIAS!:!BS_USER!/!REPO_NAME!.git"
git remote get-url "%REMOTE%" >nul 2>&1
if errorlevel 1 (
  git remote add "%REMOTE%" "!BS_URL!"
  echo ^>^> Added remote '%REMOTE%' -^> !BS_URL!
) else (
  git remote set-url "%REMOTE%" "!BS_URL!"
  echo ^>^> Updated remote '%REMOTE%' -^> !BS_URL!
)
set "ACCOUNT_OVERRIDE=!BS_ACCT!"
echo NOTE: the repo '!BS_USER!/!REPO_NAME!' must already exist on the server
echo       ^(a push cannot create it^). Create it first if you haven't.
exit /b 0

:bs_find_name
echo %~1| findstr /r "^ACCOUNT_[0-9]*_NAME$" >nul || exit /b 0
if /I not "%~2"=="!BS_ACCT!" exit /b 0
set "KK=%~1"
set "IDX=!KK:ACCOUNT_=!"
set "IDX=!IDX:_NAME=!"
set "BS_IDX=!IDX!"
exit /b 0

:pick_account_early
REM Guided "account first" menu: numbered list + create-new; sets ACCOUNT_OVERRIDE.
echo Choose the GitHub account for this repo:
for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do call :list_menu_line "%%k" "%%l"
echo   n^) create a NEW account
set "PICK="
set /p "PICK=Pick a number, or 'n' for new: "
if not defined PICK exit /b 0
if /I "!PICK!"=="n" ( call :create_account & set "ACCOUNT_OVERRIDE=!ACCOUNT_NAME!" & exit /b 0 )
if /I "!PICK!"=="new" ( call :create_account & set "ACCOUNT_OVERRIDE=!ACCOUNT_NAME!" & exit /b 0 )
set "PICK_NAME="
for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do if /I "%%k"=="ACCOUNT_!PICK!_NAME" set "PICK_NAME=%%l"
if defined PICK_NAME (
  set "ACCOUNT_OVERRIDE=!PICK_NAME!"
) else (
  echo WARNING: no account #!PICK! - skipping account setup
)
exit /b 0


:match_alias
set "MATCH_IDX="
for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do call :match_alias_line "%%k" "%%l"
if defined MATCH_IDX (
  for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do if /I "%%k"=="ACCOUNT_!MATCH_IDX!_NAME" set "ACCOUNT_NAME=%%l"
  if defined ACCOUNT_NAME echo ^>^> Matched origin host '!HOST_ALIAS!' to account '!ACCOUNT_NAME!' ^(accounts.conf^)
)
exit /b 0

:match_alias_line
echo %~1| findstr /r "^ACCOUNT_[0-9]*_ALIAS$" >nul || exit /b 0
if /I not "%~2"=="!HOST_ALIAS!" exit /b 0
set "KK=%~1"
set "IDX=!KK:ACCOUNT_=!"
set "IDX=!IDX:_ALIAS=!"
set "MATCH_IDX=!IDX!"
exit /b 0

:ask_account
echo Which account does this repo use? ^(from accounts.conf^)
for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do call :list_account_line "%%k" "%%l"
set /p "ACCOUNT_NAME=Account name (blank = none / use env token): "
exit /b 0

:list_account_line
echo %~1| findstr /r "^ACCOUNT_[0-9]*_NAME$" >nul || exit /b 0
echo   - %~2
exit /b 0

:resolve_account
set "FOUND_IDX="
for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do call :find_name_line "%%k" "%%l"
if defined FOUND_IDX (
  for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do if /I "%%k"=="ACCOUNT_!FOUND_IDX!_TOKEN" set "ACCOUNT_TOKEN=%%l"
  git config --local ghsync.account "!ACCOUNT_NAME!" >nul 2>&1
  git config --local ghsync.webhost "!WEB_HOST!" >nul 2>&1
  echo ^>^> Using account '!ACCOUNT_NAME!' ^(remembered in .git/config^)
) else (
  echo WARNING: account '!ACCOUNT_NAME!' not found in accounts.conf - ignoring
  set "ACCOUNT_NAME="
)
exit /b 0

:find_name_line
echo %~1| findstr /r "^ACCOUNT_[0-9]*_NAME$" >nul || exit /b 0
if /I not "%~2"=="!ACCOUNT_NAME!" exit /b 0
set "KK=%~1"
set "IDX=!KK:ACCOUNT_=!"
set "IDX=!IDX:_NAME=!"
set "FOUND_IDX=!IDX!"
exit /b 0

:choose_account
echo Choose the GitHub account for this project:
if defined ACCOUNT_NAME echo   0^) keep current: '!ACCOUNT_NAME!'
for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do call :list_menu_line "%%k" "%%l"
echo   n^) create a NEW account
set "PICK="
set /p "PICK=Pick a number, 'n' for new (0 = keep): "
if not defined PICK exit /b 0
if "!PICK!"=="0" exit /b 0
if /I "!PICK!"=="n" ( call :create_account & exit /b 0 )
if /I "!PICK!"=="new" ( call :create_account & exit /b 0 )
REM numeric pick -> resolve NAME for that index
set "PICK_NAME="
for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do if /I "%%k"=="ACCOUNT_!PICK!_NAME" set "PICK_NAME=%%l"
if defined PICK_NAME (
  set "ACCOUNT_NAME=!PICK_NAME!"
) else (
  echo WARNING: no account #!PICK! - keeping '!ACCOUNT_NAME!'
)
exit /b 0

:list_menu_line
echo %~1| findstr /r "^ACCOUNT_[0-9]*_NAME$" >nul || exit /b 0
set "KK=%~1"
set "MI=!KK:ACCOUNT_=!"
set "MI=!MI:_NAME=!"
echo   !MI!^) %~2
exit /b 0

:create_account
set "NEW_NAME="
set /p "NEW_NAME=New account friendly name: "
if not defined NEW_NAME exit /b 0
set "NEW_HOST="
set /p "NEW_HOST=GitHub hostname [github.com]: "
if not defined NEW_HOST set "NEW_HOST=github.com"
set "NEW_USER="
set /p "NEW_USER=GitHub username (owner): "
set "ALIAS_DEF=!NEW_NAME!"
if defined NEW_USER set "ALIAS_DEF=!NEW_USER!"
set "NEW_ALIAS="
set /p "NEW_ALIAS=SSH host alias [!NEW_HOST!-!ALIAS_DEF!]: "
if not defined NEW_ALIAS set "NEW_ALIAS=!NEW_HOST!-!ALIAS_DEF!"
set "NEW_EMAIL="
set /p "NEW_EMAIL=Commit email [!NEW_USER!@users.noreply.github.com]: "
if not defined NEW_EMAIL set "NEW_EMAIL=!NEW_USER!@users.noreply.github.com"
set "NEW_KEY="
set /p "NEW_KEY=Private key path [~/.ssh/id_ed25519_!NEW_NAME!]: "
if not defined NEW_KEY set "NEW_KEY=~/.ssh/id_ed25519_!NEW_NAME!"

REM find next free index (max existing NAME index + 1)
set "MAXIDX=0"
for /f "usebackq tokens=1,2 delims== " %%k in ("%CONF_FILE%") do call :track_maxidx "%%k"
set /a NEWIDX=MAXIDX+1

>>"%CONF_FILE%" echo.
>>"%CONF_FILE%" echo # ---- account !NEWIDX!: !NEW_NAME! (added by gh-sync --choose-account) ----
>>"%CONF_FILE%" echo ACCOUNT_!NEWIDX!_NAME=!NEW_NAME!
>>"%CONF_FILE%" echo ACCOUNT_!NEWIDX!_ALIAS=!NEW_ALIAS!
>>"%CONF_FILE%" echo ACCOUNT_!NEWIDX!_HOSTNAME=!NEW_HOST!
>>"%CONF_FILE%" echo ACCOUNT_!NEWIDX!_KEY=!NEW_KEY!
>>"%CONF_FILE%" echo ACCOUNT_!NEWIDX!_USER=!NEW_USER!
>>"%CONF_FILE%" echo ACCOUNT_!NEWIDX!_EMAIL=!NEW_EMAIL!
echo ^>^> Added account '!NEW_NAME!' to accounts.conf ^(index !NEWIDX!^).

REM set up SSH identity for the new account via the sibling script
if exist "%SCRIPT_DIR%gh-account-setup.bat" (
  echo ^>^> Setting up SSH identity for '!NEW_NAME!' ...
  call "%SCRIPT_DIR%gh-account-setup.bat" --account "!NEW_NAME!"
) else (
  echo WARNING: gh-account-setup.bat not found next to gh-sync - set up the key manually.
)
set "ACCOUNT_NAME=!NEW_NAME!"
exit /b 0

:track_maxidx
echo %~1| findstr /r "^ACCOUNT_[0-9]*_NAME$" >nul || exit /b 0
set "KK=%~1"
set "TI=!KK:ACCOUNT_=!"
set "TI=!TI:_NAME=!"
if !TI! GTR !MAXIDX! set "MAXIDX=!TI!"
exit /b 0

:after_account_memory

REM ---- optional SSH auth sanity (git@ alias remotes) -------------------------
echo !REMOTE_URL! | findstr /b "git@" >nul
if not errorlevel 1 (
  echo ^>^> Checking SSH auth to !HOST_ALIAS! ...
  ssh -T "git@!HOST_ALIAS!" 2>&1
)

if /I "%MODE%"=="push" goto do_push
goto do_pr

REM ============================================================================
:do_push
for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD') do set "CUR_BRANCH=%%b"
if "!CUR_BRANCH!"=="HEAD" set "CUR_BRANCH=%BASE_BRANCH%"
echo ^>^> Pushing '!CUR_BRANCH!' to %REMOTE% ...
git push -u "%REMOTE%" "!CUR_BRANCH!"
if errorlevel 1 (
  echo ERROR: push failed - does the repo exist on the server? create it, then re-run.
  exit /b 1
)
if defined OWNER if defined REPO echo ^>^> Done. https://!WEB_HOST!/!OWNER!/!REPO!
goto end

REM ============================================================================
:do_pr
REM ---- first-push guard: a PR needs a base branch to target. On a brand-new /
REM empty repo the base branch does not exist on the remote yet, so fall back to
REM a plain push to the base branch (which creates it). Next runs use the PR flow.
git ls-remote --exit-code --heads "%REMOTE%" "%BASE_BRANCH%" >nul 2>&1
if errorlevel 1 (
  echo ^>^> WARNING: Base branch '%BASE_BRANCH%' does not exist on '%REMOTE%' yet ^(new/empty repo^).
  echo ^>^> A PR needs a base to target - pushing the first commit straight to '%BASE_BRANCH%' instead.
  REM Push current HEAD to the remote base ref; HEAD:<base> works regardless of the
  REM local branch name and never fails on "a branch named '<base>' already exists".
  echo ^>^> Pushing HEAD to '%REMOTE%/%BASE_BRANCH%' ...
  git push -u "%REMOTE%" "HEAD:refs/heads/%BASE_BRANCH%"
  if errorlevel 1 (
    echo ERROR: push failed - does the repo exist on the server? create it, then re-run.
    exit /b 1
  )
  if defined OWNER if defined REPO echo ^>^> Done. Base branch '%BASE_BRANCH%' created. https://!WEB_HOST!/!OWNER!/!REPO!
  echo ^>^> Re-run with --pr next time to open pull requests against '%BASE_BRANCH%'.
  goto end
)

REM ---- custom PR name: ask if enabled and not provided via --pr-name ---------
if not defined PR_NAME if /I "%PR_NAME_PROMPT%"=="true" (
  set /p "PR_NAME=PR title? (blank = default 'update !STAMP!'): "
)

if defined PR_NAME (
  REM slugify via PowerShell (env var avoids CMD caret/quote issues)
  set "GHSYNC_RAWNAME=!PR_NAME!"
  for /f "usebackq delims=" %%s in (`powershell -NoProfile -Command "$s=$env:GHSYNC_RAWNAME.ToLower(); $s=[regex]::Replace($s,'[^a-z0-9]+','-'); $s=$s.Trim('-'); if([string]::IsNullOrEmpty($s)){'pr'}else{$s}"`) do set "SLUG=%%s"
  if not defined SLUG set "SLUG=pr"
  set "PR_BRANCH=feature/!SLUG!-!STAMP!"
  set "PR_TITLE=!PR_NAME!"
) else (
  set "PR_BRANCH=%COMMIT_PREFIX%/!STAMP!"
  set "PR_TITLE=%COMMIT_PREFIX% !STAMP!"
)
echo ^>^> Creating PR branch: !PR_BRANCH! (base: %BASE_BRANCH%)
REM Always cut the PR branch from the *base* branch tip, not from whatever branch we
REM happen to be on (e.g. a leftover update/<stamp> from an unmerged previous run).
git fetch -q "%REMOTE%" "%BASE_BRANCH%" 2>nul
for /f "delims=" %%h in ('git rev-parse HEAD 2^>nul') do set "NEW_HEAD=%%h"
set "BASE_REF="
git rev-parse --verify -q "%REMOTE%/%BASE_BRANCH%" >nul 2>&1
if not errorlevel 1 (
  set "BASE_REF=%REMOTE%/%BASE_BRANCH%"
) else (
  git rev-parse --verify -q "%BASE_BRANCH%" >nul 2>&1
  if not errorlevel 1 set "BASE_REF=%BASE_BRANCH%"
)
if defined BASE_REF (
  git switch -C "!PR_BRANCH!" "!BASE_REF!" 2>nul || git checkout -B "!PR_BRANCH!" "!BASE_REF!"
  if /I "!HAVE_NEW_COMMIT!"=="true" if defined NEW_HEAD (
    git cherry-pick "!NEW_HEAD!" >nul 2>&1
    if errorlevel 1 (
      echo ^>^> WARNING: cherry-pick onto %BASE_BRANCH% failed - falling back to current HEAD
      git switch -C "!PR_BRANCH!" "!NEW_HEAD!" 2>nul || git checkout -B "!PR_BRANCH!" "!NEW_HEAD!"
    )
  )
) else (
  git switch -c "!PR_BRANCH!" 2>nul || git checkout -b "!PR_BRANCH!"
)
echo ^>^> Pushing branch '!PR_BRANCH!' to %REMOTE% ...
git push -u "%REMOTE%" "!PR_BRANCH!"
if errorlevel 1 ( echo ERROR: failed to push PR branch & exit /b 1 )

set "PR_BODY=Automated update generated on !STAMP! by gh-sync."
set "COMPARE_URL=https://!WEB_HOST!/!OWNER!/!REPO!/compare/%BASE_BRANCH%...!PR_BRANCH!?expand=1"

REM token order: per-account (accounts.conf ACCOUNT_N_TOKEN) > env > global conf
set "TOKEN=!ACCOUNT_TOKEN!"
if not defined TOKEN set "TOKEN=%GITHUB_TOKEN%"
if not defined TOKEN set "TOKEN=%GH_TOKEN%"
if not defined TOKEN if exist "%CONF_FILE%" (
  for /f "tokens=2 delims==" %%t in ('findstr /b /r "[ ]*GITHUB_TOKEN=" "%CONF_FILE%"') do set "TOKEN=%%t"
)

set "PR_URL="
set "PR_NUMBER="

where gh >nul 2>&1
if not errorlevel 1 (
  gh auth status >nul 2>&1
  if not errorlevel 1 (
    echo ^>^> Opening PR via gh CLI ...
    for /f "delims=" %%p in ('gh pr create --base "%BASE_BRANCH%" --head "!PR_BRANCH!" --title "!PR_TITLE!" --body "!PR_BODY!" 2^>nul') do set "PR_URL=%%p"
    for /f "delims=" %%n in ('gh pr view "!PR_BRANCH!" --json number -q .number 2^>nul') do set "PR_NUMBER=%%n"
  )
)

set "PR_TOKEN_REASON="
if not defined PR_URL if defined TOKEN (
  where curl >nul 2>&1
  if errorlevel 1 (
    set "PR_TOKEN_REASON=curl is not installed / not on PATH"
  ) else (
    set "API_BASE=https://api.github.com"
    if /I not "!WEB_HOST!"=="github.com" set "API_BASE=https://!WEB_HOST!/api/v3"
    echo ^>^> Opening PR via REST API + token ...
    for /f "delims=" %%h in ('curl -sS -o "%TEMP%\ghpr.json" -w "%%{http_code}" -X POST -H "Authorization: token !TOKEN!" -H "Accept: application/vnd.github+json" "!API_BASE!/repos/!OWNER!/!REPO!/pulls" -d "{\"title\":\"!PR_TITLE!\",\"head\":\"!PR_BRANCH!\",\"base\":\"%BASE_BRANCH%\",\"body\":\"!PR_BODY!\"}" 2^>nul') do set "PR_HTTP=%%h"
    for /f "tokens=2 delims=:,"  %%u in ('findstr /c:"\"html_url\"" "%TEMP%\ghpr.json"') do if not defined PR_URL set "PR_URL=%%~u"
    for /f "tokens=2 delims=:,"  %%u in ('findstr /c:"\"number\""   "%TEMP%\ghpr.json"') do if not defined PR_NUMBER set "PR_NUMBER=%%~u"
    if not defined PR_URL (
      if "!PR_HTTP!"=="403" set "PR_TOKEN_REASON=token rejected (HTTP 403) - token likely lacks 'Pull requests: Read and write' (fine-grained) or 'repo' scope (classic) for !OWNER!/!REPO!."
      if "!PR_HTTP!"=="401" set "PR_TOKEN_REASON=token invalid or expired (HTTP 401)."
      if "!PR_HTTP!"=="404" set "PR_TOKEN_REASON=not found (HTTP 404) - check the token can access !OWNER!/!REPO! and that the branch was pushed."
      if "!PR_HTTP!"=="422" set "PR_TOKEN_REASON=GitHub rejected the PR (HTTP 422) - branch may have no diff vs %BASE_BRANCH%, or a PR already exists."
      if not defined PR_TOKEN_REASON set "PR_TOKEN_REASON=GitHub API error (HTTP !PR_HTTP!)."
    )
    del "%TEMP%\ghpr.json" 2>nul
  )
) else (
  if not defined PR_URL set "PR_TOKEN_REASON=no token (accounts.conf ACCOUNT_N_TOKEN / GITHUB_TOKEN, or env GITHUB_TOKEN/GH_TOKEN)"
)

if not defined PR_URL (
  echo.
  echo -----------------------------------------------------------------------
  echo  Could not auto-create the PR automatically.
  where gh >nul 2>&1
  if errorlevel 1 (
    echo  gh CLI: not installed or not authenticated.
  ) else (
    gh auth status >nul 2>&1
    if errorlevel 1 ( echo  gh CLI: not installed or not authenticated. ) else ( echo  gh CLI: authenticated but PR creation via gh failed. )
  )
  if defined PR_TOKEN_REASON ( echo  Token:  !PR_TOKEN_REASON! ) else ( echo  Token:  unavailable )
  echo  Open the PR in your browser instead:
  echo    !COMPARE_URL!
  echo -----------------------------------------------------------------------
  goto end
)
echo ^>^> PR created: !PR_URL!

if /I "%NO_MERGE%"=="true" (
  echo ^>^> --no-merge set - leaving PR open: !PR_URL!
  goto end
)
echo.
set /p "ans=Merge PR #!PR_NUMBER! into '%BASE_BRANCH%' now? [y/N] "
if /I "!ans:~0,1!"=="y" (
  where gh >nul 2>&1
  if not errorlevel 1 (
    gh auth status >nul 2>&1
    if not errorlevel 1 (
      echo ^>^> Merging via gh ...
      gh pr merge "!PR_NUMBER!" --merge --delete-branch
      if not errorlevel 1 echo ^>^> Merged into %BASE_BRANCH%.
      call :return_to_base
      goto end
    )
  )
  if defined TOKEN if defined PR_NUMBER (
    set "API_BASE=https://api.github.com"
    if /I not "!WEB_HOST!"=="github.com" set "API_BASE=https://!WEB_HOST!/api/v3"
    echo ^>^> Merging via REST API ...
    curl -sS -X PUT -H "Authorization: token !TOKEN!" -H "Accept: application/vnd.github+json" "!API_BASE!/repos/!OWNER!/!REPO!/pulls/!PR_NUMBER!/merge" -d "{\"merge_method\":\"merge\"}" >nul
    if not errorlevel 1 (
      echo ^>^> Merged into %BASE_BRANCH%.
      call :return_to_base
    )
  ) else (
    echo WARNING: no way to merge automatically - do it in the browser: !PR_URL!
  )
) else (
  echo ^>^> Left PR open: !PR_URL!
)

goto end

REM ---- after a successful merge, bring local checkout back to the base branch,
REM fast-forward it, and delete the merged feature branch. Without this the local
REM repo stays on the orphaned update/<stamp> branch for later runs/commits.
:return_to_base
echo ^>^> Returning local checkout to '%BASE_BRANCH%' ...
git switch "%BASE_BRANCH%" 2>nul || git checkout "%BASE_BRANCH%" 2>nul
if errorlevel 1 (
  echo WARNING: could not switch to '%BASE_BRANCH%' locally - you are still on '!PR_BRANCH!'
  goto :eof
)
git pull --ff-only "%REMOTE%" "%BASE_BRANCH%" 2>nul
git branch -d "!PR_BRANCH!" 2>nul
if errorlevel 1 (
  echo WARNING: kept local branch '!PR_BRANCH!' ^(not fully merged locally^).
) else (
  echo ^>^> Deleted local branch '!PR_BRANCH!'.
)
goto :eof

:end
endlocal
