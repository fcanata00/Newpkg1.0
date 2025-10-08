#!/usr/bin/env bash
#
# install-newpkg.sh
# Instalador automático para Newpkg (instala em /usr/share/newpkg e cria symlinks)
#
# Uso:
#   sudo ./install-newpkg.sh            # instala a partir de ./Newpkg1.0/newpkg
#   sudo ./install-newpkg.sh --src /caminho/para/Newpkg1.0/newpkg
#   sudo ./install-newpkg.sh --dry-run # apenas simula
#   sudo ./install-newpkg.sh --remove  # remove instalação
#   sudo ./install-newpkg.sh --reinstall
#
set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

###############
# Config
###############
SRC_DIR_DEFAULT="./Newpkg1.0/newpkg"    # pasta de origem com newpkg, newpkg.yaml, newpkg_bash_zsh e lib/
TARGET_BASE="/usr/share/newpkg"
TARGET_BIN="/usr/bin/newpkg"
ALIASES=( np pkg npg )
COMPLETION_DST_DIR="/etc/bash_completion.d"
COMPLETION_DST_ZSH_DIR="${HOME:-/root}/.zsh/completions"  # user-level fallback
LOG_DIR="/var/log/newpkg"
LOG_FILE="${LOG_DIR}/install.log"
CACHE_DIR="/var/cache/newpkg"
PORTS_DIR="/usr/ports"
BACKUP_DIR="/var/backups/newpkg"
LFS_DIR="/mnt/lfs"
LIB_SUBDIR="lib"
VERSION_FILE="${TARGET_BASE}/VERSION"

# Dependências mínimas
REQ_CMDS=( bash coreutils grep awk sed tar gzip xz curl git python3 jq )
REQ_PKGS=( yq fakeroot sqlite3 )   # extra recommended packages (yq may be optional but preferred)

# Flags runtime
DRY_RUN=0
ACTION="install"   # install / remove / reinstall
SRC_DIR="$SRC_DIR_DEFAULT"
CREATE_BUILDER_USER=1
FORCE_OVERWRITE=0

# Colors
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
  BOLD="$(tput bold)"; RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; NC="$(tput sgr0)"
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() {
  local lvl="$1"; shift
  local msg="$*"
  mkdir -p "$LOG_DIR"
  printf '%s [%s] %s\n' "$(timestamp)" "$lvl" "$msg" | tee -a "$LOG_FILE"
}
info()  { log "INFO" "$*"; }
warn()  { log "WARN" "$*"; }
error() { log "ERROR" "$*"; }

usage() {
  cat <<EOF
install-newpkg.sh - instalador para Newpkg (instala em ${TARGET_BASE})

Opções:
  --src <dir>       Diretório fonte (padrão: ${SRC_DIR_DEFAULT})
  --remove          Remove instalação (apaga /usr/share/newpkg e links)
  --reinstall       Remove e instala novamente
  --no-builder      Não criar usuário 'builder'
  --force           Substitui arquivos sem perguntar
  --dry-run         Simula as ações (não altera o sistema)
  --help            Mostra esta ajuda
EOF
}

# -------------------------
# Arg parse
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC_DIR="$2"; shift 2;;
    --remove) ACTION="remove"; shift;;
    --reinstall) ACTION="reinstall"; shift;;
    --no-builder) CREATE_BUILDER_USER=0; shift;;
    --force) FORCE_OVERWRITE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --help|-h) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

# -------------------------
# Root check
# -------------------------
if [[ $EUID -ne 0 ]]; then
  echo "${RED}Este instalador precisa ser executado como root (use sudo).${NC}"
  exit 1
fi

info "Iniciando instalador newpkg"
info "Ação: $ACTION"
info "Origem dos arquivos: $SRC_DIR"
[[ $DRY_RUN -eq 1 ]] && info "MODO: dry-run (sem alterações)"

# -------------------------
# Detect package manager
# -------------------------
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  else
    PKG_MGR="none"
  fi
  info "Gerenciador detectado: $PKG_MGR"
}

