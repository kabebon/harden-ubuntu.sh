#!/bin/bash

# =============================================================================
# harden-ubuntu.sh — безопасная настройка БЕЗ разрыва сессии v3.2
# Убрана строгая проверка порта, добавлен выбор режима (socket / classic)
# =============================================================================
set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Проверка root
[[ $EUID -ne 0 ]] && { echo -e "${RED}Запустите от root${NC}"; exit 1; }

# Защита от curl | bash
[[ -t 0 ]] || { echo -e "${RED}Не запускайте через curl | bash — скачайте и запустите отдельно${NC}"; exit 1; }

# -----------------------------------------------------------------------------
# Переменные
# -----------------------------------------------------------------------------
ROLLBACK_LOG="/root/harden-rollback-$(date +%Y%m%d-%H%M%S).log"
SSHD_BACKUP=""
USER_CREATED=false
SUDOERS_FILE=""
KEY_DIR=""
USE_SOCKET=true

OLD_PORT=$(ss -tulpn | grep -E 'ssh|sshd' | head -1 | grep -oP ':\K\d+' || echo "22")

echo "Лог отката: $ROLLBACK_LOG" | tee "$ROLLBACK_LOG"
echo "Текущий порт SSH: $OLD_PORT" | tee -a "$ROLLBACK_LOG"

# -----------------------------------------------------------------------------
# Функция отката
# -----------------------------------------------------------------------------
rollback() {
    echo -e "\n${RED}Откат...${NC}" | tee -a "$ROLLBACK_LOG"
    [ -n "$SSHD_BACKUP" ] && [ -f "$SSHD_BACKUP" ] && cp "$SSHD_BACKUP" /etc/ssh/sshd_config
    rm -rf /etc/systemd/system/ssh.socket.d 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    if $USE_SOCKET; then
        systemctl restart ssh.socket 2>/dev/null || true
    else
        systemctl restart ssh 2>/dev/null || true
    fi
    if $USER_CREATED && id "$NEW_USER" &>/dev/null; then
        deluser --remove-home "$NEW_USER" 2>/dev/null
        rm -f "$SUDOERS_FILE" 2>/dev/null
    fi
    rm -rf "$KEY_DIR" 2>/dev/null
    echo -e "${YELLOW}Откат завершён${NC}" | tee -a "$ROLLBACK_LOG"
    exit 1
}
trap rollback INT TERM

# -----------------------------------------------------------------------------
# Ввод данных
# -----------------------------------------------------------------------------
echo -e "\n${YELLOW}Имя пользователя (a-z,0-9,_,-):${NC}"
read -r -p "> " NEW_USER
NEW_USER=${NEW_USER:-kabeba}
[[ "$NEW_USER" =~ ^[a-zA-Z0-9_-]{3,32}$ ]] || { echo -e "${RED}Недопустимое имя${NC}"; exit 1; }

if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}Пользователь $NEW_USER существует. Продолжить? [y/N]${NC}"
    read -r cont; [[ "$cont" =~ ^[Yy]$ ]] || exit 0
    USER_EXISTS=true
else
    USER_EXISTS=false
fi

