#!/usr/bin/env bash
# remove.sh - safe package removal for newpkg
#
# Usage:
#   remove.sh [options] <pkg> [pkg2 ...]
#
# Options:
#   --auto            no interactive prompts (non-interactive)
#   --force           ignore reverse-dependencies warnings (dangerous)
#   --purge           remove also config files under /etc and /var for the package
#   --dry-run         show actions without executing
#   --resume          resume last interrupted removal
#   --parallel N      parallel jobs for validation/removal steps (default nproc or config)
#   --no-depclean     skip calling revdep_depclean.sh after removals
#   --no-sync         skip deps.py sync after removals
#   --quiet           minimal console output
#   --help
#
set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

##########
# CONFIG
##########
: "${CONFIG_FILE:=/etc/newpkg/newpkg.yaml}"
: "${DB_CLI:=/usr/lib/newpkg/db.sh}"
: "${DEPS_PY:=/usr/lib/newpkg/deps.py}"
: "${REVDEP:=/usr/lib/newpkg/revdep_depclean.sh}"
: "${LOG_SH:=/usr/lib/newpkg/log.sh}"
: "${PROTECTED_LIST:=/etc/newpkg/protected.list}"
: "${STATE_DIR:=/var/lib/newpkg/state}"
: "${STATE_FILE:=${STATE_DIR}/remove_state.json}"
: "${TRASH_DIR:=/var/lib/newpkg/trash}"
: "${LOG_DIR:=/var/log/newpkg}"
: "${LOG_FILE:=${LOG_DIR}/remove.log}"
: "${DB_DIR:=/var/lib/newpkg/db}"
: "${PORTS_DIR:=/usr/ports}"
: "${DEFAULT_PARALLEL:=$(nproc)}"
: "${LOCKFILE:=/tmp/newpkg-remove.lock}"

# tools
YQ="$(command -v yq || true)"
JQ="$(command -v jq || true)"
XARGS="$(command -v xargs || true)"
GIT="$(command -v git || true)"
NPROC="$(command -v nproc || true)"

# runtime flags (defaults)
DRY_RUN=0
AUTO=0
FORCE=0
PURGE=0
RESUME=0
NO_DEPCLEAN=0
NO_SYNC=0
QUIET=0
PARALLEL="${DEFAULT_PARALLEL}"

# Ensure essential directories exist
mkdir -p -- "$STATE_DIR" "$TRASH_DIR" "$LOG_DIR"

# try to source log.sh for colored logging (fallback otherwise)
if [[ -f "$LOG_SH" ]]; then
  # shellcheck source=/usr/lib/newpkg/log.sh
  source "$LOG_SH" || true
elif [[ -f "/etc/newpkg/log.sh" ]]; then
  # shellcheck source=/etc/newpkg/log.sh
  source /etc/newpkg/log.sh || true
fi

# fallback log functions if log.sh not present
_log_fallback() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  case "$level" in
    INFO) printf '%s [INFO] %s\n' "$ts" "$msg" ;;
    WARN) printf '%s [WARN] %s\n' "$ts" "$msg" >&2 ;;
    ERROR) printf '%s [ERROR] %s\n' "$ts" "$msg" >&2 ;;
    DEBUG) [[ "${NPKG_DEBUG:-0}" -eq 1 ]] && printf '%s [DEBUG] %s\n' "$ts" "$msg" ;;
    *) printf '%s %s\n' "$ts" "$msg" ;;
  esac
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE"
}
log_info()  { if declare -F log_info >/dev/null 2>&1; then log_info "$@"; else _log_fallback INFO "$@"; fi; }
log_warn()  { if declare -F log_warn >/dev/null 2>&1; then log_warn "$@"; else _log_fallback WARN "$@"; fi; }
log_error() { if declare -F log_error >/dev/null 2>&1; then log_error "$@"; else _log_fallback ERROR "$@"; fi; }
log_debug() { if declare -F log_debug >/dev/null 2>&1; then log_debug "$@"; else _log_fallback DEBUG "$@"; fi; }

