#!/usr/bin/env bash
# =============================================================================
# gh-sync.sh  --  unified "get my changes onto GitHub" worker (self-contained)
#
# Drop into ANY repo and run it - needs no other file. Reads identity from the
# repo's git config, the 'origin' remote, and ~/.ssh/config (alias -> key).
#
# Flows:
#   push : commit + push straight to the base branch (default: main)
#   pr   : commit onto a unique branch, open a PR, then ASK whether to merge.
#
# Flow selection:
#   PUSH_OR_PR_PROMPT (config below, or env GH_SYNC_PUSH_OR_PR):
#     true  -> ask on launch: 1) push  2) pr + merge
#     false -> default = push; use --pr for PR flow
#   CLI overrides: --push | --pr | --ask-flow | --no-ask-flow
#
# Full guided (interactive) mode:
#   INTERACTIVE_MODE_PROMPT (config below, or env GH_SYNC_INTERACTIVE_MODE):
#     true  -> walk through EVERY decision in one run: choose/create the account,
#              set up the 'origin' remote + identity (repo name etc.), pick push
#              vs pr+merge, ask for a PR title. A master switch that turns on all
#              the sub-prompts below.
#     false -> only the individually-enabled prompts run (default).
#   CLI: --interactive | --no-interactive
#
# Custom PR name:
#   PR_NAME_PROMPT (config below, or env GH_SYNC_PR_NAME_PROMPT):
#     true  -> in pr mode, ASK for a PR title; branch = feature/<slug>-<stamp>
#     false -> default: title "update <stamp>", branch update/<stamp>
#   CLI: --pr-name "My title"  (set directly) | --ask-name | --no-ask-name
#
# Per-repo account memory (which GitHub / account this repo targets):
#   Resolved once, then remembered in .git/config (ghsync.account + ghsync.webhost):
#     1. .git/config ghsync.account   (remembered)   -> use it
#     2. origin host alias matched in accounts.conf   -> use + remember
#     3. otherwise ask (interactive) or fall back      -> then remember
#
# Choose / create account:
#   CHOOSE_ACCOUNT_PROMPT (config below, or env GH_SYNC_CHOOSE_ACCOUNT):
#     true  -> always show a menu: keep current | pick another | CREATE A NEW one
#              (a new account is appended to accounts.conf and its SSH key/config
#               is set up via gh-account-setup). The pick is then remembered.
#     false -> use the already-configured/remembered account (default).
#   CLI: --choose-account | --no-choose-account
#
# First-time setup (make it fully script-only - no manual git commands):
#   --setup-remote : set this repo's user.name/user.email and add the 'origin'
#                    remote from an accounts.conf entry. Auto-runs (and prompts)
#                    when the repo has no 'origin' yet. Pick the account via
#                    --account <name> or the prompt; repo name via --repo <name>
#                    or the prompt (defaults to the current directory name).
#                    NOTE: the repo must already exist on the server (a push
#                    cannot create it).
#
# PR backend (auto): 1. gh CLI  2. REST API + token  3. print compare URL
#
# Usage:
#   ./gh-sync.sh [--push|--pr] [--interactive|--no-interactive]
#                [--ask-flow|--no-ask-flow] [--no-merge]
#                [--ask-name|--no-ask-name] [--pr-name "title"]
#                [--account <name>] [--forget]
#                [--choose-account|--no-choose-account]
#                [--setup-remote] [--repo <name>]
# =============================================================================
set -euo pipefail

# ---- internal config (edit to taste) ---------------------------------------
INTERACTIVE_MODE_PROMPT=true  # true = full guided flow (all prompts below)
PUSH_OR_PR_PROMPT=false        # true = ask "push or pr+merge?" on launch

PR_NAME_PROMPT=false           # true = ask for a custom PR title in pr mode
CHOOSE_ACCOUNT_PROMPT=false    # true = menu to keep/pick/create the account
DEFAULT_BASE_BRANCH=main
DEFAULT_REMOTE=origin
COMMIT_PREFIX="update"        # commit msg + default branch prefix in pr mode
# ----------------------------------------------------------------------------

info() { echo ">> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

case "${GH_SYNC_PUSH_OR_PR:-}" in
  [tT]rue|1|[yY]es) PUSH_OR_PR_PROMPT=true ;;
  [fF]alse|0|[nN]o) PUSH_OR_PR_PROMPT=false ;;
esac
case "${GH_SYNC_INTERACTIVE_MODE:-}" in
  [tT]rue|1|[yY]es) INTERACTIVE_MODE_PROMPT=true ;;
  [fF]alse|0|[nN]o) INTERACTIVE_MODE_PROMPT=false ;;
