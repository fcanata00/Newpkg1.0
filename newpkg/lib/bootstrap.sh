#!/usr/bin/env bash
# bootstrap.sh - build and maintain LFS/BLFS bootstrap toolchain stages for newpkg
#
# Purpose:
#  - prepare /mnt/lfs environment, create lfs user and LFS shell init files per LFS book (Chapter 4.4)
#  - mount/unmount chroot safely and copy resolv.conf for networking
#  - run stages (pass1, pass2, final, BLFS) defined as YAML files
#  - snapshot each stage (incremental), support pruning
#  - support resume (checkpoints) and --clean-stage to wipe and rebuild a stage
#  - support .env per package, and hooks pre/post stage and pre/post package
#  - integrate with core.sh (calls core.sh install <metafile>)
#
# Requirements: bash, yq, jq, core.sh accessible, tar, zstd (for snapshot), sudo/useradd privileges
# LFS reference for environment settings: Chapter "Setting Up the Environment". 1
#
set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

###########################
# Defaults & configuration
###########################
: "${LFS_ROOT:=/mnt/lfs}"
: "${STAGES_DIR:=/usr/lib/newpkg/bootstrap/stages}"    # where stage YAMLs live
: "${SNAPSHOT_DIR:=/var/lib/newpkg/bootstrap/snapshots}"
: "${STATE_DIR:=/var/lib/newpkg/bootstrap/state}"
: "${LOG_DIR:=/var/log/newpkg/bootstrap}"
: "${HOOKS_DIR:=/etc/newpkg/hooks/bootstrap}"
: "${CORE_SH:=/usr/lib/newpkg/core.sh}"
: "${PARALLEL:=$(nproc)}"
: "${KEEP_SNAP_DAYS:=30}"

# Tools
YQ="$(command -v yq || true)"
JQ="$(command -v jq || true)"
TAR="$(command -v tar || true)"
ZSTD="$(command -v zstd || true)"
USERADD="$(command -v useradd || true)"
GROUPADD="$(command -v groupadd || true)"
ID_BIN="$(command -v id || true)"

# runtime flags
DRY_RUN=0
QUIET=0
PREPARE_ONLY=0
RUN_STAGE=""
RUN_ALL=0
RESUME=0
CLEAN_STAGE=0
CREATE_TARBALL=0

# ensure dirs exist
mkdir -p -- "$SNAPSHOT_DIR" "$STATE_DIR" "$LOG_DIR"
mkdir -p -- "$STAGES_DIR"           # allow stage files to be placed here

# logging
log() { printf '%s [bootstrap] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }
log_info() { [[ $QUIET -eq 0 ]] && log "INFO: $*"; printf '%s [INFO] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >> "$LOG_DIR/bootstrap.log"; }
log_warn() { log "WARN: $*"; printf '%s [WARN] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >> "$LOG_DIR/bootstrap.log"; }
log_err()  { log "ERROR: $*"; printf '%s [ERROR] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >> "$LOG_DIR/bootstrap.log"; }

###########################
# Helpers
###########################
timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }

# safe run: respect dry-run
sr() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) $*"
  else
    eval "$@"
  fi
}

# safe mkdir with ownership & mode
safe_mkdir() {
  local dir="$1"; local owner="$2"; local mode="${3:-0755}"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) mkdir -p $dir && chown $owner && chmod $mode"
  else
    mkdir -p -- "$dir"
    chown -R "$owner" "$dir" || true
    chmod "$mode" "$dir" || true
  fi
}

###########################
# LFS environment files (per LFS book)
# Create ~/.bash_profile and ~/.bashrc for user lfs (Chapter 4.4)
# See LFS: "Setting Up the Environment". 2
###########################
create_lfs_user_env() {
  local lfs_home="$LFS_ROOT/home/lfs"
  local bash_profile="$lfs_home/.bash_profile"
  local bash_rc="$lfs_home/.bashrc"
  log_info "Creating LFS user environment files in $lfs_home"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would write $bash_profile and $bash_rc"
    return 0
  fi

  # Ensure home exists
  mkdir -p -- "$lfs_home"
  chown lfs:lfs "$lfs_home" || true
  chmod 0750 "$lfs_home" || true

  cat > "$bash_profile" <<'EOF'
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

  cat > "$bash_rc" <<'EOF'
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
export MAKEFLAGS=-j$(nproc)
EOF

  chown lfs:lfs "$bash_profile" "$bash_rc" || true
  chmod 0644 "$bash_profile" "$bash_rc" || true
}

