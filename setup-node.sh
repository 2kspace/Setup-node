#!/usr/bin/env bash
set -euo pipefail

MONITOR_IP="188.120.250.42"
EXPORTER_DIR="/opt/node-exporter"
EXPORTER_PORT="9100"
REMNA_DIR="/opt/remnanode"

green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }

blue "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
blue "➜ Полная подготовка ноды"
blue "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

read -rp "Страна (пример: 🇳🇱 Нидерланды): " COUNTRY
read -rp "Хостер (пример: VDSina): " HOSTER

if [[ -z "${COUNTRY// }" || -z "${HOSTER// }" ]]; then
  red "✖ Страна и хостер не должны быть пустыми"
  exit 1
fi

NODE_NAME="${COUNTRY} · ${HOSTER}"

yellow "1) Обновляю пакеты и ставлю базовые утилиты ..."
apt update
apt install -y curl ca-certificates fail2ban

green "✔ Базовые пакеты установлены"

yellow "2) Включаю BBR + fq ..."
modprobe tcp_bbr || true

grep -qxF 'net.core.default_qdisc=fq' /etc/sysctl.conf || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
grep -qxF 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf

sysctl -p >/dev/null

echo "tcp_congestion_control: $(sysctl -n net.ipv4.tcp_congestion_control || true)"
echo "default_qdisc:         $(sysctl -n net.core.default_qdisc || true)"
echo "available_cc:          $(sysctl -n net.ipv4.tcp_available_congestion_control || true)"
lsmod | grep bbr || true

green "✔ BBR + fq настроены"

yellow "3) Включаю fail2ban ..."
systemctl enable fail2ban
systemctl start fail2ban
systemctl status fail2ban --no-pager || true
green "✔ fail2ban включён"

yellow "4) Проверяю Docker ..."
if ! command -v docker >/dev/null 2>&1; then
  yellow "Docker не найден, устанавливаю ..."
  curl -fsSL https://get.docker.com | sh
fi

if ! command -v docker >/dev/null 2>&1; then
  red "✖ Docker не установился"
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  red "✖ docker compose не найден после установки Docker"
  exit 1
fi

green "✔ Docker и docker compose найдены"

yellow "5) Готовлю директорию Remnawave Node ..."
mkdir -p "$REMNA_DIR"
cd "$REMNA_DIR"

if [[ ! -f "$REMNA_DIR/docker-compose.yml" ]]; then
  echo
  blue "Сейчас нужен docker-compose.yml из панели Remnawave:"
  blue "Nodes -> Management -> + -> Copy docker-compose.yml"
  echo
  yellow "Вставь compose прямо в терминал ниже."
  yellow "Когда закончишь вставку, нажми Ctrl+D."
  echo
  cat > "$REMNA_DIR/docker-compose.yml"
else
  yellow "docker-compose.yml уже существует в $REMNA_DIR, пропускаю создание"
fi

if [[ ! -s "$REMNA_DIR/docker-compose.yml" ]]; then
  red "✖ Файл $REMNA_DIR/docker-compose.yml пустой или не создан"
  exit 1
fi

green "✔ docker-compose.yml для Remnawave Node готов"

yellow "6) Запускаю Remnawave Node ..."
cd "$REMNA_DIR"
docker compose up -d
green "✔ Remnawave Node запущена"

echo
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo

yellow "Если хочешь посмотреть логи Remnawave Node, выполни отдельно:"
echo "cd $REMNA_DIR && docker compose logs -f -t"
echo

yellow "7) Ставлю node_exporter ..."
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

cd "$EXPORTER_DIR"
docker compose up -d
green "✔ node_exporter запущен"

yellow "8) Проверяю firewall ..."
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

yellow "9) Проверяю node_exporter ..."
echo
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo

if curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/metrics" >/dev/null; then
  green "✔ Локально exporter отвечает"
  echo
  curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/metrics" | sed -n '1,20p' || true
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

yellow "10) Определяю IP адреса ..."
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
