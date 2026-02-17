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
    echo -e "${RED}Запустите от root (sudo)${NC}"
    exit 1
fi

if ! test -t 0; then
    echo -e "${RED}Этот скрипт требует интерактивного ввода.${NC}"
    echo "Рекомендуемый способ: curl ... -o harden.sh && chmod +x harden.sh && sudo ./harden.sh"
    exit 1
fi

ROLLBACK_LOG="/root/harden-rollback-$(date +%Y%m%d-%H%M%S).log"
SSHD_BACKUP=""
USER_CREATED=false
SUDOERS_FILE=""
UFW_WAS_ENABLED=false
KEY_DIR=""

echo "Лог отката будет сохранён в: $ROLLBACK_LOG" | tee -a "$ROLLBACK_LOG"

rollback() {
    echo -e "\n${RED}Прерывание или ошибка → откат${NC}" | tee -a "$ROLLBACK_LOG"
    [ -n "$KEY_DIR" ] && [ -d "$KEY_DIR" ] && rm -rf "$KEY_DIR"
    [ -n "$SSHD_BACKUP" ] && [ -f "$SSHD_BACKUP" ] && cp "$SSHD_BACKUP" /etc/ssh/sshd_config && systemctl restart ssh || systemctl restart sshd
    if $USER_CREATED && id "$NEW_USER" &>/dev/null; then
        deluser --remove-home "$NEW_USER" 2>/dev/null
        [ -n "$SUDOERS_FILE" ] && rm -f "$SUDOERS_FILE"
    fi
    if $UFW_WAS_ENABLED; then
        ufw --force disable 2>/dev/null
    fi
    echo -e "${YELLOW}Откат завершён (частично). Проверьте систему!${NC}"
    exit 1
}

trap rollback INT ERR

echo -e "\n${YELLOW}Введите имя нового пользователя (только a-z, 0-9, _, -)${NC}"
read -r -p "Имя пользователя: " NEW_USER
NEW_USER=${NEW_USER:-admin}

if [[ ! "$NEW_USER" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
    echo -e "${RED}Недопустимое имя${NC}"
    exit 1
fi

if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}Пользователь $NEW_USER уже существует — ключ будет перезаписан${NC}"
    read -r -p "Продолжить? [y/N]: " cont
    [[ "$cont" =~ ^[Yy]$ ]] || exit 0
else
    USER_CREATED=true
fi

echo -e "\n${YELLOW}Новый порт SSH (рекомендуется >1024, не 22)${NC}"
read -r -p "Новый порт SSH: " NEW_PORT
NEW_PORT=${NEW_PORT:-2222}

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1024 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo -e "${RED}Неверный порт${NC}"
    exit 1
fi

echo -e "\n${GREEN}Генерируем пару ed25519 ключей...${NC}\n"

KEY_DIR="/root/temp-ssh-key-$(date +%s)"
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"

ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -C "$NEW_USER@$(hostname)-$(date +%Y%m%d)" >/dev/null 2>&1

PUB_KEY=$(cat "$KEY_DIR/id_ed25519.pub")
PRIV_KEY=$(cat "$KEY_DIR/id_ed25519")

echo -e "${YELLOW}┌───────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│                     ВАЖНО! СДЕЛАЙТЕ ЭТО СЕЙЧАС                 │${NC}"
echo -e "${YELLOW}│  Скопируйте приватный ключ ниже — он исчезнет после выполнения!  │${NC}"
echo -e "${YELLOW}└───────────────────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "${YELLOW}Приватный ключ (скопируйте ВЕСЬ текст ниже):${NC}"
echo ""
echo "$PRIV_KEY"
echo ""

echo -e "${GREEN}Публичный ключ (будет добавлен):${NC}"
echo "$PUB_KEY"
echo ""

echo -e "${RED}Скопировали приватный ключ в безопасное место?${NC}"
read -r -p "Напишите yes и нажмите Enter для продолжения: " confirm

if [[ "$confirm" != "yes" ]]; then
    echo -e "${RED}Копирование не подтверждено. Выход без изменений.${NC}"
    rm -rf "$KEY_DIR"
    exit 1
fi

echo -e "${GREEN}Подтверждение получено. Продолжаем...${NC}\n"

# Дальше идёт остальная часть скрипта (SSHD_BACKUP, создание пользователя, sed, UFW, BBR, fail2ban и т.д.)
# Вставь сюда свой код из предыдущей версии, начиная с:

SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP" 2>/dev/null

# ... и всё остальное до конца
