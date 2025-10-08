#!/usr/bin/env bash
# newpkg_audit.sh
# Módulo unificado: selfcheck / doctor / audit / recover
# Salvar em: /usr/share/newpkg/lib/newpkg_audit.sh
#
# Uso (exemplos):
#   sudo newpkg --selfcheck
#   sudo newpkg --doctor
#   sudo newpkg --doctor --fix
#   sudo newpkg --audit         # mostra menu antes de aplicar correções
#   sudo newpkg --audit --fix   # executa audit com correções sem menu
#   sudo newpkg --recover-only  # tenta recuperar pacotes corrompidos (cache → rebuild)
#   newpkg_audit.sh --dry-run --audit
#
set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

# ---------------------
# Configurações
# ---------------------
BASE_SHARE="/usr/share/newpkg"
LIB_DIR="${BASE_SHARE}/lib"
LOG_DIR="/var/log/newpkg"
LOG_FILE="${LOG_DIR}/audit.log"
CACHE_DIR="/var/cache/newpkg"
PORTS_DIR="/usr/ports"
DB_FILE="/var/lib/newpkg/packages.db"
CORE_SH="${LIB_DIR}/core.sh"

DRY_RUN=0
AUTO_FIX=0   # when set, apply fixes without asking
MODE=""

# Colors
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
  BOLD="$(tput bold)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"
else
  BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""
fi

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() {
  local lvl="$1"; shift
  local msg="$*"
  mkdir -p "$LOG_DIR"
  printf '%s [%s] %s\n' "$(timestamp)" "$lvl" "$msg" | tee -a "$LOG_FILE"
}
info()  { log "INFO"  "$*"; }
warn()  { log "WARN"  "$*"; }
error() { log "ERROR" "$*"; }

die() { error "$*"; exit 1; }

# ---------------------
# Helpers
# ---------------------
safe_run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) $*"
  else
    eval "$@"
  fi
}

require_root_for_fix() {
  if [[ $AUTO_FIX -eq 1 || "$1" == "--fix" ]]; then
    if [[ $EUID -ne 0 ]]; then
      die "Operação de correção requer privilégios de root (sudo)."
    fi
  fi
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then echo "zypper"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  else echo "none"; fi
}

install_system_pkgs() {
  local pkgs=("$@")
  local mgr
  mgr="$(detect_pkg_mgr)"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) instalar via $mgr: ${pkgs[*]}"
    return 0
  fi
  case "$mgr" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ;;
    dnf) dnf install -y "${pkgs[@]}" ;;
    pacman) pacman -Sy --noconfirm "${pkgs[@]}" ;;
    zypper) zypper --non-interactive install "${pkgs[@]}" ;;
    apk) apk add "${pkgs[@]}" ;;
    *) warn "Gerenciador de pacotes não detectado; instale manualmente: ${pkgs[*]}"; return 2 ;;
  esac
}

install_pip_pkgs() {
  local pips=("$@")
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) pip3 install ${pips[*]}"
    return 0
  fi
  if ! command -v pip3 >/dev/null 2>&1; then
    local mgr
    mgr="$(detect_pkg_mgr)"
    case "$mgr" in
      apt) install_system_pkgs python3-pip || true ;;
      dnf) install_system_pkgs python3-pip || true ;;
      pacman) install_system_pkgs python-pip || true ;;
      apk) install_system_pkgs py3-pip || true ;;
      *) warn "pip3 ausente; instale manualmente"; ;
    esac
  fi
  pip3 install --upgrade "${pips[@]}"
}

# ---------------------
# Quick checks (selfcheck)
# ---------------------
mode_selfcheck() {
  info "Modo: selfcheck (verificação rápida)"
  local checks=(
    "[ -d /usr/share/newpkg ]"
    "[ -d /usr/share/newpkg/lib ]"
    "[ -x /usr/share/newpkg/newpkg ] || -f /usr/bin/newpkg"
    "command -v bash"
    "command -v python3"
    "command -v tar"
    "command -v gcc"
    "command -v fakeroot"
    "[ -w $LOG_DIR ] || mkdir -p $LOG_DIR"
  )
  for c in "${checks[@]}"; do
    if eval "$c" >/dev/null 2>&1; then
      info "OK: $c"
    else
      warn "FALHA: $c"
      echo -e "${YELLOW}Erro crítico detectado: $c${RESET}"
      return 1
    fi
  done
  echo -e "${GREEN}Selfcheck: ambiente mínimo OK${RESET}"
  return 0
}

