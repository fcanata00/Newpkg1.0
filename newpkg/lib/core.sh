
#!/usr/bin/env bash
# core.sh - orchestrator for newpkg builds (download -> extract -> patch -> build -> install -> package -> deploy)
# Features:
#  - reads metafile (yq) and global config (/etc/newpkg/newpkg.yaml)
#  - safe chroot mount/unmount (mount --bind /dev /proc /sys /run)
#  - per-package checkpointing for resume
#  - parallel downloads via xargs -P (configurable)
#  - retries for downloads/builds
#  - fakeroot always for DESTDIR installs
#  - hooks at /etc/newpkg/hooks/core/<stage>/
#  - logs per build in /var/log/newpkg/builds/
#
# Requirements: bash, yq, jq, wget/curl, tar, xargs, fakeroot, realpath (optional), log.sh (optional)
#
# Usage:
#   core.sh install <metafile-or-package> [<pkg2> ...] [--resume] [--dry-run] [--parallel N] [--retry N] [--quiet]
#   core.sh build <metafile-or-package>
#   core.sh resume <metafile-or-package>
#   core.sh clean <pkg>  # cleanup build dirs
#   core.sh help
#
set -o errexit
set -o nounset
set -o pipefail

##########################
# Defaults / configuration
##########################
: "${CONFIG_FILE:=/etc/newpkg/newpkg.yaml}"
: "${DB_CLI:=/usr/lib/newpkg/db.sh}"
: "${DEPS_PY:=/usr/lib/newpkg/deps.py}"
: "${REMOVE_CLI:=/usr/lib/newpkg/remove.sh}"
: "${LOG_SH_SYSTEM:=/usr/lib/newpkg/log.sh}"
: "${LOG_DIR:=/var/log/newpkg}"
: "${BUILD_LOG_DIR:=${LOG_DIR}/builds}"
: "${CACHE_DIR:=/var/cache/newpkg/sources}"
: "${WORK_DIR:=/var/cache/newpkg/work}"
: "${NPKG_HOOKS_DIR:=/etc/newpkg/hooks/core}"
: "${DEPGRAPH_CACHE:=/var/lib/newpkg/depgraph.json}"

# Tools
YQ="$(command -v yq || true)"
JQ="$(command -v jq || true)"
WGET="$(command -v wget || true)"
CURL="$(command -v curl || true)"
TAR="$(command -v tar || true)"
XARGS="$(command -v xargs || true)"
FAKEROOT="$(command -v fakeroot || true)"
REALPATH="$(command -v realpath || true)"
GIT="$(command -v git || true)"

# Validate required tools
if [[ -z "$YQ" ]]; then
  echo "ERROR: 'yq' is required but not found." >&2
  exit 1
fi
if [[ -z "$FAKEROOT" ]]; then
  echo "ERROR: 'fakeroot' is required but not found." >&2
  exit 1
fi

# defaults overridable via CLI/options
DRY_RUN=0
QUIET=0
PARALLEL=2
RETRY=2
RESUME=0
FORCE=0

# Ensure directories
mkdir -p -- "$CACHE_DIR" "$WORK_DIR" "$BUILD_LOG_DIR" "$LOG_DIR" "$WORK_DIR/checkpoints"

# Try to source log.sh for colored logging
if [[ -f "$LOG_SH_SYSTEM" ]]; then
  # shellcheck source=/usr/lib/newpkg/log.sh
  source "$LOG_SH_SYSTEM" || true
elif [[ -f "/etc/newpkg/log.sh" ]]; then
  # shellcheck source=/etc/newpkg/log.sh
  source /etc/newpkg/log.sh || true
fi

# Fallback log functions if not provided
_log_fallback() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  case "$level" in
    INFO) printf '[%s] [INFO] %s\n' "$ts" "$msg" ;; 
    WARN) printf '[%s] [WARN] %s\n' "$ts" "$msg" >&2 ;;
    ERROR) printf '[%s] [ERROR] %s\n' "$ts" "$msg" >&2 ;;
    DEBUG) [[ "${NPKG_DEBUG:-0}" -eq 1 ]] && printf '[%s] [DEBUG] %s\n' "$ts" "$msg" ;;
    *) printf '[%s] %s\n' "$ts" "$msg" ;;
  esac
  # write to aggregate log
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "${LOG_DIR}/core.log"
}
log_info()  { if declare -F log_info >/dev/null 2>&1; then log_info "$@"; else _log_fallback INFO "$@"; fi; }
log_warn()  { if declare -F log_warn >/dev/null 2>&1; then log_warn "$@"; else _log_fallback WARN "$@"; fi; }
log_error() { if declare -F log_error >/dev/null 2>&1; then log_error "$@"; else _log_fallback ERROR "$@"; fi; }
log_debug() { if declare -F log_debug >/dev/null 2>&1; then log_debug "$@"; else _log_fallback DEBUG "$@"; fi; }