###########################
# Create user lfs and chroot dirs with right perms
###########################
prepare_lfs_dirs() {
  log_info "Preparing LFS directories under $LFS_ROOT with correct ownership and permissions"

  # Directories from LFS book (common)
  local dirs=( "$LFS_ROOT" "$LFS_ROOT/tools" "$LFS_ROOT/sources" "$LFS_ROOT/build" "$LFS_ROOT/usr" "$LFS_ROOT/{bin,lib,lib64}" )
  # create important tree
  safe_mkdir "$LFS_ROOT" "root:root" 0755
  safe_mkdir "$LFS_ROOT/tools" "root:root" 0755
  safe_mkdir "$LFS_ROOT/sources" "root:root" 0755
  safe_mkdir "$LFS_ROOT/build" "root:root" 0755
  safe_mkdir "$LFS_ROOT/usr" "root:root" 0755
  # create standard directories inside LFS used for mounting
  for d in dev proc sys run dev/pts etc home var tmp; do
    safe_mkdir "$LFS_ROOT/$d" "root:root" 0755
  done

  # Create lfs user if absent
  if ! id lfs >/dev/null 2>&1; then
    log_info "Creating user 'lfs' (no-login build user)"
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "(dry-run) useradd -s /bin/bash -d $LFS_ROOT/home/lfs -m lfs"
    else
      # create group/user
      $GROUPADD -f lfs || true
      $USERADD -s /bin/bash -d "$LFS_ROOT/home/lfs" -m -g lfs lfs || true
      # ensure home points to $LFS_ROOT/home/lfs
      mkdir -p "$LFS_ROOT/home/lfs"
      chown -R lfs:lfs "$LFS_ROOT/home/lfs"
    fi
  else
    log_info "User 'lfs' already exists"
    # ensure lfs home points into chroot (best-effort)
    if [[ ! -d "$LFS_ROOT/home/lfs" ]]; then
      safe_mkdir "$LFS_ROOT/home/lfs" "lfs:lfs" 0750
    fi
  fi

  # create LFS user env files
  create_lfs_user_env
}

###########################
# Copy resolv.conf into chroot so builds have network
###########################
copy_resolv_conf() {
  local dest="$LFS_ROOT/etc/resolv.conf"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would copy /etc/resolv.conf -> $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp -L /etc/resolv.conf "$dest" || log_warn "Failed to copy /etc/resolv.conf (symlink?)"
  chmod 0644 "$dest" || true
  log_info "Copied /etc/resolv.conf into chroot"
}

###########################
# Mount/unmount chroot helpers (safe)
###########################
chroot_mounts() {
  local root="$LFS_ROOT"
  log_info "Mounting essential file systems into $root"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) bind-mount /dev /proc /sys /run and mount devpts"
    return 0
  fi

  mount --bind /dev "$root/dev" || log_warn "mount --bind /dev -> $root/dev"
  mount --bind /dev/pts "$root/dev/pts" || log_warn "mount --bind /dev/pts -> $root/dev/pts"
  mount --bind /proc "$root/proc" || log_warn "mount --bind /proc -> $root/proc"
  mount --bind /sys "$root/sys" || log_warn "mount --bind /sys -> $root/sys"
  mount --bind /run "$root/run" || log_warn "mount --bind /run -> $root/run"

  # other possible mounts (optional)
  # nothing to return
}

chroot_umounts() {
  local root="$LFS_ROOT"
  log_info "Unmounting file systems from $root (safe)"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would unmount $root/dev/pts $root/dev $root/proc $root/sys $root/run"
    return 0
  fi
  # unmount in reverse order; use lazy umount to avoid issues
  for d in run sys proc dev/pts dev; do
    if mountpoint -q "$root/$d"; then
      umount -lf "$root/$d" || log_warn "umount failed for $root/$d"
    fi
  done
}

# ensure resolv inside chroot and mounts, and register trap for cleanup
enter_chroot_prepare() {
  copy_resolv_conf
  chroot_mounts
  # ensure we unmount on exit
  trap 'chroot_teardown_and_exit' INT TERM EXIT
}
chroot_teardown_and_exit() {
  chroot_umounts
  trap - INT TERM EXIT
}