# ---------------------
# Doctor (diagnóstico profundo)
# ---------------------
mode_doctor() {
  info "Modo: doctor (diagnóstico completo)"
  echo "=== NEWPKG DOCTOR ===" | tee -a "$LOG_FILE"
  echo
  # Directories
  local dirs=( "/usr/share/newpkg" "$BASE_SHARE/newpkg.yaml" "$LIB_DIR" "$CACHE_DIR" "$PORTS_DIR" "/var/lib/newpkg" )
  for d in "${dirs[@]}"; do
    if [[ -e "$d" ]]; then
      info "Existe: $d"
    else
      warn "Ausente: $d"
    fi
  done

  # Modules
  local mods=( core.sh db.sh log.sh sync.sh deps.py revdep_depclean.sh remove.sh upgrade.sh bootstrap.sh audit.sh )
  for m in "${mods[@]}"; do
    if [[ -f "${LIB_DIR}/${m}" ]]; then
      info "Módulo: ${m} presente"
      # check syntax for shell scripts
      if [[ "${m##*.}" == "sh" ]]; then
        if bash -n "${LIB_DIR}/${m}" 2>/dev/null; then info "  Syntax OK: ${m}"; else warn "  Syntax ERRO: ${m}"; fi
      fi
    else
      warn "Módulo: ${m} ausente"
    fi
  done

  # System commands
  local commands=( bash python3 pip3 tar xz git curl wget jq yq make gcc fakeroot )
  for cmd in "${commands[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then info "Cmd: $cmd disponível"; else warn "Cmd: $cmd ausente"; fi
  done

  # Python modules
  local pmods=( yaml networkx rich )
  for p in "${pmods[@]}"; do
    if python3 -c "import $p" >/dev/null 2>&1; then info "Py: $p OK"; else warn "Py: $p ausente"; fi
  done

  # DB file
  if [[ -f "$DB_FILE" ]]; then
    info "DB presente: $DB_FILE"
  else
    warn "DB ausente: $DB_FILE"
  fi

  # mounts
  if [[ -d /mnt/lfs ]]; then
    if mountpoint -q /mnt/lfs; then info "/mnt/lfs montado"; else warn "/mnt/lfs existe mas não está montado"; fi
  else
    info "/mnt/lfs não existe (modo host normal)"
  fi

  echo
  info "Doctor concluído. Verifique $LOG_FILE para mais detalhes."
}

# ---------------------
# Audit (full) with menu
# ---------------------
_prompt_menu_audit() {
  echo
  echo -e "${BOLD}${BLUE}AUDIT: Seleção de ação${RESET}"
  echo "1) Verificar apenas (recomendada)"
  echo "2) Verificar e aplicar correções automáticas (recomendada para manutenção)"
  echo "3) Verificar e salvar relatório (sem correções)"
  echo "4) Cancelar"
  echo
  read -r -p "Escolha uma opção [1-4]: " opt
  case "$opt" in
    1) AUTO_FIX=0; return 0 ;;
    2) AUTO_FIX=1; return 0 ;;
    3) AUTO_FIX=0; return 0 ;;
    4) echo "Cancelado pelo usuário."; exit 0 ;;
    *) echo "Opção inválida"; _prompt_menu_audit ;;
  esac
}

_find_corrupted_packages() {
  # Heurística: verificar checksums dos pacotes instalados listados no DB.
  # O DB format é dependente da sua implementação; aqui assumimos linhas: name|version|install_dir|manifest_sha
  # Adapte conforme seu db.sh. Implementamos fallback simples: procurar pacotes com arquivos ausentes.
  info "Procurando pacotes corrompidos/arquivos ausentes..."
  local pkgs=()
  if [[ -f "$DB_FILE" ]]; then
    while IFS= read -r line; do
      # simplistic parse: name|version|installdir
      local name="$(echo "$line" | cut -d'|' -f1)"
      local instdir="$(echo "$line" | cut -d'|' -f3)"
      if [[ -n "$instdir" && ! -d "$instdir" ]]; then
        warn "Pacote $name: diretório de instalação ausente ($instdir)"
        pkgs+=("$name")
      fi
    done < "$DB_FILE"
  fi
  # fallback: nenhuma informação => retorna vazio
  echo "${pkgs[@]:-}"
}

