#!/usr/bin/env bash
# ============================================================
#  newpkg_doctor.sh — Diagnóstico e reparo do ambiente Newpkg
#  Uso: newpkg_doctor.sh [--fix] [--dry-run] [--help]
#  --fix     : tenta corrigir automaticamente problemas detectados
#  --dry-run : mostra o que seria feito pelo --fix, sem alterar nada
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------
# Configurações iniciais
# ---------------------------
SCRIPT_NAME="$(basename "$0")"
LOGDIR="/var/log/newpkg"
LOGFILE="${LOGDIR}/doctor.log"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Paths do newpkg (ajuste se necessário)
BASE_SHARE="/usr/share/newpkg"
LIB_DIR="${BASE_SHARE}/lib"
EXECUTABLE="${BASE_SHARE}/newpkg"
CONFIG_FILE="${BASE_SHARE}/newpkg.yaml"
COMPLETION_FILE="${BASE_SHARE}/newpkg_bash_zsh"
PORTS_DIR="/usr/ports"
CACHE_DIR="/var/cache/newpkg"
DB_DIR="/var/lib/newpkg"
LFS_DIR="/mnt/lfs"

# Flags
DO_FIX=0
DRY_RUN=0
FORCE=0

# Cores (se terminal suportar)
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
  BOLD="$(tput bold)"; RESET="$(tput sgr0)"
  GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  RED="$(tput setaf 1)"; CYAN="$(tput setaf 6)"
else
  BOLD=""; RESET=""; GREEN=""; YELLOW=""; RED=""; CYAN=""
fi

# ---------------------------
# Helpers
# ---------------------------
log() {
  local lvl="$1"; shift
  local msg="$*"
  mkdir -p "$LOGDIR"
  printf '%s [%s] %s\n' "$TIMESTAMP" "$lvl" "$msg" | tee -a "$LOGFILE"
}
info()  { log "INFO"  "$*"; }
warn()  { log "WARN"  "$*"; }
error() { log "ERROR" "$*"; }

die() {
  error "$*"
  exit 1
}

safe_run() {
  # run command unless dry-run; show what would be run in dry-run
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) $*"
  else
    eval "$*"
  fi
}

# ---------------------------
# Arg parse
# ---------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix) DO_FIX=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) 
      cat <<EOF
$SCRIPT_NAME - Diagnóstico e reparo do ambiente Newpkg

Uso:
  $SCRIPT_NAME [--fix] [--dry-run] [--force]

Opções:
  --fix       : tenta corrigir automaticamente problemas detectados
  --dry-run   : simula as ações do --fix sem alterar nada
  --force     : força substituições quando aplicável
  -h, --help  : mostra esta ajuda
EOF
      exit 0
      ;;
    *) echo "Opção desconhecida: $1"; exit 1 ;;
  esac
done

# ---------------------------
# Root check (fix operations need root)
# ---------------------------
if [[ $DO_FIX -eq 1 && $EUID -ne 0 ]]; then
  die "O modo --fix requer privilégios de root. Execute com sudo."
fi

info "Iniciando newpkg_doctor ($([[ $DO_FIX -eq 1 ]] && echo "--fix" || echo "--check-only"))"
info "Log: $LOGFILE"

# ---------------------------
# Detect package manager
# ---------------------------
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

install_system_pkgs() {
  local to_install=("$@")
  if [[ ${#to_install[@]} -eq 0 ]]; then return 0; fi
  info "Tentando instalar pacotes: ${to_install[*]}"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) instalação: ${to_install[*]}"
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y >>"$LOGFILE" 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}" >>"$LOGFILE" 2>&1 || return 1
      ;;
    dnf)
      dnf install -y "${to_install[@]}" >>"$LOGFILE" 2>&1 || return 1
      ;;
    pacman)
      pacman -Sy --noconfirm "${to_install[@]}" >>"$LOGFILE" 2>&1 || return 1
      ;;
    zypper)
      zypper --non-interactive install "${to_install[@]}" >>"$LOGFILE" 2>&1 || return 1
      ;;
    apk)
      apk add "${to_install[@]}" >>"$LOGFILE" 2>&1 || return 1
      ;;
    *)
      warn "Nenhum gerenciador de pacotes suportado detectado (instalação manual necessária): ${to_install[*]}"
      return 2
      ;;
  esac
  return 0
}