###########################
# Stage YAML parsing & execution
# Stage file example (YAML):
# stage: pass1
# packages:
#  - /usr/ports/category/foo/meta.yaml
#  - /usr/ports/category/bar/meta.yaml
# env: { ... }  # optional env overrides for stage as whole
# hooks: pre/post
###########################
stage_yaml_path() {
  local stage="$1"
  # look for <stage>.yaml under STAGES_DIR
  if [[ -f "${STAGES_DIR}/${stage}.yaml" ]]; then
    echo "${STAGES_DIR}/${stage}.yaml"
    return 0
  fi
  # allow .yml too
  if [[ -f "${STAGES_DIR}/${stage}.yml" ]]; then
    echo "${STAGES_DIR}/${stage}.yml"
    return 0
  fi
  return 1
}

# create snapshot for stage (incremental tar.zst of $LFS_ROOT tree or relevant dirs)
snapshot_stage() {
  local stage="$1"
  local ts
  ts="$(timestamp)"
  local outdir="${SNAPSHOT_DIR}/${stage}-${ts}"
  mkdir -p "$outdir"
  local tarball="${outdir}/${stage}-${ts}.tar.zst"
  log_info "Creating snapshot for stage '$stage' -> $tarball"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would create snapshot of $LFS_ROOT to $tarball"
    return 0
  fi
  # For incremental, we snapshot relevant directories (tools, usr) — as a conservative approach snapshot whole $LFS_ROOT
  if [[ -n "$ZSTD" ]]; then
    tar -C "$LFS_ROOT" -cf - . | zstd -q -o "$tarball" || { log_err "Snapshot tar failed"; return 2; }
  else
    tar -C "$LFS_ROOT" -cf "${outdir}/${stage}-${ts}.tar" . || { log_err "Snapshot tar failed"; return 2; }
  fi
  # metadata
  echo "{\"stage\":\"$stage\",\"timestamp\":\"$ts\",\"tarball\":\"$tarball\"}" > "${outdir}/metadata.json"
  log_info "Snapshot created: $outdir"
  echo "$outdir"
}

prune_old_snapshots() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would prune snapshots older than ${KEEP_SNAP_DAYS} days"
    return 0
  fi
  find "$SNAPSHOT_DIR" -maxdepth 1 -type d -mtime +"${KEEP_SNAP_DAYS}" -print -exec rm -rf {} \; 2>/dev/null || true
  log_info "Pruned snapshots older than ${KEEP_SNAP_DAYS} days"
}

###########################
# Stage execution
# - parse packages array from YAML (requires yq)
# - for each package:
#     - support package-level .env injection (stage_dir/<pkg>.env)
#     - call core.sh install <metafile>
#     - checkpoint progress in state file: STATE_DIR/<stage>.json
###########################
stage_state_file() { printf '%s/%s.state.json' "$STATE_DIR" "$1"; }

load_stage_state() {
  local stage="$1"
  local statefile
  statefile="$(stage_state_file "$stage")"
  if [[ -f "$statefile" ]]; then
    cat "$statefile"
    return 0
  fi
  echo '{"remaining":[],"completed":[]}'
}

save_stage_state() {
  local stage="$1"; shift
  local json="$*"
  local statefile
  statefile="$(stage_state_file "$stage")"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would write state to $statefile"
    return 0
  fi
  echo "$json" | jq '.' > "${statefile}.tmp" && mv -f "${statefile}.tmp" "$statefile"
  log_info "Saved state for stage $stage -> $statefile"
}

clean_stage() {
  local stage="$1"
  local stagecache="${STAGES_DIR}/${stage}"
  log_info "Cleaning stage workspace and snapshots for stage $stage"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would remove snapshots for $stage and state file"
    return 0
  fi
  # remove stage snapshot dirs
  find "$SNAPSHOT_DIR" -maxdepth 1 -type d -name "${stage}-*" -print -exec rm -rf {} \; 2>/dev/null || true
  # remove state
  rm -f "$(stage_state_file "$stage")" || true
  # optionally remove build area under LFS (be careful)
  rm -rf "${LFS_ROOT}/build" || true
  mkdir -p "${LFS_ROOT}/build"
  log_info "Stage $stage cleaned"
}