esac
case "${GH_SYNC_PR_NAME_PROMPT:-}" in
  [tT]rue|1|[yY]es) PR_NAME_PROMPT=true ;;
  [fF]alse|0|[nN]o) PR_NAME_PROMPT=false ;;
esac
case "${GH_SYNC_CHOOSE_ACCOUNT:-}" in
  [tT]rue|1|[yY]es) CHOOSE_ACCOUNT_PROMPT=true ;;
  [fF]alse|0|[nN]o) CHOOSE_ACCOUNT_PROMPT=false ;;
esac


MODE=""; NO_MERGE=false; COMMIT_MSG=""; PR_NAME=""; FORGET=false; ACCOUNT_OVERRIDE=""
SETUP_REMOTE=false; REPO_NAME=""
BASE_BRANCH="$DEFAULT_BASE_BRANCH"; REMOTE="$DEFAULT_REMOTE"
while [ $# -gt 0 ]; do
  case "$1" in
    --push)           MODE=push ;;
    --pr)             MODE=pr ;;
    --interactive)    INTERACTIVE_MODE_PROMPT=true ;;
    --no-interactive) INTERACTIVE_MODE_PROMPT=false ;;
    --ask-flow)       PUSH_OR_PR_PROMPT=true ;;
    --no-ask-flow)    PUSH_OR_PR_PROMPT=false ;;
    --no-merge)       NO_MERGE=true ;;
    --ask-name)       PR_NAME_PROMPT=true ;;
    --no-ask-name)    PR_NAME_PROMPT=false ;;
    --pr-name|--name) PR_NAME="${2:-}"; shift ;;
    --choose-account)    CHOOSE_ACCOUNT_PROMPT=true ;;
    --no-choose-account) CHOOSE_ACCOUNT_PROMPT=false ;;
    --setup-remote)   SETUP_REMOTE=true ;;
    --repo)           REPO_NAME="${2:-}"; shift ;;
    -m|--message)     COMMIT_MSG="${2:-}"; shift ;;

    --base)           BASE_BRANCH="${2:-}"; shift ;;
    --remote)         REMOTE="${2:-}"; shift ;;
    --account)        ACCOUNT_OVERRIDE="${2:-}"; shift ;;
    --forget)         FORGET=true ;;
    -h|--help)        sed -n '2,65p' "$0"; exit 0 ;;
    *)                die "unknown argument: $1" ;;
  esac
  shift
done

# Full guided mode is a master switch: turn on every sub-prompt so the user is
# walked through all scenarios (account choose/create, remote+repo setup, flow,
# and PR name) in a single run.
if [ "$INTERACTIVE_MODE_PROMPT" = true ]; then
  PUSH_OR_PR_PROMPT=true
  PR_NAME_PROMPT=true
  CHOOSE_ACCOUNT_PROMPT=true
  SETUP_REMOTE=true
fi

command -v git >/dev/null 2>&1 || die "git is not installed / not on PATH"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  info "No git repo here - initialising on branch '$BASE_BRANCH'"
  git init -b "$BASE_BRANCH" >/dev/null
fi

# =============================================================================
# accounts.conf readers (defined early so remote bootstrap can use them)
# =============================================================================
CONF_FILE="$(dirname "$0")/accounts.conf"
# First-run convenience: seed accounts.conf from the committed template so a fresh
# clone works without manual copying. The real accounts.conf stays git-ignored.
if [ ! -f "$CONF_FILE" ] && [ -f "$CONF_FILE.example" ]; then
  cp "$CONF_FILE.example" "$CONF_FILE"
  info "Created accounts.conf from accounts.conf.example - edit it (or run --interactive to add an account)."
