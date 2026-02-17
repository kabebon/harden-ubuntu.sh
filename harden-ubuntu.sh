#!/bin/bash
# =============================================================================
# harden-ubuntu.sh — безопасная начальная настройка Ubuntu-сервера
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Безопасная настройка сервера (SSH-ключ, BBR, fail2ban) ===${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите скрипт от root (sudo)${NC}"
    exit 1
fi

if ! test -t 0; then
    echo -e "${RED}Этот скрипт требует интерактивного ввода.${NC}"
    echo "Рекомендуемый способ:"
    echo "  curl -fsSL https://raw.githubusercontent.com/.../harden-ubuntu.sh -o harden.sh"
    echo "  chmod +x harden.sh"
    echo "  sudo ./harden.sh"
    exit 1
fi

# Переменные для отката
ROLLBACK_LOG="/root/harden-rollback-$(date +%Y%m%d-%H%M%S).log"
SSHD_BACKUP=""
USER_CREATED=false
SUDOERS_FILE=""
UFW_WAS_ENABLED=false
KEY_DIR=""

echo "Лог отката будет сохранён в: $ROLLBACK_LOG" | tee -a "$ROLLBACK_LOG"

rollback() {
    echo -e "\n${RED}Прерывание или ошибка → откат${NC}" | tee -a "$ROLLBACK_LOG"

    [ -n "$KEY_DIR" ] && [ -d "$KEY_DIR" ] && rm -rf "$KEY_DIR" && echo "→ Ключи удалены" | tee -a "$ROLLBACK_LOG"

    [ -n "$SSHD_BACKUP" ] && [ -f "$SSHD_BACKUP" ] && \
        cp "$SSHD_BACKUP" /etc/ssh/sshd_config && \
        systemctl restart ssh || systemctl restart sshd && \
        echo "→ sshd_config восстановлен" | tee -a "$ROLLBACK_LOG"

    if $USER_CREATED && id "$NEW_USER" &>/dev/null; then
        deluser --remove-home "$NEW_USER" 2>/dev/null
        [ -n "$SUDOERS_FILE" ] && rm -f "$SUDOERS_FILE" 2>/dev/null
        echo "→ Пользователь $NEW_USER и sudoers удалены" | tee -a "$ROLLBACK_LOG"
    fi

    if $UFW_WAS_ENABLED; then
        ufw --force disable 2>/dev/null && echo "→ UFW отключён (был выключен до запуска)" | tee -a "$ROLLBACK_LOG"
    else
        echo "→ UFW уже был включён → откат UFW пропущен" | tee -a "$ROLLBACK_LOG"
    fi

    echo -e "${YELLOW}Откат завершён (частично). Проверьте систему вручную!${NC}" | tee -a "$ROLLBACK_LOG"
    exit 1
}

trap rollback INT ERR

# ────────────────────────────────────────────────
# Запрос имени пользователя
# ────────────────────────────────────────────────
echo -e "\n${YELLOW}Введите имя нового пользователя (только a-z, 0-9, _, -)${NC}"
read -r -p "Имя пользователя: " NEW_USER
NEW_USER=${NEW_USER:-admin}

if [[ ! "$NEW_USER" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
    echo -e "${RED}Недопустимое имя (3–32 символа, только a-z0-9_-)${NC}"
    exit 1
fi

if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}Пользователь $NEW_USER уже существует — ключ будет перезаписан${NC}"
    read -r -p "Продолжить? [y/N]: " cont
    [[ "$cont" =~ ^[Yy]$ ]] || exit 0
else
    USER_CREATED=true
fi

# ────────────────────────────────────────────────
# Запрос порта
# ────────────────────────────────────────────────
echo -e "\n${YELLOW}Новый порт SSH (рекомендуется >1024, не 22)${NC}"
read -r -p "Новый порт SSH: " NEW_PORT
NEW_PORT=${NEW_PORT:-2222}

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1024 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo -e "${RED}Неверный порт (1024–65535)${NC}"
    exit 1
fi

if [ "$NEW_PORT" = "22" ]; then
    echo -e "${YELLOW}Порт 22 — не рекомендуется по безопасности${NC}"
    read -r -p "Продолжить? [y/N]: " cont22
    [[ "$cont22" =~ ^[Yy]$ ]] || exit 0
fi

# ────────────────────────────────────────────────
# Генерация и красивый вывод ключей
# ────────────────────────────────────────────────
echo -e "\n${GREEN}Генерируем пару ed25519 ключей...${NC}\n"

KEY_DIR="/root/temp-ssh-key-$(date +%s)"
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"

ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -C "$NEW_USER@$(hostname)-$(date +%Y%m%d)" >/dev/null 2>&1

PUB_KEY=$(cat "$KEY_DIR/id_ed25519.pub")
PRIV_KEY=$(cat "$KEY_DIR/id_ed25519")

echo -e "${YELLOW}┌───────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│                     ВАЖНО! СДЕЛАЙТЕ ЭТО СЕЙЧАС                 │${NC}"
echo -e "${YELLOW}│  Скопируйте приватный ключ ниже — он исчезнет после выполнения!  │${NC}"
echo -e "${YELLOW}└───────────────────────────────────────────────────────────────┘${NC}\n"

echo -e "${YELLOW}Приватный ключ:${NC}"
echo ""
echo "$PRIV_KEY"
echo ""

echo -e "${GREEN}Публичный ключ (будет добавлен):${NC}"
echo "$PUB_KEY"
echo ""

read -r -p $'\n'"${RED}Скопировали приватный ключ в безопасное место? Напишите yes: ${NC}" confirm
[[ "$confirm" == "yes" ]] || { echo -e "${RED}Не подтверждено → выход${NC}"; rm -rf "$KEY_DIR"; exit 1; }

echo -e "${GREEN}Подтверждение получено. Продолжаем...${NC}\n"

# ────────────────────────────────────────────────
# Опасная часть
# ────────────────────────────────────────────────

SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP" 2>/dev/null

if $USER_CREATED; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    SUDOERS_FILE="/etc/sudoers.d/90-$NEW_USER"
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
fi

mkdir -p "/home/$NEW_USER/.ssh"
echo "$PUB_KEY" > "/home/$NEW_USER/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh"
chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

sed -i "s/^#*Port.*/Port $NEW_PORT/" /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

if ufw status | grep -q "Status: inactive"; then
    UFW_WAS_ENABLED=true
fi

ufw allow "$NEW_PORT"/tcp  2>/dev/null || true
ufw allow 80/tcp           2>/dev/null || true
ufw allow 443/tcp          2>/dev/null || true
ufw --force enable         2>/dev/null || true

# BBR
echo -e "${YELLOW}Настройка BBR...${NC}"
if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr; then
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo "BBR включён"
    else
        echo "BBR уже активен"
    fi
else
    echo "BBR недоступен в ядре"
fi

# fail2ban
echo -e "${YELLOW}Установка fail2ban...${NC}"
apt update -qq && apt install -y fail2ban

cat <<EOT > /etc/fail2ban/jail.local
[sshd]
enabled   = true
port      = $NEW_PORT
logpath   = %(sshd_log)s
backend   = %(sshd_backend)s
maxretry  = 5
bantime   = 3600
findtime  = 600
EOT

systemctl restart fail2ban
fail2ban-client reload 2>/dev/null || true

# Перезапуск SSH
SSH_SVC="ssh"
systemctl is-active ssh >/dev/null 2>&1 || SSH_SVC="sshd"
systemctl restart "$SSH_SVC"

sleep 2
if ! systemctl is-active --quiet "$SSH_SVC"; then
    echo -e "${RED}Ошибка перезапуска SSH — откатываем${NC}"
    rollback
fi

# ────────────────────────────────────────────────
# Финал
# ────────────────────────────────────────────────

echo -e "\n${GREEN}============================================================${NC}"
echo -e "               Настройка завершена успешно${NC}"
echo ""
echo -e "Пользователь:    ${YELLOW}$NEW_USER${NC}"
echo -e "Порт SSH:        ${YELLOW}$NEW_PORT${NC}"
echo -e "BBR:             ${YELLOW}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'недоступен')${NC}"
echo -e "fail2ban:        ${GREEN}активен${NC}"
echo ""
echo -e "Команда подключения:"
echo -e "  ${YELLOW}ssh -p $NEW_PORT $NEW_USER@$(curl -s ifconfig.me 2>/dev/null || echo 'ваш_IP')${NC}"
echo ""
echo -e "${YELLOW}ОБЯЗАТЕЛЬНО проверьте вход в НОВОМ окне терминала${NC}"
echo -e "перед закрытием текущей сессии root!"
echo -e "${GREEN}============================================================${NC}"

rm -rf "$KEY_DIR"

echo -e "\nУдачи и безопасной работы!${NC}"