# attempt to install packages noninteractive per distro
install_pkgs() {
  local pkgs=( "$@" )
  if [[ "${#pkgs[@]}" -eq 0 ]]; then return 0; fi
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) instalar pacotes: ${pkgs[*]}"
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      apt-get update -y >>"$LOG_FILE" 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1 || { error "apt install falhou"; return 1; }
      ;;
    dnf)
      dnf install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1 || { error "dnf install falhou"; return 1; }
      ;;
    pacman)
      pacman -Sy --noconfirm "${pkgs[@]}" >>"$LOG_FILE" 2>&1 || { error "pacman install falhou"; return 1; }
      ;;
    zypper)
      zypper --non-interactive install "${pkgs[@]}" >>"$LOG_FILE" 2>&1 || { error "zypper install falhou"; return 1; }
      ;;
    apk)
      apk add "${pkgs[@]}" >>"$LOG_FILE" 2>&1 || { error "apk add falhou"; return 1; }
      ;;
    *)
      warn "Nenhum gerenciador de pacotes suportado detectado. Instale manualmente: ${pkgs[*]}"
      return 2
      ;;
  esac
  return 0
}

# -------------------------
# Pre-checks
# -------------------------
detect_pkg_mgr

check_cmds() {
  local missing=()
  for cmd in "${REQ_CMDS[@]}" "${REQ_PKGS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=( "$cmd" )
    fi
  done
  if [[ ${#missing[@]} -ne 0 ]]; then
    warn "Comandos/programas ausentes: ${missing[*]}"
    if [[ $DRY_RUN -eq 0 ]]; then
      # map some logical package names for common package managers (best-effort)
      local to_install=()
      for m in "${missing[@]}"; do
        case "$m" in
          yq) to_install+=( yq );;
          sqlite3) to_install+=( sqlite3 );;
          fakeroot) to_install+=( fakeroot );;
          jq) to_install+=( jq );;
          python3) to_install+=( python3 );;
          git) to_install+=( git );;
          curl) to_install+=( curl );;
          *) to_install+=( "$m" );;
        esac
      done
      info "Tentando instalar automaticamente pacotes ausentes via $PKG_MGR : ${to_install[*]}"
      install_pkgs "${to_install[@]}" || warn "Instalação automática de dependências falhou ou não suportada. Verifique manualmente."
    else
      info "(dry-run) pular instalação automática de dependências."
    fi
  else
    info "Dependências obrigatórias presentes."
  fi
}

# -------------------------
# Utility: compute sha256 of all files in source tree
# -------------------------
compute_checksums() {
  local dir="$1"
  local out="$2"
  find "$dir" -type f -print0 | sort -z | xargs -0 sha256sum > "$out"
}

# copy with verification
copy_and_verify() {
  local src="$1"
  local dest="$2"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) cp -a $src $dest"
    return 0
  fi
  # if dest exists and not forced, skip or prompt
  if [[ -e "$dest" && $FORCE_OVERWRITE -ne 1 ]]; then
    warn "$dest já existe. Usando substituição (force)."
  fi
  rm -rf -- "$dest" || true
  mkdir -p "$(dirname "$dest")"
  cp -a -- "$src" "$dest"
}

# create symlink safely
safe_symlink() {
  local src="$1"
  local dst="$2"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) ln -s $src $dst"
    return 0
  fi
  if [[ -e "$dst" || -L "$dst" ]]; then
    if [[ $FORCE_OVERWRITE -eq 1 ]]; then
      rm -f "$dst" || true
    else
      warn "Destino $dst já existe; será sobrescrito por --force"
      rm -f "$dst" || true
    fi
  fi
  ln -s "$src" "$dst"
  info "Criado symlink: $dst -> $src"
}

# ensure shell config sources completion
enable_completion_in_shells() {
  local comp_src="$1"  # full path to completion file
  # Bash: add to /etc/profile.d/newpkg_completion.sh and to user's .bashrc if not present
  local sys_profile="/etc/profile.d/newpkg_completion.sh"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) instalar completion em $COMP_DIR e adicionar source em ~/.bashrc ~/.zshrc"
    return 0
  fi
  cat > "$sys_profile" <<EOF
# newpkg completion (system-wide)
if [ -f "$COMPLETION_DST_DIR/newpkg" ]; then
  . "$COMPLETION_DST_DIR/newpkg"