install_pip_pkgs() {
  local pips=( "$@" )
  if [[ ${#pips[@]} -eq 0 ]]; then return 0; fi
  info "Tentando instalar pacotes Python: ${pips[*]}"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) pip3 install ${pips[*]}"
    return 0
  fi
  if ! command -v pip3 >/dev/null 2>&1; then
    warn "pip3 não encontrado. Tentando instalar pip3 via gerenciador de pacotes..."
    case "$PKG_MGR" in
      apt) install_system_pkgs python3-pip || true ;;
      dnf) install_system_pkgs python3-pip || true ;;
      pacman) install_system_pkgs python-pip || true ;;
      apk) install_system_pkgs py3-pip || true ;;
      *) warn "Instale pip3 manualmente." ;;
    esac
  fi
  pip3 install --upgrade "${pips[@]}" >>"$LOGFILE" 2>&1 || return 1
  return 0
}

# ---------------------------
# Checks
# ---------------------------
echo
echo -e "${BOLD}${CYAN}1) Verificando diretórios e arquivos principais...${RESET}"
declare -A CHECK_DIRS=(
  [BASE_SHARE]="$BASE_SHARE"
  [LIB_DIR]="$LIB_DIR"
  [EXECUTABLE]="$EXECUTABLE"
  [CONFIG_FILE]="$CONFIG_FILE"
  [COMPLETION_FILE]="$COMPLETION_FILE"
  [PORTS_DIR]="$PORTS_DIR"
  [CACHE_DIR]="$CACHE_DIR"
  [LOGDIR]="$LOGDIR"
  [DB_DIR]="$DB_DIR"
)
MISSING_DIRS=()
for k in "${!CHECK_DIRS[@]}"; do
  p="${CHECK_DIRS[$k]}"
  if [[ -e "$p" ]]; then
    echo -e "  → $p ... ${GREEN}OK${RESET}"
    info "$p existe"
  else
    echo -e "  → $p ... ${RED}NÃO ENCONTRADO${RESET}"
    warn "$p ausente"
    MISSING_DIRS+=("$p")
  fi
done

# ---------------------------
# Module presence
# ---------------------------
echo
echo -e "${BOLD}${CYAN}2) Verificando módulos em ${LIB_DIR}...${RESET}"
REQUIRED_MODULES=(core.sh db.sh log.sh sync.sh deps.py revdep_depclean.sh remove.sh upgrade.sh bootstrap.sh audit.sh)
MISSING_MODS=()
for mod in "${REQUIRED_MODULES[@]}"; do
  if [[ -f "${LIB_DIR}/$mod" ]]; then
    echo -e "  → ${mod} ... ${GREEN}OK${RESET}"
    info "Módulo ${mod} presente"
  else
    echo -e "  → ${mod} ... ${RED}FALTA${RESET}"
    warn "Módulo ${mod} ausente"
    MISSING_MODS+=("$mod")
  fi
done

# ---------------------------
# System cmds and python pkgs
# ---------------------------
echo
echo -e "${BOLD}${CYAN}3) Verificando dependências de sistema...${RESET}"
SYS_CMDS=(bash python3 git curl wget tar xz sha256sum make gcc ld ldconfig fakeroot jq yq pip3)
MISSING_CMDS=()
for c in "${SYS_CMDS[@]}"; do
  if command -v "$c" >/dev/null 2>&1; then
    echo -e "  → $c ... ${GREEN}OK${RESET}"
  else
    echo -e "  → $c ... ${YELLOW}ausente${RESET}"
    warn "Comando $c ausente"
    MISSING_CMDS+=("$c")
  fi
done

echo
echo -e "${BOLD}${CYAN}4) Verificando módulos Python...${RESET}"
PY_PKGS=(yaml networkx rich)
MISSING_PY=()
for p in "${PY_PKGS[@]}"; do
  if python3 -c "import ${p}" >/dev/null 2>&1; then
    echo -e "  → python ${p} ... ${GREEN}OK${RESET}"
  else
    echo -e "  → python ${p} ... ${YELLOW}ausente${RESET}"
    warn "Módulo Python ${p} ausente"
    MISSING_PY+=("$p")
  fi
done

# ---------------------------
# Connectivity and ports dir
# ---------------------------
echo
echo -e "${BOLD}${CYAN}5) Verificando conectividade e /usr/ports...${RESET}"
if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
  echo -e "  → Conexão de rede ... ${GREEN}OK${RESET}"
  info "Internet acessível (ping 8.8.8.8)"
else
  echo -e "  → Conexão de rede ... ${YELLOW}sem resposta${RESET}"
  warn "Sem resposta de ping (internet?)"
fi

if [[ -d "$PORTS_DIR" ]]; then
  if [[ -n "$(ls -A "$PORTS_DIR" 2>/dev/null || true)" ]]; then
    echo -e "  → $PORTS_DIR ... ${GREEN}OK${RESET}"
  else
    echo -e "  → $PORTS_DIR ... ${YELLOW}vazio${RESET}"
    warn "$PORTS_DIR está vazio"
    MISSING_DIRS+=("$PORTS_DIR")
  fi