fi
conf_get() { [ -f "$CONF_FILE" ] || return 0; grep -E "^[[:space:]]*ACCOUNT_$1_$2=" "$CONF_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' || true; }
# find the account index whose ALIAS matches $1 exactly (empty if none)
conf_index_for_alias() {
  local want="$1" i=1 a
  while :; do
    a="$(conf_get "$i" ALIAS)"; [ -z "$a" ] && break
    [ "$a" = "$want" ] && { echo "$i"; return; }
    i=$((i+1)); [ "$i" -gt 50 ] && break
  done
  echo ""
}
conf_index_for_name() {
  local want="$1" i=1 n
  while :; do
    n="$(conf_get "$i" NAME)"; [ -z "$n" ] && break
    [ "$n" = "$want" ] && { echo "$i"; return; }
    i=$((i+1)); [ "$i" -gt 50 ] && break
  done
  echo ""
}
# next free account index in accounts.conf (max existing + 1, else 1)
conf_next_index() {
  local i=1 last=0
  while :; do
    [ -n "$(conf_get "$i" NAME)" ] && last="$i"
    i=$((i+1)); [ "$i" -gt 50 ] && break
  done
  echo $((last+1))
}
# list all accounts as a numbered menu
list_accounts() {
  local i=1 n
  while :; do
    n="$(conf_get "$i" NAME)"; [ -z "$n" ] && break
    echo "  $i) $n  (alias: $(conf_get "$i" ALIAS), host: $(conf_get "$i" HOSTNAME))"
    i=$((i+1)); [ "$i" -gt 50 ] && break
  done
}

# interactively create a NEW account: append to accounts.conf + set up its SSH
# identity via gh-account-setup. Echoes the new account NAME on success.
create_new_account() {
  local nm al host usr eml key idx setup
  printf "New account friendly name: " >&2;              read -r nm  || nm=""
  [ -n "$nm" ] || { echo "" ; return 0; }
  printf "GitHub hostname [github.com]: " >&2;           read -r host || host=""
  [ -n "$host" ] || host="github.com"
  printf "GitHub username (owner): " >&2;                read -r usr  || usr=""
  printf "SSH host alias [%s-%s]: " "$host" "${usr:-$nm}" >&2;   read -r al   || al=""
  [ -n "$al" ] || al="$host-${usr:-$nm}"
  printf "Commit email [%s@users.noreply.github.com]: " "${usr:-user}" >&2; read -r eml || eml=""
  [ -n "$eml" ] || eml="${usr:-user}@users.noreply.github.com"
  printf "Private key path [~/.ssh/id_ed25519_%s]: " "$nm" >&2; read -r key || key=""
  [ -n "$key" ] || key="~/.ssh/id_ed25519_$nm"

  idx="$(conf_next_index)"
  [ -f "$CONF_FILE" ] || : > "$CONF_FILE"
  {
    echo ""
    echo "# ---- account $idx: $nm (added by gh-sync --choose-account) --------------"
    echo "ACCOUNT_${idx}_NAME=$nm"
    echo "ACCOUNT_${idx}_ALIAS=$al"
    echo "ACCOUNT_${idx}_HOSTNAME=$host"
    echo "ACCOUNT_${idx}_KEY=$key"
    echo "ACCOUNT_${idx}_USER=$usr"
    echo "ACCOUNT_${idx}_EMAIL=$eml"
  } >> "$CONF_FILE"
  info "Added account '$nm' to accounts.conf (index $idx)." >&2

  # set up its SSH key + ~/.ssh/config (idempotent) via the sibling script
  setup="$(dirname "$0")/gh-account-setup.sh"
  if [ -x "$setup" ] || [ -f "$setup" ]; then
    info "Setting up SSH identity for '$nm' ..." >&2
    bash "$setup" --account "$nm" >&2 || warn "gh-account-setup did not complete cleanly"
  else
    warn "gh-account-setup.sh not found next to gh-sync - set up the key manually." >&2
  fi
  echo "$nm"
}

# Interactive account picker: show a numbered list of configured accounts plus a
# "create a NEW account" option, and echo the chosen/created account NAME.
# Used up front (before the remote bootstrap) so the guided flow asks ONCE, in
# order: account -> repo -> push/pr.
pick_account_menu() {
  local pick chosen new_nm
  echo "Choose the GitHub account for this repo:" >&2
  list_accounts >&2
  echo "  n) create a NEW account" >&2
  printf "Pick a number, or 'n' for new: " >&2
  read -r pick || pick=""
  case "$pick" in
    n|N|new|NEW)
      new_nm="$(create_new_account)"
      echo "$new_nm" ;;
    ""|*[!0-9]*)
      warn "no valid selection - skipping account setup" >&2
      echo "" ;;
    *)
      chosen="$(conf_get "$pick" NAME)"
      if [ -n "$chosen" ]; then echo "$chosen"; else warn "no account #$pick" >&2; echo ""; fi ;;
  esac
}

# ACCOUNT FIRST (guided flow): if we're going to prompt anyway, resolve the
# account up front so the remote bootstrap reuses it (no bare double-prompt).
ACCT_PICKED_EARLY=false
if [ -z "$ACCOUNT_OVERRIDE" ] && [ -f "$CONF_FILE" ] \
   && { [ "$CHOOSE_ACCOUNT_PROMPT" = true ] || { [ "$SETUP_REMOTE" = true ] && [ "$PUSH_OR_PR_PROMPT" = true ]; }; }; then
  ACCOUNT_OVERRIDE="$(pick_account_menu)"
  ACCT_PICKED_EARLY=true
  # a fresh account creation may have changed accounts.conf on disk
fi