# Hooks: run scripts in NPKG_HOOKS_DIR/<hook>/*
run_hooks() {
  local hook="$1"; shift || true
  local dir="$NPKG_HOOKS_DIR/$hook"
  if [[ -d "$dir" ]]; then
    for f in "$dir"/*; do
      [[ -x "$f" ]] || continue
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "(dry-run) would run hook $f $*"
      else
        log_info "Running hook $f $*"
        "$f" "$@" || log_warn "Hook $f returned non-zero"
      fi
    done
  fi
}

#########################
# Utility helpers
#########################
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
canonicalize() {
  if [[ -n "$REALPATH" ]]; then
    "$REALPATH" -m "$1"
  else
    echo "$(cd "$(dirname "$1")"; pwd)/$(basename "$1")"
  fi
}
safe_rm_rf() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would remove $*"
  else
    rm -rf -- "$@"
  fi
}
ensure_dir() { mkdir -p -- "$1"; }
write_checkpoint() {
  local pkg="$1"; shift
  local stage="$1"; shift
  local cp="$WORK_DIR/checkpoints/${pkg}.state"
  touch "$cp"
  # mark stage as done (append unique)
  if ! grep -q "^$stage$" "$cp" 2>/dev/null; then
    echo "$stage" >> "$cp"
  fi
}
checkpoint_has() {
  local pkg="$1"; shift
  local stage="$1"; shift
  local cp="$WORK_DIR/checkpoints/${pkg}.state"
  [[ -f "$cp" ]] || return 1
  grep -q "^$stage$" "$cp" 2>/dev/null
}
clear_checkpoint() {
  local pkg="$1"
  local cp="$WORK_DIR/checkpoints/${pkg}.state"
  safe_rm_rf "$cp"
}

# read global config (yq)
core_load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # parallel_jobs configurable at sync or core level: .core.parallel_jobs or .sync.parallel_jobs
    local p
    p="$("$YQ" e '.core.parallel_jobs // .sync.parallel_jobs // '"$PARALLEL"'' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$p" && "$p" != "null" ]]; then
      PARALLEL="$p"
    fi
    local r
    r="$("$YQ" e '.core.retry // '"$RETRY"'' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$r" && "$r" != "null" ]]; then
      RETRY="$r"
    fi
  fi
  log_debug "Loaded config: PARALLEL=$PARALLEL RETRY=$RETRY"
}

# parse metafile with yq; accepts path or package name (search in /usr/ports)
core_parse_metafile() {
  local input="$1"
  local metafile=""
  # if exists as path accept it
  if [[ -f "$input" ]]; then
    metafile="$input"
  else
    # try to find under /usr/ports: assume structure /usr/ports/*/<pkg>/meta.yaml or package.yaml
    # quick search (first match)
    metafile="$(find /usr/ports -maxdepth 4 -type f \( -iname 'meta.yaml' -o -iname 'meta.yml' -o -iname 'package.yaml' -o -iname '*.yaml' \) -exec grep -l \"name: *$input\\|package: *$input\" {} + 2>/dev/null | head -n1 || true)"
    if [[ -z "$metafile" ]]; then
      log_warn "Metafile for '$input' not found under /usr/ports; try passing path"
      return 1
    fi
  fi
  echo "$metafile"
}

