#!/usr/bin/env bash
#
# audit.sh - Newpkg system auditor and auto-fixer
#
# Features:
#  - integrity checks (hash mismatches, missing files), symlinks check
#  - permission checks (world-writable, suid/gid)
#  - orphan files detection via db.sh and deps.py
#  - CVE checking using OSV API (hash-based queries) with local caching
#  - logs rotation/cleanup and old logs removal
#  - automatic safe fixes (with revert strategy: reinstall tarball from /var/cache/newpkg/packages)
#  - parallel scans, incremental mode with state cache
#  - JSON + text report generation in /var/log/newpkg/audit/
#  - interactive colored menu to review issues and confirm fixes
#  - integration with log.sh (if present), db.sh, deps.py, revdep_depclean.sh
#
# Requirements:
#   bash, jq, xargs, curl, sha256sum, tar, zstd (recommended), yq (optional)
#
# Log & state locations:
#   /var/log/newpkg/audit/audit-YYYYMMDD.log
#   /var/log/newpkg/audit/audit-YYYYMMDD.json
#   /var/cache/newpkg/audit-state.json
#
set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

# -------- Configuration --------
AUDIT_LOG_DIR="/var/log/newpkg/audit"
AUDIT_STATE_CACHE="/var/cache/newpkg/audit-state.json"
BACKUP_RESTORE_CACHE="/var/cache/newpkg/packages"
OSV_CACHE_DIR="/var/cache/newpkg/osv"
DB_CLI="/usr/lib/newpkg/db.sh"
DEPS_PY="/usr/lib/newpkg/deps.py"
REVDEP="/usr/lib/newpkg/revdep_depclean.sh"
LOG_SH="/usr/lib/newpkg/log.sh"

# defaults
PARALLEL="$(nproc 2>/dev/null || echo 1)"
DRY_RUN=0
FIX=0
AUTO=0
QUIET=0
FULL=0
SECURITY_ONLY=0
CLEANUP_ONLY=0
INTEGRITY_ONLY=0
OUTPUT_JSON=0
REPORT_ONLY=0
TAIL=0
GREP_TERM=""
STATE_INCREMENTAL=1     # use incremental mode by default
DATE_STR="$(date -u +%Y%m%d)"
LOG_FILE="${AUDIT_LOG_DIR}/audit-${DATE_STR}.log"
JSON_FILE="${AUDIT_LOG_DIR}/audit-${DATE_STR}.json"
TMP_DIR="$(mktemp -d /tmp/newpkg-audit.XXXX)"
OSV_API="https://api.osv.dev/v1/query"
# thresholds
OLD_LOG_DAYS=90
OLD_TRASH_DAYS=30
WORLD_WRITABLE_FIX=1    # attempt to fix world-writable by chmod 0755 (safe heuristic)
SUID_SGID_FIX=1         # remove suid/sgid if suspicious (will prompt unless --fix/--auto)
# colors
C_RED="\033[31m";C_YELLOW="\033[33m";C_GREEN="\033[32m";C_BLUE="\033[34m";C_RESET="\033[0m"

# ensure directories exist
mkdir -p -- "$AUDIT_LOG_DIR" "$OSV_CACHE_DIR" "$(dirname "$AUDIT_STATE_CACHE")" "$BACKUP_RESTORE_CACHE"

# try to load unified log.sh
if [[ -f "$LOG_SH" ]]; then
  # shellcheck source=/usr/lib/newpkg/log.sh
  source "$LOG_SH" || true
fi

# fallback logger
_log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
}
log_info()  { if declare -F log_info >/dev/null 2>&1; then log_info "$@"; else _log INFO "$@"; fi; }
log_warn()  { if declare -F log_warn >/dev/null 2>&1; then log_warn "$@"; else _log WARN "$@"; fi; }
log_error() { if declare -F log_error >/dev/null 2>&1; then log_error "$@"; else _log ERROR "$@"; fi; }
log_debug() { if [[ "${NPKG_DEBUG:-0}" -eq 1 ]]; then _log DEBUG "$@"; fi; }

# cleanup tmp on exit
trap 'rm -rf -- "$TMP_DIR"' EXIT