# =============================================================================
# REMOTE BOOTSTRAP (optional): set up identity + 'origin' from an account entry.
# Runs when --setup-remote is given, OR automatically (with a prompt) when there
# is no '$REMOTE' remote yet - so a brand-new repo needs no manual git commands.
# =============================================================================
if [ "$SETUP_REMOTE" = true ] || ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  if ! git remote get-url "$REMOTE" >/dev/null 2>&1 || [ "$SETUP_REMOTE" = true ]; then
    # pick the account whose identity/alias we bootstrap from
    bs_acct="$ACCOUNT_OVERRIDE"
    if [ -z "$bs_acct" ]; then
      if [ -f "$CONF_FILE" ]; then
        echo "Set up the '$REMOTE' remote for this repo. Available accounts:"
        list_accounts
        printf "Which account? (name, blank to skip remote setup): "
        read -r bs_acct || bs_acct=""
      else
        warn "no accounts.conf found - cannot bootstrap a remote automatically"
      fi
    fi
    if [ -n "$bs_acct" ]; then
      bidx="$(conf_index_for_name "$bs_acct")"
      if [ -z "$bidx" ]; then
        die "account '$bs_acct' not found in accounts.conf"
      fi
      bs_alias="$(conf_get "$bidx" ALIAS)"
      bs_user="$(conf_get "$bidx" USER)"
      bs_email="$(conf_get "$bidx" EMAIL)"
      # repo name: --repo, else prompt (default = current directory name)
      if [ -z "$REPO_NAME" ]; then
        def_repo="$(basename "$(pwd)")"
        printf "Repository name on the server [%s]: " "$def_repo"
        read -r REPO_NAME || REPO_NAME=""
        [ -n "$REPO_NAME" ] || REPO_NAME="$def_repo"
      fi
      # set per-repo identity (only if not already set for this repo)
      if [ -z "$(git config --local user.name || true)" ] && [ -n "$bs_user" ]; then
        git config --local user.name "$bs_user"
        info "Set local user.name = $bs_user"
      fi
      if [ -z "$(git config --local user.email || true)" ] && [ -n "$bs_email" ]; then
        git config --local user.email "$bs_email"
        info "Set local user.email = $bs_email"
      fi
      # add / update the remote
      bs_url="git@$bs_alias:$bs_user/$REPO_NAME.git"
      if git remote get-url "$REMOTE" >/dev/null 2>&1; then
        git remote set-url "$REMOTE" "$bs_url"
        info "Updated remote '$REMOTE' -> $bs_url"
      else
        git remote add "$REMOTE" "$bs_url"
        info "Added remote '$REMOTE' -> $bs_url"
      fi
      # remember the account choice so later resolution is silent
      ACCOUNT_OVERRIDE="$bs_acct"
      echo "NOTE: the repo '$bs_user/$REPO_NAME' must already exist on the server"
      echo "      (a push cannot create it). Create it first if you haven't."
    fi
  fi
fi

if [ -z "$MODE" ]; then
  if [ "$PUSH_OR_PR_PROMPT" = true ]; then
    echo "How do you want to sync?"
    echo "  1) push       - commit and push straight to '$BASE_BRANCH'"
    echo "  2) pr + merge - commit to a new branch, open a PR, then ask to merge"
    printf "Choose [1/2]: "
    read -r choice || choice="1"
    case "$choice" in 2|pr|PR) MODE=pr ;; *) MODE=push ;; esac
  else
    MODE=push
  fi
fi
info "Run mode: $MODE"

GIT_USER="$(git config user.name  || true)"
GIT_EMAIL="$(git config user.email || true)"
[ -n "$GIT_USER" ]  || warn "no git user.name set for this repo (commits may fail)"
[ -n "$GIT_EMAIL" ] || warn "no git user.email set for this repo (commits may fail)"

