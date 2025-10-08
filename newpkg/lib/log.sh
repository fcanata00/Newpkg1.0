#!/usr/bin/env bash
# log.sh - simple colored logger for newpkg
# Exports: log_info, log_warn, log_error, log_debug, log_step
# Rotates log file when exceeds N bytes (default 1MB)
#
# Usage: source /usr/lib/newpkg/log.sh

: "${NPKG_LOG_DIR:=/var/log/newpkg}"
: "${NPKG_LOG_FILE:=${NPKG_LOG_DIR}/db.log}"
: "${NPKG_LOG_MAX_BYTES:=1048576}"   # 1MiB
: "${NPKG_LOG_ROTATE_KEEP:=5}"

ensure_log_dir() {
  if [[ ! -d "$NPKG_LOG_DIR" ]]; then
    mkdir -p -- "$NPKG_LOG_DIR" 2>/dev/null || return 1
  fi
}

_rotate_log_if_needed() {
  ensure_log_dir || return
  if [[ -f "$NPKG_LOG_FILE" ]]; then
    local size
    size=$(stat -c%s "$NPKG_LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -ge "$NPKG_LOG_MAX_BYTES" ]]; then
      local ts
      ts=$(date -u +"%Y%m%dT%H%M%SZ")
      mv "$NPKG_LOG_FILE" "${NPKG_LOG_FILE}.${ts}" 2>/dev/null || true
      # compress rotated with zstd if available
      if command -v zstd >/dev/null 2>&1; then
        zstd -q "${NPKG_LOG_FILE}.${ts}" || true
      fi
      # cleanup old logs
      (cd "$NPKG_LOG_DIR" 2>/dev/null && ls -1tr "$(basename "$NPKG_LOG_FILE")."* 2>/dev/null | head -n -"$NPKG_LOG_ROTATE_KEEP" | xargs -r rm -f) || true
    fi
  fi
}

# color helpers
__c_reset() { printf '\033[0m'; }
__c_red()   { printf '\033[31m'; }
__c_green() { printf '\033[32m'; }
__c_yellow(){ printf '\033[33m'; }
__c_blue()  { printf '\033[34m'; }
__c_magenta(){ printf '\033[35m'; }

_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_log_write() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(_timestamp)"
  local line="[$ts] [$level] $msg"

  # append to logfile
  ensure_log_dir || true
  _rotate_log_if_needed || true
  printf '%s\n' "$line" >>"$NPKG_LOG_FILE" 2>/dev/null || true

  # human colored output to stderr
  case "$level" in
    DEBUG)  [[ "${NPKG_DEBUG:-0}" -eq 1 ]] && printf '%s %s\n' "$(_timestamp)" "$(_c=$(__c_magenta) && printf "%b" "$_c")$line$(__c_reset)" >&2 || true ;;
    INFO)   printf '%b\n' "$(__c_green)$line$(__c_reset)" >&2 ;;
    WARN)   printf '%b\n' "$(__c_yellow)$line$(__c_reset)" >&2 ;;
    ERROR)  printf '%b\n' "$(__c_red)$line$(__c_reset)" >&2 ;;
    *)      printf '%s\n' "$line" >&2 ;;
  esac
}

# exported functions
log_info()  { _log_write "INFO"  "$*"; }
log_warn()  { _log_write "WARN"  "$*"; }
log_error() { _log_write "ERROR" "$*"; }
log_debug() {
  if [[ "${NPKG_DEBUG:-0}" -eq 1 ]]; then
    _log_write "DEBUG" "$*"
  fi
}
log_step()  { _log_write "INFO" "$*"; }

# If sourced, export functions for other scripts
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This file is meant to be sourced, not executed directly."
  exit 0
fi
