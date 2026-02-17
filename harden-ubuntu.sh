#!/bin/bash
# =============================================================================
#  harden-ubuntu.sh — безопасная начальная настройка Ubuntu-сервера
# =============================================================================

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Начальная безопасная настройка сервера ===${NC}"
echo "Скрипт должен запускаться от root"

# ────────────────────────────────────────────────
# 0. Проверка прав root
# ────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите скрипт от root (sudo)${NC}"
    exit 1
fi

# ────────────────────────────────────────────────
# 1. Запрос нового порта SSH
# ────────────────────────────────────────────────
echo -e "\n${YELLOW}Введите новый порт SSH (рекомендуется 2000–65535, кроме 22)${NC}"
read -r -p "Новый порт [2222]: " NEW_PORT
NEW_PORT=${NEW_PORT:-2222}

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1024 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo -e "${RED}Некорректный порт. Должен быть числом от 1024 до 65535.${NC}"
    exit 1
fi

if [ "$NEW_PORT" = "22" ]; then
    echo -e "${YELLOW}Вы оставляете порт 22 — это не рекомендуется по соображениям безопасности.${NC}"
    read -r -p "Продолжить с портом 22? (y/N): " confirm22
    [[ "$confirm22" =~ ^[Yy]$ ]] || exit 1
fi

# ────────────────────────────────────────────────
# 2. Генерация новой пары ключей
# ────────────────────────────────────────────────
echo -e "\n${GREEN}Генерируем новую пару ed25519 ключей...${NC}"

KEY_DIR="/root/temp-ssh-key-$(date +%s)"
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -C "temp-admin@$(hostname)" > /dev/null 2>&1

PUB_KEY=$(cat "$KEY_DIR/id_ed25519.pub")
PRIV_KEY=$(cat "$KEY_DIR/id_ed25519")

echo -e "\n${YELLOW}┌────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│                    ВАЖНО! СДЕЛАЙТЕ ЭТО СЕЙЧАС                 │${NC}"
echo -e "${YELLOW}│                                                            │${NC}"
echo -e "${YELLOW}│  Это ваш приватный ключ — он больше НИГДЕ не сохранится!      │${NC}"
echo -e "${YELLOW}│  Скопируйте его прямо сейчас и сохраните в безопасном месте.  │${NC}"
echo -e "${YELLOW}└────────────────────────────────────────────────────────────┘${NC}"

echo -e "\n${GREEN}Приватный ключ (скопируйте весь текст ниже):${NC}\n"
echo "-----BEGIN OPENSSH PRIVATE KEY-----"
echo "$PRIV_KEY" | sed '1d;$d'   # убираем первую и последнюю строку с метками
echo "-----END OPENSSH PRIVATE KEY-----"

echo -e "\n${GREEN}Публичный ключ (будет добавлен на сервер):${NC}"
echo "$PUB_KEY"

# ────────────────────────────────────────────────
# 3. Подтверждение копирования приватного ключа
# ────────────────────────────────────────────────
echo -e "\n${RED}ВЫ СКОПИРОВАЛИ ПРИВАТНЫЙ КЛЮЧ В БЕЗОПАСНОЕ МЕСТО?${NC}"
read -r -p "Напишите 'yes' и нажмите Enter, чтобы продолжить: " confirmation

if [[ "$confirmation" != "yes" ]]; then
    echo -e "${RED}Копирование не подтверждено. Выход.${NC}"
    rm -rf "$KEY_DIR"
    exit 1
fi

echo -e "${GREEN}Подтверждение получено. Продолжаем...${NC}"

# ────────────────────────────────────────────────
# 4. Создание пользователя и добавление ключа
# ────────────────────────────────────────────────
NEW_USER="admin"

if id "$NEW_USER" &>/dev/null; then
    echo "Пользователь $NEW_USER уже существует → пропускаем создание"
else
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

# ────────────────────────────────────────────────
# 5. Настройка sshd_config
# ────────────────────────────────────────────────
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak-$(date +%Y%m%d-%H%M%S)"

sed -i "s/^#*Port.*/Port $NEW_PORT/" /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# ────────────────────────────────────────────────
# 6. UFW — разрешаем новый порт
# ────────────────────────────────────────────────
ufw allow "$NEW_PORT"/tcp || true
ufw allow 80/tcp   || true
ufw allow 443/tcp  || true
ufw --force enable || true

# ────────────────────────────────────────────────
# 7. Перезапуск SSH
# ────────────────────────────────────────────────
SSH_SERVICE="ssh"
systemctl is-active --quiet ssh || SSH_SERVICE="sshd"

echo -e "\n${YELLOW}Перезапускаем SSH-сервис...${NC}"
systemctl restart "$SSH_SERVICE"

sleep 2
if systemctl is-active --quiet "$SSH_SERVICE"; then
    echo -e "${GREEN}SSH перезапущен успешно${NC}"
else
    echo -e "${RED}Проблема с перезапуском SSH!${NC}"
    echo "Вероятно, новый порт уже занят или синтаксис в sshd_config."
    echo "Оставайтесь в текущей сессии! Попробуйте откатить:"
    echo "  cp /etc/ssh/sshd_config.bak-* /etc/ssh/sshd_config && systemctl restart $SSH_SERVICE"
    exit 1
fi

# ────────────────────────────────────────────────
# 8. Финальное сообщение
# ────────────────────────────────────────────────
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}               Настройка завершена!${NC}"
echo ""
echo -e "Новый пользователь:     ${YELLOW}$NEW_USER${NC}"
echo -e "Новый порт SSH:         ${YELLOW}$NEW_PORT${NC}"
echo -e "Вход только по ключу:   ${GREEN}да${NC}"
echo ""
echo -e "Команда для подключения:"
echo -e "  ${YELLOW}ssh -p $NEW_PORT $NEW_USER@$(curl -s ifconfig.me || echo "ваш_IP")${NC}"
echo ""
echo -e "${YELLOW}ОБЯЗАТЕЛЬНО проверьте подключение в НОВОМ терминале${NC}"
echo -e "перед закрытием этой сессии!"
echo -e "${GREEN}============================================================${NC}"

# Удаляем временные ключи (приватный уже должен быть скопирован пользователем)
rm -rf "$KEY_DIR"

echo -e "\nУдачи и безопасной работы!${NC}"