# -----------------------------------------------------------------------------
# Safety: never publish accounts.conf. It only sits inside the working tree when
# the repo being synced IS this toolkit directory. In that case, self-heal a
# .gitignore entry (and drop it from the index if it slipped in earlier) so the
# personal account registry is not committed. No-op for every other project.
# -----------------------------------------------------------------------------
if [ -f "$CONF_FILE" ]; then
  CONF_DIR="$(dirname "$CONF_FILE")"; CONF_BASE="$(basename "$CONF_FILE")"
  # Ask git (from the conf's own dir) whether it lives inside THIS repo, and where.
  if [ "$(cd "$CONF_DIR" && git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
     && [ "$(cd "$CONF_DIR" && git rev-parse --show-toplevel 2>/dev/null)" = "$(git rev-parse --show-toplevel 2>/dev/null)" ]; then
    REL="$(cd "$CONF_DIR" && git rev-parse --show-prefix 2>/dev/null)$CONF_BASE"
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
    GI="$REPO_ROOT/.gitignore"
    if ! { [ -f "$GI" ] && grep -qxF "$REL" "$GI"; }; then
      [ -s "$GI" ] && [ -n "$(tail -c1 "$GI" 2>/dev/null)" ] && printf '\n' >>"$GI"
      printf '%s\n' "$REL" >>"$GI"
      info "Added '$REL' to .gitignore (won't be committed)"
    fi
    git rm --cached --quiet "$REL" >/dev/null 2>&1 || true
  fi
fi

git add -A
if git diff --cached --quiet; then
  info "Nothing new to commit"; HAVE_NEW_COMMIT=false
else
  STAMP="$(date +%Y%m%d-%H%M%S)"
  MSG="${COMMIT_MSG:-$COMMIT_PREFIX $STAMP}"
  git commit -m "$MSG" >/dev/null
  info "Committed: $MSG"; HAVE_NEW_COMMIT=true
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  die "no '$REMOTE' remote. Add one first:
       git remote add $REMOTE git@<host-alias>:<user>/<repo>.git"
fi
REMOTE_URL="$(git remote get-url "$REMOTE")"
info "Remote '$REMOTE' -> $REMOTE_URL"

OWNER=""; REPO=""; HOST_ALIAS=""
case "$REMOTE_URL" in
  git@*:*)      HOST_ALIAS="${REMOTE_URL#git@}"; HOST_ALIAS="${HOST_ALIAS%%:*}"; rpath="${REMOTE_URL#*:}" ;;
  ssh://git@*/*) tmp="${REMOTE_URL#ssh://git@}"; HOST_ALIAS="${tmp%%/*}"; rpath="${tmp#*/}" ;;
  https://*/*)  tmp="${REMOTE_URL#https://}"; HOST_ALIAS="${tmp%%/*}"; rpath="${tmp#*/}" ;;
  *) rpath="" ;;
esac
rpath="${rpath%.git}"; OWNER="${rpath%%/*}"; REPO="${rpath##*/}"

WEB_HOST="$HOST_ALIAS"
case "$HOST_ALIAS" in github.com-*|github.com) WEB_HOST="github.com" ;; esac

# =============================================================================
# PER-REPO ACCOUNT MEMORY
# Resolve which accounts.conf entry this repo belongs to, then remember it in
# this repo's .git/config so future runs are silent. Never touches global config.
# (accounts.conf readers + create_new_account are defined earlier, near the top.)
# =============================================================================

# --forget wipes remembered settings for this repo
if [ "$FORGET" = true ]; then
  git config --local --remove-section ghsync >/dev/null 2>&1 || true
  info "Forgot remembered account settings for this repo."
fi

ACCOUNT_NAME="$(git config --local --get ghsync.account 2>/dev/null || true)"

# explicit override wins and is remembered
if [ -n "$ACCOUNT_OVERRIDE" ]; then
  ACCOUNT_NAME="$ACCOUNT_OVERRIDE"
fi

# if nothing remembered, try to auto-match the origin alias to accounts.conf
if [ -z "$ACCOUNT_NAME" ] && [ -n "$HOST_ALIAS" ]; then
  idx="$(conf_index_for_alias "$HOST_ALIAS")"
  if [ -n "$idx" ]; then
    ACCOUNT_NAME="$(conf_get "$idx" NAME)"
    info "Matched origin host '$HOST_ALIAS' to account '$ACCOUNT_NAME' (accounts.conf)"
  fi
fi

# CHOOSE_ACCOUNT_PROMPT: show a menu to keep the current one, pick another, or create a
# brand-new account for THIS project. Only when a conf file exists AND we did not
# already resolve the account up front in the guided "account first" step.
if [ "$CHOOSE_ACCOUNT_PROMPT" = true ] && [ "$ACCT_PICKED_EARLY" != true ] && [ -f "$CONF_FILE" ]; then
  echo "Choose the GitHub account for this project:"
  if [ -n "$ACCOUNT_NAME" ]; then echo "  0) keep current: '$ACCOUNT_NAME'"; fi
  list_accounts
  echo "  n) create a NEW account"
  if [ -n "$ACCOUNT_NAME" ]; then
    printf "Pick a number, 'n' for new, or 0 to keep: "
  else
    printf "Pick a number, or 'n' for new: "
  fi
  read -r pick || pick=""
  case "$pick" in
    0|"")  if [ -z "$ACCOUNT_NAME" ]; then info "no account kept - will fall back to env token"; fi ;;
    n|N|new|NEW)
      new_nm="$(create_new_account)"
      if [ -n "$new_nm" ]; then ACCOUNT_NAME="$new_nm"; fi ;;

    *[!0-9]*) warn "invalid selection '$pick' - keeping '$ACCOUNT_NAME'" ;;
    *)
      chosen="$(conf_get "$pick" NAME)"
      if [ -n "$chosen" ]; then ACCOUNT_NAME="$chosen"; else warn "no account #$pick - keeping '$ACCOUNT_NAME'"; fi ;;
  esac