fi
EOF
  chmod 0644 "$sys_profile"
  info "Instalado completion system-wide em $sys_profile"

  # User's bashrc & zshrc
  local bashrc="/etc/skel/.bashrc"
  # Append to /etc/skel so new users get it; for existing users, append to root and current user
  for target in "/root/.bashrc" "${SUDO_USER+:/home/${SUDO_USER}/.bashrc}"; do
    if [[ -n "$SUDO_USER" && -f "/home/${SUDO_USER}/.bashrc" ]]; then
      target="/home/${SUDO_USER}/.bashrc"
    else
      target="/root/.bashrc"
    fi
  done

  # Ensure current user's shell RCs source the completion (do for root and $SUDO_USER)
  for ufile in "/root/.bashrc" "/root/.zshrc" ; do
    if [[ -f "$ufile" ]]; then
      if ! grep -q "newpkg" "$ufile" 2>/dev/null; then
        printf "\n# newpkg completion\n[ -f %s ] && . %s\n" "$COMPLETION_DST_DIR/newpkg" "$COMPLETION_DST_DIR/newpkg" >> "$ufile"
        info "Adicionado source em $ufile"
      fi
    else
      # create minimal
      printf "# newpkg completion\n[ -f %s ] && . %s\n" "$COMPLETION_DST_DIR/newpkg" "$COMPLETION_DST_DIR/newpkg" > "$ufile"
      info "Criado $ufile com source para completion"
    fi
  done

  # For the invoking non-root user (if present)
  if [[ -n "${SUDO_USER:-}" && -f "/home/${SUDO_USER}/.bashrc" ]]; then
    if ! grep -q "newpkg" "/home/${SUDO_USER}/.bashrc" 2>/dev/null; then
      printf "\n# newpkg completion\n[ -f %s ] && . %s\n" "$COMPLETION_DST_DIR/newpkg" "$COMPLETION_DST_DIR/newpkg" >> "/home/${SUDO_USER}/.bashrc"
      info "Adicionado source em /home/${SUDO_USER}/.bashrc"
    fi
    if [[ -f "/home/${SUDO_USER}/.zshrc" && $(grep -c "newpkg" "/home/${SUDO_USER}/.zshrc" 2>/dev/null || true) -eq 0 ]]; then
      printf "\n# newpkg completion\nautoload -Uz bashcompinit && bashcompinit\n[ -f %s ] && source %s\n" "$COMPLETION_DST_DIR/newpkg" "$COMPLETION_DST_DIR/newpkg" >> "/home/${SUDO_USER}/.zshrc"
      info "Adicionado source em /home/${SUDO_USER}/.zshrc"
    fi
  fi
}