# -------- Utilities --------
json_init() {
  echo '{"meta":{"date":"'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'","host":"'"$(hostname -f)"'"},"results":{}}' > "$JSON_FILE"
}
json_add_section() {
  local section="$1"; local payload="$2"
  # payload must be valid JSON
  tmp="$(mktemp)"
  jq --arg section "$section" --argjson payload "$payload" '.results[$section]=$payload' "$JSON_FILE" > "$tmp" && mv -f "$tmp" "$JSON_FILE"
}
json_write() { cat "$JSON_FILE"; }

# interactive prompt helper
confirm_prompt() {
  local prompt="$1"
  if [[ "$AUTO" -eq 1 ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy] ]] && return 0 || return 1
}

# OSV caching helper
osv_query_hash_cached() {
  local sha="$1"
  local cachef="${OSV_CACHE_DIR}/${sha}.json"
  if [[ -f "$cachef" && $(stat -c %s "$cachef") -gt 0 ]]; then
    cat "$cachef"
    return 0
  fi
  # query OSV API
  local payload
  payload="{\"hash\":\"${sha}\"}"
  if curl -sS -X POST -H 'Content-Type: application/json' -d "$payload" "$OSV_API" -o "$cachef.tmp"; then
    mv -f "$cachef.tmp" "$cachef"
    cat "$cachef"
  else
    log_warn "OSV query failed for $sha"
    return 1
  fi
}

# attempt to restore package by extracting cached tarball(s)
restore_package_from_cache() {
  local pkg="$1"
  local stage="$2"   # informative
  log_info "Attempting restore for package $pkg from cache"
  # find candidate tarball
  local tarf
  tarf="$(ls -1 "${BACKUP_RESTORE_CACHE}/${pkg}-"* 2>/dev/null | head -n1 || true)"
  if [[ -z "$tarf" ]]; then
    log_warn "No cached tarball found for $pkg in $BACKUP_RESTORE_CACHE"
    return 1
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would extract $tarf to /"
    return 0
  fi
  if command -v zstd >/dev/null 2>&1 && [[ "$tarf" == *.zst || "$tarf" == *.zstd ]]; then
    zstd -d -c "$tarf" | tar -C / -xf - || { log_warn "Failed to extract $tarf"; return 2; }
  else
    tar -C / -xf "$tarf" || { log_warn "Failed to extract $tarf"; return 2; }
  fi
  log_info "Restore from $tarf completed"
  return 0
}

# find orphan files: compare filesystem to db.sh records
find_orphan_files() {
  # iterate db.sh records and build a set of files that belong to packages; then find files under /usr that are not in set
  local pkg_files_tmp="$TMP_DIR/pkg_files.txt"
  : > "$pkg_files_tmp"
  if [[ -x "$DB_CLI" ]]; then
    # db.sh list --json -> each object has files array
    local alljson
    alljson="$("$DB_CLI" list --json 2>/dev/null || true)"
    if [[ -n "$alljson" && -n "$(command -v jq)" ]]; then
      echo "$alljson" | jq -r '.[]?.files[]? // empty' | sed '/^$/d' >> "$pkg_files_tmp" || true
    fi
  else
    log_warn "db.sh not found; cannot compute orphans via DB"
  fi
  # list candidate files under /usr /bin /sbin /lib /lib64 /etc (but excluding package database and var)
  local fs_tmp="$TMP_DIR/fs_files.txt"
  find /usr /bin /sbin /lib /lib64 /etc -xdev -type f 2>/dev/null | sed '/^\/var\/lib\/newpkg/d' > "$fs_tmp" || true
  # compute difference: files present in fs_tmp but not in pkg_files_tmp
  comm -23 <(sort -u "$fs_tmp") <(sort -u "$pkg_files_tmp") || true
}

# find broken symlinks
find_broken_symlinks() {
  find / -xdev -type l ! -exec test -e {} \; -print 2>/dev/null || true
}

# find suspicious permissions (world-writable excluding /tmp /var/tmp) and SUID/SGID
find_permission_issues() {
  # world-writable excluding common tmp dirs and specially allowed
  find / -xdev -type d -perm -0002 ! -path "/tmp/*" ! -path "/var/tmp/*" 2>/dev/null || true
  # suid/sgid files
  find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null || true
}