fi

# still unknown: ask (interactive) or leave blank (fallback to env token)
if [ -z "$ACCOUNT_NAME" ] && [ "$PUSH_OR_PR_PROMPT" = true ] && [ -f "$CONF_FILE" ]; then
  echo "Which account does this repo use? (from accounts.conf)"
  i=1; while :; do n="$(conf_get "$i" NAME)"; [ -z "$n" ] && break; echo "  - $n  (alias: $(conf_get "$i" ALIAS), host: $(conf_get "$i" HOSTNAME))"; i=$((i+1)); [ "$i" -gt 50 ] && break; done
  printf "Account name (blank = none / use env token): "
  read -r ACCOUNT_NAME || ACCOUNT_NAME=""
fi

# resolve account -> ACCOUNT_TOKEN + remember
ACCOUNT_TOKEN=""
if [ -n "$ACCOUNT_NAME" ]; then
  aidx="$(conf_index_for_name "$ACCOUNT_NAME")"
  if [ -n "$aidx" ]; then
    ACCOUNT_TOKEN="$(conf_get "$aidx" TOKEN)"
    # remember for next time (local only)
    git config --local ghsync.account "$ACCOUNT_NAME" 2>/dev/null || true
    git config --local ghsync.webhost "$WEB_HOST" 2>/dev/null || true
    info "Using account '$ACCOUNT_NAME' (remembered in .git/config)"
  else
    warn "account '$ACCOUNT_NAME' not found in accounts.conf - ignoring"
    ACCOUNT_NAME=""
  fi
fi

case "$REMOTE_URL" in
  git@*)
    info "Checking SSH auth to $HOST_ALIAS ..."
    AUTH_MSG="$(ssh -T "git@$HOST_ALIAS" 2>&1 || true)"
    echo "   $AUTH_MSG" ;;
esac

# =============================================================================
# PUSH MODE
# =============================================================================
if [ "$MODE" = push ]; then
  CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  [ "$CUR_BRANCH" = "HEAD" ] && CUR_BRANCH="$BASE_BRANCH"
  info "Pushing '$CUR_BRANCH' to $REMOTE ..."
  if git push -u "$REMOTE" "$CUR_BRANCH"; then
    if [ -n "$OWNER" ] && [ -n "$REPO" ]; then
      info "Done. https://$WEB_HOST/$OWNER/$REPO"
    else
      info "Done."
    fi
  else
    die "push failed - does the repo exist on the server? create it, then re-run."
  fi
  exit 0
fi

# =============================================================================
# PR MODE  (branch -> push -> open PR -> ask to merge)
# =============================================================================
# First-push guard: a PR needs a base branch to target. On a brand-new / empty
# repo the base branch does not exist on the remote yet, so a PR branch would
# have nothing to merge into ("There isn't anything to compare"). Detect that
# and fall back to a plain push to the base branch, which creates it. Next runs
# (base now exists) proceed with the normal PR flow.
if ! git ls-remote --exit-code --heads "$REMOTE" "$BASE_BRANCH" >/dev/null 2>&1; then
  warn "Base branch '$BASE_BRANCH' does not exist on '$REMOTE' yet (new/empty repo)."
  info "A PR needs a base to target - pushing the first commit straight to '$BASE_BRANCH' instead."
  # Push the current HEAD to the remote base ref. Using HEAD:<base> creates the
  # remote branch from whatever commit we are on, regardless of the LOCAL branch
  # name, so it never fails on "a branch named '<base>' already exists".
  info "Pushing HEAD to '$REMOTE/$BASE_BRANCH' ..."
  if git push -u "$REMOTE" "HEAD:refs/heads/$BASE_BRANCH"; then
    if [ -n "$OWNER" ] && [ -n "$REPO" ]; then
      info "Done. Base branch '$BASE_BRANCH' created. https://$WEB_HOST/$OWNER/$REPO"
    else
      info "Done. Base branch '$BASE_BRANCH' created."
    fi
    info "Re-run with --pr next time to open pull requests against '$BASE_BRANCH'."
  else
    die "push failed - does the repo exist on the server? create it, then re-run."
  fi
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"

# custom PR name: ask if enabled and not provided via --pr-name
if [ -z "$PR_NAME" ] && [ "$PR_NAME_PROMPT" = true ]; then
  printf "PR title? (blank = default 'update %s'): " "$STAMP"
  read -r PR_NAME || PR_NAME=""
fi