_apply_fix_for_pkg() {
  local pkg="$1"
  info "Tentando reparar pacote: $pkg"

  # 1) procurar tarball no cache
  local tarball
  tarball="$(find "$CACHE_DIR" -type f -iname "${pkg}*.tar.*" -o -iname "${pkg}*.tar.zst" 2>/dev/null | head -n1 || true)"
  if [[ -n "$tarball" ]]; then
    info "Encontrado tarball em cache: $tarball"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) restaurar $tarball"
      return 0
    fi
    # extrair para tmp e instalar com fakeroot (assumindo que tarball tem estrutura apropriada)
    tmpd="$(mktemp -d)"
    tar -C "$tmpd" -xf "$tarball" || { warn "Falha ao extrair $tarball"; rm -rf "$tmpd"; return 1; }
    info "Extraído para $tmpd — instalando em destdir temporário"
    # if core.sh supports an 'install-from-dir' mode, use it; else attempt a naive copy (best-effort)
    if [[ -x "$CORE_SH" ]]; then
      safe_run "bash '$CORE_SH' --install-from-dir '$tmpd' --skip-deps"
      info "Reconstrução via core.sh finalizada (se suportado)"
    else
      warn "core.sh não disponível para instalar automaticamente; manual required"
    fi
    rm -rf "$tmpd"
    return 0
  fi

  # 2) se não tiver no cache, tentar reconstruir via core.sh (requer metafile)
  info "Tarball não encontrado no cache; tentaremos reconstruir $pkg via core.sh"
  if [[ -x "$CORE_SH" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) bash $CORE_SH install $pkg"
      return 0
    fi
    safe_run "bash '$CORE_SH' install '$pkg'"
    return $?
  else
    warn "core.sh não disponível; não é possível reconstruir automaticamente $pkg"
    return 2
  fi
}

mode_audit() {
  info "Modo: audit (auditoria completa)"

  if [[ $AUTO_FIX -eq 0 ]]; then
    # ask user for menu if not auto-fix triggered from flags
    _prompt_menu_audit
  fi

  # STEP 1: basic checks
  info "Executando checks básicos..."
  mode_selfcheck || warn "Selfcheck reportou problemas (veja logs)"

  # STEP 2: detect corrupted packages
  local corrupted
  corrupted=$(_find_corrupted_packages)
  if [[ -n "$corrupted" ]]; then
    info "Pacotes corrompidos detectados: $corrupted"
  else
    info "Nenhum pacote corrompido detectado por heurística."
  fi

  # STEP 3: security and hygiene checks (permissions, suid, stray files)
  info "Verificando permisos world-writable, arquivos SUID/GUID e symlinks quebrados..."
  # world-writable excluding /tmp
  local ww
  ww="$(find / -xdev -path /proc -prune -o -type f -perm -0002 -print 2>/dev/null | head -n 50 || true)"
  if [[ -n "$ww" ]]; then warn "Arquivos world-writable (exemplo): $(echo "$ww" | head -n1)"; else info "Sem arquivos world-writable detectados (amostra)"; fi
  # suid files
  local suid
  suid="$(find / -xdev -path /proc -prune -o -perm -4000 -type f -print 2>/dev/null | head -n 20 || true)"
  if [[ -n "$suid" ]]; then warn "Arquivos SUID (exemplo): $(echo "$suid" | head -n1)"; else info "Sem SUIDs incomuns (amostra)"; fi
  # broken symlinks under /usr
  local broken
  broken="$(find /usr -xtype l 2>/dev/null | head -n 20 || true)"
  if [[ -n "$broken" ]]; then warn "Symlinks quebrados (ex.): $(echo "$broken" | head -n1)"; else info "Nenhum symlink quebrado em /usr (amostra)"; fi

  # STEP 4: apply fixes if requested
  if [[ $AUTO_FIX -eq 1 ]]; then
    info "Aplicando correções automáticas..."
    # fix permissions (conservative)
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) corrigir permissões base em /usr/share/newpkg e /var/log/newpkg"
    else
      safe_run "chmod -R 0755 /usr/share/newpkg || true"
      safe_run "chmod -R 0755 /var/log/newpkg || true"
    fi

    # attempt repair of corrupted packages
    if [[ -n "$corrupted" ]]; then
      for p in $corrupted; do
        _apply_fix_for_pkg "$p" || warn "Falha ao reparar pacote $p"
      done
    fi

    # cleanup stray files (example: old build dirs >30d)
    info "Limpando caches antigos..."
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) find $CACHE_DIR -type f -mtime +90 -print"
    else
      find "$CACHE_DIR" -type f -mtime +90 -print -delete || true
    fi

    info "Correções aplicadas."
  else
    info "Modo somente verificação — nenhuma correção foi aplicada."
    info "Execute com --fix ou escolha a opção 2 no menu para aplicar correções."
  fi

  info "Auditoria completa. Veja o log em $LOG_FILE"
}

