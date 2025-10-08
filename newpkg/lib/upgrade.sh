#!/usr/bin/env bash
# upgrade.sh - orchestrator for package upgrades for newpkg
#
# Features:
#  - detect available newer versions in /usr/ports (metafiles)
#  - snapshot current package (tarball of installed files OR cached package) for rollback
#  - build & install new version via core.sh (in chroot) with resume/checkpoints
#  - rollback automatically by reinstalling previous snapshot on failure
#  - single git auto-commit at end with changelog of upgraded packages
#  - integrity checks (sha256sum before/after)
#  - detection & optional removal of orphan files (old files not present in new manifest)
#  - checkpointing and resume: refaz pacote que quebrou e continua
#  - extras: parallelism, checkpoint/resume, snapshot cleanup, auto-commit, integrity check, orphan detection
#
# Usage:
#   upgrade.sh [options] [pkg...]
#
# Options:
#   --all             upgrade all updatable packages
#   --resume          resume interrupted upgrade
#   --dry-run         simulate actions
#   --force           force rebuild even if same version
#   --quiet           minimal output
#   --auto            run non-interactively (assume yes)
#   --rollback        immediately restore latest snapshot (global rollback)
#   --no-commit       don't auto-commit in git
#   --no-revdep       skip revdep_depclean step
#   --no-sync         skip deps.py sync at end
#   --parallel N      set number of parallel jobs
#   --stage STAGE     stage: pass1, pass2, normal (affects target)
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
: "${PORTS_DIR:=/usr/ports}"
: "${DB_CLI:=/usr/lib/newpkg/db.sh}"
: "${CORE:=/usr/lib/newpkg/core.sh}"
: "${DEPS_PY:=/usr/lib/newpkg/deps.py}"
: "${SYNC:=/usr/lib/newpkg/sync.sh}"
: "${REVDEP:=/usr/lib/newpkg/revdep_depclean.sh}"
: "${SNAPSHOT_DIR:=/var/lib/newpkg/snapshots}"
: "${STATE_DIR:=/var/lib/newpkg/state}"
: "${STATE_FILE:=${STATE_DIR}/upgrade_state.json}"
: "${LOG_DIR:=/var/log/newpkg}"
: "${LOG_FILE:=${LOG_DIR}/upgrade.log}"
: "${LOCKFILE:=/tmp/newpkg-upgrade.lock}"
: "${CACHE_PKGS:=/var/cache/newpkg/packages}"
: "${DEFAULT_PARALLEL:=$(nproc)}"

# tools
YQ="$(command -v yq || true)"
JQ="$(command -v jq || true)"
GIT="$(command -v git || true)"
SHA256SUM="$(command -v sha256sum || true)"
XARGS="$(command -v xargs || true)"

# runtime flags
DRY_RUN=0
AUTO=0
FORCE=0
QUIET=0
RESUME=0
ROLLBACK=0
NO_COMMIT=0
NO_REVDEP=0
NO_SYNC=0
PARALLEL="${DEFAULT_PARALLEL}"
STAGE="normal"

# housekeeping dirs
mkdir -p "${SNAPSHOT_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${CACHE_PKGS}"

# logging helpers (try log.sh)
LOG_SH="/usr/lib/newpkg/log.sh"
if [[ -f "$LOG_SH" ]]; then
  # shellcheck source=/usr/lib/newpkg/log.sh
  source "$LOG_SH" || true
fi
_log_fallback() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
}
log_info()  { if declare -F log_info >/dev/null 2>&1; then log_info "$@"; else _log_fallback INFO "$@"; fi; }
log_warn()  { if declare -F log_warn >/dev/null 2>&1; then log_warn "$@"; else _log_fallback WARN "$@"; fi; }
log_error() { if declare -F log_error >/dev/null 2>&1; then log_error "$@"; else _log_fallback ERROR "$@"; fi; }
log_debug() { if declare -F log_debug >/dev/null 2>&1; then log_debug "$@"; else _log_fallback DEBUG "$@"; fi; }

# hooks directory
HOOKS_DIR="/etc/newpkg/hooks/upgrade"