# -------------------------
# Install flow
# -------------------------
do_install() {
  info "Fluxo de instalação iniciado"

  # verify source exists
  if [[ ! -d "$SRC_DIR" ]]; then
    error "Diretório fonte não encontrado: $SRC_DIR"
    exit 1
  fi
  if [[ ! -f "${SRC_DIR}/newpkg" ]]; then
    error "Executável newpkg não encontrado em ${SRC_DIR}/newpkg"
    exit 1
  fi

  # Compute checksums from source
  local tmp_checksums="$(mktemp)"
  compute_checksums "$SRC_DIR" "$tmp_checksums"
  info "Checksums calculados para $SRC_DIR (arquivo temporário: $tmp_checksums)"

  # create target directories
  local dirs=( "$TARGET_BASE" "${TARGET_BASE}/${LIB_SUBDIR}" "$COMPLETION_DST_DIR" "$LOG_DIR" "$CACHE_DIR" "$PORTS_DIR" "$BACKUP_DIR" "$LFS_DIR" )
  for d in "${dirs[@]}"; do
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) mkdir -p $d"
    else
      mkdir -p "$d"
      chmod 0755 "$d" || true
      info "Criado/confirmado diretório $d"
    fi
  done

  # Copy main files
  info "Copiando arquivos para ${TARGET_BASE}"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) copiar árvore $SRC_DIR -> $TARGET_BASE"
  else
    # copy top-level files (newpkg, newpkg.yaml, newpkg_bash_zsh)
    for f in newpkg newpkg.yaml newpkg_bash_zsh; do
      if [[ -f "${SRC_DIR}/${f}" ]]; then
        cp -f "${SRC_DIR}/${f}" "${TARGET_BASE}/" || { error "Falha ao copiar ${f}"; exit 1; }
        chmod 0755 "${TARGET_BASE}/newpkg" || true
        info "Copiado: ${f} -> ${TARGET_BASE}/"
      fi
    done
    # copy lib dir
    if [[ -d "${SRC_DIR}/${LIB_SUBDIR}" ]]; then
      rm -rf "${TARGET_BASE}/${LIB_SUBDIR}" || true
      cp -a "${SRC_DIR}/${LIB_SUBDIR}" "${TARGET_BASE}/" || { error "Falha ao copiar lib/"; exit 1; }
      info "Copiado: lib/ -> ${TARGET_BASE}/${LIB_SUBDIR}"
    else
      warn "Diretório lib/ não encontrado em ${SRC_DIR}/${LIB_SUBDIR}"
    fi
  fi

  # Verify copied checksums
  local tmp_checksums_target="$(mktemp)"
  compute_checksums "$TARGET_BASE" "$tmp_checksums_target"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) pular verificação pós-cópia"
  else
    # compare checksums: we expect filenames to map, so compare names & hashes intersection
    info "Verificando integridade pós-cópia (checksum)..."
    # For simplicity compare counts and tell if any mismatch
    local src_count tgt_count
    src_count="$(wc -l < "$tmp_checksums" 2>/dev/null || echo 0)"
    tgt_count="$(wc -l < "$tmp_checksums_target" 2>/dev/null || echo 0)"
    if [[ "$src_count" -ne "$tgt_count" ]]; then
      warn "Número de arquivos fonte ($src_count) difere do instalado ($tgt_count) — verifique manualmente"
    fi
    # more thorough diff: check mismatch lines
    local mismatches
    mismatches="$(join -j2 <(awk '{print $2" "$1}' "$tmp_checksums" | sort) <(awk '{print $2" "$1}' "$tmp_checksums_target" | sort) | awk '$2!=$3{print}' || true)"
    if [[ -n "$mismatches" ]]; then
      warn "Foram encontradas diferenças de checksum entre fonte e destino. Listando (parcial):"
      echo "$mismatches" | head -n 50
      warn "Continuando a instalação, mas verifique os arquivos listados."
    else
      info "Checksums conferem (fonte -> destino)."
    fi
  fi

  # write VERSION file
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) escrever $VERSION_FILE"
  else
    mkdir -p "$(dirname "$VERSION_FILE")"
    echo "Newpkg 1.0" > "$VERSION_FILE"
    echo "Installed: $(timestamp)" >> "$VERSION_FILE"
    chmod 0644 "$VERSION_FILE"
    info "Criado $VERSION_FILE"
  fi

  # create symlink /usr/bin/newpkg and aliases
  info "Criando symlinks em /usr/bin/"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) ln -s ${TARGET_BASE}/newpkg /usr/bin/newpkg"
  else
    safe_remove_if_exists() { local p="$1"; [[ -L "$p" || -f "$p" ]] && rm -f "$p" || true; }
    safe_remove_if_exists "/usr/bin/newpkg"
    ln -s "${TARGET_BASE}/newpkg" "/usr/bin/newpkg"
    chmod +x "${TARGET_BASE}/newpkg" || true
    info "Link criado: /usr/bin/newpkg -> ${TARGET_BASE}/newpkg"
    for alias in "${ALIASES[@]}"; do
      safe_remove_if_exists "/usr/bin/$alias"
      ln -s "/usr/bin/newpkg" "/usr/bin/$alias" || true
      info "Link criado: /usr/bin/$alias -> /usr/bin/newpkg"
    done
  fi

  # install completion file
  if [[ -f "${TARGET_BASE}/newpkg_bash_zsh" ]]; then
    info "Instalando arquivo de completion em ${COMPLETION_DST_DIR}/newpkg"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) cp ${TARGET_BASE}/newpkg_bash_zsh ${COMPLETION_DST_DIR}/newpkg"
    else
      cp -f "${TARGET_BASE}/newpkg_bash_zsh" "${COMPLETION_DST_DIR}/newpkg"
      chmod 0644 "${COMPLETION_DST_DIR}/newpkg"
      info "Completion copiado para ${COMPLETION_DST_DIR}/newpkg"
      enable_completion_in_shells "${COMPLETION_DST_DIR}/newpkg"
    fi
  else
    warn "Arquivo newpkg_bash_zsh não encontrado em ${TARGET_BASE}"
  fi

  # create builder user optionally
  if [[ $CREATE_BUILDER_USER -eq 1 ]]; then
    if id builder >/dev/null 2>&1; then
      info "Usuário 'builder' já existe"
    else
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) useradd -m -s /bin/bash builder"
      else
        if command -v useradd >/dev/null 2>&1; then
          useradd -m -s /bin/bash builder || warn "Falha ao criar usuário 'builder' (talvez já exista)"
          info "Usuário 'builder' criado"
        else
          warn "useradd não disponível; não foi criado usuário 'builder'"
        fi
      fi
    fi
  fi

  # set ownership/permissions conservative defaults
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) chmod/chown recursivo em ${TARGET_BASE}"
  else
    chown -R root:root "${TARGET_BASE}" || true
    find "${TARGET_BASE}" -type d -exec chmod 0755 {} \; || true
    find "${TARGET_BASE}" -type f -exec chmod 0644 {} \; || true
    chmod 0755 "${TARGET_BASE}/newpkg" || true
    info "Permissões ajustadas em ${TARGET_BASE}"
  fi

  info "Instalação concluída com sucesso. Verifique $LOG_FILE para detalhes."
  info "Resumo:"
  info "  Binário    : /usr/bin/newpkg -> ${TARGET_BASE}/newpkg"
  info "  Base       : ${TARGET_BASE}"
  info "  Libs       : ${TARGET_BASE}/${LIB_SUBDIR}"
  info "  Completion : ${COMPLETION_DST_DIR}/newpkg"
  info "  Logs       : ${LOG_FILE}"
  info "  Cache      : ${CACHE_DIR}"
  info "  Ports dir  : ${PORTS_DIR}"
  info "  LFS root   : ${LFS_DIR}"
}

