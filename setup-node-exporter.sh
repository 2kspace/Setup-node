#!/usr/bin/env bash
set -euo pipefail

MONITOR_IP="188.120.250.42"
EXPORTER_DIR="/opt/node-exporter"
EXPORTER_PORT="9100"

green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }

blue "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
blue "➜ Установка node_exporter"
blue "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

read -rp "Страна с эмодзи (пример: 🇳🇱 Нидерланды): " COUNTRY
read -rp "Хостер (пример: VDSina): " HOSTER

if [[ -z "${COUNTRY// }" || -z "${HOSTER// }" ]]; then
  red "✖ Страна и хостер не должны быть пустыми"
  exit 1
fi

NODE_NAME="${COUNTRY} · ${HOSTER}"

yellow "1) Проверяю наличие Docker ..."
if ! command -v docker >/dev/null 2>&1; then
  red "✖ Docker не найден. Сначала установи Docker."
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  red "✖ docker compose не найден. Проверь установку Docker Compose."
  exit 1
fi

green "✔ Docker и docker compose найдены"

yellow "2) Создаю compose для node_exporter ..."
mkdir -p "$EXPORTER_DIR"

cat > "$EXPORTER_DIR/docker-compose.yml" <<'COMPOSE'
services:
  node-exporter:
    image: prom/node-exporter:v1.10.2
    container_name: node-exporter
    restart: unless-stopped
    network_mode: host
    pid: host
    volumes:
      - /:/host:ro,rslave
    command:
      - '--path.rootfs=/host'
      - '--web.listen-address=:9100'
COMPOSE

green "✔ Файл $EXPORTER_DIR/docker-compose.yml создан"

yellow "3) Запускаю node_exporter ..."
cd "$EXPORTER_DIR"
docker compose up -d
green "✔ node_exporter запущен"

yellow "4) Проверяю firewall ..."
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q "Status: active"; then
    yellow "ufw активен, открываю ${EXPORTER_PORT} только для ${MONITOR_IP}"
    ufw allow from "$MONITOR_IP" to any port "$EXPORTER_PORT" proto tcp
    ufw reload
    ufw status numbered
    green "✔ Правило ufw применено"
  else
    yellow "⚠ ufw установлен, но не включен. Firewall не трогаю."
  fi
else
  yellow "⚠ ufw не установлен, firewall не трогаю"
fi

yellow "5) Проверяю node_exporter ..."
echo
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo

if curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/metrics" | head -n 20; then
  green "✔ Локально exporter отвечает"
else
  red "✖ Локально exporter не отвечает"
  exit 1
fi

echo
if ss -tulpn | grep -q ":${EXPORTER_PORT}"; then
  ss -tulpn | grep ":${EXPORTER_PORT}"
  green "✔ Порт ${EXPORTER_PORT} слушается"
else
  red "✖ Порт ${EXPORTER_PORT} не слушается"
  exit 1
fi
echo

yellow "6) Определяю IP адреса ..."
LOCAL_IPS="$(hostname -I | xargs || true)"
PUBLIC_IP="$(curl -4 -s --max-time 10 ifconfig.me || true)"

echo "Локальные IP: ${LOCAL_IPS:-не удалось определить}"
echo "Публичный IP: ${PUBLIC_IP:-не удалось определить}"
echo "Имя ноды: ${NODE_NAME}"

if [[ -n "${PUBLIC_IP:-}" ]]; then
  echo
  blue "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  blue "➜ Дальше выполни НА СЕРВЕРЕ МОНИТОРИНГА:"
  blue "cd /opt/monitoring && ./register-node.sh ${PUBLIC_IP} \"${NODE_NAME}\""
  blue "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  yellow "⚠ Не удалось определить публичный IP. Узнай его вручную и вызови register-node.sh на сервере мониторинга."
fi