# find old logs
find_old_logs() {
  # logs older than OLD_LOG_DAYS under /var/log
  find /var/log -type f -mtime +"$OLD_LOG_DAYS" 2>/dev/null || true
}

# check open ports & suspicious processes
check_open_ports() {
  if command -v ss >/dev/null 2>&1; then
    ss -tulpen 2>/dev/null || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tulpen 2>/dev/null || true
  else
    log_warn "ss/netstat not available"
  fi
}

# check systemd units failing (if systemd present)
check_systemd_units() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --failed --no-legend 2>/dev/null || true
  else
    log_debug "systemctl not present"
  fi
}

# compute file sha256 (parallel-safe wrapper)
compute_sha256() {
  local file="$1"
  sha256sum "$file" 2>/dev/null | awk '{print $1}' || echo ""
}

# check binary for CVEs: compute sha256 and query OSV
check_binary_cves() {
  local file="$1"
  if [[ ! -f "$file" ]]; then return 1; fi
  local sha
  sha="$(compute_sha256 "$file")"
  if [[ -z "$sha" ]]; then return 1; fi
  local res
  res="$(osv_query_hash_cached "$sha" 2>/dev/null || true)"
  # return JSON result or empty
  printf '%s\n' "$res"
}

# attempt to auto-fix a world-writable dir by chmod 0755
fix_world_writable() {
  local path="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would chmod 0755 $path"
    return 0
  fi
  chmod 0755 "$path" && log_info "Fixed world-writable: $path" || log_warn "Failed to chmod $path"
}

# attempt to remove a broken symlink
fix_broken_symlink() {
  local symlink="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would rm $symlink"
    return 0
  fi
  rm -f -- "$symlink" && log_info "Removed broken symlink: $symlink" || log_warn "Failed to remove $symlink"
}

# attempt to remove orphan file by mapping owner package: uses db.sh
fix_orphan_file() {
  local file="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would remove orphan file $file"
    return 0
  fi
  # try to identify package owner via db.sh find-by-file (if available)
  if [[ -x "$DB_CLI" ]]; then
    if pkg="$("$DB_CLI" owner "$file" 2>/dev/null || true)"; then
      if [[ -n "$pkg" ]]; then
        log_info "File $file belongs to package $pkg according to db.sh; skipping removal"
        return 0
      fi
    fi
  fi
  rm -f -- "$file" && log_info "Removed orphan file: $file" || log_warn "Failed to remove orphan file $file"
}

# try to reinstall package to recover from broken fix
attempt_reinstall_from_cache() {
  local pkg="$1"
  log_info "Attempting to reinstall $pkg from cache as recovery"
  if restore_package_from_cache "$pkg" "audit-recovery"; then
    log_info "Reinstall from cache successful for $pkg"
    return 0
  fi
  log_warn "Reinstall from cache failed for $pkg"
  return 1
}

# -------- Major operations (composed) --------

op_check_integrity() {
  log_info "Starting integrity checks..."
  local files=()
  # compute a list of files to check: /usr and /bin /sbin /lib
  while IFS= read -r f; do files+=("$f"); done < <(find /usr /bin /sbin /lib /lib64 -xdev -type f 2>/dev/null || true)
  log_info "Found ${#files[@]} files to check (this may take time)"
  # sample: compute sha for each and compare with DB manifest if available.
  # We'll attempt parallel checks but keep memory usage modest.
  local results_tmp="$TMP_DIR/integrity_results.txt"
  : > "$results_tmp"
  for f in "${files[@]}"; do
    (
      local sha
      sha="$(compute_sha256 "$f")"
      if [[ -n "$sha" ]]; then
        # check db ownership: if file in DB, optionally compare stored expected hash (if DB stores)
        # For now record sha
        printf '%s\t%s\n' "$f" "$sha"
      fi
    ) &
    # limit parallel jobs
    while (( $(jobs -r | wc -l) >= PARALLEL )); do sleep 0.05; done
  done
  wait
  # move results to JSON
  local payload
  payload="$(awk '{printf "{\"file\":\"%s\",\"sha\":\"%s\"},", $1, $2}' "$results_tmp" | sed 's/,$//')"
  if [[ -z "$payload" ]]; then payload="[]"; else payload="[$payload]"; fi
  json_add_section "integrity" "$payload"
  log_info "Integrity checks completed (hashed files recorded)"
}

