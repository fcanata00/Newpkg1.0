#!/usr/bin/env bash
# sync.sh - synchronize /usr/ports (ports tree) and package cache for newpkg
# Features:
#  - sync multiple git repos (defined in /etc/newpkg/newpkg.yaml) in parallel (xargs -P)
#  - branch override, auto-commit info written to repo.meta
#  - cache sync (index.json + package files)
#  - hooks (pre-sync, post-sync, post-sync-repo, post-cache-sync)
#  - dry-run and quiet modes
# Dependencies: bash, git, yq, jq, xargs, tar, wget or curl, optionally gpg, log.sh (optional)
#
# Usage examples:
#   sync.sh all
#   sync.sh repo official --branch testing
#   sync.sh all --parallel 4 --dry-run
#   sync.sh cache
#   sync.sh status
#
set -o errexit
set -o nounset
set -o pipefail

###############
# Configuration
###############
: "${CONFIG_FILE:=/etc/newpkg/newpkg.yaml}"
: "${DEFAULT_PARALLEL:=2}"
: "${DEFAULT_CACHE_DIR:=/var/cache/newpkg/packages}"
: "${DEFAULT_PORTS_DIR:=/usr/ports}"
: "${NPKG_LOG_DIR:=/var/log/newpkg}"
: "${NPKG_HOOKS_DIR:=/etc/newpkg/hooks/sync}"

# Tools
YQ_BIN="$(command -v yq || true)"
GIT_BIN="$(command -v git || true)"
JQ_BIN="$(command -v jq || true)"
XARGS_BIN="$(command -v xargs || true)"
WGET_BIN="$(command -v wget || true)"
CURL_BIN="$(command -v curl || true)"
GPG_BIN="$(command -v gpg || true)"
TAR_BIN="$(command -v tar || true)"

# Verify required tools
if [[ -z "$YQ_BIN" ]]; then
  echo "ERROR: 'yq' required but not found." >&2
  exit 1
fi
if [[ -z "$GIT_BIN" ]]; then
  echo "ERROR: 'git' required but not found." >&2
  exit 1
fi
if [[ -z "$JQ_BIN" ]]; then
  echo "ERROR: 'jq' required but not found." >&2
  exit 1
fi
if [[ -z "$XARGS_BIN" ]]; then
  echo "ERROR: 'xargs' required but not found." >&2
  exit 1
fi

# try to source log.sh (optional)
if [[ -f "/usr/lib/newpkg/log.sh" ]]; then
  # shellcheck source=/usr/lib/newpkg/log.sh
  source /usr/lib/newpkg/log.sh || true
elif [[ -f "/etc/newpkg/log.sh" ]]; then
  # shellcheck source=/etc/newpkg/log.sh
  source /etc/newpkg/log.sh || true
fi

# fallback logging
_log() {
  local lvl="$1"; shift
  if declare -F log_info >/dev/null 2>&1 && [[ "$lvl" == "INFO" ]]; then
    log_info "$*" || true; return
  fi
  if declare -F log_warn >/dev/null 2>&1 && [[ "$lvl" == "WARN" ]]; then
    log_warn "$*" || true; return
  fi
  if declare -F log_error >/dev/null 2>&1 && [[ "$lvl" == "ERROR" ]]; then
    log_error "$*" || true; return
  fi
  case "$lvl" in
    INFO)  printf '[INFO] %s\n' "$*" ;;
    WARN)  printf '[WARN] %s\n' "$*" >&2 ;;
    ERROR) printf '[ERROR] %s\n' "$*" >&2 ;;
    DEBUG) [[ "${NPKG_DEBUG:-0}" -eq 1 ]] && printf '[DEBUG] %s\n' "$*" ;;
    *) printf '%s\n' "$*" ;;
  esac
}
log_info()  { _log INFO "$*"; }
log_warn()  { _log WARN "$*"; }
log_error() { _log ERROR "$*"; }
log_debug() { _log DEBUG "$*"; }

####################
# Global runtime vars
####################
DRY_RUN=0
QUIET=0
PARALLEL="$DEFAULT_PARALLEL"
BRANCH_OVERRIDE=""
ONLY_REPO=""     # name of single repo to sync
ONLY_CACHE=0
ONLY_REPOS=0

