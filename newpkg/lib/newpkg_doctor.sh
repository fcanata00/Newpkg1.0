#!/usr/bin/env bash
# ============================================================
#  newpkg_doctor.sh — Diagnóstico completo do ambiente Newpkg
# ============================================================

set -euo pipefail

# --- Cores ---
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

echo -e "${CYAN}🔍 Iniciando verificação do ambiente Newpkg...${RESET}"
LOGFILE="/var/log/newpkg/doctor.log"
mkdir -p /var/log/newpkg
echo "=== Newpkg Doctor $(date) ===" > "$LOGFILE"

# --- Função auxiliar ---
check() {
    local desc="$1"
    local cmd="$2"
    echo -ne "${CYAN}→ ${desc}...${RESET} "
    if eval "$cmd" &>/dev/null; then
        echo -e "${GREEN}[OK]${RESET}"
        echo "[OK] $desc" >> "$LOGFILE"
    else
        echo -e "${RED}[FALHA]${RESET}"
        echo "[ERRO] $desc" >> "$LOGFILE"
    fi
}

# --- Seções ---
echo -e "\n${YELLOW}1️⃣  Verificação de diretórios e permissões...${RESET}"
for dir in /usr/share/newpkg /var/log/newpkg /var/cache/newpkg /usr/ports; do
    check "Diretório $dir existe" "[ -d $dir ]"
done

echo -e "\n${YELLOW}2️⃣  Verificação de módulos principais...${RESET}"
modules=(
    core.sh db.sh log.sh sync.sh deps.py
    revdep_depclean.sh remove.sh upgrade.sh
    bootstrap.sh audit.sh
)
for m in "${modules[@]}"; do
    check "Módulo $m presente" "[ -f /usr/share/newpkg/lib/$m ]"
done

echo -e "\n${YELLOW}3️⃣  Verificação do executável e YAML...${RESET}"
check "Executável newpkg" "[ -f /usr/share/newpkg/newpkg ]"
check "Configuração newpkg.yaml" "[ -f /usr/share/newpkg/newpkg.yaml ]"
check "Bash completion" "[ -f /usr/share/newpkg/newpkg_bash_zsh ]"

echo -e "\n${YELLOW}4️⃣  Dependências de sistema...${RESET}"
deps=(bash python3 yq xargs tar make gcc patch git wget curl fakeroot)
for d in "${deps[@]}"; do
    check "Dependência: $d" "command -v $d"
done

echo -e "\n${YELLOW}5️⃣  Dependências Python...${RESET}"
pydeps=(pyyaml networkx rich)
for p in "${pydeps[@]}"; do
    check "Módulo Python: $p" "python3 -c 'import $p'"
done

echo -e "\n${YELLOW}6️⃣  Verificação de conectividade e repositórios...${RESET}"
check "Conexão com internet" "ping -c1 -W2 linuxfromscratch.org"
check "Repositório /usr/ports acessível" "[ -d /usr/ports ] && [ -n \"\$(ls /usr/ports 2>/dev/null)\" ]"

echo -e "\n${YELLOW}7️⃣  Verificação de montagem LFS (se existir)...${RESET}"
if [ -d /mnt/lfs ]; then
    check "/mnt/lfs montado" "mountpoint -q /mnt/lfs"
    check "resolv.conf presente no chroot" "[ -f /mnt/lfs/etc/resolv.conf ]"
else
    echo -e "${YELLOW}Aviso:${RESET} diretório /mnt/lfs não existe — modo host normal."
fi

echo -e "\n${YELLOW}8️⃣  Verificação de integridade dos módulos...${RESET}"
for f in /usr/share/newpkg/lib/*.sh; do
    check "Sintaxe: $(basename "$f")" "bash -n $f"
done

echo -e "\n${YELLOW}9️⃣  Verificação de cache e banco de dados...${RESET}"
check "Cache acessível" "[ -w /var/cache/newpkg ]"
check "Banco de dados legível" "[ -f /var/lib/newpkg/packages.db ] || true"

echo -e "\n${YELLOW}🔟  Verificação de hooks e permissões extras...${RESET}"
check "Permissões adequadas" "[ -w /usr/share/newpkg ] && [ -w /var/log/newpkg ]"
check "Usuário tem sudo (para instalar pacotes)" "sudo -n true 2>/dev/null"

echo -e "\n${YELLOW}💾  Teste rápido de escrita em log...${RESET}"
echo "Teste de log $(date)" >> "$LOGFILE" && echo -e "${GREEN}[OK]${RESET} Log escrito em $LOGFILE"

echo -e "\n${CYAN}✅ Diagnóstico concluído!${RESET}"
echo -e "Confira o relatório detalhado em: ${YELLOW}$LOGFILE${RESET}"

# Sugestão automática
echo -e "\n${YELLOW}Sugestão:${RESET} Rode '${GREEN}newpkg --doctor --fix${RESET}' para corrigir automaticamente diretórios ausentes."