# run hooks in /etc/newpkg/hooks/remove/<hook>/*
run_hooks() {
  local hook="$1"; shift || true
  local dir="/etc/newpkg/hooks/remove/$hook"
  if [[ -d "$dir" ]]; then
    for s in "$dir"/*; do
      [[ -x "$s" ]] || continue
      if [[ $DRY_RUN -eq 1 ]]; then
        log_info "(dry-run) would run hook: $s $*"
      else
        log_info "Running hook: $s $*"
        "$s" "$@" || log_warn "Hook $s exited non-zero"
      fi
    done
  fi
}

# helper: acquire lockfile to prevent concurrent runs
_acquire_lock() {
  if [[ -e "$LOCKFILE" ]]; then
    local pid
    pid="$(cat "$LOCKFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log_error "Another remove.sh appears to be running (PID $pid). Aborting."
      exit 1
    else
      log_warn "Stale lockfile found; removing"
      rm -f "$LOCKFILE"
    fi
  fi
  printf '%s' "$$" > "$LOCKFILE"
  trap '_release_lock; exit' INT TERM EXIT
}
_release_lock() {
  rm -f "$LOCKFILE" 2>/dev/null || true
  trap - INT TERM EXIT
}

# parse config yaml for default parallel_jobs/auto_commit etc.
load_config() {
  if [[ -n "$YQ" && -f "$CONFIG_FILE" ]]; then
    local cfg_parallel
    cfg_parallel="$("$YQ" e '.remove.parallel_jobs // .core.parallel_jobs // '"$PARALLEL"'' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$cfg_parallel" && "$cfg_parallel" != "null" ]]; then PARALLEL="$cfg_parallel"; fi
    local acfg
    acfg="$("$YQ" e '.remove.auto_commit // .core.auto_commit // false' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ "$acfg" == "true" ]]; then AUTO_COMMIT_CFG=1; else AUTO_COMMIT_CFG=0; fi
  else
    AUTO_COMMIT_CFG=0
  fi
}

# protected list loader
load_protected() {
  PROTECTED=()
  if [[ -f "$PROTECTED_LIST" ]]; then
    while IFS= read -r l; do
      l="${l%%#*}"
      l="${l//[[:space:]]/}"
      [[ -z "$l" ]] && continue
      PROTECTED+=("$l")
    done < "$PROTECTED_LIST"
  fi
}

is_protected() {
  local pkg="$1"
  for p in "${PROTECTED[@]}"; do
    if [[ "$pkg" == "$p" ]]; then return 0; fi
  done
  return 1
}

# helper: query db.sh to confirm package installed and get version & manifest
db_query_manifest() {
  local pkg="$1"
  if [[ -x "$DB_CLI" ]]; then
    if out="$("$DB_CLI" query "$pkg" --json 2>/dev/null)"; then
      # db.sh query may return one or more JSON blocks; try to parse first object or array
      if [[ -n "$JQ" ]]; then
        echo "$out" | "$JQ" -c 'if type=="array" then .[0] else . end' 2>/dev/null || echo "$out"
      else
        echo "$out"
      fi
    else
      return 1
    fi
  else
    log_warn "db.sh not found; cannot query package $pkg"
    return 1
  fi
}

# use deps.py or db.sh to find revdeps
get_revdeps() {
  local pkg="$1"
  if [[ -x "$DEPS_PY" ]]; then
    # deps.py mark_for_rebuild prints dependents; but we have db.sh revdeps as fallback
    if out="$("$DEPS_PY" rebuild "$pkg" 2>/dev/null)"; then
      # deps.py rebuild prints one per line -> convert to newline list
      echo "$out" || true
      return 0
    fi
  fi
  if [[ -x "$DB_CLI" ]]; then
    "$DB_CLI" revdeps "$pkg" 2>/dev/null || true
    return 0
  fi
  return 1
}

# remove files listed in manifest (manifest format from db.sh)
# We expect manifests in /var/lib/newpkg/db/<pkg>-<ver>.json or db.sh can provide file list via "db.sh query <pkg> --field files"
remove_files_for_pkg() {
  local pkg="$1"
  local purge_flag="$2"  # "1" to purge /etc /var extras if available
  local dry="$3"
  # First try db.sh to list files
  if [[ -x "$DB_CLI" && -n "$JQ" ]]; then
    local files_json
    files_json="$("$DB_CLI" query "$pkg" --json 2>/dev/null || true)"
    if [[ -n "$files_json" ]]; then
      # try to extract files array
      local filelist
      filelist="$(echo "$files_json" | "$JQ" -r 'if type=="array" then .[0].files[]? else .files[]? end' 2>/dev/null || true)"
      if [[ -n "$filelist" ]]; then
        # iterate and remove
        while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          if [[ "$dry" -eq 1 ]]; then
            log_info "(dry-run) would remove file: $f"
          else
            if [[ -e "$f" ]]; then
              log_info "Removing file: $f"
              rm -rf -- "$f" || log_warn "Failed to remove $f"
            else
              log_debug "File not present: $f"
            fi
          fi
        done <<< "$filelist"
      else
        log_warn "db.sh returned no file list for $pkg"
      fi
    else
      log_warn "db.sh query failed for $pkg; cannot list files"
    fi
  else
    log_warn "db.sh or jq not available; cannot remove file list for $pkg automatically"
  fi

  # Purge: attempt to remove config/var leftovers
  if [[ "$purge_flag" -eq 1 ]]; then
    # Heuristics: remove /etc/<pkg>*, /var/lib/<pkg>*, /var/cache/<pkg>*
    local patterns=( "/etc/${pkg}" "/etc/${pkg}*" "/var/lib/${pkg}" "/var/lib/${pkg}*" "/var/cache/${pkg}" "/var/cache/${pkg}*" "/var/log/${pkg}*" )
    for pat in "${patterns[@]}"; do
      if [[ "$dry" -eq 1 ]]; then
        log_info "(dry-run) would purge pattern: $pat"
      else
        shopt -s nullglob
        for path in $pat; do
          log_info "Purging: $path"
          rm -rf -- "$path" || log_warn "Failed to purge $path"
        done
        shopt -u nullglob
      fi
    done
  fi
}

# backup manifest(s) for package to trash
backup_manifest_to_trash() {
  local pkg="$1"
  local ts
  ts="$(date -u +"%Y%m%dT%H%M%SZ")"
  # Move manifests matching pkg-*.json from DB_DIR to trash
  if [[ -d "$DB_DIR" ]]; then
    for f in "$DB_DIR"/${pkg}-*.json; do
      [[ -f "$f" ]] || continue
      if [[ $DRY_RUN -eq 1 ]]; then
        log_info "(dry-run) would move $f to $TRASH_DIR/${ts}-$(basename "$f")"
      else
        mv -f "$f" "$TRASH_DIR/${ts}-$(basename "$f")" || log_warn "Failed moving $f to trash"
      fi
    done
  fi
}

# Remove package: validate, confirm, remove files, update DB, call hooks
remove_one_package() {
  local pkg="$1"
  local dry="$2"       # 1 -> dry run
  local auto="$3"      # 1 -> non-interactive accept
  local force="$4"     # 1 -> force removal ignoring revdeps
  local purge_flag="$5"
  local ret=0

  log_info "Preparing removal for: $pkg"

  # Check installed and get version
  local manifest
  if ! manifest="$(db_query_manifest "$pkg" 2>/dev/null || true)"; then
    log_warn "Package $pkg not found in DB; skipping."
    return 1
  fi
  # attempt to get version
  local version
  if [[ -n "$JQ" && -n "$manifest" ]]; then
    version="$(echo "$manifest" | "$JQ" -r '.version // empty' 2>/dev/null || true)"
  fi
  [[ -z "$version" ]] && version="unknown"

  # Check protected
  if is_protected "$pkg" && [[ "$force" -ne 1 ]]; then
    log_warn "Package $pkg is protected; skipping removal."
    return 2
  fi

  # pre-remove hooks
  if [[ "$dry" -eq 1 ]]; then
    log_info "(dry-run) would run pre-remove hooks for $pkg"
  else
    run_hooks pre-remove "$pkg" "$version"
  fi

  # Check reverse-deps
  local revdeps
  revdeps="$(get_revdeps "$pkg" || true)"
  if [[ -n "$revdeps" ]]; then
    # revdeps output lines with names (might include versions). Show summarised list.
    local deps_count
    deps_count="$(echo "$revdeps" | wc -l || true)"
    if [[ "$deps_count" -gt 0 && "$force" -ne 1 ]]; then
      log_warn "Package $pkg has ${deps_count} reverse-dependency(ies):"
      echo "$revdeps" | sed 's/^/  - /'
      if [[ "$auto" -ne 1 ]]; then
        # interactive confirm
        read -r -p "Remove $pkg anyway? [y/N]: " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
          log_info "User aborted removal of $pkg due to reverse-deps"
          return 3
        fi
      else
        log_warn "--auto mode: proceeding to remove $pkg despite reverse-deps"
      fi
    fi
  fi

  # Backup manifest(s)
  backup_manifest_to_trash "$pkg"

  # Remove files
  remove_files_for_pkg "$pkg" "$purge_flag" "$dry"

  # Remove manifest from DB (use db.sh remove)
  if [[ "$dry" -eq 1 ]]; then
    log_info "(dry-run) would call db.sh remove $pkg --force"
  else
    if [[ -x "$DB_CLI" ]]; then
      if ! "$DB_CLI" remove "$pkg" --force; then
        log_warn "db.sh failed to remove package $pkg; continuing"
        ret=4
      else
        log_info "DB updated: removed $pkg"
      fi
    else
      log_warn "db.sh not available; manual DB cleanup needed for $pkg"
      ret=5
    fi
  fi

  # post-remove hooks
  if [[ "$dry" -eq 1 ]]; then
    log_info "(dry-run) would run post-remove hooks for $pkg"
  else
    run_hooks post-remove "$pkg" "$version"
  fi

  return $ret
}

# Save / load resume state
save_state() {
  local -a remaining=("${!1}"); local -a completed=("${!2}")
  mkdir -p "$(dirname "$STATE_FILE")"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would write state to $STATE_FILE"
    return 0
  fi
  # build JSON
  local json
  json="$(jq -n --argjson rem "$(printf '%s\n' "${remaining[@]}" | jq -R -s -c 'split("\n")[:-1]')" --argjson done "$(printf '%s\n' "${completed[@]}" | jq -R -s -c 'split("\n")[:-1]')" '{remaining:$rem, completed:$done}')"
  printf '%s\n' "$json" > "$STATE_FILE.tmp" && mv -f "$STATE_FILE.tmp" "$STATE_FILE"
  log_debug "Saved state to $STATE_FILE"
}
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    if [[ -n "$JQ" ]]; then
      mapfile -t remaining < <(jq -r '.remaining[]' "$STATE_FILE" 2>/dev/null || true)
      mapfile -t completed < <(jq -r '.completed[]' "$STATE_FILE" 2>/dev/null || true)
    else
      # naive parse
      remaining=()
      completed=()
    fi
    return 0
  else
    remaining=()
    completed=()
    return 1
  fi
}

# perform auto-commit once at the end (if enabled)
git_autocommit_final() {
  local -n pkgs_ref=$1
  # commit only once for all packages
  if [[ "$AUTO_COMMIT_CFG" -ne 1 && "$AUTO_COMMIT" -ne 1 ]]; then
    log_debug "Auto-commit not enabled"
    return 0
  fi
  if [[ -z "$GIT" ]]; then
    log_warn "git not found; cannot auto-commit"
    return 1
  fi
  if [[ ! -d "$PORTS_DIR/.git" ]]; then
    log_warn "$PORTS_DIR is not a git repo; skipping auto-commit"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would run git add -A and commit removed packages: ${pkgs_ref[*]}"
    return 0
  fi
  pushd "$PORTS_DIR" >/dev/null || return 1
  "$GIT" add -A || log_warn "git add failed"
  # build commit message
  local msg="Auto remove: ${pkgs_ref[*]} - $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if "$GIT" commit -m "$msg" >/dev/null 2>&1; then
    log_info "Created git commit for removals"
    # run git gc to prune
    "$GIT" gc --prune=now || log_warn "git gc failed"
  else
    log_info "No changes to commit"
  fi
  popd >/dev/null || true
  return 0
}

# cleanup old trash (older than 30 days)
cleanup_trash() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would cleanup trash older than 30 days in $TRASH_DIR"
    return 0
  fi
  find "$TRASH_DIR" -type f -mtime +30 -print -delete 2>/dev/null || true
  log_info "Old trash cleaned (older than 30 days)"
}

# show help
show_help() {
  cat <<'EOF'
remove.sh - newpkg package remover

Usage: remove.sh [options] <pkg> [pkg2 ...]

Options:
  --auto            no interactive prompts
  --force           ignore reverse-dependencies
  --purge           remove also config files under /etc and /var
  --dry-run         show actions without executing
  --resume          resume last interrupted removal
  --parallel N      set parallel jobs (default from config / nproc)
  --no-depclean     skip calling revdep_depclean.sh after removals
  --no-sync         skip deps.py sync after removals
  --quiet           minimal output
  --help
EOF
}

###########
# CLI parse
###########
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO=1; shift ;;
    --force) FORCE=1; shift ;;
    --purge) PURGE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --resume) RESUME=1; shift ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --no-depclean) NO_DEPCLEAN=1; shift ;;
    --no-sync) NO_SYNC=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --help|-h) show_help; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done; break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

# validations
if [[ ${#@} -eq 0 && "$RESUME" -eq 0 ]]; then
  log_error "No packages provided and --resume not specified. Nothing to do."
  show_help
  exit 1
fi

# load config & protected list & get lock
load_config
load_protected
_acquire_lock

# prepare list of packages to remove (possibly from state)
declare -a TODO=()
declare -a DONE=()

if [[ "$RESUME" -eq 1 ]]; then
  if load_state; then
    log_info "Resuming removal; loaded state: ${#remaining[@]} remaining, ${#completed[@]} completed"
    mapfile -t TODO <<< "${remaining[@]}"
    mapfile -t DONE <<< "${completed[@]}"
  else
    log_warn "No previous state found; nothing to resume"
    # if user supplied packages, proceed normally
    if [[ $# -gt 0 ]]; then
      TODO=( "$@" )
    else
      _release_lock
      exit 0
    fi
  fi
else
  TODO=( "$@" )
fi

# normalize package names (strip possible name-version to base name)
normalize_pkgname() {
  local p="$1"
  # if contains / treat as path and try to get base from manifest
  if [[ -f "$p" ]]; then
    # attempt to extract name from yaml
    if [[ -n "$YQ" ]]; then
      local n
      n="$("$YQ" e '.name // .package // .pkgname' "$p" 2>/dev/null || true)"
      [[ -n "$n" && "$n" != "null" ]] && echo "$n" && return 0
    fi
    echo "$(basename "$p")"
    return 0
  fi
  # otherwise strip -version portion if present (first hyphen delim)
  echo "${p%%-*}"
}

# expand TODO -> dedupe and map to base names (we will operate on base names)
declare -A seen
declare -a EXPANDED=()
for t in "${TODO[@]}"; do
  b="$(normalize_pkgname "$t")"
  if [[ -z "${seen[$b]:-}" ]]; then
    EXPANDED+=( "$b" )
    seen[$b]=1
  fi
done
TODO=( "${EXPANDED[@]}" )

if [[ "${#TODO[@]}" -eq 0 ]]; then
  log_info "No packages to remove after normalization."
  _release_lock
  exit 0
fi

log_info "Planned removals: ${TODO[*]} (parallel=$PARALLEL)"

# Process each pkg sequentially but do validation in parallel where possible
# We'll remove packages one-by-one to keep correctness; however pre-check (revdeps) can be parallelized.
# Pre-checks: revdeps for each package
log_info "Running pre-checks (revdeps) in parallel..."
if [[ -n "$XARGS" ]]; then
  # produce newline-separated pkgs
  printf '%s\0' "${TODO[@]}" > /tmp/newpkg_remove_list.null
  # helper function invoked per pkg
  _revdeps_helper() {
    local pkg="$1"
    local out
    out="$(get_revdeps "$pkg" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      printf '%s:REVIDS:%s\n' "$pkg" "$(echo "$out" | tr '\n' ',' | sed 's/,$//')"
    else
      printf '%s:REVIDS:\n' "$pkg"
    fi
  }
  # To avoid complicated inlining, iterate in shell loop (lightweight) because number of pkgs usually small
  # But still we can parallelize using xargs -P
  : > /tmp/newpkg_revdeps.out
  for pkg in "${TODO[@]}"; do
    (
      out="$(get_revdeps "$pkg" 2>/dev/null || true)"
      if [[ -n "$out" ]]; then
        printf '%s:REVIDS:%s\n' "$pkg" "$(echo "$out" | tr '\n' ',' | sed 's/,$//')"
      else
        printf '%s:REVIDS:\n' "$pkg"
      fi
    ) &
    # limit jobs to PARALLEL
    while (( $(jobs -r | wc -l) >= PARALLEL )); do sleep 0.1; done
  done
  wait
else
  for pkg in "${TODO[@]}"; do
    out="$(get_revdeps "$pkg" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      printf '%s:REVIDS:%s\n' "$pkg" "$(echo "$out" | tr '\n' ',' | sed 's/,$//')"
    else
      printf '%s:REVIDS:\n' "$pkg"
    fi
  done
fi

# Now iterate packages and remove sequentially (to keep commit semantics simple)
for pkg in "${TODO[@]}"; do
  # if already in DONE (resume), skip
  for d in "${DONE[@]}"; do [[ "$d" == "$pkg" ]] && { log_info "Skipping $pkg (already completed)"; continue 2; }; done

  # run removal
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would remove $pkg (purge=$PURGE)"
    DONE+=( "$pkg" )
    save_state TODO[@] DONE[@]
    continue
  fi

  # interactive confirm if not auto and not force
  if [[ "$AUTO" -ne 1 && "$FORCE" -ne 1 ]]; then
    read -r -p "Remove package $pkg? [y/N]: " svar
    if [[ ! "$svar" =~ ^[Yy] ]]; then
      log_info "User declined removal of $pkg"
      continue
    fi
  fi

  run_hooks pre-remove "$pkg"

  if ! remove_one_package "$pkg" 0 "$AUTO" "$FORCE" "$PURGE"; then
    log_error "Removal of $pkg returned non-zero; saving state and aborting"
    # Save TODO with remaining packages (including current if not done)
    # Build remaining list: current + remaining in TODO after this index
    idx_found=0
    remaining=()
    for x in "${TODO[@]}"; do
      if [[ "$idx_found" -eq 1 ]]; then
        remaining+=( "$x" )
      elif [[ "$x" == "$pkg" ]]; then
        # include current if not removed
        remaining+=( "$x" )
        idx_found=1
      fi
    done
    save_state remaining[@] DONE[@]
    _release_lock
    exit 2
  fi

  DONE+=( "$pkg" )
  # update state file
  save_state TODO[@] DONE[@]
done

# At this point, all requested packages processed
log_info "All requested removals processed: ${DONE[*]}"

# Final steps: revdep_depclean and deps.py sync (if not skipped)
if [[ "$NO_DEPCLEAN" -eq 0 ]]; then
  if [[ -x "$REVDEP" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "(dry-run) would run: $REVDEP --auto --auto-commit"
    else
      log_info "Running revdep_depclean.sh --auto --auto-commit"
      "$REVDEP" --auto --auto-commit || log_warn "revdep_depclean returned non-zero"
    fi
  else
    log_warn "revdep_depclean.sh not found; skipping"
  fi
fi

if [[ "$NO_SYNC" -eq 0 ]]; then
  if [[ -x "$DEPS_PY" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "(dry-run) would run: $DEPS_PY sync"
    else
      log_info "Running deps.py sync"
      "$DEPS_PY" sync || log_warn "deps.py sync failed"
    fi
  else
    log_warn "deps.py not found; skipping sync"
  fi
fi

# Auto-commit once at the end (if configured either by CLI or config)
AUTO_COMMIT=0
if [[ -n "$AUTO_COMMIT_CFG" && "$AUTO_COMMIT_CFG" -eq 1 ]]; then AUTO_COMMIT=1; fi
# allow --auto_commit via env or config in future (lefthook)
if [[ "$AUTO_COMMIT" -eq 1 || "$AUTO" -eq 1 ]]; then
  git_autocommit_final DONE
fi

# cleanup: remove state file
if [[ -f "$STATE_FILE" ]]; then rm -f "$STATE_FILE"; fi

# cleanup old trash
cleanup_trash

run_hooks post-remove "${DONE[*]}"

_release_lock
log_info "Removal run finished successfully."

exit 0