echo -e "\n${YELLOW}Новый порт SSH (1024-65535) [рекомендую 2222]:${NC}"
read -r -p "> " NEW_PORT
NEW_PORT=${NEW_PORT:-2222}
[[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT" -ge 1024 ] && [ "$NEW_PORT" -le 65535 ] || {
    echo -e "${RED}Неверный порт${NC}"; exit 1
}

# Простая проверка (только занят ли явно)
if ss -tuln | grep -q ":$NEW_PORT "; then
    echo -e "${RED}Порт $NEW_PORT занят (виден в ss)${NC}"
    echo "Подождите 2–3 минуты (TIME_WAIT) или выберите другой порт."
    exit 1
fi

echo -e "${YELLOW}Хотите использовать socket-активацию? (рекомендуется) [Y/n]${NC}"
read -r socket_choice
[[ "$socket_choice" =~ ^[Nn]$ ]] && USE_SOCKET=false

# -----------------------------------------------------------------------------
# Генерация ключей
# -----------------------------------------------------------------------------
echo -e "\n${GREEN}Генерируем ключи ed25519...${NC}"
KEY_DIR="/root/temp-ssh-key-$(date +%s)"
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -C "$NEW_USER@$(hostname)-$(date +%Y%m%d)" >/dev/null 2>&1
PUB_KEY=$(cat "$KEY_DIR/id_ed25519.pub")
PRIV_KEY=$(cat "$KEY_DIR/id_ed25519")

echo -e "\n${YELLOW}═══ ПРИВАТНЫЙ КЛЮЧ (СКОПИРУЙТЕ СЕЙЧАС) ═══${NC}\n$PRIV_KEY\n"
echo -e "${YELLOW}═══════════════════════════════════════════${NC}\n"
echo -e "${GREEN}Публичный ключ:${NC}\n$PUB_KEY${NC}\n"

echo -e "${RED}!!! СКОПИРУЙТЕ ПРИВАТНЫЙ КЛЮЧ СЕЙЧАС !!! После копирования введите 'yes'${NC}"
read -r -p "Введите yes для продолжения: " confirm
[[ "$confirm" == "yes" ]] || { rm -rf "$KEY_DIR"; exit 1; }

# -----------------------------------------------------------------------------
# Применение изменений
# -----------------------------------------------------------------------------
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP"

# Создание пользователя
if ! $USER_EXISTS; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    SUDOERS_FILE="/etc/sudoers.d/90-$NEW_USER"
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    USER_CREATED=true
fi

# Установка ключа
mkdir -p "/home/$NEW_USER/.ssh"
echo "$PUB_KEY" > "/home/$NEW_USER/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh" && chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

# Настройка sshd_config
if grep -q "^Port" /etc/ssh/sshd_config; then
    sed -i 's/^Port/#Port/g' /etc/ssh/sshd_config
fi
echo "Port $OLD_PORT" >> /etc/ssh/sshd_config
echo "Port $NEW_PORT" >> /etc/ssh/sshd_config

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

if ! grep -q "^ListenAddress" /etc/ssh/sshd_config; then
    echo "ListenAddress 0.0.0.0" >> /etc/ssh/sshd_config
    echo "ListenAddress ::" >> /etc/ssh/sshd_config
fi

sshd -t || { echo -e "${RED}Ошибка в sshd_config${NC}"; rollback; }

# -----------------------------------------------------------------------------
# Настройка сокета или классического режима
# -----------------------------------------------------------------------------
if $USE_SOCKET && systemctl is-active ssh.socket >/dev/null 2>&1; then
    echo -e "${YELLOW}Добавляем порт $NEW_PORT в socket-активацию...${NC}"
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/override.conf <<EOT
[Socket]
ListenStream=
ListenStream=0.0.0.0:$OLD_PORT
ListenStream=0.0.0.0:$NEW_PORT
EOT

    IPV6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)
    if [[ "$IPV6_DISABLED" == "0" ]]; then
        echo "ListenStream=[::]:$OLD_PORT" >> /etc/systemd/system/ssh.socket.d/override.conf
        echo "ListenStream=[::]:$NEW_PORT" >> /etc/systemd/system/ssh.socket.d/override.conf
    fi
    echo "FreeBind=true" >> /etc/systemd/system/ssh.socket.d/override.conf

    systemctl daemon-reload
    if ! systemctl try-reload-or-restart ssh.socket; then
        echo -e "${RED}Не удалось обновить ssh.socket — откат${NC}"
        rollback
    fi
else
    echo -e "${YELLOW}Отключаем socket-активацию и переходим в классический режим${NC}"
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl mask ssh.socket 2>/dev/null || true
    systemctl unmask ssh.service 2>/dev/null || true
    systemctl enable --now ssh.service 2>/dev/null || true
    systemctl restart ssh
fi

# -----------------------------------------------------------------------------
# UFW
# -----------------------------------------------------------------------------
if command -v ufw >/dev/null; then
    ufw allow "$NEW_PORT"/tcp 2>/dev/null || true
    [[ "$(ufw status | grep -c 'Status: active')" -eq 0 ]] && echo y | ufw enable
fi

# -----------------------------------------------------------------------------
# Финал
# -----------------------------------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e " 🎉 НАСТРОЙКА ЗАВЕРШЕНА 🎉"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}\n"

echo -e "${YELLOW}Текущая сессия НЕ ПРЕРЫВАЛАСЬ! Старый порт $OLD_PORT работает.${NC}"
echo -e "${GREEN}Новый порт $NEW_PORT добавлен.${NC}"
echo -e "Пользователь: ${YELLOW}$NEW_USER${NC}"
echo -e "Проверьте в НОВОМ окне терминала:"
echo -e "  ssh -p $NEW_PORT $NEW_USER@$SERVER_IP\n"

echo -e "${RED}ВАЖНО:${NC}"
echo "1. Откройте новое окно → проверьте подключение по новому порту"
echo "2. Если работает → можно закрыть старый порт (опция ниже)"
echo "3. Если НЕ работает → Ctrl+C в этом окне → откат"

echo -e "\n${YELLOW}Ожидание... (Enter = всё ок, Ctrl+C = откат)${NC}"
read -r

# Опционально закрыть старый порт
echo -e "\n${GREEN}Закрыть старый порт $OLD_PORT автоматически? [y/N]${NC}"
read -r close_old
if [[ "$close_old" =~ ^[Yy]$ ]]; then
    sed -i "/Port $OLD_PORT/d" /etc/ssh/sshd_config
    if $USE_SOCKET; then
        cat > /etc/systemd/system/ssh.socket.d/override.conf <<EOT
[Socket]
ListenStream=
ListenStream=0.0.0.0:$NEW_PORT
EOT
        [[ "$IPV6_DISABLED" == "0" ]] && echo "ListenStream=[::]:$NEW_PORT" >> /etc/systemd/system/ssh.socket.d/override.conf
        echo "FreeBind=true" >> /etc/systemd/system/ssh.socket.d/override.conf
        systemctl daemon-reload
        systemctl try-reload-or-restart ssh.socket || systemctl restart ssh.socket
    else
        systemctl restart ssh
    fi
    ufw delete allow "$OLD_PORT"/tcp 2>/dev/null || true
    echo -e "${GREEN}Старый порт закрыт${NC}"
fi

rm -rf "$KEY_DIR"
echo -e "\n${GREEN}Скрипт завершён. Сессия сохранена.${NC}"
trap - INT TERM
exit 0