# -------------------------
# Remove flow
# -------------------------
do_remove() {
  info "Iniciando remoção do newpkg"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) rm -rf ${TARGET_BASE} /usr/bin/newpkg /usr/bin/np /usr/bin/pkg /usr/bin/npg ${COMPLETION_DST_DIR}/newpkg"
    return 0
  fi

  # remove symlinks
  for p in "/usr/bin/newpkg" "${ALIASES[@]/#/\/usr\/bin\/}"; do
    if [[ -L "$p" || -f "$p" ]]; then
      rm -f "$p" && info "Removido link $p"
    fi
  done

  # remove completion
  if [[ -f "${COMPLETION_DST_DIR}/newpkg" ]]; then
    rm -f "${COMPLETION_DST_DIR}/newpkg" && info "Removido completion ${COMPLETION_DST_DIR}/newpkg"
  fi

  # remove installed files (keep backups optional)
  if [[ -d "${TARGET_BASE}" ]]; then
    # move to backup instead of immediate rm (safer)
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local archive="${BACKUP_DIR}/newpkg-backup-${ts}.tar.gz"
    mkdir -p "$BACKUP_DIR"
    tar -C "$(dirname "${TARGET_BASE}")" -czf "$archive" "$(basename "${TARGET_BASE}")" || warn "Falha ao criar backup ${archive}"
    info "Backup criado em ${archive}"
    rm -rf "${TARGET_BASE}" && info "Removido ${TARGET_BASE}"
  else
    info "${TARGET_BASE} não encontrado; nada a remover."
  fi

  info "Remoção completada. Logs em $LOG_FILE"
}

# -------------------------
# Main dispatch
# -------------------------
case "$ACTION" in
  install)
    check_cmds
    do_install
    ;;
  remove)
    do_remove
    ;;
  reinstall)
    do_remove
    do_install
    ;;
  *)
    error "Ação desconhecida: $ACTION"
    exit 1
    ;;
esac

exit 0