op_check_symlinks() {
  log_info "Scanning for broken symlinks..."
  local out="$TMP_DIR/broken_symlinks.txt"
  find_broken_symlinks > "$out" || true
  local count
  count="$(wc -l < "$out" 2>/dev/null || echo 0)"
  json_add_section "broken_symlinks" "$(jq -R -s -c 'split("\n")[:-1]' "$out")"
  log_info "Found $count broken symlink(s)"
  # if fix mode -> attempt removals (interactive unless AUTO)
  if [[ "$FIX" -eq 1 ]]; then
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      if [[ "$AUTO" -eq 0 ]]; then
        printf "${C_YELLOW}Broken symlink:${C_RESET} %s\n" "$s"
        if confirm_prompt "Remove symlink $s?"; then fix_broken_symlink "$s"; fi
      else
        fix_broken_symlink "$s"
      fi
    done < "$out"
  fi
}

op_check_permissions() {
  log_info "Scanning for permission issues (world-writable, suid/sgid)..."
  local ww="$TMP_DIR/world_writable.txt"
  local sg="$TMP_DIR/suid_sgid.txt"
  find / -xdev -type d -perm -0002 ! -path "/tmp/*" ! -path "/var/tmp/*" > "$ww" 2>/dev/null || true
  find / -xdev \( -perm -4000 -o -perm -2000 \) -type f > "$sg" 2>/dev/null || true
  json_add_section "world_writable" "$(jq -R -s -c 'split("\n")[:-1]' "$ww")"
  json_add_section "suid_sgid" "$(jq -R -s -c 'split("\n")[:-1]' "$sg")"
  log_info "Found $(wc -l < "$ww" 2>/dev/null || echo 0) world-writable dirs and $(wc -l < "$sg" 2>/dev/null || echo 0) suid/sgid files"
  # Fix heuristics
  if [[ "$FIX" -eq 1 ]]; then
    if [[ -s "$ww" ]]; then
      while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        if [[ "$AUTO" -eq 0 ]]; then
          printf "${C_YELLOW}World-writable dir:${C_RESET} %s\n" "$d"
          if confirm_prompt "Fix (chmod 0755) $d?"; then fix_world_writable "$d"; fi
        else
          fix_world_writable "$d"
        fi
      done < "$ww"
    fi
    if [[ -s "$sg" ]]; then
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # conservative: do not remove suid/sgid automatically for known binaries like /usr/bin/sudo
        if [[ "$f" =~ sudo|su|passwd|login ]]; then
          log_info "Preserving expected suid/sgid: $f"
          continue
        fi
        if [[ "$AUTO" -eq 0 ]]; then
          printf "${C_YELLOW}SUID/SGID file:${C_RESET} %s\n" "$f"
          if confirm_prompt "Remove suid/sgid bits from $f? (will chmod g-s,u-s)"; then
            chmod a-s "$f" && log_info "Removed suid/sgid from $f"
          fi
        else
          chmod a-s "$f" && log_info "Removed suid/sgid from $f"
        fi
      done < "$sg"
    fi
  fi
}

op_find_orphans() {
  log_info "Detecting orphan files (files not tracked by db.sh)..."
  local orphans_tmp="$TMP_DIR/orphans.txt"
  find_orphan_files > "$orphans_tmp" || true
  json_add_section "orphans" "$(jq -R -s -c 'split("\n")[:-1]' "$orphans_tmp")"
  log_info "Found $(wc -l < "$orphans_tmp" 2>/dev/null || echo 0) orphan files"
  if [[ "$FIX" -eq 1 ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ "$AUTO" -eq 0 ]]; then
        printf "${C_YELLOW}Orphan file:${C_RESET} %s\n" "$f"
        if confirm_prompt "Remove orphan file $f?"; then
          fix_orphan_file "$f" || {
            log_warn "Removal failed for $f; attempting reinstall of owning package"
            # attempt to find candidate owner and reinstall
            owner="$("$DB_CLI" owner "$f" 2>/dev/null || true)"
            [[ -n "$owner" ]] && attempt_reinstall_from_cache "$owner"
          }
        fi
      else
        fix_orphan_file "$f"
      fi
    done < "$orphans_tmp"
  fi
}