run_stage() {
  local stage="$1"
  local sf
  sf="$(stage_yaml_path "$stage")" || { log_err "Stage yaml for '$stage' not found in $STAGES_DIR"; return 1; }
  log_info "Running stage '$stage' from $sf"

  # parse stage-level env
  local stage_env_json
  stage_env_json="$("$YQ" e '.environment // {}' -o=json "$sf" 2>/dev/null || echo '{}')"

  # get packages array (metafile paths or package names)
  # support either list of metafiles or names (we will let core.sh parse names)
  mapfile -t packages < <( "$YQ" e '.packages[]' "$sf" 2>/dev/null || true )

  # prepare state
  local state_json; state_json="$(load_stage_state "$stage")"
  local -a remaining; local -a completed
  mapfile -t remaining < <(echo "$state_json" | jq -r '.remaining[]?' 2>/dev/null || true)
  mapfile -t completed < <(echo "$state_json" | jq -r '.completed[]?' 2>/dev/null || true)

  if [[ ${#remaining[@]} -eq 0 ]]; then
    # initialize remaining from packages
    remaining=( "${packages[@]}" )
  fi

  log_info "Stage $stage: will process ${#remaining[@]} packages"

  # Enter chroot (mounts + resolv.conf) before running any package
  enter_chroot_prepare

  # iterate
  for pkg_meta in "${remaining[@]}"; do
    # if clean_stage is requested earlier, abort
    if [[ $CLEAN_STAGE -eq 1 ]]; then
      log_info "--clean-stage requested; aborting stage run to perform clean"
      chroot_teardown_and_exit
      clean_stage "$stage"
      return 0
    fi

    # normalize pkg_meta: if yq output contains quotes, strip; also allow plain names
    pkg_meta="$(echo "$pkg_meta" | sed 's/^"//;s/"$//')"
    log_info "Stage $stage: processing package entry: $pkg_meta"

    # run pre-pkg hooks
    if [[ -d "${HOOKS_DIR}/${stage}/pre-pkg" ]]; then
      run_hooks "${stage}/pre-pkg" "$pkg_meta"
    fi

    # if package-specific env file exists, source it (but do in a subshell)
    local pkg_env_file="${STAGES_DIR}/${stage}/${pkg_meta}.env"
    if [[ -f "$pkg_env_file" ]]; then
      log_info "Found package env for $pkg_meta: $pkg_env_file"
      # copy env into chroot /tmp and source inside chroot when executing core.sh if needed
      # We'll export variables for the core.sh invocation
      # read env key=val lines
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        export "$line"
      done < "$pkg_env_file"
    fi

    # Execute core.sh for this package (assume core.sh accepts metafile or package name)
    if [[ ! -x "$CORE_SH" ]]; then
      log_err "core.sh not found at $CORE_SH; aborting stage"
      chroot_teardown_and_exit
      return 2
    fi

    # Build log per package
    local pkg_log="${LOG_DIR}/${stage}-${pkg_meta//\//_}.log"
    mkdir -p "$(dirname "$pkg_log")"

    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "(dry-run) would run: $CORE_SH install $pkg_meta (inside chroot with LFS stage)"
    else
      # call core.sh with CORE_STAGE env so core.sh performs correct install behavior for pass1/pass2/normal
      CORE_STAGE="$stage" "$CORE_SH" install "$pkg_meta" 2>&1 | tee -a "$pkg_log"
      local rc=${PIPESTATUS[0]}
      if [[ $rc -ne 0 ]]; then
        log_err "core.sh failed for $pkg_meta (rc=$rc). Saving state for resume and exiting stage."
        # save remaining with current pkg at head to be retried
        # build remaining JSON: current pkg plus rest (we had remaining array)
        # find index of current pkg to remove from remaining
        # For simplicity, write state with remaining unchanged (so resume will retry this pkg)
        local new_state
        new_state="$(jq -n --argjson rem "$(printf '%s\n' "${remaining[@]}" | jq -R -s -c 'split("\n")[:-1]')" --argjson done "$(printf '%s\n' "${completed[@]}" | jq -R -s -c 'split("\n")[:-1]')" '{remaining:$rem,completed:$done}')"
        save_stage_state "$stage" "$new_state"
        chroot_teardown_and_exit
        return 3
      fi
    fi

    # success: move pkg from remaining -> completed (we'll reconstruct arrays)
    completed+=( "$pkg_meta" )
    # remove first element of remaining
    remaining=( "${remaining[@]:1}" )
    # save state
    local state_out
    state_out="$(jq -n --argjson rem "$(printf '%s\n' "${remaining[@]}" | jq -R -s -c 'split("\n")[:-1]')" --argjson done "$(printf '%s\n' "${completed[@]}" | jq -R -s -c 'split("\n")[:-1]')" '{remaining:$rem,completed:$done}')"
    save_stage_state "$stage" "$state_out"

    # post-pkg hooks
    if [[ -d "${HOOKS_DIR}/${stage}/post-pkg" ]]; then
      run_hooks "${stage}/post-pkg" "$pkg_meta"
    fi
  done

  # all packages done for stage: snapshot stage and clear state
  chroot_teardown_and_exit
  local snapdir
  snapdir="$(snapshot_stage "$stage" || true)"
  # clear stage state file
  rm -f "$(stage_state_file "$stage")" || true

  # post-stage hooks
  if [[ -d "${HOOKS_DIR}/${stage}/post-stage" ]]; then
    run_hooks "${stage}/post-stage" "$snapdir"
  fi

  log_info "Stage '$stage' completed successfully"
  return 0
}

###########################
# CLI
###########################
usage() {
  cat <<EOF
bootstrap.sh - manage LFS/BLFS bootstrap stages

Usage:
  bootstrap.sh --prepare               # prepare /mnt/lfs, create lfs user, create env
  bootstrap.sh --run <stage>          # run a stage (pass1, pass2, final, etc.)
  bootstrap.sh --all                  # run all stages found in $STAGES_DIR in lexical order
  bootstrap.sh --resume --run <stage> # resume interrupted stage
  bootstrap.sh --clean-stage <stage>  # remove snapshots/state and rebuild stage from scratch
  bootstrap.sh --tarball <stage>      # create a tarball snapshot for stage only
  bootstrap.sh --prune-snapshots      # remove snapshots older than ${KEEP_SNAP_DAYS} days
  Options:
    --dry-run   simulate actions
    --quiet     minimal output
    --help
EOF
}

# parse args
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare) PREPARE_ONLY=1; shift ;;
    --run) RUN_STAGE="$2"; shift 2 ;;
    --all) RUN_ALL=1; shift ;;
    --resume) RESUME=1; shift ;;
    --clean-stage) CLEAN_STAGE=1; RUN_STAGE="$2"; shift 2 ;;
    --tarball) CREATE_TARBALL=1; RUN_STAGE="$2"; shift 2 ;;
    --prune-snapshots) prune_old_snapshots; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# Ensure prerequisites