##############
# Helpers
##############
ensure_dir() { mkdir -p -- "$1"; }
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
canonicalize() {
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$1"
  else
    (cd "$(dirname "$1")" 2>/dev/null || pwd && printf '/%s\n' "$(basename "$1")")
  fi
}
run_hook_dir() {
  local hook="$1"; shift
  local d="$NPKG_HOOKS_DIR/$hook"
  if [[ -d "$d" ]]; then
    for s in "$d"/*; do
      [[ -x "$s" ]] || continue
      log_info "Running hook $s"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "(dry-run) would run hook $s"
      else
        "$s" "$@" || log_warn "hook $s exited non-zero"
      fi
    done
  fi
}

##############
# Config loader
##############
sync_load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_warn "Config file $CONFIG_FILE not found; using defaults."
    SYNC_REPOS=()
    SYNC_CACHE_ENABLE=0
    SYNC_CACHE_URL=""
    SYNC_CACHE_DIR="$DEFAULT_CACHE_DIR"
    return 0
  fi

  # parse repos array; each repo entry must have name, url, branch(optional), dest(optional)
  mapfile -t SYNC_REPOS < <(
    "$YQ_BIN" eval -o=json '.sync.repos[]? | {name: .name, url: .url, branch: (.branch // "main"), dest: (.dest // "'"$DEFAULT_PORTS_DIR"'") }' "$CONFIG_FILE" \
    | "$JQ_BIN" -c '.'
  ) || true

  # cache config
  SYNC_CACHE_ENABLE=$("$YQ_BIN" e '.sync.cache.enable // false' "$CONFIG_FILE")
  SYNC_CACHE_URL=$("$YQ_BIN" e '.sync.cache.url // ""' "$CONFIG_FILE")
  SYNC_CACHE_DIR=$("$YQ_BIN" e '.sync.cache.dest // "'"$DEFAULT_CACHE_DIR"'"' "$CONFIG_FILE")
  SYNC_PARALLEL_CFG=$("$YQ_BIN" e '.sync.parallel_jobs // '"$DEFAULT_PARALLEL"'' "$CONFIG_FILE")

  # gpg config
  SYNC_GPG_ENABLE=$("$YQ_BIN" e '.sync.gpg.enable // false' "$CONFIG_FILE")
  SYNC_GPG_KEYRING=$("$YQ_BIN" e '.sync.gpg.keyring // ""' "$CONFIG_FILE")

  # normalize values
  PARALLEL="${PARALLEL:-${SYNC_PARALLEL_CFG:-$DEFAULT_PARALLEL}}"
  ensure_dir "$SYNC_CACHE_DIR"
  ensure_dir "$NPKG_LOG_DIR"
}

# write repo.meta with commit info atomically
write_repo_meta() {
  local dest="$1"   # path to repo dir
  local name="$2"
  local url="$3"
  local branch="$4"
  local commit="$5"
  local file="${dest%/}/repo.meta"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would write repo.meta to $file"
    return 0
  fi
  printf 'repo=%s\nurl=%s\nbranch=%s\ncommit=%s\nupdated=%s\n' \
    "$name" "$url" "$branch" "$commit" "$(timestamp)" > "${file}.tmp" && mv -f "${file}.tmp" "$file"
}

# sync single repo by JSON entry (compact) or by name lookup
# args: repo-json-string (from SYNC_REPOS) OR repo-name when called manually
sync_repo_entry() {
  local repo_json="$1"
  local branch_arg="${2:-}"
  local repo
  repo="$(echo "$repo_json" | "$JQ_BIN" -r '.name')"
  local url
  url="$(echo "$repo_json" | "$JQ_BIN" -r '.url')"
  local branch_cfg
  branch_cfg="$(echo "$repo_json" | "$JQ_BIN" -r '.branch')"
  local dest
  dest="$(echo "$repo_json" | "$JQ_BIN" -r '.dest')"

  # allow CLI branch override
  local branch="${BRANCH_OVERRIDE:-${branch_arg:-$branch_cfg}}"
  dest="${dest:-$DEFAULT_PORTS_DIR}"

  log_info "Syncing repo '$repo' -> $dest (branch=$branch)"
  run_hook_dir pre-sync-repo "$repo" "$dest"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would ensure directory $dest and run git clone/pull"
    write_repo_meta "$dest" "$repo" "$url" "$branch" "DRYRUN"
    run_hook_dir post-sync-repo "$repo" "$dest"
    return 0
  fi

  # ensure parent directory exists
  ensure_dir "$dest"

  if [[ ! -d "$dest/.git" ]]; then
    log_info "Cloning $url into $dest"
    if [[ "$QUIET" -eq 1 ]]; then
      "$GIT_BIN" clone --branch "$branch" --depth 1 "$url" "$dest" >/dev/null 2>&1 || {
        log_error "Failed to clone $url"
        return 2
      }
    else
      "$GIT_BIN" clone --branch "$branch" --depth 1 "$url" "$dest" || {
        log_error "Failed to clone $url"
        return 2
      }
    fi
  else
    # fetch and reset to remote branch HEAD
    log_info "Fetching updates in $dest"
    pushd "$dest" >/dev/null || return 2
    if [[ "$QUIET" -eq 1 ]]; then
      "$GIT_BIN" fetch --all --prune >/dev/null 2>&1 || true
      "$GIT_BIN" reset --hard "origin/$branch" >/dev/null 2>&1 || true
    else
      "$GIT_BIN" fetch --all --prune || true
      "$GIT_BIN" reset --hard "origin/$branch" || true
    fi
    popd >/dev/null || true
  fi

  # get current commit
  local commit
  commit="$("$GIT_BIN" -C "$dest" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  write_repo_meta "$dest" "$repo" "$url" "$branch" "$commit"

  run_hook_dir post-sync-repo "$repo" "$dest"
  log_info "Repo '$repo' synchronized (commit: $commit)"
  return 0
}

# wrapper to call sync_repo_entry by name
sync_repo_by_name() {
  local name="$1"; shift
  local branch_arg="${1:-}"
  # find matching repo in SYNC_REPOS
  for r in "${SYNC_REPOS[@]}"; do
    local rn
    rn="$(echo "$r" | "$JQ_BIN" -r '.name')"
    if [[ "$rn" == "$name" ]]; then
      sync_repo_entry "$r" "$branch_arg"
      return
    fi
  done
  log_error "Repository named '$name' not found in config."
  return 2
}

# sync_all: parallelize using xargs -P
sync_all() {
  run_hook_dir pre-sync
  local repo_count="${#SYNC_REPOS[@]}"
  if [[ "$repo_count" -eq 0 ]]; then
    log_info "No repositories configured to sync."
  else
    log_info "Synchronizing $repo_count repos with parallel=$PARALLEL"
    # prepare list of JSON strings escaped (null-separated safer)
    local tmpfile
    tmpfile="$(mktemp)"
    for r in "${SYNC_REPOS[@]}"; do
      if [[ -n "$ONLY_REPO" && "$(echo "$r" | "$JQ_BIN" -r '.name')" != "$ONLY_REPO" ]]; then
        continue
      fi
      printf '%s\0' "$r" >>"$tmpfile"
    done

    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "(dry-run) Would sync repositories (list):"
      while IFS= read -r -d '' rec; do
        echo " - $(echo "$rec" | "$JQ_BIN" -r '.name') -> $(echo "$rec" | "$JQ_BIN" -r '.dest') (branch: $(echo "$rec" | "$JQ_BIN" -r '.branch'))"
      done <"$tmpfile"
    else
      # use xargs -0 -P to parallelize; each invocation calls a small bash -c wrapper
      cat "$tmpfile" | XARGS_BIN -0 -n1 -P "$PARALLEL" bash -c '
        rec="$0"
        # we need to source parent environment for DRY_RUN/QUIET/BRANCH_OVERRIDE
        sync_repo_entry() {
          # decode arguments: rec JSON is in $rec
          '"$(declare -f sync_repo_entry)"'
        }
        # re-export functions used (sync_repo_entry uses run_hook_dir/write_repo_meta which are defined outside)
        '"$(declare -f run_hook_dir)"'
        '"$(declare -f write_repo_meta)"'
        '"$(declare -f ensure_dir)"'
        '"$(declare -f timestamp)"'
        # set DRY_RUN and QUIET from exported env
        export DRY_RUN='"$DRY_RUN"'
        export QUIET='"$QUIET"'
        export BRANCH_OVERRIDE='"'"$BRANCH_OVERRIDE"'"'
        sync_repo_entry "$rec"
      ' _
    fi
    rm -f "$tmpfile" || true
  fi

  # cache sync optionally
  if [[ "$ONLY_CACHE" -eq 0 ]]; then
    log_info "Finished repo sync."
  fi

  run_hook_dir post-sync
}

# sync_cache: download index.json from cache URL and fetch missing packages
sync_cache() {
  if [[ "${SYNC_CACHE_ENABLE:-false}" != "true" && "${SYNC_CACHE_ENABLE:-0}" -ne 1 ]]; then
    log_info "Cache sync not enabled in configuration."
    return 0
  fi
  ensure_dir "$SYNC_CACHE_DIR"
  log_info "Syncing cache from $SYNC_CACHE_URL into $SYNC_CACHE_DIR"
  run_hook_dir pre-cache-sync

  local index_url
  index_url="${SYNC_CACHE_URL%/}/index.json"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) Would fetch index: $index_url"
  else
    # get index
    if [[ -n "$WGET_BIN" ]]; then
      if ! "$WGET_BIN" -q -O "$SYNC_CACHE_DIR/index.json.tmp" "$index_url"; then
        log_warn "Failed to download index.json from $index_url"
      else
        mv -f "$SYNC_CACHE_DIR/index.json.tmp" "$SYNC_CACHE_DIR/index.json"
      fi
    elif [[ -n "$CURL_BIN" ]]; then
      if ! "$CURL_BIN" -sSf -o "$SYNC_CACHE_DIR/index.json.tmp" "$index_url"; then
        log_warn "Failed to download index.json from $index_url"
      else
        mv -f "$SYNC_CACHE_DIR/index.json.tmp" "$SYNC_CACHE_DIR/index.json"
      fi
    else
      log_warn "No downloader available (wget or curl)"
    fi
  fi

  # if index exists, fetch packages listed
  if [[ -f "$SYNC_CACHE_DIR/index.json" ]]; then
    local pkgs
    pkgs="$(jq -r '.[] | @base64' "$SYNC_CACHE_DIR/index.json" 2>/dev/null || true)"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local entry
      entry="$(echo "$line" | base64 --decode)"
      local pkgfile url sum
      pkgfile="$(echo "$entry" | jq -r '.file')"
      url="$(echo "$entry" | jq -r '.url')"
      sum="$(echo "$entry" | jq -r '.sha256 // empty')"
      local dest="$SYNC_CACHE_DIR/$pkgfile"
      if [[ -f "$dest" ]]; then
        log_debug "Package $pkgfile already in cache"
        continue
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "(dry-run) would download $url -> $dest"
        continue
      fi
      log_info "Downloading $pkgfile"
      if [[ -n "$WGET_BIN" ]]; then
        "$WGET_BIN" -q -O "$dest.tmp" "$url" || { log_warn "Failed to download $url"; rm -f "$dest.tmp"; continue; }
      else
        "$CURL_BIN" -sSf -L "$url" -o "$dest.tmp" || { log_warn "Failed to download $url"; rm -f "$dest.tmp"; continue; }
      fi
      if [[ -n "$sum" && -n "$SHA256SUM_BIN" ]]; then
        local got
        got="$("$SHA256SUM_BIN" "$dest.tmp" | awk "{print \$1}")"
        if [[ "$got" != "$sum" ]]; then
          log_warn "Checksum mismatch for $pkgfile (expected $sum, got $got)"
          rm -f "$dest.tmp"
          continue
        fi
      fi
      mv -f "$dest.tmp" "$dest"
      log_info "Cached $pkgfile"
    done < <(jq -r '.[] | @base64' "$SYNC_CACHE_DIR/index.json")
  else
    log_warn "No index.json present in cache dir"
  fi

  run_hook_dir post-cache-sync
}

# verify: verify git repos/meta and optionally package signatures via gpg
sync_verify() {
  log_info "Verifying repositories and cache..."
  # verify each repo meta
  for r in "${SYNC_REPOS[@]}"; do
    local name dest
    name="$(echo "$r" | jq -r '.name')"
    dest="$(echo "$r" | jq -r '.dest')"
    if [[ -f "${dest}/repo.meta" ]]; then
      echo "Repo $name: $(cat "${dest}/repo.meta")"
    else
      log_warn "Repo meta missing for $name at $dest"
    fi
  done

  # verify cache signatures if enabled
  if [[ "${SYNC_GPG_ENABLE:-false}" == "true" ]]; then
    if [[ -z "$GPG_BIN" ]]; then
      log_warn "GPG verification enabled but gpg not found"
    else
      if [[ -n "$SYNC_CACHE_DIR" && -f "$SYNC_CACHE_DIR/index.json" ]]; then
        # for each entry, expect .sig or .asc present; attempt verify if signature present
        jq -c '.[]' "$SYNC_CACHE_DIR/index.json" | while IFS= read -r ent; do
          local f url sigfile pkgfile
          pkgfile="$(echo "$ent" | jq -r '.file')"
          sigfile="${SYNC_CACHE_DIR}/${pkgfile}.sig"
          if [[ -f "$SYNC_CACHE_DIR/$pkgfile" && -f "$sigfile" ]]; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
              log_info "(dry-run) would gpg --verify $sigfile $SYNC_CACHE_DIR/$pkgfile"
            else
              if ! "$GPG_BIN" --verify "$sigfile" "$SYNC_CACHE_DIR/$pkgfile" >/dev/null 2>&1; then
                log_warn "GPG verification failed for $pkgfile"
              else
                log_info "GPG OK: $pkgfile"
              fi
            fi
          fi
        done
      fi
    fi
  fi
}

# status: show summary
sync_status() {
  echo "Sync status (generated at $(timestamp))"
  for r in "${SYNC_REPOS[@]}"; do
    local name dest url branch commit updated
    name="$(echo "$r" | jq -r '.name')"
    url="$(echo "$r" | jq -r '.url')"
    dest="$(echo "$r" | jq -r '.dest')"
    branch="$(echo "$r" | jq -r '.branch')"
    if [[ -f "${dest}/repo.meta" ]]; then
      # parse repo.meta
      commit="$(grep '^commit=' "${dest}/repo.meta" 2>/dev/null | cut -d= -f2- || echo unknown)"
      updated="$(grep '^updated=' "${dest}/repo.meta" 2>/dev/null | cut -d= -f2- || echo unknown)"
    else
      commit="(no meta)"
      updated="(no meta)"
    fi
    printf "Repo: %-20s Branch: %-10s Commit: %-10s Updated: %s\n" "$name" "$branch" "$commit" "$updated"
  done

  if [[ -d "$SYNC_CACHE_DIR" ]]; then
    local cnt
    cnt="$(find "$SYNC_CACHE_DIR" -maxdepth 1 -type f -name '*.tar.zst' 2>/dev/null | wc -l || echo 0)"
    echo "Cache dir: $SYNC_CACHE_DIR  packages: $cnt"
  fi
}

# cleanup: optional reset/cleanup repos or cache
sync_cleanup() {
  run_hook_dir pre-cleanup
  log_info "Cleanup not implemented automatically; implement as needed."
  run_hook_dir post-cleanup
}

###################
# CLI & dispatch
###################
show_help() {
  cat <<'EOF'
sync.sh - synchronize ports and packages for newpkg

Usage: sync.sh <command> [options]

Commands:
  all                    Sync repos + cache (default)
  repos                  Sync repos only
  repo <name> [--branch BR]  Sync single repository (branch override)
  cache                  Sync cache only
  verify                 Verify repos and cache
  status                 Show sync status
  cleanup                Cleanup (hooks enabled)
  help

Global options:
  --parallel N           Number of parallel repo syncs (default from config)
  --branch BR            Override branch for repo operations
  --dry-run              Show actions without executing
  --quiet                Reduce console output (logs still written)
  --repo NAME            Limit sync_all to a single repo by name
EOF
}

# parse global args that may appear before command
if [[ $# -lt 1 ]]; then
  show_help
  exit 1
fi

# parse potential global flags located anywhere (simple approach)
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --parallel) PARALLEL="$2"; shift 2 ;;
    --branch) BRANCH_OVERRIDE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --repo) ONLY_REPO="$2"; shift 2 ;;
    --cache-only) ONLY_CACHE=1; shift ;;
    --repos-only) ONLY_REPOS=1; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# restore positional params to remaining ARGS
set -- "${ARGS[@]}"

# load config
sync_load_config

cmd="${1:-all}"; shift || true

case "$cmd" in
  all)
    if [[ "$ONLY_CACHE" -eq 1 ]]; then
      sync_cache
    elif [[ "$ONLY_REPOS" -eq 1 ]]; then
      sync_all
    else
      run_hook_dir pre-sync
      sync_all
      sync_cache
      run_hook_dir post-sync
    fi
    ;;
  repos)
    sync_all
    ;;
  repo)
    if [[ $# -lt 1 ]]; then echo "Usage: sync.sh repo <name> [--branch BR]"; exit 1; fi
    repo_name="$1"; shift || true
    # allow optional inline --branch
    local_branch=""
    if [[ $# -ge 2 && "$1" == "--branch" ]]; then
      local_branch="$2"; shift 2
    fi
    # find repo and call sync_repo_entry
    for r in "${SYNC_REPOS[@]}"; do
      if [[ "$(echo "$r" | jq -r '.name')" == "$repo_name" ]]; then
        sync_repo_entry "$r" "$local_branch"
        exit $?
      fi
    done
    log_error "Repo '$repo_name' not found in config"
    exit 2
    ;;
  cache)
    sync_cache
    ;;
  verify)
    sync_verify
    ;;
  status)
    sync_status
    ;;
  cleanup)
    sync_cleanup
    ;;
  help|-h)
    show_help
    ;;
  *)
    log_error "Unknown command: $cmd"
    show_help
    exit 1
    ;;
esac

exit 0