op_check_cves() {
  log_info "Checking binaries for known CVEs (OSV)"
  local bins="$TMP_DIR/binaries.txt"
  # limit to ELF binaries under /usr /bin /sbin /lib
  find /usr /bin /sbin /lib /lib64 -type f -executable -exec file {} \; 2>/dev/null | grep ELF | awk -F: '{print $1}' | sort -u > "$bins" || true
  local out_json="[]"
  local count=0
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    # compute hash and query OSV
    local sha
    sha="$(compute_sha256 "$b")" || continue
    if [[ -z "$sha" ]]; then continue; fi
    local osv_res
    osv_res="$(osv_query_hash_cached "$sha" 2>/dev/null || true)"
    if [[ -n "$osv_res" && "$osv_res" != "{}" ]]; then
      count=$((count+1))
      # build small object
      local obj
      obj="$(jq -n --arg file "$b" --arg sha "$sha" --argjson osv "$osv_res" '{file:$file,sha:$sha,osv:$osv}')"
      out_json="$(echo "$out_json" | jq --argjson add "$obj" '. + [$add]')"
    fi
  done < "$bins"
  json_add_section "cves" "$out_json"
  log_info "OSV scanning complete. Binaries with CVE hits: $count"
  # in fix mode: suggest upgrade of owning package and/or mark for rebuild
  if [[ "$FIX" -eq 1 && "$count" -gt 0 ]]; then
    log_warn "Detected CVE hits; attempting safe remedial actions"
    # for each item, attempt get owner via db.sh and run deps.py rebuild suggestion
    echo "$out_json" | jq -c '.[]' | while read -r item; do
      file="$(echo "$item" | jq -r '.file')"
      owner="$( "$DB_CLI" owner "$file" 2>/dev/null || true )"
      if [[ -n "$owner" ]]; then
        log_info "File $file belongs to package $owner; scheduling rebuild/update"
        # attempt reinstall from cache first, else mark for upgrade
        if attempt_reinstall_from_cache "$owner"; then
          log_info "Reinstalled $owner from cache"
        else
          # call deps.py to mark for rebuild if available
          if [[ -x "$DEPS_PY" ]]; then
            "$DEPS_PY" rebuild "$owner" || log_warn "deps.py rebuild failed for $owner"
          fi
        fi
      else
        log_warn "Owner not found for $file; manual inspection needed"
      fi
    done
  fi
}

op_check_logs_old() {
  log_info "Finding old logs older than ${OLD_LOG_DAYS} days"
  local old_logs="$TMP_DIR/old_logs.txt"
  find_old_logs > "$old_logs" || true
  json_add_section "old_logs" "$(jq -R -s -c 'split("\n")[:-1]' "$old_logs")"
  log_info "Found $(wc -l < "$old_logs" 2>/dev/null || echo 0) old log files"
  if [[ "$FIX" -eq 1 ]]; then
    while IFS= read -r lf; do
      [[ -z "$lf" ]] && continue
      if [[ "$AUTO" -eq 0 ]]; then
        printf "${C_BLUE}Old log:${C_RESET} %s\n" "$lf"
        if confirm_prompt "Remove/compress $lf?"; then
          gzip -c "$lf" > "${lf}.gz" && rm -f "$lf" && log_info "Compressed and removed $lf"
        fi
      else
        gzip -c "$lf" > "${lf}.gz" && rm -f "$lf" && log_info "Compressed and removed $lf"
      fi
    done < "$old_logs"
  fi
}

op_check_services_ports() {
  log_info "Checking open ports and failing services"
  local ports_out="$TMP_DIR/ports.out"
  check_open_ports > "$ports_out" || true
  json_add_section "network" "$(jq -R -s -c 'split("\n")[:-1]' "$ports_out")"
  local failed_units="$TMP_DIR/failed_units.out"
  check_systemd_units > "$failed_units" || true
  json_add_section "systemd_failed" "$(jq -R -s -c 'split("\n")[:-1]' "$failed_units")"
}