# ---------------------
# Recover-only mode
# ---------------------
mode_recover_only() {
  info "Modo: recover-only (recuperação somente)"
  # find corrupted packages
  local corrupted
  corrupted=$(_find_corrupted_packages)
  if [[ -z "$corrupted" ]]; then
    info "Nenhum pacote corrompido detectado."
    return 0
  fi
  info "Pacotes corrompidos detectados: $corrupted"
  # require root to perform repair operations
  if [[ $EUID -ne 0 ]]; then
    die "Recuperação precisa de privilégios de root. Rode com sudo."
  fi
  for p in $corrupted; do
    info "Recuperando $p ..."
    if _apply_fix_for_pkg "$p"; then
      info "Pacote $p recuperado com sucesso."
    else
      warn "Falha ao recuperar $p. Veja logs."
    fi
  done
  info "Recover-only finalizado."
}

# ---------------------
# CLI parsing
# ---------------------
show_help() {
  cat <<EOF
newpkg_audit.sh - Auditoria, Diagnóstico e Recuperação do Newpkg

Modos:
  --selfcheck           Verificação rápida de pré-requisitos.
  --doctor              Diagnóstico completo (lista problemas).
  --doctor --fix        Diagnóstico + correção automática.
  --audit               Auditoria completa (menu antes de aplicar correções).
  --audit --fix         Auditoria completa e aplica correções sem menu.
  --recover-only        Recupera pacotes corrompidos (cache → rebuild).
  --dry-run             Simula ações (não altera o sistema).
  -h, --help            Exibe esta ajuda.

Logs: $LOG_FILE
EOF
}

# parse args and dispatch
if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

# parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selfcheck) MODE="selfcheck"; shift ;;
    --doctor) MODE="doctor"; shift ;;
    --audit) MODE="audit"; shift ;;
    --recover-only) MODE="recover-only"; shift ;;
    --fix) AUTO_FIX=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Argumento inválido: $1"; show_help; exit 1 ;;
  esac
done

# dispatch
case "$MODE" in
  selfcheck)
    mode_selfcheck
    ;;
  doctor)
    if [[ $AUTO_FIX -eq 1 ]]; then
      require_root_for_fix "--fix"
      mode_doctor
      # attempt basic fixes (reuse audit logic)
      AUTO_FIX=1
      mode_audit
    else
      mode_doctor
    fi
    ;;
  audit)
    if [[ $AUTO_FIX -eq 0 ]]; then
      # interactive menu for audit
      _prompt_menu_audit
    fi
    # if user selected AUTO_FIX in menu, AUTO_FIX will be set by _prompt_menu_audit
    if [[ $AUTO_FIX -eq 1 ]]; then
      require_root_for_fix "--fix"
      mode_audit
    else
      mode_audit
    fi
    ;;
  "recover-only")
    mode_recover_only
    ;;
  *)
    show_help
    exit 1
    ;;
esac

exit 0
