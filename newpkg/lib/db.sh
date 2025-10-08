#!/usr/bin/env bash
# db.sh - simple package metadata DB for newpkg
# Requirements: bash, jq, tar, zstd (optional for backup)
#
# Usage: db.sh <command> [args...]
# Commands:
#   init
#   add <manifest.json> [--replace]
#   remove <pkg|pkg-version> [--force]
#   query <pkg|pkg-version> [--json] [--field FIELD] [--files]
#   list [--stage <stage>] [--json] [--count]
#   revdeps <pkg>
#   provides <file-path>
#   backup
#   restore <backup-file>
#   verify <pkg|pkg-version>
#   orphans
#   search <term>
#   size <pkg|pkg-version>
#   help
#
# Author: Generated for user
# Date: 2025-10-08

set -o errexit
set -o pipefail
set -o nounset

###########################
# Configuration & globals
###########################
: "${NPKG_DB_DIR:=/var/lib/newpkg/db}"
: "${NPKG_DB_BACKUP_DIR:=/var/lib/newpkg/db-backup}"
: "${NPKG_LOG_DIR:=/var/log/newpkg}"
: "${NPKG_HOOKS_DIR:=/etc/newpkg/hooks}"
: "${DB_BACKUP_KEEP:=5}"

# Tools
JQ_BIN="$(command -v jq || true)"
TAR_BIN="$(command -v tar || true)"
ZSTD_BIN="$(command -v zstd || true)"
SHA256SUM_BIN="$(command -v sha256sum || true)"

# Ensure required tools
if [[ -z "$JQ_BIN" ]]; then
  echo "ERROR: 'jq' is required but not found in PATH." >&2
  exit 1
fi
if [[ -z "$TAR_BIN" ]]; then
  echo "ERROR: 'tar' is required but not found in PATH." >&2
  exit 1
fi

###########################
# Logging helpers
###########################
_log() {
  local level="$1"; shift
  local msg="$*"
  # If an external log function exists (from log.sh), use it
  if declare -F log_info >/dev/null 2>&1 && [[ "$level" == "INFO" ]]; then
    log_info "$msg" || true
    return 0
  fi
  if declare -F log_warn >/dev/null 2>&1 && [[ "$level" == "WARN" ]]; then
    log_warn "$msg" || true
    return 0
  fi
  if declare -F log_error >/dev/null 2>&1 && [[ "$level" == "ERROR" ]]; then
    log_error "$msg" || true
    return 0
  fi
  # Fallback to echo with prefix
  case "$level" in
    INFO)  echo "[INFO]  $msg" ;;
    WARN)  echo "[WARN]  $msg" >&2 ;;
    ERROR) echo "[ERROR] $msg" >&2 ;;
    DEBUG) [[ "${DB_DEBUG:-0}" -eq 1 ]] && echo "[DEBUG] $msg" ;; 
    *)     echo "[LOG]   $msg" ;;
  esac
}

log_info()  { _log INFO "$*"; }
log_warn()  { _log WARN "$*"; }
log_error() { _log ERROR "$*"; }
log_debug() { _log DEBUG "$*"; }

###########################
# Utilities
###########################
ensure_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    mkdir -p -- "$d"
  fi
}

timestamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

