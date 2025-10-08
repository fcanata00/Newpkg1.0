#!/usr/bin/env bash
# revdep_depclean.sh - reverse-dependency cleanup tool for newpkg
# Features:
#  - detect orphan packages using deps.py (preferred) or db.sh fallback
#  - interactive / auto / dry-run removal modes
#  - protected list to avoid removing system-critical packages
#  - parallel revdep checks using xargs -P $(nproc)
#  - auto-commit to git repo and git gc --prune=now
#  - hooks at /etc/newpkg/hooks/revdep/
#  - purge-cache option to clear /var/lib/newpkg/depgraph.json and force deps.py sync
#
# Requirements: bash, jq, xargs, nproc, git (for auto-commit), deps.py (recommended), db.sh, remove.sh
#
# Usage examples:
#   revdep_depclean.sh --dry-run
#   revdep_depclean.sh --interactive
#   revdep_depclean.sh --auto --auto-commit
#   revdep_depclean.sh --verify --purge-cache
#
set -o errexit
set -o nounset
set -o pipefail

############################
# Configuration / Defaults
############################
: "${DEPGRAPH_CACHE:=/var/lib/newpkg/depgraph.json}"
: "${PROTECTED_LIST:=/etc/newpkg/protected.list}"
: "${HOOKS_DIR:=/etc/newpkg/hooks/revdep}"
: "${LOG_DIR:=/var/log/newpkg}"
: "${LOG_FILE:=${LOG_DIR}/depclean.log}"
: "${DB_CLI:=/usr/lib/newpkg/db.sh}"
: "${REMOVE_CLI:=/usr/lib/newpkg/remove.sh}"
: "${DEPS_PY:=/usr/lib/newpkg/deps.py}"
: "${PORTS_DIR:=/usr/ports}"
: "${PARALLEL_JOBS:=$(nproc)}"

# Tools
JQ_BIN="$(command -v jq || true)"
XARGS_BIN="$(command -v xargs || true)"
GIT_BIN="$(command -v git || true)"
NPROC_BIN="$(command -v nproc || true)"

# Modes (set via CLI)
DRY_RUN=0
AUTO=0
INTERACTIVE=0
VERIFY=0
QUIET=0
FORCE=0
AUTO_COMMIT=0
PURGE_CACHE=0
SHOW_SUMMARY_ALWAYS=1  # always print summary even quiet (we will show color summary)

# Colors / symbols for summary
C_RESET="\033[0m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
SY_OK="✅"
SY_WARN="⚠️"
SY_ERR="❌"

# Create log dir
mkdir -p -- "$LOG_DIR"

# try to source log.sh for unified logging
if [[ -f "/usr/lib/newpkg/log.sh" ]]; then
  # shellcheck source=/usr/lib/newpkg/log.sh
  source /usr/lib/newpkg/log.sh || true
elif [[ -f "/etc/newpkg/log.sh" ]]; then
  # shellcheck source=/etc/newpkg/log.sh
  source /etc/newpkg/log.sh || true
fi

# fallback logging functions if log.sh didn't provide them
_log_fallback() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
}
log_info()  { if declare -F log_info >/dev/null 2>&1; then log_info "$@"; else _log_fallback "INFO" "$@"; fi; }
log_warn()  { if declare -F log_warn >/dev/null 2>&1; then log_warn "$@"; else _log_fallback "WARN" "$@"; fi; }
log_error() { if declare -F log_error >/dev/null 2>&1; then log_error "$@"; else _log_fallback "ERROR" "$@"; fi; }
log_debug() { if [[ "${NPKG_DEBUG:-0}" -eq 1 ]]; then _log_fallback "DEBUG" "$@"; fi; }

