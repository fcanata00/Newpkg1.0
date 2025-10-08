#!/usr/bin/env bash
# db.sh - package metadata DB for newpkg (with incremental index + hooks + backups)
# Requires: bash, jq, tar, (zstd optional), realpath optional
#
# Save: /usr/lib/newpkg/db.sh
# Make executable: chmod +x /usr/lib/newpkg/db.sh

set -o errexit
set -o nounset
set -o pipefail

###########################
# Configuration & globals
###########################
: "${NPKG_DB_DIR:=/var/lib/newpkg/db}"
: "${NPKG_DB_BACKUP_DIR:=/var/lib/newpkg/db-backup}"
: "${NPKG_LOG_DIR:=/var/log/newpkg}"
: "${NPKG_HOOKS_DIR:=/etc/newpkg/hooks}"
: "${DB_BACKUP_KEEP:=5}"
INDEX_FILE="${NPKG_DB_DIR}/index.json"

# Tools
JQ_BIN="$(command -v jq || true)"
TAR_BIN="$(command -v tar || true)"
ZSTD_BIN="$(command -v zstd || true)"
REALPATH_BIN="$(command -v realpath || true)"
SHA256SUM_BIN="$(command -v sha256sum || true)"

# Ensure required tool jq
if [[ -z "$JQ_BIN" ]]; then
  echo "ERROR: 'jq' is required but not found in PATH." >&2
  exit 1
fi
if [[ -z "$TAR_BIN" ]]; then
  echo "ERROR: 'tar' is required but not found in PATH." >&2
  exit 1
fi

# Attempt to source log.sh if present
if [[ -f "/usr/lib/newpkg/log.sh" ]]; then
  # shellcheck source=/usr/lib/newpkg/log.sh
  source /usr/lib/newpkg/log.sh || true
elif [[ -f "/etc/newpkg/log.sh" ]]; then
  # shellcheck source=/etc/newpkg/log.sh
  source /etc/newpkg/log.sh || true
fi

# Fallback logging if log.sh didn't define functions
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
  # fallback simple
  case "$lvl" in
    INFO) printf '[INFO] %s\n' "$*" ;;
    WARN) printf '[WARN] %s\n' "$*" >&2 ;;
    ERROR) printf '[ERROR] %s\n' "$*" >&2 ;;
    DEBUG) [[ "${NPKG_DEBUG:-0}" -eq 1 ]] && printf '[DEBUG] %s\n' "$*" ;;
    *) printf '%s\n' "$*" ;;
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

timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }

canonicalize() {
  local p="$1"
  if [[ -n "$REALPATH_BIN" ]]; then
    "$REALPATH_BIN" -m -- "$p"
  else
    echo "$(cd "$(dirname "$p")" 2>/dev/null || pwd)/$(basename "$p")"
  fi
}