if [[ -z "$YQ" || -z "$JQ" ]]; then
  log_err "yq and jq are required. Install them before running bootstrap.sh"
  exit 1
fi
if [[ ! -x "$CORE_SH" ]]; then
  log_warn "core.sh not found at $CORE_SH; stage execution will fail if core.sh missing"
fi

# Actions
if [[ $PREPARE_ONLY -eq 1 ]]; then
  prepare_lfs_dirs
  copy_resolv_conf
  log_info "Preparation complete. Please verify /etc/bash.bashrc moved aside if required (per LFS book)."
  exit 0
fi

if [[ $RUN_ALL -eq 1 ]]; then
  # run each stage file in lexical order (basename without extension)
  for f in "$STAGES_DIR"/*.y*ml; do
    [[ -f "$f" ]] || continue
    stagebase="$(basename "$f" | sed 's/\.[^.]*$//')"
    if [[ $CLEAN_STAGE -eq 1 ]]; then
      clean_stage "$stagebase"
    fi
    if [[ $RESUME -eq 1 ]]; then
      run_stage "$stagebase"
    else
      run_stage "$stagebase"
    fi
  done
  prune_old_snapshots
  exit 0
fi

if [[ -n "$RUN_STAGE" ]]; then
  if [[ $CLEAN_STAGE -eq 1 ]]; then
    clean_stage "$RUN_STAGE"
  fi
  if [[ $CREATE_TARBALL -eq 1 ]]; then
    snapshot_stage "$RUN_STAGE"
    exit 0
  fi
  if [[ $RESUME -eq 1 ]]; then
    log_info "Resuming stage $RUN_STAGE"
  fi
  run_stage "$RUN_STAGE"
  prune_old_snapshots
  exit 0
fi

usage
exit 0