# fetch sources: multiple URLs allowed; store into CACHE_DIR; retry logic
core_download_sources() {
  local pkgid="$1"        # name-version string unique
  shift
  local -a srcs=( "$@" )
  local need_download=()
  ensure_dir "$CACHE_DIR"
  for src in "${srcs[@]}"; do
    # determine filename
    local fname
    fname="$(basename "${src%%\?*}")"
    local dest="$CACHE_DIR/$fname"
    if [[ -f "$dest" && "$FORCE" -ne 1 ]]; then
      log_info "Source cached: $fname"
      continue
    fi
    need_download+=("$src")
  done

  if [[ "${#need_download[@]}" -eq 0 ]]; then
    write_checkpoint "$pkgid" downloaded
    return 0
  fi

  # create temp list for xargs -0
  local listfile
  listfile="$(mktemp)"
  for s in "${need_download[@]}"; do printf '%s\0' "$s" >> "$listfile"; done

  # downloader function used by xargs; we implement inline bash -c that writes to cache
  local downloader_cmd
  downloader_cmd='
    src="$0"
    fname="$(basename "${src%%\?*}")"
    dest="'"$CACHE_DIR"'/${fname}"
    attempt=0
    ok=1
    while true; do
      attempt=$((attempt+1))
      if [[ "'"$DRY_RUN"'" -eq 1 ]]; then
        echo "(dry-run) would download $src -> $dest"
        ok=0
        break
      fi
      if [[ -n "'"$WGET"'" ]]; then
        "'"$WGET"'" -q -O "${dest}.tmp" "$src" && { mv -f "${dest}.tmp" "$dest"; ok=0; break; } || true
      elif [[ -n "'"$CURL"'" ]]; then
        "'"$CURL"'" -sSf -L -o "${dest}.tmp" "$src" && { mv -f "${dest}.tmp" "$dest"; ok=0; break; } || true
      else
        echo "No downloader available" >&2
        ok=1
        break
      fi
      if [[ $attempt -ge '"$RETRY"' ]]; then
        break
      fi
      sleep 1
    done
    if [[ $ok -ne 0 ]]; then
      echo "FAILED:$src" >&2
      exit 2
    fi
    echo "OK:$src"
  '

  # run xargs -0 -P "$PARALLEL"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would download ${#need_download[@]} sources in parallel ($PARALLEL)"
    rm -f "$listfile"
    write_checkpoint "$pkgid" downloaded
    return 0
  fi

  # Use xargs to parallelize downloads
  # Note: some systems require -0 support; ensure XARGS exists
  if [[ -n "$XARGS" ]]; then
    # xargs -0 -n1 -P "$PARALLEL" bash -c "$downloader_cmd" _
    # but embedding quotes is tricky; create a small helper script
    local helper
    helper="$(mktemp)"
    cat >"$helper" <<'EOF'
#!/usr/bin/env bash
src="$1"
fname="$(basename "${src%%\?*}")"
dest="'"$CACHE_DIR"'/${fname}"
attempt=0
ok=1
while true; do
  attempt=$((attempt+1))
  if [[ "'"$DRY_RUN"'" -eq 1 ]]; then
    echo "(dry-run) would download $src -> $dest"
    ok=0
    break
  fi
  if [[ -n "'"$WGET"'" ]]; then
    "'"$WGET"'" -q -O "${dest}.tmp" "$src" && { mv -f "${dest}.tmp" "$dest"; ok=0; break; } || true
  elif [[ -n "'"$CURL"'" ]]; then
    "'"$CURL"'" -sSf -L -o "${dest}.tmp" "$src" && { mv -f "${dest}.tmp" "$dest"; ok=0; break; } || true
  else
    echo "No downloader available" >&2
    ok=1
    break
  fi
  if [[ $attempt -ge '"$RETRY"' ]]; then
    break
  fi
  sleep 1
done
if [[ $ok -ne 0 ]]; then
  echo "FAILED:$src" >&2
  exit 2
fi
echo "OK:$src"
EOF
    chmod +x "$helper"
    # feed null-separated
    cat "$listfile" | "$XARGS" -0 -n1 -P "$PARALLEL" bash "$helper"
    local rc=$?
    rm -f "$listfile" "$helper"
    if [[ $rc -ne 0 ]]; then
      log_error "Some downloads failed (see above)."
      return 2
    fi
  else
    log_warn "xargs not available; downloading serially"
    while IFS= read -r -d '' s; do
      bash -c "$downloader_cmd" "$s" || return 2
    done <"$listfile"
    rm -f "$listfile"
  fi

  write_checkpoint "$pkgid" downloaded
  return 0
}