# run hooks under HOOKS_DIR/<hook>/*
run_hooks() {
  local hook="$1"; shift || true
  local d="$HOOKS_DIR/$hook"
  if [[ -d "$d" ]]; then
    for s in "$d"/*; do
      [[ -x "$s" ]] || continue
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "(dry-run) would run hook: $s $*"
      else
        log_info "running hook: $s $*"
        "$s" "$@" || log_warn "hook $s exited non-zero"
      fi
    done
  fi
}

############################
# Utility functions
############################
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Load protected list into array PROTECTED_PACKAGES
load_protected_list() {
  PROTECTED_PACKAGES=()
  if [[ -f "$PROTECTED_LIST" ]]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line//[[:space:]]/}"
      [[ -z "$line" ]] && continue
      PROTECTED_PACKAGES+=("$line")
    done <"$PROTECTED_LIST"
  fi
}

is_protected() {
  local pkg="$1"
  for p in "${PROTECTED_PACKAGES[@]}"; do
    if [[ "$pkg" == "$p" ]]; then
      return 0
    fi
  done
  return 1
}

# Confirm prompt (yes/no)
confirm_prompt() {
  local prompt="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "(dry-run) $prompt -> assumed NO"
    return 1
  fi
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    read -r -p "$prompt [y/N]: " ans
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      *) return 1 ;;
    esac
  else
    return 1
  fi
}

# Run remove for a package via remove.sh or db.sh fallback
perform_remove() {
  local pkg="$1"
  if is_protected "$pkg" && [[ "$FORCE" -ne 1 ]]; then
    log_warn "Skipping $pkg: protected"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would remove $pkg"
    return 0
  fi

  if [[ -x "$REMOVE_CLI" ]]; then
    log_info "Calling $REMOVE_CLI remove $pkg --yes"
    "$REMOVE_CLI" remove "$pkg" --yes || {
      log_warn "remove.sh failed for $pkg; attempting db.sh remove"
      [[ -x "$DB_CLI" ]] && "$DB_CLI" remove "$pkg" --force || {
        log_error "db.sh remove not available; manual cleanup needed for $pkg"
        return 1
      }
    }
  else
    if [[ -x "$DB_CLI" ]]; then
      log_info "remove.sh not found; using db.sh remove $pkg --force"
      "$DB_CLI" remove "$pkg" --force || {
        log_error "Failed to remove $pkg via db.sh"
        return 1
      }
    else
      log_error "No removal tool found (remove.sh or db.sh). Cannot remove $pkg"
      return 1
    fi
  fi
  return 0
}

# Auto-commit to git repo if repo root is under PORTS_DIR or specified tree
git_autocommit_if_repo() {
  local repo_root="$1"
  local msg="${2:-Auto depclean $(timestamp)}"
  if [[ "$AUTO_COMMIT" -ne 1 ]]; then
    return 0
  fi
  if [[ -z "$GIT_BIN" ]]; then
    log_warn "git not found; skipping auto-commit"
    return 1
  fi
  if [[ ! -d "$repo_root/.git" ]]; then
    log_warn "No git repo at $repo_root; skipping auto-commit"
    return 1
  fi
  pushd "$repo_root" >/dev/null || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would run: git add -A && git commit -m \"$msg\" && git gc --prune=now"
    popd >/dev/null
    return 0
  fi
  "$GIT_BIN" add -A || log_warn "git add failed (non-fatal)"
  if "$GIT_BIN" commit -m "$msg" >/dev/null 2>&1; then
    log_info "Auto-commit created in $repo_root"
    # run git gc
    if command -v git >/dev/null 2>&1; then
      log_info "Running git gc --prune=now"
      "$GIT_BIN" gc --prune=now || log_warn "git gc failed"
    fi
  else
    log_info "No changes to commit in $repo_root"
  fi
  popd >/dev/null || true
  return 0
}

# fallback orphan detection with db.sh if deps.py not available or fails
fallback_orphans_via_db() {
  local tmpfile
  tmpfile="$(mktemp)"
  # get list of installed packages (name-version) via db.sh list --json
  if [[ -x "$DB_CLI" ]]; then
    if ! out="$("$DB_CLI" list --json 2>/dev/null)"; then
      log_error "db.sh list failed"
      rm -f "$tmpfile"
      return 1
    fi
    echo "$out" | jq -r '.[] | .name + "-" + .version' >"$tmpfile" || true
  else
    log_error "db.sh not found; cannot run fallback orphan detection"
    rm -f "$tmpfile"
    return 1
  fi

  # For each installed package, check revdeps; if zero revdeps -> candidate orphan
  local candidates_file
  candidates_file="$(mktemp)"
  cat "$tmpfile" | XARGS_BIN -P "$PARALLEL_JOBS" -I{} bash -c '
    pkg="{}"
    if '"$DB_CLI"' revdeps "$pkg" >/dev/null 2>&1; then
      cnt=$('"$DB_CLI"' revdeps "$pkg" 2>/dev/null | wc -l)
      if [[ "$cnt" -eq 0 ]]; then
        printf "%s\n" "$pkg"
      fi
    fi
  ' >"$candidates_file"
  # output deduped base names (strip version)
  awk -F- "{print \$1}" "$candidates_file" | sort -u
  rm -f "$tmpfile" "$candidates_file"
  return 0
}

# Use deps.py clean (preferred) or fallback
detect_orphans() {
  # try deps.py if available
  if [[ -x "$DEPS_PY" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "(dry-run) would call deps.py clean"
      "$DEPS_PY" clean || true
      return 0
    fi
    # deps.py clean prints orphans to stdout (one per line) per our earlier design
    if orphans_raw="$("$DEPS_PY" clean 2>/dev/null)"; then
      if [[ -z "$orphans_raw" ]]; then
        echo ""
        return 0
      else
        # normalize outputs: each line is package name
        echo "$orphans_raw" | awk '{print $1}' | sort -u
        return 0
      fi
    else
      log_warn "deps.py clean failed or returned non-zero; falling back to db.sh"
      fallback_orphans_via_db
      return $?
    fi
  else
    log_warn "deps.py not found; using db.sh fallback"
    fallback_orphans_via_db
    return $?
  fi
}

# verify: run deps.py sync && db.sh verify (if requested)
verify_db_and_graph() {
  log_info "Verifying DB and dependency graph consistency..."
  if [[ "$PURGE_CACHE" -eq 1 ]]; then
    if [[ -f "$DEPGRAPH_CACHE" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "(dry-run) would remove $DEPGRAPH_CACHE"
      else
        rm -f "$DEPGRAPH_CACHE" && log_info "Removed depgraph cache $DEPGRAPH_CACHE"
      fi
    fi
  fi
  if [[ -x "$DEPS_PY" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "(dry-run) would run: $DEPS_PY sync"
    else
      "$DEPS_PY" sync || log_warn "deps.py sync returned non-zero"
    fi
  fi
  if [[ -x "$DB_CLI" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "(dry-run) would run: $DB_CLI list"
    else
      "$DB_CLI" list >/dev/null 2>&1 || log_warn "db.sh list failed"
    fi
  fi
}

# main removal engine: receives list of package names (base names, no versions)
process_orphans_list() {
  local -a orphans=("$@")
  local removed=()
  local skipped=()
  local failed=()
  for pkg in "${orphans[@]}"; do
    # check protected
    if is_protected "$pkg"; then
      log_info "Skipping protected package: $pkg"
      skipped+=("$pkg")
      continue
    fi

    # double-check revdeps via db.sh (if available)
    if [[ -x "$DB_CLI" ]]; then
      cnt=0
      if revs="$("$DB_CLI" revdeps "$pkg" 2>/dev/null)"; then
        cnt="$(echo "$revs" | wc -l || echo 0)"
      fi
      if [[ "$cnt" -gt 0 && "$FORCE" -ne 1 ]]; then
        log_warn "Package $pkg has $cnt reverse-dependency(ies); skipping (use --force to override)"
        skipped+=("$pkg")
        continue
      fi
    fi

    # interactive confirmation if not auto
    if [[ "$AUTO" -ne 1 && "$INTERACTIVE" -ne 1 ]]; then
      # default: do not remove unless auto or interactive
      log_info "Candidate orphan: $pkg (not removed: neither --auto nor --interactive provided)"
      skipped+=("$pkg")
      continue
    fi

    if [[ "$INTERACTIVE" -eq 1 ]]; then
      if ! confirm_prompt "Remove package $pkg?"; then
        log_info "User declined removal of $pkg"
        skipped+=("$pkg")
        continue
      fi
    fi

    # perform removal
    if perform_remove "$pkg"; then
      removed+=("$pkg")
      log_info "Removed: $pkg"
    else
      failed+=("$pkg")
      log_error "Failed to remove: $pkg"
    fi
  done

  # After removals, update deps graph cache if any removed
  if [[ "${#removed[@]}" -gt 0 ]]; then
    if [[ -x "$DEPS_PY" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "(dry-run) would run: $DEPS_PY sync"
      else
        "$DEPS_PY" sync || log_warn "deps.py sync after removal returned non-zero"
      fi
    fi
  fi

  # auto-commit if enabled and removals happened
  if [[ "${#removed[@]}" -gt 0 && "$AUTO_COMMIT" -eq 1 ]]; then
    # try to git commit at ports tree root if present
    if [[ -d "$PORTS_DIR/.git" ]]; then
      git_autocommit_if_repo "$PORTS_DIR" "Auto depclean: removed ${#removed[@]} packages ($(date -u))"
    else
      log_warn "Auto-commit requested but $PORTS_DIR is not a git repo"
    fi
  fi

  # produce summary
  summarize_and_exit "${removed[*]}" "${skipped[*]}" "${failed[*]}"
}

summarize_and_exit() {
  local removed_list="$1"
  local skipped_list="$2"
  local failed_list="$3"

  local nr=0 ns=0 nf=0
  if [[ -n "$removed_list" ]]; then nr=$(echo "$removed_list" | wc -w); fi
  if [[ -n "$skipped_list" ]]; then ns=$(echo "$skipped_list" | wc -w); fi
  if [[ -n "$failed_list" ]]; then nf=$(echo "$failed_list" | wc -w); fi

  # Color summary (still print even quiet)
  printf "\n"
  printf "%b Summary (%s) %b\n" "$C_GREEN" "$(timestamp)" "$C_RESET"
  if [[ "$nr" -gt 0 ]]; then
    printf "%b %s removed%b\n" "$C_GREEN$SY_OK" "$nr" "$C_RESET"
  else
    printf "%b %s removed%b\n" "$C_GREEN$SY_OK" "0" "$C_RESET"
  fi
  if [[ "$ns" -gt 0 ]]; then
    printf "%b %s skipped%b\n" "$C_YELLOW$SY_WARN" "$ns" "$C_RESET"
  else
    printf "%b %s skipped%b\n" "$C_YELLOW$SY_WARN" "0" "$C_RESET"
  fi
  if [[ "$nf" -gt 0 ]]; then
    printf "%b %s failed%b\n" "$C_RED$SY_ERR" "$nf" "$C_RESET"
  else
    printf "%b %s failed%b\n" "$C_RED$SY_ERR" "0" "$C_RESET"
  fi

  # always write concise line to logfile
  echo "$(timestamp) depclean summary: removed=$nr skipped=$ns failed=$nf" >>"$LOG_FILE"

  if [[ "$nf" -gt 0 ]]; then
    exit 2
  else
    exit 0
  fi
}

############################
# CLI: parse args
############################
show_help() {
  cat <<'EOF'
Usage: revdep_depclean.sh [options]

Options:
  --auto            Remove detected orphans automatically
  --interactive     Confirm each removal interactively
  --dry-run         Show what would be removed (no changes)
  --verify          Verify DB+graph before running (runs deps.py sync and db.sh list)
  --auto-commit     Commit changes to git in /usr/ports if repo present
  --purge-cache     Remove depgraph cache and force rebuild
  --force           Force removal even if revdeps reported (dangerous)
  --quiet           Reduce output (summary still printed)
  --help            Show this message
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO=1; shift ;;
    --interactive) INTERACTIVE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --auto-commit) AUTO_COMMIT=1; shift ;;
    --purge-cache) PURGE_CACHE=1; shift ;;
    --force) FORCE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "Unknown arg: $1"; show_help; exit 1 ;;
  esac
done

# Sanity: if neither auto nor interactive specified, default to dry-run (safe)
if [[ "$AUTO" -eq 0 && "$INTERACTIVE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
  log_info "No --auto or --interactive provided; defaulting to --dry-run for safety"
  DRY_RUN=1
fi

# load protected list
load_protected_list

# optionally verify DB/graph
if [[ "$VERIFY" -eq 1 ]]; then
  verify_db_and_graph
fi

run_hooks pre-clean

# purge cache if requested
if [[ "$PURGE_CACHE" -eq 1 ]]; then
  if [[ -f "$DEPGRAPH_CACHE" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "(dry-run) would remove depgraph cache: $DEPGRAPH_CACHE"
    else
      rm -f "$DEPGRAPH_CACHE" && log_info "Removed depgraph cache: $DEPGRAPH_CACHE"
    fi
  fi
  # run deps.py sync to rebuild if not dry-run
  if [[ -x "$DEPS_PY" && "$DRY_RUN" -eq 0 ]]; then
    "$DEPS_PY" sync || log_warn "deps.py sync returned non-zero"
  fi
fi

# detect orphans
log_info "Detecting orphan packages..."
orphans_raw="$(detect_orphans || true)"
if [[ -z "$orphans_raw" ]]; then
  log_info "No orphan packages detected."
  summarize_and_exit "" "" ""
fi

# Normalize orphans to array of base names (strip -version if present)
mapfile -t ORPHANS <<<"$(echo "$orphans_raw" | awk -F- '{print $1}' | sort -u)"

if [[ "${#ORPHANS[@]}" -eq 0 ]]; then
  log_info "No orphan packages after normalization."
  summarize_and_exit "" "" ""
fi

# Show found candidates (always show)
log_info "Orphan candidates found:"
for p in "${ORPHANS[@]}"; do
  if is_protected "$p"; then
    printf "%s (protected)\n" "$p"
  else
    printf "%s\n" "$p"
  fi
done

# If dry-run only -> print summary and exit
if [[ "$DRY_RUN" -eq 1 && "$AUTO" -eq 0 && "$INTERACTIVE" -eq 0 ]]; then
  log_info "(dry-run) not removing anything. Use --auto or --interactive to remove."
  summarize_and_exit "" "$(printf '%s ' "${ORPHANS[@]}")" ""
fi

# Process the orphans list (removal or interactive)
process_orphans_list "${ORPHANS[@]}"

# run post-clean hooks
run_hooks post-clean

# script ends within summarize_and_exit
