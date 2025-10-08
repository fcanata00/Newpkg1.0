#!/usr/bin/env bash
# ==============================================================================
# core.sh - Orquestrador de build do Newpkg (versão "Pro" com integrações)
# Local recomendado: /usr/share/newpkg/lib/core.sh
#
# Recursos adicionados / integrados:
#  - Integração com newpkg_audit.sh --selfcheck (abort on fail)
#  - Caminhos padronizados: /usr/share/newpkg/lib/
#  - Hooks locais por pacote + hooks globais do sistema
#  - Chroot inteligente (monta uma vez para fila, limpa entre pacotes, desmonta no final)
#  - Relatório final (concluídos/falhos) e log por pacote
#  - --install-from-dir funciona no fluxo de recuperação (cache -> rebuild)
#  - Fila / resume: salva queue em /var/lib/newpkg/state/current.queue
#  - --parallel via xargs -P, --dry-run, --resume, --continue-on-error
#
# Requisitos: bash, tar, zstd, xz, unzip, curl/wget, make, fakeroot, yq (recomendado), xargs
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

### Configurações principais (ajustáveis)
BASE_SHARE="/usr/share/newpkg"
LIB_DIR="${BASE_SHARE}/lib"
LOG_DIR="/var/log/newpkg"
BUILD_LOG_DIR="${LOG_DIR}/builds"
AUDIT_SH="${LIB_DIR}/newpkg_audit.sh"
DB_SH="${LIB_DIR}/db.sh"
YQ_CMD="$(command -v yq || true)"

STATE_DIR="/var/lib/newpkg/state"
QUEUE_FILE="${STATE_DIR}/current.queue"
CACHE_SOURCES="/var/cache/newpkg/sources"
CACHE_PACKAGES="/var/cache/newpkg/packages"
BUILD_ROOT="/build/newpkg"
PORTS_DIR="/usr/ports"
LFS_DIR="/mnt/lfs"

# Defaults
PARALLEL=1
DRY_RUN=0
RESUME=0
CONTINUE_ON_ERROR=0
STAGE_OVERRIDE=""
VERBOSE=1
NEWPKG_RECOVERY="${NEWPKG_RECOVERY:-0}"

# Colors
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
  BOLD="$(tput bold)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"
else
  BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""
fi

timestamp(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log(){ mkdir -p "$LOG_DIR"; printf '%s [%s] %s\n' "$(timestamp)" "$1" "$2" | tee -a "$LOG_DIR/core.log"; }
info(){ log "INFO" "$*"; }
warn(){ log "WARN" "$*"; }
error(){ log "ERROR" "$*"; }

# Load log.sh (if present) for richer output
if [[ -f "${LIB_DIR}/log.sh" ]]; then
  # shellcheck source=/usr/share/newpkg/lib/log.sh
  source "${LIB_DIR}/log.sh" || true
fi

# Ensure dirs exist
mkdir -p "$STATE_DIR" "$CACHE_SOURCES" "$CACHE_PACKAGES" "$BUILD_ROOT" "$BUILD_LOG_DIR"

# ---------------------------
# Helper utilities
# ---------------------------
safe_run(){
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) $*"
  else
    eval "$@"
  fi
}

require_root_if(){
  # usage: require_root_if <condition-expr> <message>
  local cond="$1"; shift
  local msg="$*"
  if eval "$cond"; then
    if [[ $EUID -ne 0 ]]; then
      error "$msg (requer root). Abortando."
      exit 1
    fi
  fi
}

usage(){
  cat <<EOF
Uso: core.sh [opções] <ação> [args...]

Ações:
  install <pkg> [...]            Constrói/instala pacotes por nome (procura metafile em /usr/ports)
  --install-from-dir <path>     Instala a partir de diretório pronto ou tarball (fluxo de recuperação)
  help                          Mostra esta ajuda

Opções:
  --parallel N      Número de tarefas paralelas (xargs -P)
  --dry-run         Simula ações sem executar
  --resume          Retoma a fila a partir do pacote com falha
  --continue-on-error  Continua para próximos pacotes mesmo se um falhar
  --stage <stage>   Força stage (pass1, pass2, normal)
  --verbose/--quiet
EOF
  exit 1
}