# extract sources to build dir
core_extract_sources() {
  local pkgid="$1"; local build_dir="$2"
  ensure_dir "$build_dir"
  # find archives in cache for this package: heuristics: meta may list folder name for extraction but here we extract all archives referenced in metafile
  # For simplicity, extract all files in CACHE_DIR that match name-version or known suffixes (caller should pass list of files ideally)
  # But we will expect caller to pass exact filenames in $3...; to keep interface, we'll accept remaining args as filenames
  shift 2
  local -a files=( "$@" )
  if [[ "${#files[@]}" -eq 0 ]]; then
    # fallback: extract any archive present in cache
    mapfile -t files < <(ls -1 "$CACHE_DIR"/* 2>/dev/null || true)
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would extract ${#files[@]} files to $build_dir"
    write_checkpoint "$pkgid" extracted
    return 0
  fi

  for f in "${files[@]}"; do
    [[ -f "$f" ]] || { log_warn "Archive $f not found; skipping"; continue; }
    case "$f" in
      *.tar.gz|*.tgz) "$TAR" -xzf "$f" -C "$build_dir" || { log_error "extract failed: $f"; return 2; } ;;
      *.tar.xz) "$TAR" -xJf "$f" -C "$build_dir" || { log_error "extract failed: $f"; return 2; } ;;
      *.tar.bz2) "$TAR" -xjf "$f" -C "$build_dir" || { log_error "extract failed: $f"; return 2; } ;;
      *.tar.zst) "$TAR" -I zstd -xf "$f" -C "$build_dir" || { log_error "extract failed: $f"; return 2; } ;;
      *.zip) unzip -q "$f" -d "$build_dir" || { log_error "extract failed: $f"; return 2; } ;;
      *) log_warn "Unknown archive format: $f; attempting tar -xf"; "$TAR" -xf "$f" -C "$build_dir" || { log_warn "tar -xf failed on $f"; } ;;
    esac
  done

  write_checkpoint "$pkgid" extracted
  return 0
}

# apply patches listed in metafile; expects patches array be filenames present in some patches/ dir relative to work_dir or absolute
core_apply_patches() {
  local pkgid="$1"; local build_dir="$2"
  local -a patches=( "$@" )
  # patches passed as subsequent args; if none, skip
  if [[ "${#patches[@]}" -eq 0 ]]; then
    write_checkpoint "$pkgid" patched
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    for p in "${patches[@]}"; do
      log_info "(dry-run) would apply patch $p in $build_dir"
    done
    write_checkpoint "$pkgid" patched
    return 0
  fi
  pushd "$build_dir" >/dev/null || return 2
  for p in "${patches[@]}"; do
    if [[ ! -f "$p" ]]; then
      # try in work_dir/patches
      if [[ -f "$WORK_DIR/patches/$p" ]]; then
        p="$WORK_DIR/patches/$p"
      else
        log_warn "Patch not found: $p ; skipping"
        continue
      fi
    fi
    log_info "Applying patch $p"
    patch -p1 < "$p" || { log_error "Patch failed: $p"; popd >/dev/null; return 2; }
  done
  popd >/dev/null || true
  write_checkpoint "$pkgid" patched
  return 0
}

# run custom commands (configure/build/install) specified in metafile as commands.configure, commands.build, commands.install
core_run_commands() {
  local pkgid="$1"; local build_dir="$2"
  shift 2
  local -a cmds=( "$@" )
  if [[ "${#cmds[@]}" -eq 0 ]]; then
    write_checkpoint "$pkgid" built
    return 0
  fi
  # always run under build_dir
  pushd "$build_dir" >/dev/null || return 2
  for cmd in "${cmds[@]}"; do
    if [[ -z "$cmd" ]]; then continue; fi
    # support placeholders: @MAKEJOBS@
    cmd="${cmd//@MAKEJOBS@/-j$(nproc)}"
    log_info "Running: $cmd"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "(dry-run) would run: $cmd"
      continue
    fi
    # run with retry logic
    local attempt=0
    local ok=1
    while true; do
      attempt=$((attempt+1))
      if eval "$cmd"; then
        ok=0
        break
      else
        log_warn "Command failed (attempt $attempt): $cmd"
      fi
      if [[ $attempt -ge $RETRY ]]; then
        break
      fi
      sleep 1
    done
    if [[ $ok -ne 0 ]]; then
      popd >/dev/null || true
      return 2
    fi
  done
  popd >/dev/null || true
  write_checkpoint "$pkgid" built
  return 0
}

# install into DESTDIR with fakeroot
core_install_destdir() {
  local pkgid="$1"; local build_dir="$2"; local destdir="$3"
  ensure_dir "$destdir"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would run install to destdir $destdir from $build_dir via fakeroot"
    write_checkpoint "$pkgid" installed_destdir
    return 0
  fi
  pushd "$build_dir" >/dev/null || return 2
  # The usual install command expected: make install DESTDIR="$destdir" or provided in metafile as commands.install
  # We will simply run "make install DESTDIR=$destdir" under fakeroot, but caller may pass exact install cmd earlier via core_run_commands
  if [[ -n "$MAKE" ]]; then true; fi
  if "$FAKEROOT" sh -c 'make install DESTDIR="'"$destdir"'"' >/dev/null 2>&1; then
    log_info "Installed into destdir $destdir"
  else
    # try running caller-provided install step may have already done installation; still mark as installed
    log_warn "make install to DESTDIR failed; ensure metafile's install command was run."
  fi
  popd >/dev/null || true
  write_checkpoint "$pkgid" installed_destdir
  return 0
}

# package destdir into tar.zst
core_package() {
  local pkgname="$1"; local version="$2"; local destdir="$3"; local outdir="$4"
  ensure_dir "$outdir"
  local arch
  arch="$(uname -m)"
  local fname="${pkgname}-${version}-${arch}.tar.zst"
  local outfile="$outdir/$fname"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would pack $destdir -> $outfile"
    return 0
  fi
  pushd "$destdir" >/dev/null || return 2
  if command -v zstd >/dev/null 2>&1; then
    tar -C "$destdir" -cf - . | zstd -q -o "$outfile" || { log_error "Packaging failed"; popd >/dev/null; return 2; }
  else
    tar -C "$destdir" -cf "$outfile" . || { log_error "Packaging failed"; popd >/dev/null; return 2; }
  fi
  popd >/dev/null || true
  log_info "Packaged: $outfile"
  return 0
}

# deploy (install) package to final location
core_deploy() {
  local pkgname="$1"; local version="$2"; local stage="$3"; local package_file="$4"
  # stage: normal -> install to / (requires root); pass1/pass2 -> /mnt/lfs and use user lfs for tests
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would deploy $package_file for stage $stage"
    write_checkpoint "${pkgname}-${version}" deployed
    return 0
  fi
  if [[ "$stage" == "normal" ]]; then
    # extract to /
    if [[ -f "$package_file" ]]; then
      if [[ "$EUID" -ne 0 ]]; then
        log_warn "Deploying to / requires root; run as root"
        return 2
      fi
      if command -v zstd >/dev/null 2>&1 && [[ "$package_file" == *.zst ]]; then
        zstd -d -c "$package_file" | tar -C / -xf - || { log_error "Deploy failed"; return 2; }
      else
        tar -C / -xf "$package_file" || { log_error "Deploy failed"; return 2; }
      fi
      log_info "Deployed package to /"
    else
      log_error "Package file not found: $package_file"
      return 2
    fi
  else
    # stage1/pass* -> /mnt/lfs; ensure mounts and user lfs exist
    local target="/mnt/lfs"
    if [[ ! -d "$target" ]]; then
      log_warn "$target not found; creating"
      mkdir -p "$target"
    fi
    # extract to /mnt/lfs
    if command -v zstd >/dev/null 2>&1 && [[ "$package_file" == *.zst ]]; then
      zstd -d -c "$package_file" | tar -C "$target" -xf - || { log_error "Deploy to $target failed"; return 2; }
    else
      tar -C "$target" -xf "$package_file" || { log_error "Deploy to $target failed"; return 2; }
    fi
    log_info "Deployed package to $target (stage $stage)"
  fi
  write_checkpoint "${pkgname}-${version}" deployed
  return 0
}

# register package in DB (create manifest and call db.sh add)
core_register_db() {
  local metafile="$1"
  local pkgname="$2"
  local version="$3"
  local stage="$4"
  local install_prefix="$5"
  local manifest_out="$WORK_DIR/manifests/${pkgname}-${version}.json"
  ensure_dir "$(dirname "$manifest_out")"
  # Try to synthesize manifest: use yq to extract fields from metafile: depends/provides/files etc.
  # Minimal manifest
  local origin
  origin="$("$YQ" e '.origin // ""' "$metafile" 2>/dev/null || true)"
  local files_json='[]'
  # we cannot easily list installed files here; leave files empty or allow build system to produce filelist step
  jq -n --arg name "$pkgname" --arg version "$version" --arg stage "$stage" --arg origin "$origin" --arg prefix "$install_prefix" \
    '{name:$name,version:$version,stage:$stage,origin:$origin,install_prefix:$prefix,files:[],build_date:(now|todate)}' > "$manifest_out" || true

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) would register manifest $manifest_out to DB"
    return 0
  fi

  if [[ -x "$DB_CLI" ]]; then
    "$DB_CLI" add "$manifest_out" --replace || {
      log_warn "db.sh add returned non-zero"
    }
  else
    log_warn "db.sh not found; skipping DB registration"
  fi
  return 0
}

#########################
# Chroot helpers
#########################
# Creates a minimal chroot at CHROOT_DIR by bind-mounting /dev /proc /sys /run
chroot_setup() {
  local chroot_dir="$1"
  ensure_dir "$chroot_dir"
  for d in dev proc sys run; do
    ensure_dir "$chroot_dir/$d"
    if mountpoint -q "$chroot_dir/$d"; then
      log_debug "$chroot_dir/$d already mounted"
    else
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "(dry-run) would mount --bind /$d -> $chroot_dir/$d"
      else
        mount --bind "/$d" "$chroot_dir/$d" || { log_error "mount --bind /$d failed"; return 2; }
      fi
    fi
  done
  return 0
}
chroot_teardown() {
  local chroot_dir="$1"
  for d in run sys proc dev; do
    if mountpoint -q "$chroot_dir/$d"; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "(dry-run) would umount $chroot_dir/$d"
      else
        umount -lf "$chroot_dir/$d" || log_warn "umount failed for $chroot_dir/$d"
      fi
    fi
  done
}

chroot_exec() {
  local chroot_dir="$1"; shift
  # run a command array inside chroot using env sanitized
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "(dry-run) chroot $chroot_dir $*"
    return 0
  fi
  chroot "$chroot_dir" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/bin:/usr/bin:/sbin:/usr/sbin "$@"
}

#########################
# High level orchestrator
#########################
core_do_package() {
  # args: metafile-path or package-name
  local input="$1"
  log_info "Starting core build for: $input"
  local metafile
  metafile="$(core_parse_metafile "$input")" || { log_error "Failed to locate metafile for $input"; return 2; }

  # read common fields via yq
  local name version stage build_dir install_prefix sources patches build_system commands_configure commands_build commands_install
  name="$("$YQ" e '.name // .package // .pkgname' "$metafile" 2>/dev/null)"
  version="$("$YQ" e '.version // "0.0.0"' "$metafile" 2>/dev/null)"
  stage="$("$YQ" e '.stage // "normal"' "$metafile" 2>/dev/null)"
  build_dir="$("$YQ" e '.build_dir // "build"' "$metafile" 2>/dev/null)"
  install_prefix="$("$YQ" e '.install_prefix // "/"' "$metafile" 2>/dev/null)"
  # sources is array
  mapfile -t sources < <( "$YQ" e '.sources[]?' -o=json "$metafile" 2>/dev/null | "$JQ" -r '.[]? // empty' 2>/dev/null || true )
  # if above fails, try reading different path
  if [[ "${#sources[@]}" -eq 0 ]]; then
    # attempt to read as plain scalar list
    mapfile -t sources < <( "$YQ" e '.sources[]?' "$metafile" 2>/dev/null || true )
  fi
  # patches
  mapfile -t patches < <( "$YQ" e '.patches[]?' -o=json "$metafile" 2>/dev/null | "$JQ" -r '.[]? // empty' 2>/dev/null || true || true )
  # commands (configure, build, install)
  commands_configure="$( "$YQ" e '.commands.configure // ""' "$metafile" 2>/dev/null || true )"
  commands_build="$(     "$YQ" e '.commands.build // ""' "$metafile" 2>/dev/null || true )"
  commands_install="$(   "$YQ" e '.commands.install // ""' "$metafile" 2>/dev/null || true )"

  local pkgid="${name}-${version}"
  local pkg_work="$WORK_DIR/$pkgid"
  local pkg_builddir="$pkg_work/$build_dir"
  local destdir="$pkg_work/destdir"
  local pkg_log="$BUILD_LOG_DIR/${pkgid}.log"

  ensure_dir "$pkg_work" "$pkg_builddir" "$destdir" "$(dirname "$pkg_log")"

  # stage pre-init
  run_hooks pre-init "$pkgid" "$metafile"

  # Stage: download
  if ! checkpoint_has "$pkgid" downloaded; then
    log_info "Downloading sources for $pkgid"
    core_download_sources "$pkgid" "${sources[@]}" | tee -a "$pkg_log" || { log_error "Download failed for $pkgid"; return 2; }
  else
    log_info "Skipping download: already downloaded (checkpoint)"
  fi
  run_hooks post-download "$pkgid" "$metafile"

  # Stage: extract
  if ! checkpoint_has "$pkgid" extracted; then
    # compute list of source files in cache: map by basename of URLs
    mapfile -t srcfiles < <(for s in "${sources[@]}"; do echo "$CACHE_DIR/$(basename "${s%%\?*}")"; done)
    core_extract_sources "$pkgid" "$pkg_builddir" "${srcfiles[@]}" 2>&1 | tee -a "$pkg_log" || { log_error "Extract failed for $pkgid"; return 2; }
  else
    log_info "Skipping extract: checkpoint present"
  fi
  run_hooks post-extract "$pkgid" "$metafile"

  # Stage: patch
  if ! checkpoint_has "$pkgid" patched; then
    core_apply_patches "$pkgid" "$pkg_builddir" "${patches[@]}" 2>&1 | tee -a "$pkg_log" || { log_error "Patch stage failed for $pkgid"; return 2; }
  else
    log_info "Skipping patch: checkpoint present"
  fi
  run_hooks post-patch "$pkgid" "$metafile"

  # Stage: configure/build/install to DESTDIR
  if ! checkpoint_has "$pkgid" built; then
    # run configure if present
    cmds=()
    if [[ -n "$commands_configure" && "$commands_configure" != "null" ]]; then
      cmds+=( "$commands_configure" )
    fi
    if [[ -n "$commands_build" && "$commands_build" != "null" ]]; then
      cmds+=( "$commands_build" )
    else
      cmds+=( "make -j$(nproc)" )
    fi
    if [[ -n "${commands_install}" && "$commands_install" != "null" ]]; then
      cmds+=( "$commands_install" )
    else
      # we'll run default install into destdir via fakeroot later; still run make install here but to build artifacts only
      cmds+=( "make -j$(nproc) install DESTDIR=$destdir" )
    fi
    core_run_commands "$pkgid" "$pkg_builddir" "${cmds[@]}" 2>&1 | tee -a "$pkg_log" || { log_error "Build commands failed for $pkgid"; return 2; }
  else
    log_info "Skipping build: checkpoint present"
  fi
  run_hooks post-build "$pkgid" "$metafile"

  # Stage: install into destdir (with fakeroot) -- if built step already ran make install DESTDIR, this may be redundant
  if ! checkpoint_has "$pkgid" installed_destdir; then
    core_install_destdir "$pkgid" "$pkg_builddir" "$destdir" 2>&1 | tee -a "$pkg_log" || { log_error "Install to destdir failed for $pkgid"; return 2; }
  else
    log_info "Skipping destdir install: checkpoint present"
  fi
  run_hooks post-install "$pkgid" "$metafile"

  # Stage: package
  ensure_dir "$CACHE_DIR/packages"
  if ! checkpoint_has "$pkgid" packaged; then
    core_package "$name" "$version" "$destdir" "$CACHE_DIR/packages" 2>&1 | tee -a "$pkg_log" || { log_error "Packaging failed for $pkgid"; return 2; }
  else
    log_info "Skipping packaging: checkpoint present"
  fi
  run_hooks post-package "$pkgid" "$metafile"

  # Stage: deploy
  local package_file
  package_file="$(ls -1 "$CACHE_DIR/packages/${name}-${version}-"*.tar.* 2>/dev/null | head -n1 || true)"
  if [[ -z "$package_file" ]]; then
    log_warn "Package file not found for $pkgid; skipping deploy"
  else
    if ! checkpoint_has "$pkgid" deployed; then
      core_deploy "$name" "$version" "$stage" "$package_file" 2>&1 | tee -a "$pkg_log" || { log_error "Deploy failed for $pkgid"; return 2; }
    else
      log_info "Skipping deploy: checkpoint present"
    fi
  fi
  run_hooks post-deploy "$pkgid" "$metafile"

  # Stage: register DB
  if ! checkpoint_has "$pkgid" registered; then
    core_register_db "$metafile" "$name" "$version" "$stage" "$install_prefix" 2>&1 | tee -a "$pkg_log" || { log_warn "DB registration returned non-zero for $pkgid"; }
  else
    log_info "Skipping DB register: checkpoint present"
  fi
  run_hooks post-register "$pkgid" "$metafile"

  # Stage: cleanup local work (optionally keep work_dir on failure or for debug)
  run_hooks pre-cleanup "$pkgid"
  # remove builddir if configured to clean; check config
  local clean_after
  clean_after="$("$YQ" e '.core.clean_after_build // true' "$CONFIG_FILE" 2>/dev/null || true)"
  if [[ "$clean_after" == "true" ]]; then
    safe_rm_rf "$pkg_work"
    log_info "Cleaned workdir for $pkgid"
  else
    log_info "Preserving workdir for $pkgid (core.clean_after_build=false)"
  fi
  run_hooks post-cleanup "$pkgid"

  log_info "Build pipeline completed for $pkgid"
  return 0
}

#########################
# Top-level sequence for list of packages
# Supports resume: if checkpoint stage exists it won't re-run stages
#########################
core_install_list() {
  local -a pkgs=( "$@" )
  # Determine full install order via deps.py if available
  # If multiple packages passed on command line, resolve with deps.py for order and skip installed per checkpoint
  local ordered=()
  if [[ -x "$DEPS_PY" && "${#pkgs[@]}" -gt 0 ]]; then
    # call deps.py order for each and concatenate unique preserving order
    declare -A seen
    for p in "${pkgs[@]}"; do
      mapfile -t ord < <("$DEPS_PY" order "$p" --skip-installed 2>/dev/null || true)
      if [[ "${#ord[@]}" -eq 0 ]]; then
        # fallback to just p
        ord=( "$p" )
      fi
      for q in "${ord[@]}"; do
        if [[ -z "${seen[$q]:-}" ]]; then
          ordered+=( "$q" )
          seen[$q]=1
        fi
      done
    done
  else
    ordered=( "${pkgs[@]}" )
  fi

  # process in order
  for tgt in "${ordered[@]}"; do
    log_info "Processing target: $tgt"
    if core_do_package "$tgt"; then
      log_info "Completed $tgt"
    else
      log_error "Build FAILED for $tgt (see logs)"
      # if resume requested, continue to next package; otherwise exit non-zero
      if [[ "$RESUME" -eq 1 ]]; then
        log_info "Resume mode: moving to next package"
        continue
      else
        log_error "Exiting due to build failure for $tgt"
        return 2
      fi
    fi
  done
  return 0
}

#########################
# CLI: parse args
#########################
show_help() {
  cat <<'EOF'
core.sh - newpkg build orchestrator

Usage:
  core.sh install <pkg-or-metafile> [<pkg2> ...] [options]
  core.sh build <pkg-or-metafile>
  core.sh resume <pkg-or-metafile>
  core.sh clean <pkg>     # remove work dirs and checkpoints for pkg
  core.sh help

Options:
  --resume           Continue after failures, skip completed stages
  --dry-run          Show actions without executing
  --parallel N       Parallel jobs for downloads (overrides config)
  --retry N          Retry count for downloads/commands
  --quiet            Minimal output
  --force            Force re-download/extract/patch steps
  --help
EOF
}

# Parse global options that may appear anywhere
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume) RESUME=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --retry) RETRY="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --force) FORCE=1; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) ARGS+=( "$1" ); shift ;;
  esac
done
set -- "${ARGS[@]}"

if [[ $# -lt 1 ]]; then
  show_help
  exit 1
fi

core_load_config

cmd="$1"; shift || true

case "$cmd" in
  install)
    if [[ $# -lt 1 ]]; then echo "install needs at least one package"; exit 1; fi
    core_install_list "$@"
    ;;
  build)
    if [[ $# -lt 1 ]]; then echo "build needs a package or metafile"; exit 1; fi
    core_do_package "$1"
    ;;
  resume)
    # resume is same as install with --resume enabled
    RESUME=1
    if [[ $# -lt 1 ]]; then echo "resume needs at least one package"; exit 1; fi
    core_install_list "$@"
    ;;
  clean)
    if [[ $# -lt 1 ]]; then echo "clean needs a package name"; exit 1; fi
    for p in "$@"; do
      safe_rm_rf "$WORK_DIR/${p}-*" "$WORK_DIR/checkpoints/${p}-*.state"
      log_info "Cleaned work/checkpoints for $p"
    done
    ;;
  help|-h|--help)
    show_help
    ;;
  *)
    echo "Unknown command: $cmd"
    show_help
    exit 1
    ;;
esac

exit 0