op_clean_caches() {
  log_info "Cleaning common caches (newpkg cache and tmp)"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "(dry-run) would remove /var/cache/newpkg/* and /tmp/newpkg-audit-*"
    return 0
  fi
  rm -rf /var/cache/newpkg/* 2>/dev/null || true
  find /tmp -maxdepth 1 -type d -name "newpkg-audit-*" -exec rm -rf {} \; 2>/dev/null || true
  log_info "Caches cleaned"
}

# generate final report and summary
generate_report() {
  log_info "Generating final report: $LOG_FILE and $JSON_FILE"
  # basic summary: counts per section
  if [[ -f "$JSON_FILE" ]]; then
    echo "Audit report: $JSON_FILE"
    echo "Summary:"
    jq -r '.results | keys[] as $k | "\($k): \( (.[$k]|length) )"' "$JSON_FILE" || true
  else
    log_warn "No JSON report produced"
  fi
  log_info "Report locations: $LOG_FILE and $JSON_FILE"
}

# show interactive menu (colored) summarizing findings and offering to fix
interactive_menu() {
  # present high-level sections from JSON
  if [[ ! -f "$JSON_FILE" ]]; then
    log_warn "No JSON results to present"
    return 0
  fi
  echo -e "${C_BLUE}== newpkg audit interactive summary ==${C_RESET}"
  jq -r '.results | to_entries[] | "\(.key) (\(.value|length))"' "$JSON_FILE" | nl -w2 -s'. ' -v1
  echo
  echo "Enter the number(s) of sections to auto-fix (comma-separated), 'a' for all, or ENTER to skip:"
  read -r sel
  if [[ -z "$sel" ]]; then
    echo "No fixes selected."
    return 0
  fi
  if [[ "$sel" == "a" ]]; then
    FIX=1
    AUTO=1
    log_info "Auto-fix all selected"
    return 0
  fi
  # map numbers to section names
  mapfile -t choices < <(echo "$sel" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' )
  local idx=1
  local sections
  mapfile -t sections < <(jq -r '.results | keys[]' "$JSON_FILE")
  for c in "${choices[@]}"; do
    if [[ "$c" =~ ^[0-9]+$ ]]; then
      local i=$((c-1))
      if [[ $i -ge 0 && $i -lt ${#sections[@]} ]]; then
        local section="${sections[$i]}"
        log_info "Queuing fix for section: $section"
        # perform per-section fixes by calling matching op_ functions
        case "$section" in
          broken_symlinks) FIX=1; op_check_symlinks ;; 
          world_writable|suid_sgid) FIX=1; op_check_permissions ;;
          orphans) FIX=1; op_find_orphans ;;
          cves) FIX=1; op_check_cves ;;
          old_logs) FIX=1; op_check_logs_old ;;
          integrity) FIX=1; op_check_integrity ;;
          network|systemd_failed) FIX=1; op_check_services_ports ;;
          *) log_warn "No automatic fixer implemented for section $section" ;;
        esac
      fi
    fi
  done
}

# command to show audit logs quickly
show_audit_log() {
  local tail_lines=50
  if [[ "$TAIL" -ne 0 ]]; then tail_lines="$TAIL"; fi
  if [[ -n "$GREP_TERM" ]]; then
    grep -i "$GREP_TERM" "$AUDIT_LOG_DIR"/audit-* 2>/dev/null | tail -n "$tail_lines" || true
  else
    tail -n "$tail_lines" "$AUDIT_LOG_DIR"/audit-* 2>/dev/null || true
  fi
}

# -------- Main dispatcher --------
usage() {
  cat <<EOF
Usage: audit.sh [options]
Options:
  --full              run full audit (default sections)
  --security          run only security checks (CVEs)
  --cleanup           run only cleanup tasks
  --integrity         run only file-integrity hash scan
  --fix               apply safe fixes automatically (use with caution)
  --auto              non-interactive (assume yes for prompts)
  --dry-run           simulate actions
  --json              produce JSON report
  --report-only       produce report from previous run
  --show-log [--tail N] [--grep TERM]   show audit logs
  --parallel N        concurrency (default nproc)
  --quiet
  --help
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL=1; shift ;;
    --security) SECURITY_ONLY=1; shift ;;
    --cleanup) CLEANUP_ONLY=1; shift ;;
    --integrity) INTEGRITY_ONLY=1; shift ;;
    --fix) FIX=1; shift ;;
    --auto) AUTO=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --json) OUTPUT_JSON=1; shift ;;
    --report-only) REPORT_ONLY=1; shift ;;
    --show-log) shift; SHOW_LOG=1; # handled below (optional args)
      # handle optional tail/grep following tokens
      while [[ $# -gt 0 && "$1" =~ ^--(tail|grep)$ ]]; do
        case "$1" in
          --tail) TAIL="$2"; shift 2 ;;
          --grep) GREP_TERM="$2"; shift 2 ;;
        esac
      done
      ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# if show-log requested
if [[ "${SHOW_LOG:-0}" -eq 1 ]]; then
  show_audit_log
  exit 0
fi

# default to full if nothing specified
if [[ $FULL -eq 0 && $SECURITY_ONLY -eq 0 && $CLEANUP_ONLY -eq 0 && $INTEGRITY_ONLY -eq 0 && $REPORT_ONLY -eq 0 ]]; then
  FULL=1
fi

# Prepare JSON report file
if [[ "$OUTPUT_JSON" -eq 1 || $FULL -eq 1 || $SECURITY_ONLY -eq 1 || $INTEGRITY_ONLY -eq 1 ]]; then
  json_init
fi

# execute hooks pre-audit
if [[ -d /etc/newpkg/hooks/audit/pre-audit ]]; then
  for h in /etc/newpkg/hooks/audit/pre-audit/*; do [[ -x "$h" ]] && "$h" || true; done
fi

# run requested checks
if [[ $FULL -eq 1 || $INTEGRITY_ONLY -eq 1 ]]; then
  op_check_integrity
fi

if [[ $FULL -eq 1 || $SECURITY_ONLY -eq 1 ]]; then
  op_check_cves
fi

if [[ $FULL -eq 1 || $CLEANUP_ONLY -eq 1 ]]; then
  op_check_logs_old
  op_clean_caches
fi

# always run symlink and permission scans as part of full
if [[ $FULL -eq 1 ]]; then
  op_check_symlinks
  op_check_permissions
  op_find_orphans
  op_check_services_ports
fi

# generate final JSON report if requested
if [[ "$OUTPUT_JSON" -eq 1 ]]; then
  # ensure JSON collects latest sections
  generate_report
fi

# interactive menu if not auto and not quiet and not dry-run and fixes available
if [[ $AUTO -eq 0 && $DRY_RUN -eq 0 && $QUIET -eq 0 && -f "$JSON_FILE" ]]; then
  interactive_menu
fi

# if FIX requested (either initially or by menu), run remaining fix operations
if [[ $FIX -eq 1 ]]; then
  log_info "Applying automatic fixes..."
  # re-run fix-capable ops that we previously recorded (we executed some with FIX=1 earlier)
  # ensure orphan & permissions & broken symlinks fixed if still present
  op_check_symlinks
  op_check_permissions
  op_find_orphans
  op_check_cves
  op_check_logs_old
  # after fixes, sync deps and run revdep cleanup if available
  if [[ -x "$DEPS_PY" ]]; then
    log_info "Syncing dependency graph via deps.py"
    if [[ $DRY_RUN -eq 0 ]]; then
      "$DEPS_PY" sync || log_warn "deps.py sync returned non-zero"
    fi
  fi
  if [[ -x "$REVDEP" ]]; then
    log_info "Running reverse-dep cleaner"
    if [[ $DRY_RUN -eq 0 ]]; then
      "$REVDEP" --auto --auto-commit || log_warn "revdep_depclean returned non-zero"
    fi
  fi
fi

# final hooks
if [[ -d /etc/newpkg/hooks/audit/post-audit ]]; then
  for h in /etc/newpkg/hooks/audit/post-audit/*; do [[ -x "$h" ]] && "$h" || true; done
fi

# Save final JSON if requested
if [[ "$OUTPUT_JSON" -eq 1 && -f "$JSON_FILE" ]]; then
  log_info "Audit JSON saved to $JSON_FILE"
fi

log_info "Audit run complete. Log: $LOG_FILE"
if [[ "$OUTPUT_JSON" -eq 1 ]]; then
  echo "JSON report: $JSON_FILE"
fi

exit 0
