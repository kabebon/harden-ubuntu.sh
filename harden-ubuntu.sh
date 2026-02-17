#!/bin/bash
# =============================================================================
#  harden-ubuntu.sh — безопасная начальная настройка Ubuntu-сервера с откатом
# =============================================================================

set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Начальная безопасная настройка сервера ===${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите от root${NC}"
    exit 1
fi

# Защита от запуска через пайп
if ! test -t 0; then
    echo -e "${RED}Не запускайте через curl | bash — ввод с клавиатуры не сработает${NC}"
    echo "Скачайте: curl ... -o harden.sh && chmod +x harden.sh && sudo ./harden.sh"
    exit 1
fi

# Переменные для отката
ROLLBACK_LOG="/root/harden-rollback-$(date +%Y%m%d-%H%M%S).log"
SSHD_BACKUP=""
USER_CREATED=false
SUDOERS_CREATED=false
UFW_WAS_ENABLED=false
KEY_DIR=""

echo "Лог отката будет сохранён в: $ROLLBACK_LOG" | tee -a "$ROLLBACK_LOG"

# ────────────────────────────────────────────────
# Функция отката / очистки
# ────────────────────────────────────────────────
rollback() {
    echo -e "\n${RED}ОБНАРУЖЕНО ПРЕРЫВАНИЕ или ОШИБКА — запускаем откат${NC}" | tee -a "$ROLLBACK_LOG"
    echo "Время: $(date)" | tee -a "$ROLLBACK_LOG"

    # 1. Удаление временных ключей
    if [ -n "$KEY_DIR" ] && [ -d "$KEY_DIR" ]; then
        rm -rf "$KEY_DIR" 2>/dev/null
        echo "→ Удалены временные ключи" | tee -a "$ROLLBACK_LOG"
    fi

    # 2. Откат sshd_config
    if [ -n "$SSHD_BACKUP" ] && [ -f "$SSHD_BACKUP" ]; then
        cp "$SSHD_BACKUP" /etc/ssh/sshd_config 2>/dev/null
        systemctl restart ssh || systemctl restart sshd 2>/dev/null
        echo "→ Восстановлен sshd_config из $SSHD_BACKUP" | tee -a "$ROLLBACK_LOG"
    fi

    # 3. Откат пользователя и sudoers (только если создавали в этом запуске)
    if $USER_CREATED && id "$NEW_USER" &>/dev/null; then
        deluser --remove-home "$NEW_USER" 2>/dev/null
        rm -f "/etc/sudoers.d/90-$NEW_USER" 2>/dev/null
        echo "→ Удалён пользователь $NEW_USER и sudoers-файл" | tee -a "$ROLLBACK_LOG"
    fi

    # 4. UFW — отключить, если включали
    if $UFW_WAS_ENABLED; then
        ufw --force disable 2>/dev/null
        echo "→ UFW отключён (был включён скриптом)" | tee -a "$ROLLBACK_LOG"
    fi

    echo -e "${YELLOW}Откат завершён (возможно, частично).${NC}" | tee -a "$ROLLBACK_LOG"
    echo "Проверьте систему вручную!" | tee -a "$ROLLBACK_LOG"
    exit 1
}

# Ловим Ctrl+C и ошибки
trap rollback INT ERR

# ────────────────────────────────────────────────
# Запрос данных
# ────────────────────────────────────────────────

read -r -p "Имя пользователя [admin]: " NEW_USER
NEW_USER=${NEW_USER:-admin}

if [[ ! "$NEW_USER" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
    echo -e "${RED}Недопустимое имя${NC}"
    exit 1
fi

if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}$NEW_USER уже существует — ключ будет перезаписан${NC}"
else
    USER_CREATED=true
fi

read -r -p "Новый порт SSH [2222]: " NEW_PORT
NEW_PORT=${NEW_PORT:-2222}

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || (( NEW_PORT < 1024 || NEW_PORT > 65535 )); then
    echo -e "${RED}Неверный порт${NC}"
    exit 1
fi

# ────────────────────────────────────────────────
# Генерация ключей
# ────────────────────────────────────────────────

KEY_DIR="/root/temp-ssh-key-$(date +%s)"
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"

ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -C "$NEW_USER@$(hostname)" >/dev/null 2>&1

PUB_KEY=$(cat "$KEY_DIR/id_ed25519.pub")
PRIV_KEY=$(cat "$KEY_DIR/id_ed25519")

echo -e "\n${YELLOW}┌─────────────────────────────── ПРИВАТНЫЙ КЛЮЧ ───────────────────────────────┐${NC}"
echo "$PRIV_KEY"
echo -e "${YELLOW}└───────────────────────────────────────────────────────────────────────────────┘${NC}"

read -r -p "Скопировали приватный ключ? Напишите yes для продолжения: " confirm
[[ "$confirm" == "yes" ]] || { echo "Не подтверждено → выход"; rollback; }

# ────────────────────────────────────────────────
# Опасная часть — здесь начинается откат при ошибке
# ────────────────────────────────────────────────

# Бэкап sshd_config
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP" 2>/dev/null

# Пользователь
if $USER_CREATED; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$NEW_USER"
    chmod 0440 "/etc/sudoers.d/90-$NEW_USER"
fi

mkdir -p "/home/$NEW_USER/.ssh"
echo "$PUB_KEY" > "/home/$NEW_USER/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh"
chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

# sshd_config
sed -i "s/^#*Port.*/Port $NEW_PORT/" /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# UFW
if ufw status | grep -q "Status: inactive"; then
    UFW_WAS_ENABLED=true
fi
ufw allow "$NEW_PORT"/tcp 2>/dev/null
ufw allow 80/tcp 2>/dev/null
ufw allow 443/tcp 2>/dev/null
ufw --force enable 2>/dev/null

# Перезапуск SSH
SSH_SVC=$(systemctl is-active ssh >/dev/null && echo ssh || echo sshd)
systemctl restart "$SSH_SVC"

echo -e "\n${GREEN}Настройка завершена${NC}"
echo "Подключение: ssh -p $NEW_PORT $NEW_USER@$(curl -s ifconfig.me)"

# Уборка
rm -rf "$KEY_DIR"

echo -e "${YELLOW}Не закрывайте сессию, пока не проверите новый вход!${NC}"