run_hooks() {
  local hookname="$1"; shift
  local dir="$NPKG_HOOKS_DIR/$hookname"
  if [[ -d "$dir" ]]; then
    log_debug "Running hooks in $dir"
    local hook
    for hook in "$dir"/*; do
      [[ -x "$hook" ]] || continue
      log_info "hook: running $hook"
      "$hook" "$@" || {
        log_warn "hook $hook returned non-zero"
        # do not abort by default
      }
    done
  fi
}

# Atomic write helper for JSON files
_atomic_write() {
  local src_content="$1"
  local dest="$2"
  local tmp
  tmp="$(mktemp "${dest}.tmp.XXXX")"
  printf '%s' "$src_content" >"$tmp"
  sync "$tmp" || true
  mv -f "$tmp" "$dest"
}

###########################
# DB primitives + Index
###########################
db_init() {
  ensure_dir "$NPKG_DB_DIR"
  ensure_dir "$NPKG_DB_BACKUP_DIR"
  ensure_dir "$NPKG_LOG_DIR"
  # ensure index exists
  if [[ ! -f "$INDEX_FILE" ]]; then
    printf '[]' >"$INDEX_FILE"
  fi
  chmod 0755 "$NPKG_DB_DIR" || true
  chmod 0755 "$NPKG_DB_BACKUP_DIR" || true
  log_info "DB initialized at $NPKG_DB_DIR (index: $INDEX_FILE)"
}

_validate_manifest() {
  local manifest="$1"
  if ! "$JQ_BIN" -e '.name and .version and .files' "$manifest" >/dev/null 2>&1; then
    log_error "Manifest missing required fields (name, version, files): $manifest"
    return 3
  fi
  return 0
}

# rebuild index scanning all manifests
db_reindex() {
  log_info "Rebuilding index from manifests in $NPKG_DB_DIR..."
  local tmp
  tmp="$(mktemp "${INDEX_FILE}.tmp.XXXX")"
  printf '%s\n' "[" >"$tmp"
  local first=1
  local f
  for f in "$NPKG_DB_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    # create index entry
    local entry
    entry="$("$JQ_BIN" -c '{name: .name, version: .version, origin: (.origin // ""), provides: (.provides // []), depends: (.depends // {}), stage: (.stage // "normal"), manifest: ( .name + "-" + .version + ".json") }' "$f")"
    if [[ $first -eq 1 ]]; then
      printf '%s' "$entry" >>"$tmp"
      first=0
    else
      printf ',%s' "$entry" >>"$tmp"
    fi
  done
  printf ']' >>"$tmp"
  mv -f "$tmp" "$INDEX_FILE"
  log_info "Index rebuilt: $(wc -c <"$INDEX_FILE") bytes"
  run_hooks db_reindex "$INDEX_FILE"
}

# internal: add/update index entry (atomic)
_index_add_or_replace() {
  local manifest_path="$1"  # full path to manifest file in db dir
  if [[ ! -f "$manifest_path" ]]; then
    log_warn "Index add: manifest not present: $manifest_path"
    return 1
  fi
  local name version
  name="$("$JQ_BIN" -r '.name' "$manifest_path")"
  version="$("$JQ_BIN" -r '.version' "$manifest_path")"
  local entry
  entry="$("$JQ_BIN" -c '{name: .name, version: .version, origin: (.origin // ""), provides: (.provides // []), depends: (.depends // {}), stage: (.stage // "normal"), manifest: (.name + "-" + .version + ".json") }' "$manifest_path")"

  # build new index by reading existing and filtering out same name-version then appending entry
  local tmp
  tmp="$(mktemp "${INDEX_FILE}.tmp.XXXX")"
  "$JQ_BIN" -c --argjson new "$entry" '. as $idx | map(select(.name != $new.name or .version != $new.version)) + [$new]' "$INDEX_FILE" >"$tmp" || {
    # if jq fails (e.g., empty index), simply write [entry]
    printf '[%s]\n' "$entry" >"$tmp"
  }
  mv -f "$tmp" "$INDEX_FILE"
  log_debug "Index updated (add/replace) for $name-$version"
}

# internal: remove index entries matching name or name-version
_index_remove() {
  local query="$1"  # name or name-version
  local pattern_name pattern_name_version
  if [[ "$query" == *-* ]]; then
    pattern_name_version="$query"
    pattern_name="${query%%-*}"
  else
    pattern_name="$query"
    pattern_name_version=""
  fi
  local tmp
  tmp="$(mktemp "${INDEX_FILE}.tmp.XXXX")"
  if [[ -n "$pattern_name_version" ]]; then
    "$JQ_BIN" 'map(select(.name + "-" + .version != "'"$pattern_name_version"'"))' "$INDEX_FILE" >"$tmp"
  else
    "$JQ_BIN" 'map(select(.name != "'"$pattern_name"'"))' "$INDEX_FILE" >"$tmp"
  fi
  mv -f "$tmp" "$INDEX_FILE"
  log_debug "Index remove applied for query=$query"
}

# copy manifest into db dir and update index; options: --replace
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

  # Update index
  _index_add_or_replace "$dest"

  # post-add hooks
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
  (cd "$NPKG_DB_BACKUP_DIR" && ls -1t 2>/dev/null | tail -n +"$((DB_BACKUP_KEEP+1))" | xargs -r rm -f) || true
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

  # collect manifests matching query
  local matches=()
  if [[ -f "$NPKG_DB_DIR/$target.json" ]]; then
    matches+=("$NPKG_DB_DIR/$target.json")
  else
    # match by name
    for f in "$NPKG_DB_DIR/$target-"*.json; do
      [[ -f "$f" ]] || continue
      matches+=("$f")
    done
    # try exact name (single version) search
    for f in "$NPKG_DB_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      if "$JQ_BIN" -e --arg n "$target" '.name == $n' "$f" >/dev/null 2>&1; then
        matches+=("$f")
      fi
    done
  fi

  if [[ "${#matches[@]}" -eq 0 ]]; then
    log_error "No manifests found for '$target'"
    return 2
  fi

  if [[ "${#matches[@]}" -gt 1 && "$force" != "yes" ]]; then
    log_warn "Multiple versions found for '$target':"
    for m in "${matches[@]}"; do
      echo "  - $(basename "$m")"
    done
    log_warn "Use --force to remove all versions or specify name-version"
    return 1
  fi

  for m in "${matches[@]}"; do
    # backup then remove file
    db_backup_single "$m" || {
      log_warn "Failed to backup $m; skipping removal"
      continue
    }
    local base
    base="$(basename "$m")"
    # update index
    local qname
    qname="$("$JQ_BIN" -r '.name + "-" + .version' "$m")"
    _index_remove "$qname"
    # run hooks with original manifest path
    run_hooks db_remove "$m"
    log_info "Removed manifest $base (moved to backup)"
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

  # If a direct filename
  if [[ -f "$NPKG_DB_DIR/$target.json" ]]; then
    if [[ "$out_json" == "yes" ]]; then
      cat "$NPKG_DB_DIR/$target.json"
      return 0
    fi
    target="$(jq -r '.name' "$NPKG_DB_DIR/$target.json")"
  fi

  # search by name: prefer index for speed
  if [[ -f "$INDEX_FILE" ]]; then
    local hits
    hits="$("$JQ_BIN" -c --arg n "$target" 'map(select(.name == $n))' "$INDEX_FILE")"
    if [[ "$hits" != "[]" ]]; then
      # iterate hits
      echo "$hits" | while IFS= read -r item; do
        local manifest_file
        manifest_file="$NPKG_DB_DIR/$(echo "$item" | "$JQ_BIN" -r '.manifest')"
        if [[ ! -f "$manifest_file" ]]; then
          # manifest missing — schedule reindex maybe
          log_warn "Manifest referenced in index missing: $manifest_file"
          continue
        fi
        if [[ "$out_json" == "yes" ]]; then
          cat "$manifest_file"
          continue
        fi
        if [[ -n "$field" ]]; then
          "$JQ_BIN" -r --arg f "$field" '.[$f] // empty' "$manifest_file" || true
          continue
        fi
        if [[ "$files_only" == "yes" ]]; then
          if "$JQ_BIN" -e '.files[0] | type == "object"' "$manifest_file" >/dev/null 2>&1; then
            "$JQ_BIN" -r '.files[] | .path' "$manifest_file" || true
          else
            "$JQ_BIN" -r '.files[]' "$manifest_file" || true
          fi
          continue
        fi
        # pretty print basic info
        local name ver origin stage install_prefix build_date
        name="$("$JQ_BIN" -r '.name' "$manifest_file")"
        ver="$("$JQ_BIN" -r '.version' "$manifest_file")"
        origin="$("$JQ_BIN" -r '.origin // empty' "$manifest_file")"
        stage="$("$JQ_BIN" -r '.stage // empty' "$manifest_file")"
        install_prefix="$("$JQ_BIN" -r '.install_prefix // empty' "$manifest_file")"
        build_date="$("$JQ_BIN" -r '.build_date // empty' "$manifest_file")"
        cat <<EOF
Package: $name
Version: $ver
Origin:  $origin
Stage:   $stage
Prefix:  $install_prefix
Built:   $build_date
Manifest: $(canonicalize "$manifest_file")
EOF
        echo "----"
      done
      return 0
    fi
  fi

  # fallback: scan manifests (slower)
  local found=()
  for f in "$NPKG_DB_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if "$JQ_BIN" -e --arg n "$target" '.name == $n or (.name + "-" + .version) == $n' "$f" >/dev/null 2>&1; then
      found+=("$f")
    fi
  done

  if [[ "${#found[@]}" -eq 0 ]]; then
    log_error "No manifest found for '$target'"
    return 2
  fi

  if [[ "$out_json" == "yes" && "${#found[@]}" -eq 1 ]]; then
    cat "${found[0]}"
    return 0
  fi

  for m in "${found[@]}"; do
    if [[ -n "$field" ]]; then
      "$JQ_BIN" -r --arg f "$field" '.[$f] // empty' "$m" || true
      continue
    fi
    if [[ "$files_only" == "yes" ]]; then
      if "$JQ_BIN" -e '.files[0] | type == "object"' "$m" >/dev/null 2>&1; then
        "$JQ_BIN" -r '.files[] | .path' "$m" || true
      else
        "$JQ_BIN" -r '.files[]' "$m" || true
      fi
      continue
    fi
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
Manifest: $(canonicalize "$m")
EOF
    echo "----"
  done
}

# list packages (with optional stage filter)
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

  if [[ "$out_json" == "yes" ]]; then
    if [[ -n "$stage_filter" ]]; then
      "$JQ_BIN" --arg s "$stage_filter" 'map(select(.stage == $s))' "$INDEX_FILE"
    else
      cat "$INDEX_FILE"
    fi
    return 0
  fi

  if [[ -n "$stage_filter" ]]; then
    "$JQ_BIN" -r --arg s "$stage_filter" '.[] | select(.stage == $s) | .name + "-" + .version' "$INDEX_FILE"
    return 0
  fi

  if [[ "$count_only" == "yes" ]]; then
    "$JQ_BIN" 'length' "$INDEX_FILE"
    return 0
  fi

  "$JQ_BIN" -r '.[] | .name + "-" + .version' "$INDEX_FILE"
}

# revdeps: use index for faster lookup
db_revdeps() {
  local target="$1"
  # look for packages where depends.build or depends.run contain the target (naive matching)
  "$JQ_BIN" -r --arg t "$target" '
    .[] |
    select(
      ( .depends.build? // [] | map( (.|tostring) ) | index($t) != null )
      or
      ( .depends.run? // [] | map( (.|tostring) ) | index($t) != null )
      or
      ( .provides? // [] | index($t) != null )
    )
    | .name + "-" + .version
  ' "$INDEX_FILE"
}

# provides: lookup package by file path by scanning manifests (index doesn't store file lists)
db_provides() {
  local filepath="$1"
  for f in "$NPKG_DB_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if "$JQ_BIN" -e --arg p "$filepath" 'any(.files[]; type=="object" and .path == $p) or any(.files[]; . == $p)' "$f" >/dev/null 2>&1; then
      echo "$(jq -r '.name + "-" + .version' "$f")"
    fi
  done
}

# backup entire DB (tar + optional zstd)
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
}

# restore from backup
db_restore() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    log_error "Backup file not found: $file"
    return 1
  fi
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
  # safe swap
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
    [[ -d "$swp" ]] && mv "$swp" "$NPKG_DB_DIR" || true
    rm -rf "$tmp"
    return 1
  }
  rm -rf "$swp" || true
  log_info "DB restored from $file"
  run_hooks db_restore "$file"
  # rebuild index to ensure consistency
  db_reindex
}

# verify manifest files exist and optional checksums
db_verify() {
  local target="$1"
  local manifests=()
  # find matching via index
  local hits
  hits="$("$JQ_BIN" -c --arg n "$target" 'map(select(.name == $n or (.name + "-" + .version) == $n))' "$INDEX_FILE" 2>/dev/null || true)"
  if [[ -n "$hits" && "$hits" != "[]" ]]; then
    # iterate hits
    echo "$hits" | while IFS= read -r item; do
      local mf="$NPKG_DB_DIR/$(echo "$item" | "$JQ_BIN" -r '.manifest')"
      "$JQ_BIN" -e '.files[0] | type == "object"' "$mf" >/dev/null 2>&1 && {
        local cnt="$("$JQ_BIN" '.files | length' "$mf")"
        for ((i=0;i<cnt;i++)); do
          local p hs
          p="$("$JQ_BIN" -r ".files[$i].path" "$mf")"
          hs="$("$JQ_BIN" -r ".files[$i].sha256 // empty" "$mf")"
          if [[ ! -e "$p" ]]; then
            log_warn "Missing: $p"
          else
            log_info "Found: $p"
            if [[ -n "$hs" && -n "$SHA256SUM_BIN" ]]; then
              local got
              got="$(sha256sum "$p" | awk '{print $1}')"
              if [[ "$got" != "$hs" ]]; then
                log_warn "sha256 mismatch: $p"
              else
                log_info "sha256 OK: $p"
              fi
            fi
          fi
        done
      } || {
        # simple list
        "$JQ_BIN" -r '.files[]' "$mf" | while IFS= read -r p; do
          if [[ ! -e "$p" ]]; then
            log_warn "Missing: $p"
          else
            log_info "Found: $p"
          fi
        done
      }
    done
    return 0
  fi
  # fallback to scanning manifests
  for f in "$NPKG_DB_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if "$JQ_BIN" -e --arg n "$target" '.name == $n or (.name + "-" + .version) == $n' "$f" >/dev/null 2>&1; then
      db_verify "$f" || true
    fi
  done
}

# orphans: list packages with zero revdeps
db_orphans() {
  local total
  total="$("$JQ_BIN" 'length' "$INDEX_FILE")"
  if [[ "$total" -eq 0 ]]; then
    echo ""
    return 0
  fi
  local names
  names="$("$JQ_BIN" -r '.[].name' "$INDEX_FILE" | sort -u)"
  for n in $names; do
    local rdeps
    rdeps="$(db_revdeps "$n" | wc -l || true)"
    if [[ -z "$rdeps" || "$rdeps" -eq 0 ]]; then
      # print latest version if multiple
      "$JQ_BIN" -r --arg n "$n" 'map(select(.name==$n)) | max_by(.version) | .name + "-" + .version' "$INDEX_FILE"
    fi
  done
}

# search by name/description/origin
db_search() {
  local term="$1"
  "$JQ_BIN" -r --arg t "$term" '.[] | select( (.name|contains($t)) or (.origin|contains($t)) ) | .name + "-" + .version + " (" + .origin + ")"' "$INDEX_FILE"
}

# size: sum file sizes for manifest(s)
db_size() {
  local target="$1"
  local total=0
  # find relevant manifests via index
  local hits
  hits="$("$JQ_BIN" -c --arg n "$target" 'map(select(.name == $n or (.name + "-" + .version) == $n))' "$INDEX_FILE" 2>/dev/null || true)"
  if [[ -n "$hits" && "$hits" != "[]" ]]; then
    echo "$hits" | while IFS= read -r item; do
      local mf="$NPKG_DB_DIR/$(echo "$item" | "$JQ_BIN" -r '.manifest')"
      if [[ ! -f "$mf" ]]; then continue; fi
      # accumulate
      if "$JQ_BIN" -e '.files[0] | type == "object"' "$mf" >/dev/null 2>&1; then
        local cnt
        cnt="$("$JQ_BIN" '.files | length' "$mf")"
        for ((i=0;i<cnt;i++)); do
          local p
          p="$("$JQ_BIN" -r ".files[$i].path" "$mf")"
          if [[ -f "$p" ]]; then
            total=$((total + $(stat -c%s "$p" 2>/dev/null || echo 0)))
          fi
        done
      else
        while IFS= read -r p; do
          [[ -z "$p" ]] && continue
          if [[ -f "$p" ]]; then
            total=$((total + $(stat -c%s "$p" 2>/dev/null || echo 0)))
          fi
        done < <("$JQ_BIN" -r '.files[]' "$mf")
      fi
    done
  fi
  # print human readable
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
  cat <<'EOF'
db.sh - package metadata DB for newpkg (with index)
Usage: db.sh <command> [args...]

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
  reindex
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

  case "$cmd" in
    init)
      db_init; return $?
      ;;
  esac

  # ensure db exists for other commands
  db_init

  case "$cmd" in
    add) db_add "$@" ;;
    remove) db_remove "$@" ;;
    query) db_query "$@" ;;
    list) db_list "$@" ;;
    revdeps) db_revdeps "$@" ;;
    provides) db_provides "$@" ;;
    backup) db_backup ;;
    restore) db_restore "$@" ;;
    reindex) db_reindex ;;
    verify) db_verify "$@" ;;
    orphans) db_orphans ;;
    search) db_search "$@" ;;
    size) db_size "$@" ;;
    help|-h|--help) show_help ;;
    *) log_error "Unknown command: $cmd"; show_help; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