else
  echo -e "  → $PORTS_DIR ... ${RED}ausente${RESET}"
  MISSING_DIRS+=("$PORTS_DIR")
fi

# ---------------------------
# LFS checks
# ---------------------------
echo
echo -e "${BOLD}${CYAN}6) Verificação LFS (ponto /mnt/lfs)...${RESET}"
if [[ -d "$LFS_DIR" ]]; then
  if mountpoint -q "$LFS_DIR"; then
    echo -e "  → $LFS_DIR montado ... ${GREEN}OK${RESET}"
  else
    echo -e "  → $LFS_DIR existe, não montado ... ${YELLOW}atenção${RESET}"
    warn "$LFS_DIR existe mas não está montado"
  fi
else
  echo -e "  → $LFS_DIR ... ${YELLOW}não existe${RESET}"
fi

# ---------------------------
# Syntax checks for shell modules
# ---------------------------
echo
echo -e "${BOLD}${CYAN}7) Verificando sintaxe dos módulos shell...${RESET}"
for f in "${LIB_DIR}"/*.sh; do
  if [[ -f "$f" ]]; then
    if bash -n "$f" 2>/dev/null; then
      echo -e "  → $(basename "$f") ... ${GREEN}OK${RESET}"
    else
      echo -e "  → $(basename "$f") ... ${RED}Erro de sintaxe${RESET}"
      warn "Erro de sintaxe em $f"
    fi
  fi
done

# ---------------------------
# Summary of findings
# ---------------------------
echo
echo -e "${BOLD}${CYAN}Resumo: ${RESET}"
[[ ${#MISSING_DIRS[@]} -eq 0 ]] && echo -e "  → Diretórios: ${GREEN}OK${RESET}" || echo -e "  → Diretórios faltando: ${YELLOW}${MISSING_DIRS[*]}${RESET}"
[[ ${#MISSING_MODS[@]} -eq 0 ]] && echo -e "  → Módulos: ${GREEN}OK${RESET}" || echo -e "  → Módulos faltando: ${RED}${MISSING_MODS[*]}${RESET}"
[[ ${#MISSING_CMDS[@]} -eq 0 ]] && echo -e "  → Comandos: ${GREEN}OK${RESET}" || echo -e "  → Comandos faltando: ${YELLOW}${MISSING_CMDS[*]}${RESET}"
[[ ${#MISSING_PY[@]} -eq 0 ]] && echo -e "  → Python: ${GREEN}OK${RESET}" || echo -e "  → Python faltando: ${YELLOW}${MISSING_PY[*]}${RESET}"

# ---------------------------
# Auto-fix actions (--fix)
# ---------------------------
if [[ $DO_FIX -eq 1 ]]; then
  echo
  echo -e "${BOLD}${CYAN}Executando correções automáticas (--fix)...${RESET}"
  detect_pkg_mgr

  # 1) criar diretórios ausentes
  if [[ ${#MISSING_DIRS[@]} -gt 0 ]]; then
    for d in "${MISSING_DIRS[@]}"; do
      info "Criar diretório: $d"
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) mkdir -p $d"
      else
        mkdir -p "$d"
        chmod 0755 "$d" || true
        info "Criado $d"
      fi
    done
  fi

  # 2) copiar arquivos padrão se faltarem (ex: completion, executable, config)
  if [[ ! -f "$EXECUTABLE" && -f "${BASE_SHARE}/newpkg" ]]; then
    info "Instalar executável newpkg em $EXECUTABLE"
    safe_run "cp -a '${BASE_SHARE}/newpkg' '$EXECUTABLE' && chmod 0755 '$EXECUTABLE'"
  fi
  if [[ ! -f "$CONFIG_FILE" && -f "${BASE_SHARE}/newpkg.yaml" ]]; then
    info "Instalar newpkg.yaml em $CONFIG_FILE"
    safe_run "cp -a '${BASE_SHARE}/newpkg.yaml' '$CONFIG_FILE' && chmod 0644 '$CONFIG_FILE'"
  fi
  if [[ ! -f "$COMPLETION_FILE" && -f "${BASE_SHARE}/newpkg_bash_zsh" ]]; then
    info "Instalar completion em $COMPLETION_FILE"
    safe_run "cp -a '${BASE_SHARE}/newpkg_bash_zsh' '$COMPLETION_FILE' && chmod 0644 '$COMPLETION_FILE'"
  fi

  # 3) copiar módulos faltantes se existirem em fonte (BASE_SHARE/lib)
  for mod in "${MISSING_MODS[@]:-}"; do
    src="${BASE_SHARE}/lib/${mod}"
    dst="${LIB_DIR}/${mod}"
    if [[ -f "$src" ]]; then
      info "Copiar módulo $mod para $LIB_DIR"
      safe_run "mkdir -p '$LIB_DIR' && cp -a '$src' '$dst' && chmod 0644 '$dst'"
    else
      warn "Módulo $mod não encontrado em ${BASE_SHARE}/lib; não foi possível copiar automaticamente."
    fi
  done

  # 4) instalar dependências do sistema faltantes
  if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then
    # mapear nomes genéricos para pacotes de distro (melhor esforço)
    pkgs_to_install=()
    for m in "${MISSING_CMDS[@]}"; do
      case "$m" in
        yq) pkgs_to_install+=(yq) ;;
        jq) pkgs_to_install+=(jq) ;;
        pip3) pkgs_to_install+=(python3-pip) ;;
        python3) pkgs_to_install+=(python3) ;;
        fakeroot) pkgs_to_install+=(fakeroot) ;;
        sha256sum) pkgs_to_install+=(coreutils) ;;
        xz) pkgs_to_install+=(xz-utils) ;;
        *) pkgs_to_install+=("$m") ;;
      esac
    done
    install_system_pkgs "${pkgs_to_install[@]}" || warn "Instalação automática de pacotes falhou ou não suportada. Instale manualmente: ${pkgs_to_install[*]}"
  fi

  # 5) instalar pacotes Python faltantes
  if [[ ${#MISSING_PY[@]} -gt 0 ]]; then
    install_pip_pkgs "${MISSING_PY[@]}" || warn "Falha ao instalar pacotes Python (${MISSING_PY[*]})"
  fi

  # 6) garantir symlink /usr/bin/newpkg e aliases
  if [[ ! -L /usr/bin/newpkg || ! -f /usr/bin/newpkg ]]; then
    info "Criando symlink /usr/bin/newpkg -> ${EXECUTABLE}"
    safe_run "ln -sf '${EXECUTABLE}' /usr/bin/newpkg && chmod +x '${EXECUTABLE}'"
  fi
  for a in np pkg npg; do
    if [[ ! -L "/usr/bin/$a" ]]; then
      info "Criando alias /usr/bin/$a -> /usr/bin/newpkg"
      safe_run "ln -sf /usr/bin/newpkg '/usr/bin/$a'"
    fi
  done

  # 7) garantir completion system-wide (copiar para /etc/bash_completion.d)
  if [[ -f "$COMPLETION_FILE" ]]; then
    COMP_DST="/etc/bash_completion.d/newpkg"
    info "Instalando completion system-wide em $COMP_DST"
    safe_run "mkdir -p /etc/bash_completion.d && cp -f '$COMPLETION_FILE' '$COMP_DST' && chmod 0644 '$COMP_DST'"
    # Add source to /etc/profile.d if missing
    PROFILE_D="/etc/profile.d/newpkg_completion.sh"
    if [[ ! -f "$PROFILE_D" ]]; then
      info "Criando /etc/profile.d/newpkg_completion.sh"
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) criar $PROFILE_D"
      else
        cat > "$PROFILE_D" <<EOF
# newpkg completion (system-wide)
if [ -f /etc/bash_completion.d/newpkg ]; then
  . /etc/bash_completion.d/newpkg
fi
EOF
        chmod 0644 "$PROFILE_D"
      fi
    fi
  fi

  # 8) criar usuário builder/lfs opcional (apenas se não existirem)
  if id builder &>/dev/null; then
    info "Usuário 'builder' já existe"
  else
    info "Criando usuário 'builder' (opcional)"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) useradd -m -s /bin/bash builder"
    else
      if command -v useradd >/dev/null 2>&1; then
        useradd -m -s /bin/bash builder || warn "Falha ao criar usuário builder"
      else
        warn "useradd não disponível; crie usuário builder manualmente se quiser."
      fi
    fi
  fi

  # 9) ajustar permissões básicas
  info "Ajustando permissões em ${BASE_SHARE} e logs"
  safe_run "chown -R root:root '${BASE_SHARE}' || true"
  safe_run "chmod -R 0755 '${BASE_SHARE}' || true"
  safe_run "chmod -R 0755 '${LIB_DIR}' || true"
  safe_run "mkdir -p '${LOGDIR}' && chmod 0755 '${LOGDIR}' || true"

  info "Correções concluídas. Verifique $LOGFILE para detalhes."
fi

# ---------------------------
# Final
# ---------------------------
echo
echo -e "${BOLD}${CYAN}Verificação concluída.${RESET}"
echo "Relatório em: $LOGFILE"
if [[ $DO_FIX -eq 1 ]]; then
  echo -e "${GREEN}As correções foram aplicadas (ou simuladas em dry-run).${RESET}"
else
  echo -e "${YELLOW}Execute com --fix para tentar corrigir problemas detectados.${RESET}"
fi

exit 0