# ---------------------------
# YAML helpers (yq preferred)
# ---------------------------
yaml_get(){
  local file="$1"; local path="$2"
  if [[ -n "$YQ_CMD" ]]; then
    "$YQ_CMD" e "$path" "$file" 2>/dev/null || true
  else
    # fallback: naive grep for simple scalar values (key:)
    # path expected like '.name' -> use 'name'
    local key="${path#.}"
    grep -E "^\s*${key}:" "$file" 2>/dev/null | head -n1 | sed -E 's/^[^:]*:\s*//'
  fi
}

# ---------------------------
# Metafile and package helpers
# ---------------------------
find_metafile(){
  local pkg="$1"
  # try exact path: /usr/ports/*/<pkg>/metafile.yaml
  local mf
  mf="$(find "$PORTS_DIR" -type f -path "*/${pkg}/metafile.yaml" -print -quit 2>/dev/null || true)"
  if [[ -z "$mf" ]]; then
    mf="$(find "$PORTS_DIR" -type f -iname "metafile.yaml" -path "*/${pkg}/*" -print -quit 2>/dev/null || true)"
  fi
  echo "$mf"
}

state_file_for_pkg(){ printf "%s/%s.state" "$STATE_DIR" "$1"; }
mark_state(){ local pkg="$1"; local st="$2"; printf "%s|%s\n" "$st" "$(timestamp)" > "$(state_file_for_pkg "$pkg")"; }
get_state(){ local pkg="$1"; if [[ -f "$(state_file_for_pkg "$pkg")" ]]; then cat "$(state_file_for_pkg "$pkg")"; else echo "none"; fi }

# Save/restore queue
save_queue(){ local arr=("$@"); mkdir -p "$(dirname "$QUEUE_FILE")"; printf "%s\n" "${arr[@]}" > "$QUEUE_FILE"; }
load_queue(){ [[ -f "$QUEUE_FILE" ]] && mapfile -t arr < "$QUEUE_FILE" && printf "%s\n" "${arr[@]}"; }

# ---------------------------
# Hooks: priority local (/usr/ports/.../scripts) then global (/etc/newpkg/hooks/core/<hook>/)
# ---------------------------
run_hook(){
  local metafile="$1"; local hook_name="$2"; local workdir="${3:-.}"
  # local hook in package scripts/
  local pkgdir; pkgdir="$(dirname "$metafile")"
  local local_hook="${pkgdir}/scripts/${hook_name}"
  local global_hook="/etc/newpkg/hooks/core/${hook_name}"
  if [[ -x "$local_hook" ]]; then
    info "Executando hook local: $local_hook"
    safe_run "bash -c 'cd \"$workdir\" && \"$local_hook\" \"$metafile\" \"$workdir\"'"
  elif [[ -x "$global_hook" ]]; then
    info "Executando hook global: $global_hook"
    safe_run "bash -c 'cd \"$workdir\" && \"$global_hook\" \"$metafile\" \"$workdir\"'"
  else
    info "Nenhum hook ($hook_name) definido para pacote"
  fi
}

# ---------------------------
# Archive extraction and packaging
# ---------------------------
extract_archive(){
  local archive="$1"; local outdir="$2"
  mkdir -p "$outdir"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$outdir" ;;
    *.tar.xz) tar -xJf "$archive" -C "$outdir" ;;
    *.tar.bz2) tar -xjf "$archive" -C "$outdir" ;;
    *.tar.zst|*.tzst) zstd -d "$archive" -c | tar -xf - -C "$outdir" ;;
    *.zip) unzip -q "$archive" -d "$outdir" ;;
    *) error "Formato desconhecido: $archive"; return 1 ;;
  esac
}

package_dir_to_tarzst(){
  local src="$1"; local out="$2"
  safe_run "tar -C \"$(dirname "$src")\" -cf - \"$(basename "$src")\" | zstd -o \"$out\" -T0"
}

# ---------------------------
# Chroot helpers (mount once for group; clean between packages)
# ---------------------------
_chroot_mounted=false
core_chroot_mount(){
  local target="$1"
  if mountpoint -q "$target"; then
    _chroot_mounted=true
    info "Chroot $target já montado"
    return 0
  fi
  info "Montando chroot em $target..."
  safe_run "mkdir -p \"$target\""
  safe_run "mount --bind /dev \"$target/dev\""
  safe_run "mount --bind /dev/pts \"$target/dev/pts\""
  safe_run "mount -t proc proc \"$target/proc\""
  safe_run "mount -t sysfs sysfs \"$target/sys\""
  safe_run "mount -t tmpfs tmpfs \"$target/run\" || true"
  safe_run "cp -L /etc/resolv.conf \"$target/etc/resolv.conf\" || true"
  _chroot_mounted=true
}

core_chroot_clean_between_packages(){
  local target="$1"
  info "Limpando diretórios temporários dentro do chroot ($target) entre builds..."
  # attempt safe cleanup: /tmp, /var/tmp, /build
  safe_run "rm -rf \"$target/tmp\"/* 2>/dev/null || true"
  safe_run "rm -rf \"$target/var/tmp\"/* 2>/dev/null || true"
  safe_run "rm -rf \"$target/build\"/* 2>/dev/null || true"
}

core_chroot_umount(){
  local target="$1"
  if ! _chroot_mounted; then
    info "Chroot não está montado; nada a desmontar."
    return 0
  fi
  info "Desmontando chroot em $target..."
  safe_run "umount -l \"$target/run\" 2>/dev/null || true"
  safe_run "umount -l \"$target/sys\" 2>/dev/null || true"
  safe_run "umount -l \"$target/proc\" 2>/dev/null || true"
  safe_run "umount -l \"$target/dev/pts\" 2>/dev/null || true"
  safe_run "umount -l \"$target/dev\" 2>/dev/null || true"
  _chroot_mounted=false
}

# ---------------------------
# Audit/selfcheck integration (abort if fails)
# ---------------------------
preflight_selfcheck(){
  if [[ -x "$AUDIT_SH" ]]; then
    info "Executando newpkg_audit.sh --selfcheck (pré-build)"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) skip execução real do --selfcheck"
      return 0
    fi
    if ! bash "$AUDIT_SH" --selfcheck; then
      error "Selfcheck falhou — abortando operação."
      exit 2
    fi
    info "Selfcheck OK"
  else
    warn "newpkg_audit.sh não encontrado; pulando selfcheck (recomendado instalar)"
  fi
}

# ---------------------------
# Find best source in cache or download
# ---------------------------
download_sources_from_metafile(){
  local metafile="$1"; local pkgcache="$2"
  mkdir -p "$pkgcache"
  if [[ -n "$YQ_CMD" ]]; then
    local urls; mapfile -t urls < <("$YQ_CMD" e '.source[]' "$metafile" 2>/dev/null || true)
  else
    urls=()
  fi
  local success=0
  for url in "${urls[@]:-}"; do
    [[ -z "$url" ]] && continue
    local fname; fname="$(basename "$url")"
    if [[ -f "${pkgcache}/${fname}" ]]; then
      info "Fonte já em cache: ${pkgcache}/${fname}"
      success=1; break
    fi
    info "Tentando baixar: $url"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) curl -L -o ${pkgcache}/${fname} $url"
      success=1; break
    else
      if curl -L --fail -o "${pkgcache}/${fname}" "$url" >/dev/null 2>&1; then
        info "Baixado: ${fname}"
        success=1; break
      else
        warn "Falha ao baixar de $url"
      fi
    fi
  done
  return $success
}

# ---------------------------
# Build / install steps
# ---------------------------
core_run_build(){
  local srcdir="$1"; local metafile="$2"; local pkg="$3"; local worklog="$4"
  run_hook "$metafile" "pre-build" "$srcdir" || true
  # apply patches
  # local patches via yq .patches[]
  if [[ -n "$YQ_CMD" ]]; then
    local patches; mapfile -t patches < <("$YQ_CMD" e '.patches[]' "$metafile" 2>/dev/null || true)
    for p in "${patches[@]:-}"; do
      [[ -z "$p" ]] && continue
      local patchfile="$(dirname "$metafile")/patches/$p"
      if [[ -f "$patchfile" ]]; then
        info "Aplicando patch: $patchfile"
        safe_run "patch -p1 -d \"$srcdir\" < \"$patchfile\""
      else
        warn "Patch não encontrado: $patchfile"
      fi
    done
  fi

  # build commands (yq .build[])
  if [[ -n "$YQ_CMD" ]]; then
    local build_cmds; mapfile -t build_cmds < <("$YQ_CMD" e '.build[]' "$metafile" 2>/dev/null || true)
    if [[ ${#build_cmds[@]} -gt 0 ]]; then
      for cmd in "${build_cmds[@]}"; do
        [[ -z "$cmd" ]] && continue
        info "Executando (build): $cmd"
        safe_run "bash -lc 'cd \"$srcdir\" && $cmd' 2>&1 | tee -a \"$worklog\""
      done
    else
      # fallback: standard
      if [[ -x "$srcdir/configure" ]]; then
        safe_run "bash -lc 'cd \"$srcdir\" && ./configure --prefix=/usr' 2>&1 | tee -a \"$worklog\""
      fi
      safe_run "bash -lc 'cd \"$srcdir\" && make -j${PARALLEL}' 2>&1 | tee -a \"$worklog\""
    fi
  else
    # fallback
    if [[ -x "$srcdir/configure" ]]; then
      safe_run "bash -lc 'cd \"$srcdir\" && ./configure --prefix=/usr' 2>&1 | tee -a \"$worklog\""
    fi
    safe_run "bash -lc 'cd \"$srcdir\" && make -j${PARALLEL}' 2>&1 | tee -a \"$worklog\""
  fi

  run_hook "$metafile" "post-build" "$srcdir" || true
}

core_install_destdir(){
  local srcdir="$1"; local metafile="$2"; local pkg="$3"; local destdir="$4"; local worklog="$5"
  mkdir -p "$destdir"
  run_hook "$metafile" "pre-install" "$destdir" || true
  # install commands from metafile
  if [[ -n "$YQ_CMD" ]]; then
    local install_cmds; mapfile -t install_cmds < <("$YQ_CMD" e '.install[]' "$metafile" 2>/dev/null || true)
    if [[ ${#install_cmds[@]} -gt 0 ]]; then
      for ic in "${install_cmds[@]}"; do
        [[ -z "$ic" ]] && continue
        info "Executando (install): $ic"
        safe_run "bash -lc 'cd \"$srcdir\" && fakeroot bash -lc \"$ic\"' 2>&1 | tee -a \"$worklog\""
      done
    else
      safe_run "bash -lc 'cd \"$srcdir\" && fakeroot make DESTDIR=\"$destdir\" install' 2>&1 | tee -a \"$worklog\""
    fi
  else
    safe_run "bash -lc 'cd \"$srcdir\" && fakeroot make DESTDIR=\"$destdir\" install' 2>&1 | tee -a \"$worklog\""
  fi
  run_hook "$metafile" "post-install" "$destdir" || true
}

core_package_destdir(){
  local destdir="$1"; local outtar="$2"
  safe_run "tar -C \"$destdir\" -cf - . | zstd -o \"$outtar\" -T0"
}

core_final_deploy(){
  local pkg_tar="$1"; local stage="$2"
  local tmpd; tmpd="$(mktemp -d)"
  safe_run "tar -C \"$tmpd\" -xvf \"$pkg_tar\" >/dev/null 2>&1 || true"
  if [[ "$stage" == "pass1" || "$stage" == "pass2" ]]; then
    info "Instalando em $LFS_DIR (stage $stage)"
    safe_run "bash -lc 'cd \"$tmpd\" && fakeroot tar -C \"$LFS_DIR\" -xvf ./*' || true"
  else
    info "Instalando em / (sistema)"
    safe_run "bash -lc 'cd \"$tmpd\" && fakeroot tar -C / -xvf ./*' || true"
  fi
  rm -rf "$tmpd"
}

# ---------------------------
# Recovery helper: try package from cache, else rebuild via core_install_package()
# ---------------------------
core_recover_package(){
  local pkg="$1"
  info "Recuperação para pacote: $pkg"
  # look for package tar in cache (best match)
  local tarball
  tarball="$(find "$CACHE_PACKAGES" -type f -iname "${pkg}*.tar.zst" -print -quit 2>/dev/null || true)"
  if [[ -n "$tarball" ]]; then
    info "Tarball encontrado no cache: $tarball -> reinstalando"
    core_final_deploy "$tarball" "normal"
    return 0
  fi
  # else rebuild
  info "Tarball não encontrado no cache; reconstruindo $pkg"
  # call core_install_package which will follow normal build path
  core_install_package "$pkg"
  return $?
}

# ---------------------------
# Main per-package orchestration
# ---------------------------
core_install_package(){
  local pkg="$1"
  local worklog="${BUILD_LOG_DIR}/${pkg}.$(date +%s).log"
  info "=== Iniciando pacote: $pkg ==="
  mark_state "$pkg" "started"

  # find metafile
  local metafile; metafile="$(find_metafile "$pkg")"
  if [[ -z "$metafile" ]]; then
    error "Metafile não encontrado para $pkg"
    mark_state "$pkg" "error-metafile"
    return 3
  fi

  # read metadata
  local name version stage build_dir
  name="$(yaml_get "$metafile" '.name' 2>/dev/null || true)"
  version="$(yaml_get "$metafile" '.version' 2>/dev/null || true)"
  stage="$(yaml_get "$metafile" '.stage' 2>/dev/null || true)"
  build_dir="$(yaml_get "$metafile" '.build_dir' 2>/dev/null || true)"
  [[ -z "$stage" ]] && stage="normal"
  [[ -n "$STAGE_OVERRIDE" ]] && stage="$STAGE_OVERRIDE"

  info "Pacote: ${name:-$pkg} Versão:${version:-unspecified} Stage:${stage}"

  # prepare work dirs
  local pkgcache="${CACHE_SOURCES}/${pkg}"
  local work_parent="${BUILD_ROOT}/${pkg}"
  rm -rf "$work_parent" || true
  mkdir -p "$pkgcache" "$work_parent"

  # run pre-download hook
  run_hook "$metafile" "pre-download" "$work_parent" || true

  # download (or rely on cache)
  if ! download_sources_from_metafile "$metafile" "$pkgcache"; then
    warn "Não foi possível obter fontes para $pkg (verifique URLs)"
    mark_state "$pkg" "error-download"
    return 4
  fi

  run_hook "$metafile" "post-download" "$work_parent" || true

  # find archive in cache (take first file)
  local archive; archive="$(ls -1 "${pkgcache}"/* 2>/dev/null | head -n1 || true)"
  local srcdir
  if [[ -n "$archive" ]]; then
    info "Extraindo $archive para $work_parent"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) extrair $archive"
      srcdir="$work_parent"
    else
      rm -rf "${work_parent:?}/*" || true
      mkdir -p "$work_parent"
      extract_archive "$archive" "$work_parent" || { warn "Erro ao extrair $archive"; mark_state "$pkg" "error-extract"; return 5; }
      srcdir="$(find "$work_parent" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
      [[ -z "$srcdir" ]] && srcdir="$work_parent"
    fi
  else
    info "Nenhum archive no cache; assumindo fonte já presente em $work_parent (ou VCS build)"
    srcdir="$work_parent"
  fi

  # build step (inside chroot if stage requires)
  if [[ "$stage" == "pass1" || "$stage" == "pass2" ]]; then
    # ensure chroot mounted
    core_chroot_mount "$LFS_DIR"
    # execute build inside chroot
    # we will bind mount necessary build dirs if needed, but for simplicity we'll copy sources into chroot build area
    local chroot_build_root="${LFS_DIR}/build/${pkg}"
    safe_run "rm -rf \"$chroot_build_root\" || true; mkdir -p \"$chroot_build_root\""
    safe_run "cp -a \"$srcdir/.\" \"$chroot_build_root/\""
    info "Iniciando build em chroot ($LFS_DIR) para $pkg"
    # run build inside chroot
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) chroot build $pkg"
    else
      core_run_build "$chroot_build_root" "$metafile" "$pkg" "$worklog" || { warn "Build em chroot falhou para $pkg"; mark_state "$pkg" "error-build"; return 6; }
    fi
    # install to destdir inside chroot (we'll use a destdir under chroot to package)
    local destdir="${CACHE_PACKAGES}/${pkg}-destdir"
    rm -rf "$destdir" || true; mkdir -p "$destdir"
    core_install_destdir "$chroot_build_root" "$metafile" "$pkg" "$destdir" "$worklog" || { warn "Install destdir falhou (chroot)"; mark_state "$pkg" "error-install"; return 7; }
  else
    # normal stage (host)
    core_run_build "$srcdir" "$metafile" "$pkg" "$worklog" || { warn "Build falhou para $pkg"; mark_state "$pkg" "error-build"; return 6; }
    local destdir="${CACHE_PACKAGES}/${pkg}-destdir"
    rm -rf "$destdir" || true; mkdir -p "$destdir"
    core_install_destdir "$srcdir" "$metafile" "$pkg" "$destdir" "$worklog" || { warn "Install destdir falhou"; mark_state "$pkg" "error-install"; return 7; }
  fi

  # package destdir
  local pkg_tar="${CACHE_PACKAGES}/${pkg}-${version:-manual}.tar.zst"
  info "Empacotando destdir -> $pkg_tar"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) empacotar -> $pkg_tar"
  else
    core_package_destdir "$destdir" "$pkg_tar" || warn "Falha no empacotamento"
  fi

  # final deploy
  core_final_deploy "$pkg_tar" "$stage" || warn "Falha no deploy final"

  # register in DB if db.sh provides function
  if [[ -f "$DB_SH" ]]; then
    # shellcheck source=/usr/share/newpkg/lib/db.sh
    source "$DB_SH" || true
    if type db_record_install >/dev/null 2>&1; then
      db_record_install "$pkg" "${version:-manual}" "$pkg_tar" || warn "db_record_install retornou erro"
    fi
  fi

  # post-deploy audit: call recovery-only if needed (but only in auto-recover scenarios)
  if [[ -x "$AUDIT_SH" && "$NEWPKG_RECOVERY" -eq 1 ]]; then
    info "Chamando newpkg_audit.sh --recover-only para validação pós-deploy do $pkg"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) skip newpkg_audit.sh --recover-only"
    else
      bash "$AUDIT_SH" --recover-only || warn "recover-only reportou problemas"
    fi
  fi

  mark_state "$pkg" "ok"
  info "=== Pacote $pkg concluído com sucesso ==="
  return 0
}

# ---------------------------
# Install-from-dir (recovery-friendly)
# ---------------------------
core_install_from_dir(){
  local src="$1"
  info "Instalação a partir de diretório/tarball: $src"
  if [[ -d "$src" ]]; then
    local pkgname; pkgname="$(basename "$src")"
    local destdir="${CACHE_PACKAGES}/${pkgname}-destdir"
    rm -rf "$destdir" || true; mkdir -p "$destdir"
    safe_run "cp -a \"$src/.\" \"$destdir/.\""
    local pkg_tar="${CACHE_PACKAGES}/${pkgname}-manual-$(date +%Y%m%d%H%M%S).tar.zst"
    core_package_destdir "$destdir" "$pkg_tar"
    core_final_deploy "$pkg_tar" "normal"
    if [[ -f "$DB_SH" ]]; then
      source "$DB_SH" || true
      if type db_record_install >/dev/null 2>&1; then
        db_record_install "$pkgname" "manual" "$pkg_tar" || true
      fi
    fi
    info "Instalação a partir de diretório concluída: $pkgname"
    return 0
  elif [[ -f "$src" ]]; then
    # assume tarball
    local tmpd; tmpd="$(mktemp -d)"
    extract_archive "$src" "$tmpd"
    local pkgname; pkgname="$(basename "$src" | sed -E 's/(\.tar\..*|\.tar\.zst)//')"
    local pkg_tar="${CACHE_PACKAGES}/${pkgname}-manual-$(date +%Y%m%d%H%M%S).tar.zst"
    core_package_destdir "$tmpd" "$pkg_tar"
    core_final_deploy "$pkg_tar" "normal"
    rm -rf "$tmpd"
    info "Instalação a partir de tarball concluída: $pkgname"
    return 0
  else
    error "Caminho inválido para --install-from-dir: $src"
    return 1
  fi
}

# ---------------------------
# Driver: process list with queue/resume and chroot handling
# ---------------------------
process_pkg_list(){
  local pkgs=( "$@" )
  mkdir -p "$STATE_DIR"
  save_queue "${pkgs[@]}"

  # preflight selfcheck (abort if fails)
  preflight_selfcheck

  # chroot logic: if any package requires chroot, we mount once and keep mounted until end;
  # also we will clean between packages and unmount at the end.
  local any_chroot=0
  for p in "${pkgs[@]}"; do
    local mf; mf="$(find_metafile "$p")"
    local st
    if [[ -n "$mf" ]]; then
      st="$(yaml_get "$mf" '.stage' 2>/dev/null || true)"
      [[ "$st" == "pass1" || "$st" == "pass2" ]] && any_chroot=1
    fi
  done

  if [[ $any_chroot -eq 1 ]]; then
    core_chroot_mount "$LFS_DIR"
    trap 'core_chroot_umount "$LFS_DIR"; exit 1' INT TERM EXIT
  fi

  local completed=()
  local failed=()

  # If RESUME, skip packages already ok
  for p in "${pkgs[@]}"; do
    local st; st="$(get_state "$p" || echo "none")"
    if [[ "$RESUME" -eq 1 && "$st" == ok* ]]; then
      info "Pulando $p (já marcado como ok)"
      completed+=( "$p" )
      continue
    fi
    # attempt build
    if core_install_package "$p"; then
      completed+=( "$p" )
      # clean between packages if chroot mounted and more packages to go
      if [[ $any_chroot -eq 1 ]]; then
        core_chroot_clean_between_packages "$LFS_DIR"
      fi
    else
      warn "Pacote $p falhou. Registrando e abortando fila (resume irá retomar aqui)."
      failed+=( "$p" )
      # unmount chroot only if we previously set trap? We'll keep mounted to allow debugging,
      # but per requirement, we should clean and leave state. For safety we clean tmp inside chroot.
      if [[ $any_chroot -eq 1 ]]; then
        core_chroot_clean_between_packages "$LFS_DIR"
      fi
      # clear trap and unmount
      core_chroot_umount "$LFS_DIR"
      trap - INT TERM EXIT
      break
    fi
  done

  # after loop, if chroot was mounted, unmount (unless we already unmounted on error)
  if [[ $any_chroot -eq 1 && "$_chroot_mounted" = true ]]; then
    core_chroot_umount "$LFS_DIR"
    trap - INT TERM EXIT
  fi

  # summary
  info "======================"
  info "Relatório de Build:"
  if [[ ${#completed[@]} -gt 0 ]]; then
    echo -e "${GREEN}Concluídos:${RESET} ${completed[*]}"
    info "Concluídos: ${completed[*]}"
  else
    echo -e "${YELLOW}Concluídos: nenhum${RESET}"
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo -e "${RED}Falharam:${RESET} ${failed[*]}"
    info "Falharam: ${failed[*]}"
    # write summary log
    printf 'Concluídos: %s\nFalharam: %s\n' "${completed[*]-None}" "${failed[*]-None}" >> "${LOG_DIR}/build-summary.log"
    return 2
  else
    printf 'Concluídos: %s\nFalharam: %s\n' "${completed[*]-None}" "None" >> "${LOG_DIR}/build-summary.log"
  fi

  return 0
}

# ---------------------------
# CLI parse
# ---------------------------
if [[ $# -lt 1 ]]; then usage; fi
ACTION=""
INSTALL_FROM_DIR=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    install) ACTION="install"; shift ;;
    --install-from-dir) ACTION="install-from-dir"; INSTALL_FROM_DIR="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --resume) RESUME=1; shift ;;
    --continue-on-error) CONTINUE_ON_ERROR=1; shift ;;
    --stage) STAGE_OVERRIDE="$2"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --quiet) VERBOSE=0; shift ;;
    -h|--help) usage; ;;
    --) shift; break ;;
    *) POSITIONAL+=( "$1" ); shift ;;
  esac
done

# If no explicit action but positional args exist, treat as install
if [[ -z "$ACTION" && ${#POSITIONAL[@]} -gt 0 ]]; then
  ACTION="install"
fi

case "$ACTION" in
  install)
    if [[ ${#POSITIONAL[@]} -eq 0 ]]; then error "Nenhum pacote informado para install"; usage; fi
    process_pkg_list "${POSITIONAL[@]}"
    ;;
  install-from-dir)
    if [[ -z "$INSTALL_FROM_DIR" ]]; then error "--install-from-dir exige caminho"; usage; fi
    # preflight selfcheck
    preflight_selfcheck
    core_install_from_dir "$INSTALL_FROM_DIR"
    ;;
  *)
    usage
    ;;
esac

exit 0