# slugify a custom name -> lowercase, non-alnum -> '-', trim repeats/edges
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-//; s/-$//'
}

if [ -n "$PR_NAME" ]; then
  SLUG="$(slugify "$PR_NAME")"
  [ -n "$SLUG" ] || SLUG="pr"
  PR_BRANCH="feature/$SLUG-$STAMP"
  PR_TITLE="$PR_NAME"
else
  PR_BRANCH="$COMMIT_PREFIX/$STAMP"
  PR_TITLE="$COMMIT_PREFIX $STAMP"
fi
info "Creating PR branch: $PR_BRANCH (base: $BASE_BRANCH)"
# Always cut the PR branch from the *base* branch tip, not from whatever branch we
# happen to be on (e.g. a leftover update/<stamp> from an unmerged previous run).
# Refresh our knowledge of the remote base, then branch from it and replay the new
# commit on top, so each PR branch is a clean single change against main.
git fetch -q "$REMOTE" "$BASE_BRANCH" 2>/dev/null || true
NEW_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
BASE_REF=""
if git rev-parse --verify -q "$REMOTE/$BASE_BRANCH" >/dev/null 2>&1; then
  BASE_REF="$REMOTE/$BASE_BRANCH"
elif git rev-parse --verify -q "$BASE_BRANCH" >/dev/null 2>&1; then
  BASE_REF="$BASE_BRANCH"
fi
if [ -n "$BASE_REF" ]; then
  git switch -C "$PR_BRANCH" "$BASE_REF" 2>/dev/null || git checkout -B "$PR_BRANCH" "$BASE_REF"
  # replay the just-made commit (if any) on top of the fresh base
  if [ "${HAVE_NEW_COMMIT:-false}" = true ] && [ -n "$NEW_HEAD" ]; then
    git cherry-pick "$NEW_HEAD" >/dev/null 2>&1 || {
      warn "cherry-pick onto $BASE_BRANCH failed - falling back to current HEAD"
      git switch -C "$PR_BRANCH" "$NEW_HEAD" 2>/dev/null || git checkout -B "$PR_BRANCH" "$NEW_HEAD"
    }
  fi
else
  # no base ref locally or on the remote yet - just branch from current HEAD
  git switch -c "$PR_BRANCH" 2>/dev/null || git checkout -b "$PR_BRANCH"
fi

if [ "${HAVE_NEW_COMMIT:-false}" != true ]; then
  warn "no new commit; PR only differs if this branch is ahead of $BASE_BRANCH"
fi

info "Pushing branch '$PR_BRANCH' to $REMOTE ..."
git push -u "$REMOTE" "$PR_BRANCH" || die "failed to push PR branch"

PR_BODY="Automated update generated on $STAMP by gh-sync."
COMPARE_URL="https://$WEB_HOST/$OWNER/$REPO/compare/$BASE_BRANCH...$PR_BRANCH?expand=1"

# token resolution order: per-account (accounts.conf ACCOUNT_N_TOKEN) > env >
# global GITHUB_TOKEN= in accounts.conf
TOKEN="${ACCOUNT_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -f "$CONF_FILE" ]; then
  TOKEN="$(grep -E '^[[:space:]]*GITHUB_TOKEN=' "$CONF_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
fi

API_BASE="https://api.github.com"
case "$WEB_HOST" in github.com) ;; *) API_BASE="https://$WEB_HOST/api/v3" ;; esac

PR_NUMBER=""; PR_URL=""

open_pr_with_gh() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
  info "Opening PR via gh CLI ..."
  PR_URL="$(gh pr create --base "$BASE_BRANCH" --head "$PR_BRANCH" \
              --title "$PR_TITLE" --body "$PR_BODY" 2>/dev/null)" || return 1
  PR_NUMBER="$(gh pr view "$PR_BRANCH" --json number -q .number 2>/dev/null || true)"
  return 0
}

# Reason string explaining why token-based PR creation could not run / failed.
# Set by open_pr_with_token so the fallback message is specific, not generic.
PR_TOKEN_REASON=""