run_hooks() {
  local hook=$1; shift || true
  local d="${HOOKS_DIR}/${hook}"
  if [[ -d "$d" ]]; then
    for s in "$d"/*; do
      [[ -x "$s" ]] || continue
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "(dry-run) would run hook: $s $*"
      else
        log_info "Running hook: $s $*"
        "$s" "$@" || log_warn "hook $s returned non-zero"
      fi
    done
  fi
}

_acquire_lock() {
  if [[ -e "$LOCKFILE" ]]; then
    local pid
    pid="$(cat "$LOCKFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log_error "Another upgrade process ($pid) is running. Aborting."
      exit 1
    else
      log_warn "Stale lockfile found, removing"
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

# read config (parallel_jobs, auto_commit)
load_config() {
  if [[ -n "$YQ" && -f "$CONFIG_FILE" ]]; then
    local cfg_parallel
    cfg_parallel="$("$YQ" e '.upgrade.parallel_jobs // .core.parallel_jobs // '"$PARALLEL"'' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$cfg_parallel" && "$cfg_parallel" != "null" ]]; then PARALLEL="$cfg_parallel"; fi
    local acfg
    acfg="$("$YQ" e '.upgrade.auto_commit // .core.auto_commit // false' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ "$acfg" == "true" ]]; then AUTO_COMMIT_CFG=1; else AUTO_COMMIT_CFG=0; fi
    local keep_snap
    keep_snap="$("$YQ" e '.upgrade.keep_snapshots_days // 30' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$keep_snap" && "$keep_snap" != "null" ]]; then KEEP_SNAP_DAYS="$keep_snap"; else KEEP_SNAP_DAYS=30; fi
  else
    AUTO_COMMIT_CFG=0
    KEEP_SNAP_DAYS=30
  fi
}

# state functions (checkpoint/resume)
save_state() {
  local -n st="$1"
  mkdir -p "$(dirname "$STATE_FILE")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would save state to $STATE_FILE"
    return 0
  fi
  echo "$st" | jq '.' > "${STATE_FILE}.tmp" && mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
  log_debug "Saved state to $STATE_FILE"
}
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
    return 0
  fi
  return 1
}
clear_state() {
  rm -f "$STATE_FILE" 2>/dev/null || true
}

# helper: find metafile for a package under /usr/ports
find_metafile() {
  local pkg="$1"
  # fast heuristic: search for files with name/version fields matching pkg
  # Prefer meta.yaml or package.yaml
  local found
  found="$(find "$PORTS_DIR" -maxdepth 4 -type f \( -iname 'meta.yaml' -o -iname 'meta.yml' -o -iname 'package.yaml' -o -iname '*.yaml' \) -exec grep -l -E "^name:.*${pkg}\$|package:.*${pkg}\$" {} + 2>/dev/null | head -n1 || true)"
  if [[ -n "$found" ]]; then
    printf '%s' "$found"
    return 0
  fi
  # fallback: look for directory named pkg
  found="$(find "$PORTS_DIR" -type d -name "$pkg" -print -quit 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    # prefer meta.yaml inside
    if [[ -f "$found/meta.yaml" ]]; then
      printf '%s' "$found/meta.yaml"; return 0
    fi
  fi
  return 1
}

# helper: get installed version from db.sh
installed_version() {
  local pkg="$1"
  if [[ -x "$DB_CLI" ]]; then
    local out
    out="$("$DB_CLI" query "$pkg" --json 2>/dev/null || true)"
    if [[ -n "$out" && -n "$JQ" ]]; then
      echo "$out" | jq -r 'if type=="array" then .[0].version else .version end' 2>/dev/null || echo ""
      return 0
    fi
  fi
  echo ""
  return 0
}

# helper: get version from metafile
metafile_version() {
  local mf="$1"
  if [[ -n "$YQ" && -f "$mf" ]]; then
    "$YQ" e '.version // ""' "$mf" 2>/dev/null || echo ""
    return 0
  fi
  echo ""
  return 0
}

# snapshot functions
snapshot_create_for_pkg() {
  local pkg="$1"
  local installed_ver
  installed_ver="$(installed_version "$pkg" || true)"
  local ts
  ts="$(date -u +"%Y%m%dT%H%M%SZ")"
  local snapdir="${SNAPSHOT_DIR}/${pkg}-${installed_ver}-${ts}"
  mkdir -p "$snapdir"
  log_info "Creating snapshot for $pkg (version ${installed_ver:-unknown}) -> $snapdir"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would create snapshot dir $snapdir"
    echo "$snapdir"
    return 0
  fi

  # 1) try to find cached package tarball
  local pkgfile
  pkgfile="$(ls -1 "${CACHE_PKGS}/${pkg}-"* 2>/dev/null | head -n1 || true)"
  if [[ -n "$pkgfile" ]]; then
    cp -a "$pkgfile" "${snapdir}/package.tar" || cp -a "$pkgfile" "${snapdir}/package.tar.zst" || true
  else
    # 2) try to create tarball from files listed in DB manifest
    if [[ -x "$DB_CLI" && -n "$JQ" ]]; then
      local files_json
      files_json="$("$DB_CLI" query "$pkg" --json 2>/dev/null || true)"
      if [[ -n "$files_json" ]]; then
        local files
        files="$(echo "$files_json" | jq -r 'if type=="array" then .[0].files[]? else .files[]? end' 2>/dev/null || true)"
        # create tar with those files if any
        if [[ -n "$files" ]]; then
          (cd /; tar -cf - $(echo "$files" | sed 's/^\.//') ) | (command -v zstd >/dev/null 2>&1 && zstd -q -o "${snapdir}/package.tar.zst" || cat > "${snapdir}/package.tar") || true
        fi
        # also save manifest
        echo "$files_json" > "${snapdir}/manifest.json"
      fi
    fi
  fi

  # write metadata
  echo "{\"package\":\"${pkg}\",\"version\":\"${installed_ver}\",\"timestamp\":\"${ts}\"}" > "${snapdir}/metadata.json"
  # compute sha256 of package if file present
  if [[ -f "${snapdir}/package.tar.zst" && -n "$SHA256SUM" ]]; then
    (cd "$snapdir" && "$SHA256SUM" package.tar.zst > sha256.sum) || true
  elif [[ -f "${snapdir}/package.tar" && -n "$SHA256SUM" ]]; then
    (cd "$snapdir" && "$SHA256SUM" package.tar > sha256.sum) || true
  fi
  log_info "Snapshot created: $snapdir"
  echo "$snapdir"
}

snapshot_restore_for_pkg() {
  local snapdir="$1"
  local stage="$2"
  if [[ ! -d "$snapdir" ]]; then
    log_warn "Snapshot dir not found: $snapdir"
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would restore snapshot from $snapdir (stage=$stage)"
    return 0
  fi
  # restore package tarball into target (normal => / ; pass1/pass2 => /mnt/lfs)
  local target="/"
  if [[ "$stage" != "normal" ]]; then
    target="/mnt/lfs"
    mkdir -p "$target"
  fi
  # find package archive
  if [[ -f "${snapdir}/package.tar.zst" ]]; then
    if command -v zstd >/dev/null 2>&1; then
      log_info "Restoring package from ${snapdir}/package.tar.zst to $target"
      zstd -d -c "${snapdir}/package.tar.zst" | tar -C "$target" -xf - || log_warn "Failed to extract snapshot archive"
    else
      log_warn "zstd not available; cannot restore ${snapdir}/package.tar.zst"
      return 1
    fi
  elif [[ -f "${snapdir}/package.tar" ]]; then
    log_info "Restoring package from ${snapdir}/package.tar to $target"
    tar -C "$target" -xf "${snapdir}/package.tar" || log_warn "Failed to extract snapshot archive"
  else
    log_warn "No package archive in snapshot to restore"
    return 1
  fi
  # restore DB manifest if any
  if [[ -f "${snapdir}/manifest.json" && -x "$DB_CLI" ]]; then
    log_info "Restoring DB manifest from snapshot"
    "$DB_CLI" add "${snapdir}/manifest.json" --replace || log_warn "db.sh add failed during snapshot restore"
  fi
  return 0
}

# helper: compute sha256 of installed package files via manifest
compute_manifest_sha256() {
  local pkg="$1"
  if [[ -x "$DB_CLI" && -n "$JQ" && -n "$SHA256SUM" ]]; then
    local files_json
    files_json="$("$DB_CLI" query "$pkg" --json 2>/dev/null || true)"
    if [[ -n "$files_json" ]]; then
      local files
      files="$(echo "$files_json" | jq -r 'if type=="array" then .[0].files[]? else .files[]? end' 2>/dev/null || true)"
      # produce combined sha256: hash of concatenated file checksums
      local tmp
      tmp="$(mktemp)"
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ -f "$f" ]]; then
          "$SHA256SUM" "$f" >> "$tmp" || true
        fi
      done <<< "$files"
      sort "$tmp" | "$SHA256SUM" | awk '{print $1}' || { rm -f "$tmp"; echo ""; return 1; }
      rm -f "$tmp"
    fi
  fi
  echo ""
  return 0
}

# find upgrades: compare installed_version with ports metafile version
find_upgrades_for_pkgs() {
  local -a pkgs=("$@")
  local -a todo=()
  for p in "${pkgs[@]}"; do
    local mf
    mf="$(find_metafile "$p" 2>/dev/null || true)"
    if [[ -z "$mf" ]]; then
      log_warn "Metafile for $p not found; skipping"
      continue
    fi
    local newv
    newv="$(metafile_version "$mf")"
    local oldv
    oldv="$(installed_version "$p")"
    if [[ -z "$oldv" ]]; then
      log_info "$p is not installed; scheduling install"
      todo+=( "$p" )
      continue
    fi
    if [[ "$FORCE" -eq 1 || -z "$oldv" || -z "$newv" || "$newv" != "$oldv" ]]; then
      log_info "Upgrade available: $p $oldv -> $newv"
      todo+=( "$p" )
    else
      log_info "No new version for $p (installed $oldv, ports $newv)"
    fi
  done
  printf '%s\n' "${todo[@]}"
}

# detect all updatable packages in ports (naive approach: for each installed package check ports)
find_all_upgrades() {
  local installed_list
  installed_list="$("$DB_CLI" list --json 2>/dev/null || true)"
  if [[ -z "$installed_list" ]]; then
    log_warn "db.sh list returned nothing; cannot detect upgrades"
    return 1
  fi
  local pkgs
  pkgs="$(echo "$installed_list" | jq -r '.[] | .name' 2>/dev/null || true)"
  local -a upgrades=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    local mf
    mf="$(find_metafile "$p" 2>/dev/null || true)"
    if [[ -z "$mf" ]]; then continue; fi
    local newv
    newv="$(metafile_version "$mf")"
    local oldv
    oldv="$(installed_version "$p")"
    if [[ -z "$oldv" || -z "$newv" ]]; then continue; fi
    if [[ "$newv" != "$oldv" ]]; then upgrades+=( "$p" ); fi
  done <<< "$pkgs"
  printf '%s\n' "${upgrades[@]}"
}

# remove old snapshots older than KEEP_SNAP_DAYS
prune_old_snapshots() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would prune snapshots older than ${KEEP_SNAP_DAYS} days in $SNAPSHOT_DIR"
    return 0
  fi
  find "$SNAPSHOT_DIR" -maxdepth 1 -type d -mtime +"${KEEP_SNAP_DAYS}" -print -exec rm -rf {} \; 2>/dev/null || true
  log_info "Pruned snapshots older than ${KEEP_SNAP_DAYS} days"
}

# upgrade single package: create snapshot, build+install new version, verify, handle rollback on failure
upgrade_one_pkg() {
  local pkg="$1"
  local mf
  mf="$(find_metafile "$pkg" 2>/dev/null || true)"
  if [[ -z "$mf" ]]; then
    log_warn "Metafile not found for $pkg; skipping"
    return 1
  fi
  local newv
  newv="$(metafile_version "$mf")"
  local oldv
  oldv="$(installed_version "$pkg")"
  log_info "Upgrading $pkg: ${oldv:-<not-installed>} -> ${newv:-<unknown>}"

  # pre-upgrade hook
  run_hooks pre-upgrade "$pkg" "$oldv" "$newv"

  # snapshot current state
  local snapdir
  snapdir="$(snapshot_create_for_pkg "$pkg" || true)"
  if [[ -z "$snapdir" ]]; then
    log_warn "Snapshot creation failed for $pkg; continuing without snapshot"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would build and install $pkg (new ver: $newv)"
    run_hooks post-upgrade "$pkg" "$oldv" "$newv"
    return 0
  fi

  # call core.sh to build & install; prefer core.sh install which handles deps and DESTDIR logic
  if [[ -x "$CORE" ]]; then
    # use stage if provided: pass as env var CORE_STAGE
    CORE_STAGE="$STAGE" "$CORE" install "$mf"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      log_error "core.sh failed for $pkg (rc=$rc). Attempting rollback."
      if [[ -n "$snapdir" ]]; then
        snapshot_restore_for_pkg "$snapdir" "$STAGE" || log_warn "Snapshot restore failed for $pkg"
      fi
      run_hooks upgrade-failed "$pkg" "$oldv" "$newv"
      return 2
    fi
  else
    log_error "core.sh not found at $CORE; cannot build/install $pkg"
    # attempt rollback immediately if snapshot present
    if [[ -n "$snapdir" ]]; then snapshot_restore_for_pkg "$snapdir" "$STAGE" || true; fi
    return 3
  fi

  # post-install: verify integrity: compute sha256 of manifest files before and after; if mismatch, warn
  if [[ -n "$SHA256SUM" && -x "$DB_CLI" && -n "$JQ" ]]; then
    local before_sha after_sha
    before_sha="$( ( [[ -n "$snapdir" ]] && [[ -f "${snapdir}/sha256.sum" ]] && awk '{print $1}' "${snapdir}/sha256.sum" ) || true )"
    after_sha="$(compute_manifest_sha256 "$pkg" || true)"
    if [[ -n "$before_sha" && -n "$after_sha" && "$before_sha" != "$after_sha" ]]; then
      log_warn "Integrity: sha256 before/after differ for $pkg (before:$before_sha after:$after_sha)"
      # not necessarily fatal: files may legitimately change between versions
    fi
  fi

  # call post-upgrade hooks
  run_hooks post-upgrade "$pkg" "$oldv" "$newv"

  return 0
}

# after a set of upgrades: run revdep & deps sync & remove orphan files (optionally)
post_upgrades_finalize() {
  local -n upgraded_pkgs_ref="$1"
  # revdep/depclean
  if [[ "$NO_REVDEP" -eq 0 && -x "$REVDEP" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "(dry-run) would run revdep_depclean.sh --auto --auto-commit"
    else
      "$REVDEP" --auto --auto-commit || log_warn "revdep_depclean returned non-zero"
    fi
  fi

  # deps.py sync
  if [[ "$NO_SYNC" -eq 0 && -x "$DEPS_PY" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "(dry-run) would run deps.py sync"
    else
      "$DEPS_PY" sync || log_warn "deps.py sync returned non-zero"
    fi
  fi

  # orphan detection & removal: for each upgraded package, compare old manifest files vs new manifest; remove files not present in new manifest
  for pkg in "${upgraded_pkgs_ref[@]}"; do
    # try to locate latest snapshot for pkg -> previous manifest
    local latest_snap
    latest_snap="$(ls -1d "${SNAPSHOT_DIR}/${pkg}-"* 2>/dev/null | sort -r | head -n1 || true)"
    if [[ -z "$latest_snap" ]]; then
      log_debug "No snapshot for $pkg; skipping orphan detection"
      continue
    fi
    # get old file list
    local old_files new_files
    if [[ -f "${latest_snap}/manifest.json" && -n "$JQ" ]]; then
      old_files="$(jq -r 'if type=="array" then .[0].files[]? else .files[]? end' "${latest_snap}/manifest.json" 2>/dev/null || true)"
    fi
    # new files from db
    if [[ -x "$DB_CLI" && -n "$JQ" ]]; then
      local new_json
      new_json="$("$DB_CLI" query "$pkg" --json 2>/dev/null || true)"
      new_files="$(echo "$new_json" | jq -r 'if type=="array" then .[0].files[]? else .files[]? end' 2>/dev/null || true)"
    fi
    # compute orphans = old_files - new_files
    if [[ -n "$old_files" ]]; then
      local orphans
      orphans="$(comm -23 <(echo "$old_files" | sort) <(echo "$new_files" | sort) || true)"
      if [[ -n "$orphans" ]]; then
        log_info "Detected orphan files for $pkg (old files not present in new manifest):"
        echo "$orphans" | sed 's/^/  - /'
        if [[ "$AUTO" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
          # auto remove or dry-run listing
          if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "(dry-run) would remove orphan files for $pkg"
          else
            while IFS= read -r f; do
              if [[ -n "$f" && -f "$f" ]]; then
                log_info "Removing orphan: $f"
                rm -f -- "$f" || log_warn "Failed to remove orphan $f"
              fi
            done <<< "$orphans"
          fi
        else
          # interactive prompt
          read -r -p "Remove orphan files for $pkg? [y/N]: " ans
          if [[ "$ans" =~ ^[Yy] ]]; then
            while IFS= read -r f; do
              [[ -n "$f" && -f "$f" ]] && rm -f -- "$f" || true
            done <<< "$orphans"
          else
            log_info "Skipping orphan removal for $pkg"
          fi
        fi
      fi
    fi
  done
}

# Git commit with changelog summarizing upgraded packages
git_commit_summary() {
  local -n pkgs_ref="$1"
  if [[ "$NO_COMMIT" -eq 1 && "$AUTO_COMMIT_CFG" -eq 0 ]]; then
    log_debug "Git commit disabled"
    return 0
  fi
  if [[ -z "$GIT" ]]; then
    log_warn "git not found; skipping commit"
    return 1
  fi
  if [[ ! -d "$PORTS_DIR/.git" ]]; then
    log_warn "$PORTS_DIR is not a git repo; skipping commit"
    return 0
  fi
  local msg="Auto-upgrade: "
  msg+="Upgraded: $(IFS=,; echo "${pkgs_ref[*]}") - $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would run git add -A && git commit -m \"$msg\""
    return 0
  fi
  pushd "$PORTS_DIR" >/dev/null || return 1
  "$GIT" add -A || log_warn "git add failed"
  if "$GIT" commit -m "$msg" >/dev/null 2>&1; then
    log_info "Committed upgrades to git"
    "$GIT" gc --prune=now || log_warn "git gc failed"
  else
    log_info "No changes to commit"
  fi
  popd >/dev/null || true
  return 0
}

# CLI parsing
show_help() {
  cat <<'EOF'
upgrade.sh - newpkg upgrade orchestrator

Usage: upgrade.sh [options] [pkg1 pkg2 ...]

Options:
  --all            upgrade all available packages
  --resume         resume interrupted upgrade
  --dry-run        simulate
  --force          force rebuild
  --quiet
  --auto           non-interactive (accept prompts)
  --rollback       restore latest snapshot (global)
  --no-commit      skip git commit
  --no-revdep      skip revdep/depclean after upgrades
  --no-sync        skip deps.py sync after upgrades
  --parallel N     parallel jobs
  --stage STAGE    pass1|pass2|normal
  --help
EOF
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --resume) RESUME=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --auto) AUTO=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --no-commit) NO_COMMIT=1; shift ;;
    --no-revdep) NO_REVDEP=1; shift ;;
    --no-sync) NO_SYNC=1; shift ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --help|-h) show_help; exit 0 ;;
    *) ARGS+=( "$1" ); shift ;;
  esac
done

set -- "${ARGS[@]}"

load_config
_acquire_lock

if [[ "${ROLLBACK:-0}" -eq 1 ]]; then
  # restore latest snapshot for all packages? we'll ask for package or restore last global snapshot if single
  # find most recent snapshot directory
  latest="$(ls -1dt ${SNAPSHOT_DIR}/* 2>/dev/null | head -n1 || true)"
  if [[ -z "$latest" ]]; then
    log_error "No snapshots found to rollback"
    _release_lock
    exit 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would restore snapshot $latest"
    _release_lock
    exit 0
  fi
  log_info "Restoring snapshot: $latest"
  snapshot_restore_for_pkg "$latest" "$STAGE" || log_warn "Snapshot restore returned non-zero"
  _release_lock
  exit 0
fi

# determine packages to upgrade
declare -a PKGS_TO_UPGRADE=()
if [[ "${RESUME:-0}" -eq 1 ]]; then
  if load_state >/dev/null 2>&1; then
    statejson="$(load_state)"
    # parse remaining and current_failed to resume; expecting fields: remaining, completed, failed_current
    PKGS_TO_UPGRADE=( $(echo "$statejson" | jq -r '.remaining[]?') )
    RETRY_FROM="$(echo "$statejson" | jq -r '.failed_current // ""')"
    if [[ -n "$RETRY_FROM" ]]; then
      # ensure the failed package is first (we need to refazer)
      PKGS_TO_UPGRADE=( "$RETRY_FROM" "${PKGS_TO_UPGRADE[@]}" )
    fi
    log_info "Resuming upgrade; pending packages: ${PKGS_TO_UPGRADE[*]}"
  else
    log_warn "No state file to resume from"
  fi
elif [[ "${ALL:-0}" -eq 1 ]]; then
  if [[ -x "$DB_CLI" ]]; then
    mapfile -t PKGS_TO_UPGRADE < <(find_all_upgrades)
  else
    log_error "db.sh required to detect all upgrades"
    _release_lock
    exit 1
  fi
elif [[ $# -gt 0 ]]; then
  # user supplied package list
  # expand each to name only (strip version)
  for p in "$@"; do
    PKGS_TO_UPGRADE+=( "$(basename "$p" | cut -d- -f1)" )
  done
else
  log_error "No packages specified. Use --all or list package names."
  _release_lock
  exit 1
fi

if [[ "${#PKGS_TO_UPGRADE[@]}" -eq 0 ]]; then
  log_info "No packages to upgrade."
  _release_lock
  exit 0
fi

# quick preview
log_info "Packages to upgrade: ${PKGS_TO_UPGRADE[*]}"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log_info "(dry-run) preview complete"
  _release_lock
  exit 0
fi

# prepare state structure
declare -a REMAINING=("${PKGS_TO_UPGRADE[@]}")
declare -a COMPLETED=()
CURRENT_FAILED=""

# iterate packages
for pkg in "${PKGS_TO_UPGRADE[@]}"; do
  log_info "Starting upgrade for $pkg"
  # save state before processing
  state_json="$(jq -n --argjson rem "$(printf '%s\n' "${REMAINING[@]}" | jq -R -s -c 'split("\n")[:-1]')" --argjson done "$(printf '%s\n' "${COMPLETED[@]}" | jq -R -s -c 'split("\n")[:-1]')" --arg failed "$CURRENT_FAILED" '{remaining:$rem,completed:$done,failed_current:$failed}')"
  save_state state_json

  # attempt upgrade
  if upgrade_one_pkg "$pkg"; then
    log_info "Upgrade succeeded for $pkg"
    COMPLETED+=( "$pkg" )
    # remove first element from REMAINING
    REMAINING=( "${REMAINING[@]:1}" )
    CURRENT_FAILED=""
    # save state
    state_json="$(jq -n --argjson rem "$(printf '%s\n' "${REMAINING[@]}" | jq -R -s -c 'split("\n")[:-1]')" --argjson done "$(printf '%s\n' "${COMPLETED[@]}" | jq -R -s -c 'split("\n")[:-1]')" --arg failed "$CURRENT_FAILED" '{remaining:$rem,completed:$done,failed_current:$failed}')"
    save_state state_json
    continue
  else
    log_error "Upgrade failed for $pkg"
    # record failed_current and save state; resume should refazer pkg
    CURRENT_FAILED="$pkg"
    state_json="$(jq -n --argjson rem "$(printf '%s\n' "${REMAINING[@]}" | jq -R -s -c 'split("\n")[:-1]')" --argjson done "$(printf '%s\n' "${COMPLETED[@]}" | jq -R -s -c 'split("\n")[:-1]')" --arg failed "$CURRENT_FAILED" '{remaining:$rem,completed:$done,failed_current:$failed}')"
    save_state state_json
    # behavior: refazer the failed package when resuming (so exit now)
    log_warn "Exiting due to failure. Run --resume to retry (the failed package will be retried first)."
    _release_lock
    exit 2
  fi
done

# all packages processed successfully
log_info "All upgrades completed: ${COMPLETED[*]}"

# finalize: prune snapshots older than KEEP_SNAP_DAYS
prune_old_snapshots

# run post-upgrade finalize: revdep & deps sync & orphan cleanup
post_upgrades_finalize COMPLETED

# auto-commit summary once at the end if configured
if [[ "$NO_COMMIT" -eq 0 && ( "$AUTO_COMMIT_CFG" -eq 1 || "$AUTO" -eq 1 ) ]]; then
  git_commit_summary COMPLETED
fi

# clear state
clear_state

_release_lock
log_info "Upgrade run finished successfully."
exit 0