# run hooks if present: $1 = hook-name (e.g. db_add), rest are args
run_hooks() {
  local hookname="$1"; shift
  local dir="$NPKG_HOOKS_DIR/$hookname"
  if [[ -d "$dir" ]]; then
    log_debug "Running hooks in $dir"
    # Execute scripts in numeric order
    local hook
    for hook in "$dir"/*; do
      [[ -x "$hook" ]] || continue
      log_info "hook: running $hook"
      "$hook" "$@" || {
        log_warn "hook $hook returned non-zero"
        # Continue on non-zero for now — user can change hook behavior.
      }
    done
  fi
}

# safe canonical path
canonicalize() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$p"
  else
    # fallback: basic normalization
    echo "$(cd "$(dirname "$p")" 2>/dev/null || pwd)/$(basename "$p")"
  fi
}

###########################
# DB primitives
###########################
db_init() {
  ensure_dir "$NPKG_DB_DIR"
  ensure_dir "$NPKG_DB_BACKUP_DIR"
  ensure_dir "$NPKG_LOG_DIR"
  # Ensure ownership/perms (root user expected)
  chmod 0755 "$NPKG_DB_DIR" || true
  chmod 0755 "$NPKG_DB_BACKUP_DIR" || true
  log_info "DB initialized at $NPKG_DB_DIR"
}

# internal: find manifest file(s) for pkg or pkg-version
# arg: name or name-version or pattern
_find_manifests() {
  local q="$1"
  # exact if contains '/'
  if [[ "$q" == */* ]]; then
    # treat as path-like origin -> search manifests with origin matching
    # scanning manifests for origin equals q
    jq -r --arg o "$q" 'select(.origin==$o) | @sh "\(.name)-\(.version).json"' "$NPKG_DB_DIR"/*.json 2>/dev/null || true
    return
  fi

  # if contains '-' and a .json exists exactly: assume name-version
  if [[ "$q" == *-* ]]; then
    if [[ -f "$NPKG_DB_DIR/$q.json" ]]; then
      printf '%s\n' "$NPKG_DB_DIR/$q.json"
      return
    fi
  fi

  # otherwise, search manifests where .name == q
  local f
  for f in "$NPKG_DB_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if "$JQ_BIN" -e --arg n "$q" '.name == $n' "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
    fi
  done
}

# validate that manifest contains required fields
_validate_manifest() {
  local manifest="$1"
  if ! "$JQ_BIN" -e '.name and .version and .files' "$manifest" >/dev/null 2>&1; then
    log_error "Manifest missing required fields (name, version, files): $manifest"
    return 3
  fi
  return 0
}

# Add manifest: copy to db dir; options: --replace
db_add() {
  local manifest="$1"; shift
  local replace="no"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --replace) replace="yes"; shift ;;
      *) shift ;;
    esac
  done

  if [[ ! -f "$manifest" ]]; then
    log_error "Manifest not found: $manifest"
    return 3
  fi

  _validate_manifest "$manifest" || return $?

  local name version dest
  name="$("$JQ_BIN" -r '.name' "$manifest")"
  version="$("$JQ_BIN" -r '.version' "$manifest")"
  dest="$NPKG_DB_DIR/$name-$version.json"

  if [[ -f "$dest" ]]; then
    if [[ "$replace" == "yes" ]]; then
      # backup existing
      db_backup_single "$dest"
      log_info "Replacing existing manifest $dest"
    else
      log_error "Package $name-$version already exists in DB. Use --replace to overwrite."
      return 1
    fi
  fi

  cp -a -- "$manifest" "$dest" || {
    log_error "Failed to copy manifest to DB: $manifest -> $dest"
    return 4
  }

  # Run hooks for db_add if present
  run_hooks db_add "$dest"

  log_info "Added package manifest: $name-$version"
  return 0
}

# backup a single manifest (move to backup dir with timestamp)
db_backup_single() {
  local filepath="$1"
  ensure_dir "$NPKG_DB_BACKUP_DIR"
  local ts
  ts="$(timestamp)"
  local base
  base="$(basename "$filepath")"
  local dest="$NPKG_DB_BACKUP_DIR/${ts}-$base"
  mv -- "$filepath" "$dest" || {
    log_warn "Couldn't move $filepath to backup $dest"
    return 1
  }
  # maintain only DB_BACKUP_KEEP recent files
  (cd "$NPKG_DB_BACKUP_DIR" && ls -1t | tail -n +"$((DB_BACKUP_KEEP+1))" | xargs -r rm -f) || true
}

# Remove: pkg or pkg-version
db_remove() {
  local target="$1"; shift
  local force="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force="yes"; shift ;;
      *) shift ;;
    esac
  done

  # find manifests
  local found=()
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    found+=("$m")
  done < <(_find_manifests "$target")

  if [[ "${#found[@]}" -eq 0 ]]; then
    log_error "No manifests found for '$target'"
    return 2
  fi

  # If multiple found and not force, prompt / error
  if [[ "${#found[@]}" -gt 1 && "$force" != "yes" ]]; then
    log_warn "Multiple versions found for '$target':"
    for m in "${found[@]}"; do
      echo "  - $(basename "$m")"
    done
    log_warn "Use --force to remove all versions or specify name-version"
    return 1
  fi

  # Move manifests to backup dir
  for m in "${found[@]}"; do
    db_backup_single "$m" || {
      log_warn "Failed to backup $m; skipping removal"
      continue
    }
    log_info "Removed manifest $(basename "$m") (moved to backup)"
    run_hooks db_remove "$m"
  done
  return 0
}

# Query: print manifest or fields
db_query() {
  local target="$1"; shift
  local out_json="no"
  local field=""
  local files_only="no"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) out_json="yes"; shift ;;
      --field) field="$2"; shift 2 ;;
      --files) files_only="yes"; shift ;;
      *) shift ;;
    esac
  done

  local manifests
  manifests=()
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    manifests+=("$m")
  done < <(_find_manifests "$target")

  if [[ "${#manifests[@]}" -eq 0 ]]; then
    log_error "No manifest found for '$target'"
    return 2
  fi

  if [[ "$out_json" == "yes" && "${#manifests[@]}" -eq 1 ]]; then
    cat "${manifests[0]}"
    return 0
  fi

  # If field requested
  if [[ -n "$field" ]]; then
    for m in "${manifests[@]}"; do
      "$JQ_BIN" -r --arg f "$field" '.[$f] // empty' "$m" || true
    done
    return 0
  fi

  if [[ "$files_only" == "yes" ]]; then
    for m in "${manifests[@]}"; do
      # files may be array of strings or array of objects with path
      if "$JQ_BIN" -e '.files[0] | type == "object"' "${m}" >/dev/null 2>&1; then
        "$JQ_BIN" -r '.files[] | .path' "$m" || true
      else
        "$JQ_BIN" -r '.files[]' "$m" || true
      fi
    done
    return 0
  fi

  # Pretty print basic info
  for m in "${manifests[@]}"; do
    local name ver origin stage install_prefix build_date
    name="$("$JQ_BIN" -r '.name' "$m")"
    ver="$("$JQ_BIN" -r '.version' "$m")"
    origin="$("$JQ_BIN" -r '.origin // empty' "$m")"
    stage="$("$JQ_BIN" -r '.stage // empty' "$m")"
    install_prefix="$("$JQ_BIN" -r '.install_prefix // empty' "$m")"
    build_date="$("$JQ_BIN" -r '.build_date // empty' "$m")"
    cat <<EOF
Package: $name
Version: $ver
Origin:  $origin
Stage:   $stage
Prefix:  $install_prefix
Built:   $build_date
Manifest: $(realpath "$m")
EOF
    echo "----"
  done
}

# list packages
db_list() {
  local stage_filter=""
  local out_json="no"
  local count_only="no"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage) stage_filter="$2"; shift 2 ;;
      --json) out_json="yes"; shift ;;
      --count) count_only="yes"; shift ;;
      *) shift ;;
    esac
  done

  local manifests=()
  local f
  for f in "$NPKG_DB_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    manifests+=("$f")
  done

  if [[ -z "$stage_filter" ]]; then
    if [[ "$out_json" == "yes" ]]; then
      "$JQ_BIN" -s '.' "${manifests[@]}" 2>/dev/null || echo '[]'
      return 0
    fi
    if [[ "$count_only" == "yes" ]]; then
      echo "${#manifests[@]}"
      return 0
    fi
    for f in "${manifests[@]}"; do
      echo "$(jq -r '.name + "-" + .version' "$f")"
    done
    return 0
  fi

  # filter by stage
  local results=()
  for f in "${manifests[@]}"; do
    if "$JQ_BIN" -e --arg s "$stage_filter" '.stage == $s' "$f" >/dev/null 2>&1; then
      results+=("$f")
    fi
  done

  if [[ "$out_json" == "yes" ]]; then
    if [[ "${#results[@]}" -gt 0 ]]; then
      "$JQ_BIN" -s '.' "${results[@]}" 2>/dev/null || echo '[]'
    else
      echo '[]'
    fi
    return 0
  fi

  if [[ "$count_only" == "yes" ]]; then
    echo "${#results[@]}"
    return 0
  fi

  for f in "${results[@]}"; do
    echo "$(jq -r '.name + "-" + .version' "$f")"
  done
}

# revdeps: list packages that depend on target
db_revdeps() {
  local target="$1"
  local manifests=()
  local f
  for f in "$NPKG_DB_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    manifests+=("$f")
  done

  local res=()
  for f in "${manifests[@]}"; do
    # check build deps and run deps and provides
    if "$JQ_BIN" -e --arg t "$target" '(.depends.build // []) + (.depends.run // []) | index($t) != null' "$f" >/dev/null 2>&1; then
      res+=("$f")
      continue
    fi
    # Additionally, check for requirements with versions like "libfoo>=1.0"
    if "$JQ_BIN" -e --arg t "$target" '((.depends.build // []) + (.depends.run // [])) | map(split(/[<>=]/)[0]) | index($t) != null' "$f" >/dev/null 2>&1; then
      res+=("$f")
      continue
    fi
  done

  for f in "${res[@]}"; do
    echo "$(jq -r '.name + "-" + .version' "$f")"
  done
}

# provides: find which package provides a given installed file path
db_provides() {
  local filepath="$1"
  local manifests=()
  for f in "$NPKG_DB_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    # if files are objects with path field
    if "$JQ_BIN" -e --arg p "$filepath" '.files[0] | type == "object"' "$f" >/dev/null 2>&1; then
      if "$JQ_BIN" -e --arg p "$filepath" 'any(.files[]; .path == $p)' "$f" >/dev/null 2>&1; then
        echo "$(jq -r '.name + "-" + .version' "$f")"
      fi
    else
      if "$JQ_BIN" -e --arg p "$filepath" 'any(.files[]; . == $p)' "$f" >/dev/null 2>&1; then
        echo "$(jq -r '.name + "-" + .version' "$f")"
      fi
    fi
  done
}

# backup entire DB
db_backup() {
  ensure_dir "$NPKG_DB_BACKUP_DIR"
  local ts
  ts="$(timestamp)"
  local outfile="$NPKG_DB_BACKUP_DIR/db-${ts}.tar"
  if [[ -n "$ZSTD_BIN" ]]; then
    outfile="${outfile}.zst"
    "$TAR_BIN" -C "$(dirname "$NPKG_DB_DIR")" -cf - "$(basename "$NPKG_DB_DIR")" | "$ZSTD_BIN" -q -o "$outfile" || {
      log_error "Backup failed"
      return 1
    }
  else
    "$TAR_BIN" -C "$(dirname "$NPKG_DB_DIR")" -cf "$outfile" "$(basename "$NPKG_DB_DIR")" || {
      log_error "Backup failed"
      return 1
    }
  fi
  log_info "DB backup created: $outfile"
  # rotate backups
  (cd "$NPKG_DB_BACKUP_DIR" && ls -1t db-* 2>/dev/null | tail -n +"$((DB_BACKUP_KEEP+1))" | xargs -r rm -f) || true
  run_hooks db_backup "$outfile"
  return 0
}

# restore from backup file (tar or tar.zst)
db_restore() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    log_error "Backup file not found: $file"
    return 1
  fi
  # extract to temp dir first
  local tmp
  tmp="$(mktemp -d)"
  if [[ "$file" =~ \.zst$ ]] && [[ -n "$ZSTD_BIN" ]]; then
    "$ZSTD_BIN" -d -c "$file" | "$TAR_BIN" -C "$tmp" -xf - || {
      log_error "Failed to extract backup"
      rm -rf "$tmp"
      return 1
    }
  else
    "$TAR_BIN" -C "$tmp" -xf "$file" || {
      log_error "Failed to extract backup"
      rm -rf "$tmp"
      return 1
    }
  fi
  # Move extracted db into place (safe swap)
  local swp="${NPKG_DB_DIR}.old.$(timestamp)"
  if [[ -d "$NPKG_DB_DIR" ]]; then
    mv "$NPKG_DB_DIR" "$swp" || {
      log_error "Failed to move existing DB aside"
      rm -rf "$tmp"
      return 1
    }
  fi
  mv "$tmp/$(basename "$NPKG_DB_DIR")" "$NPKG_DB_DIR" || {
    log_error "Failed to move restored DB into place"
    # try to restore old
    [[ -d "$swp" ]] && mv "$swp" "$NPKG_DB_DIR" || true
    rm -rf "$tmp"
    return 1
  }
  rm -rf "$swp" || true
  log_info "DB restored from $file"
  run_hooks db_restore "$file"
  return 0
}

# verify: check files exist and optionally checksums
db_verify() {
  local target="$1"
  local manifests=()
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    manifests+=("$m")
  done < <(_find_manifests "$target")

  if [[ "${#manifests[@]}" -eq 0 ]]; then
    log_error "No manifest found for '$target'"
    return 2
  fi

  for m in "${manifests[@]}"; do
    log_info "Verifying manifest: $(basename "$m")"
    # Determine file item type
    if "$JQ_BIN" -e '.files[0] | type == "object"' "$m" >/dev/null 2>&1; then
      # objects with path & optional sha256
      local idx=0
      local count
      count="$("$JQ_BIN" '.files | length' "$m")"
      while [[ $idx -lt $count ]]; do
        local path="$("$JQ_BIN" -r ".files[$idx].path" "$m")"
        local hs
        hs="$("$JQ_BIN" -r ".files[$idx].sha256 // empty" "$m")"
        if [[ -z "$path" ]]; then
          log_warn "Empty path entry in manifest $m at index $idx"
          idx=$((idx+1)); continue
        fi
        if [[ ! -e "$path" ]]; then
          log_warn "Missing file: $path"
        else
          log_info "Found: $path"
          if [[ -n "$hs" && -n "$SHA256SUM_BIN" ]]; then
            local got
            got="$(sha256sum "$path" | awk '{print $1}')"
            if [[ "$got" != "$hs" ]]; then
              log_warn "sha256 mismatch for $path"
            else
              log_info "sha256 OK: $path"
            fi
          fi
        fi
        idx=$((idx+1))
      done
    else
      # files array of strings
      local f
      while IFS= read -r f; do
        if [[ -z "$f" ]]; then continue; fi
        if [[ ! -e "$f" ]]; then
          log_warn "Missing file: $f"
        else
          log_info "Found: $f"
        fi
      done < <("$JQ_BIN" -r '.files[]' "$m")
    fi
  done
}

# orphans: packages without reverse deps and optionally not explicitly installed
db_orphans() {
  local manifests=()
  local f
  for f in "$NPKG_DB_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    manifests+=("$f")
  done

  for f in "${manifests[@]}"; do
    local name
    name="$("$JQ_BIN" -r '.name' "$f")"
    # count revdeps
    local deps_count
    deps_count="$(db_revdeps "$name" | wc -l || true)"
    if [[ -z "$deps_count" || "$deps_count" -eq 0 ]]; then
      # skip if package has runtime deps (meaning it depends on others)??? but orphans defined as nobody depends on them
      echo "$(jq -r '.name + "-" + .version' "$f")"
    fi
  done
}

# search: search by name or description
db_search() {
  local term="$1"
  local f
  for f in "$NPKG_DB_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if "$JQ_BIN" -e --arg t "$term" '(.name | contains($t)) or (.description // "" | contains($t)) or (.origin // "" | contains($t))' "$f" >/dev/null 2>&1; then
      echo "$(jq -r '.name + "-" + .version + "  (" + (.origin // "") + ") "' "$f")"
    fi
  done
}

# size: estimate installed size by summing sizes of files
db_size() {
  local target="$1"
  local manifests=()
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    manifests+=("$m")
  done < <(_find_manifests "$target")

  if [[ "${#manifests[@]}" -eq 0 ]]; then
    log_error "No manifest found for '$target'"
    return 2
  fi

  local total=0
  for m in "${manifests[@]}"; do
    # iterate files
    if "$JQ_BIN" -e '.files[0] | type == "object"' "$m" >/dev/null 2>&1; then
      local idx=0
      local cnt="$("$JQ_BIN" '.files | length' "$m")"
      while [[ $idx -lt $cnt ]]; do
        local p="$("$JQ_BIN" -r ".files[$idx].path" "$m")"
        if [[ -f "$p" ]]; then
          local s
          s=$(stat -c%s "$p" 2>/dev/null || echo 0)
          total=$((total + s))
        fi
        idx=$((idx+1))
      done
    else
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if [[ -f "$p" ]]; then
          local s
          s=$(stat -c%s "$p" 2>/dev/null || echo 0)
          total=$((total + s))
        fi
      done < <("$JQ_BIN" -r '.files[]' "$m")
    fi
  done

  # print human-friendly
  if [[ "$total" -lt 1024 ]]; then
    echo "${total} bytes"
  elif [[ "$total" -lt $((1024*1024)) ]]; then
    printf "%.1f KiB\n" "$(awk "BEGIN {print $total/1024}")"
  elif [[ "$total" -lt $((1024*1024*1024)) ]]; then
    printf "%.1f MiB\n" "$(awk "BEGIN {print $total/1024/1024}")"
  else
    printf "%.1f GiB\n" "$(awk "BEGIN {print $total/1024/1024/1024}")"
  fi
}

###########################
# CLI dispatch
###########################
show_help() {
  sed -n '1,200p' "$0" | sed -n '1,120p'
  cat <<'EOF'

Commands:
  init
  add <manifest.json> [--replace]
  remove <pkg|pkg-version> [--force]
  query <pkg|pkg-version> [--json] [--field FIELD] [--files]
  list [--stage <stage>] [--json] [--count]
  revdeps <pkg>
  provides <file-path>
  backup
  restore <backup-file>
  verify <pkg|pkg-version>
  orphans
  search <term>
  size <pkg|pkg-version>
  help
EOF
}

main() {
  if [[ $# -lt 1 ]]; then
    show_help
    exit 1
  fi

  local cmd="$1"; shift

  # ensure base dirs exist for most commands
  case "$cmd" in
    init)
      db_init
      return $?
      ;;
    add|backup|restore|list|query|remove|revdeps|provides|verify|orphans|search|size)
      db_init
      ;;
  esac

  case "$cmd" in
    init) db_init ;;
    add) db_add "$@" ;;
    remove) db_remove "$@" ;;
    query) db_query "$@" ;;
    list) db_list "$@" ;;
    revdeps) 
      if [[ $# -lt 1 ]]; then echo "revdeps <pkg>"; return 1; fi
      db_revdeps "$1"
      ;;
    provides)
      if [[ $# -lt 1 ]]; then echo "provides <file>"; return 1; fi
      db_provides "$1"
      ;;
    backup) db_backup ;;
    restore)
      if [[ $# -lt 1 ]]; then echo "restore <file>"; return 1; fi
      db_restore "$1"
      ;;
    verify)
      if [[ $# -lt 1 ]]; then echo "verify <pkg>"; return 1; fi
      db_verify "$1"
      ;;
    orphans) db_orphans ;;
    search)
      if [[ $# -lt 1 ]]; then echo "search <term>"; return 1; fi
      db_search "$1"
      ;;
    size)
      if [[ $# -lt 1 ]]; then echo "size <pkg>"; return 1; fi
      db_size "$1"
      ;;
    help|-h|--help) show_help ;;
    *)
      echo "Unknown command: $cmd"
      show_help
      return 1
      ;;
  esac
}

# allow script to be sourced for function use
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