open_pr_with_token() {
  if [ -z "$TOKEN" ]; then PR_TOKEN_REASON="no token (accounts.conf ACCOUNT_N_TOKEN / GITHUB_TOKEN, or env GITHUB_TOKEN/GH_TOKEN)"; return 1; fi
  if ! command -v curl >/dev/null 2>&1; then PR_TOKEN_REASON="curl is not installed / not on PATH"; return 1; fi
  info "Opening PR via REST API + token ..."
  local resp http body msg
  # capture body + trailing HTTP status so we can report GitHub's real error
  resp="$(curl -sS -w $'\n%{http_code}' -X POST \
      -H "Authorization: token $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$API_BASE/repos/$OWNER/$REPO/pulls" \
      -d "{\"title\":\"$PR_TITLE\",\"head\":\"$PR_BRANCH\",\"base\":\"$BASE_BRANCH\",\"body\":\"$PR_BODY\"}" 2>/dev/null)" \
    || { PR_TOKEN_REASON="curl request to $API_BASE failed (network/proxy/DNS?)"; return 1; }
  http="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"
  PR_URL="$(printf '%s' "$body" | grep -o '"html_url": *"[^"]*"' | head -n1 | cut -d'"' -f4)"
  PR_NUMBER="$(printf '%s' "$body" | grep -o '"number": *[0-9]*' | head -n1 | grep -o '[0-9]*')"
  if [ -n "$PR_URL" ]; then return 0; fi
  # failure: extract GitHub's message field for a precise reason
  msg="$(printf '%s' "$body" | grep -o '"message": *"[^"]*"' | head -n1 | cut -d'"' -f4)"
  case "$http" in
    403) PR_TOKEN_REASON="token rejected (HTTP 403: ${msg:-forbidden}). The token likely lacks 'Pull requests: Read and write' (fine-grained) or 'repo' scope (classic) for $OWNER/$REPO." ;;
    401) PR_TOKEN_REASON="token invalid/expired (HTTP 401: ${msg:-unauthorized})." ;;
    404) PR_TOKEN_REASON="not found (HTTP 404: ${msg:-not found}) - check the token can access $OWNER/$REPO and the branch was pushed." ;;
    422) PR_TOKEN_REASON="GitHub rejected the PR (HTTP 422: ${msg:-unprocessable}) - branch may have no diff vs $BASE_BRANCH, or a PR already exists." ;;
    *)   PR_TOKEN_REASON="GitHub API error (HTTP ${http:-?}: ${msg:-unknown})." ;;
  esac
  return 1
}

if open_pr_with_gh; then
  info "PR created: ${PR_URL:-<open in browser>}"
elif open_pr_with_token; then
  info "PR created: $PR_URL"
else
  echo
  echo "-----------------------------------------------------------------------"
  echo " Could not auto-create the PR automatically."
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo " gh CLI: authenticated but PR creation via gh failed."
  else
    echo " gh CLI: not installed or not authenticated."
  fi
  echo " Token:  ${PR_TOKEN_REASON:-unavailable}"
  echo " Open the PR in your browser instead:"
  echo "   $COMPARE_URL"
  echo "-----------------------------------------------------------------------"
  exit 0
fi

if [ "$NO_MERGE" = true ]; then
  info "--no-merge set - leaving PR open: ${PR_URL:-$COMPARE_URL}"
  exit 0
fi
echo
printf "Merge PR #%s into '%s' now? [y/N] " "${PR_NUMBER:-?}" "$BASE_BRANCH"
read -r ans || ans="n"

# After a successful merge, bring the local checkout back to the base branch and
# fast-forward it, then delete the merged feature branch. Without this the local
# repo stays on the orphaned update/<stamp> branch and every later run/commit
# happens there instead of on main.
return_to_base() {
  info "Returning local checkout to '$BASE_BRANCH' ..."
  git switch "$BASE_BRANCH" 2>/dev/null || git checkout "$BASE_BRANCH" 2>/dev/null || {
    warn "could not switch to '$BASE_BRANCH' locally - you are still on '$PR_BRANCH'"
    return 0
  }
  # update local base with the merge commit from the remote
  git pull --ff-only "$REMOTE" "$BASE_BRANCH" 2>/dev/null || true
  # drop the now-merged local feature branch (kept if it still has unmerged work)
  git branch -d "$PR_BRANCH" 2>/dev/null \
    && info "Deleted local branch '$PR_BRANCH'." \
    || warn "kept local branch '$PR_BRANCH' (not fully merged locally)."
}

case "$ans" in
  [yY]*)
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      info "Merging via gh ..."
      if gh pr merge "${PR_NUMBER:-$PR_BRANCH}" --merge --delete-branch; then
        info "Merged into $BASE_BRANCH."
        return_to_base
      fi
    elif [ -n "$TOKEN" ] && [ -n "$PR_NUMBER" ]; then
      info "Merging via REST API ..."
      if curl -sS -X PUT \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "$API_BASE/repos/$OWNER/$REPO/pulls/$PR_NUMBER/merge" \
        -d '{"merge_method":"merge"}' >/dev/null; then
        info "Merged into $BASE_BRANCH."
        return_to_base
      fi
    else
      warn "no way to merge automatically - do it in the browser: ${PR_URL:-$COMPARE_URL}"
    fi
    ;;
  *)
    info "Left PR open: ${PR_URL:-$COMPARE_URL}"
    ;;
esac

