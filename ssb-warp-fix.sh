#!/usr/bin/env bash
#
# ssb-warp-fix.sh — Cloudflare WARP (warp-cli) repair + verification for SSB nodes
#
# ЧТО ЛЕЧИТ
#   1) Симптом: warp-cli рапортует "Connected", туннель поднят, но SOCKS5-прокси
#      127.0.0.1:40000 отдаёт "socks5: request rejected, code=4" почти на всё,
#      кроме домёнов Cloudflare. В итоге всё, что в sing-box привязано к outbound
#      "warp" (.ru/.su, openai/anthropic/xai, tiktok, habr/rutracker), недоступно.
#      Причина: регистрация устройства на стороне Cloudflare «разъехалась» —
#      handshake живой, но выход обслуживает только периферию Cloudflare.
#      Лечение: новая регистрация (registration delete + new).
#
#   2) Симптом: WARP вроде работает, но часть запросов падает (у нас на одном
#      аплинке h3 давал 7/15 и 5/15). Причина: MASQUE over HTTP/3 (QUIC) нестабилен.
#      Лечение: принудительно h2-only — MASQUE over HTTP/2 (TCP/443): 45/45.
#
#   Резерв, если WARP починить не удалось: --ru-direct — правило «.ru/.su -> direct»
#   в /etc/sing-box/config.json (бэкап, sing-box check, авто-откат).
#
# ИСПОЛЬЗОВАНИЕ
#   ssb-warp-fix.sh                  # диагностика + ремонт (лестница) + проверка .ru
#   ssb-warp-fix.sh --check          # только чтение: диагностика и проверка
#   ssb-warp-fix.sh --no-reregister  # ремонт без смены WARP-регистрации
#   ssb-warp-fix.sh --port 40000     # другой порт SOCKS-прокси WARP
#   ssb-warp-fix.sh --json           # короткий JSON-итог в stdout
#   ssb-warp-fix.sh --ru-direct      # резерв: .ru/.su через direct в sing-box
#   ssb-warp-fix.sh --ru-restore     # откатить --ru-direct
#   ssb-warp-fix.sh --h2             # принудительно MASQUE over HTTP/2 (флапы h3)
#   ssb-warp-fix.sh --no-e2e         # не проверять через цепочку sing-box
#
# ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ
#   WARP_PORT=40000  TIMEOUT=10  RU_THRESHOLD=80  STAB_TRIES=5  STAB_THRESHOLD=90
#   LOG_FILE=/var/log/ssb-warp-fix.log
#
# КОДЫ ВОЗВРАТА
#   0 — WARP здоров, .ru проходят порог, стабильность в норме
#   1 — WARP отвечает, но .ru/стабильность ниже порога
#   2 — фатально: нет root / нет warp-cli / сервис не поднимается
#
# ОДНОЙ КОМАНДОЙ (свежий сервер):
#   curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-warp-fix/main/ssb-warp-fix.sh | bash
#
set -uo pipefail

VERSION="1.2.1"
CONFIG_DEFAULT="/etc/sing-box/config.json"
BOXLOG_DEFAULT="/var/lib/sing-box/box.log"
BACKUP_DIR="/root"
BACKUP_PREFIX="sb-config-backup-ssbwarpfix"

PROXY_HOST="127.0.0.1"
WARP_PORT="${WARP_PORT:-40000}"
TIMEOUT="${TIMEOUT:-10}"
RU_THRESHOLD="${RU_THRESHOLD:-80}"
STAB_TRIES="${STAB_TRIES:-5}"
STAB_THRESHOLD="${STAB_THRESHOLD:-90}"
LOG_FILE="${LOG_FILE:-/var/log/ssb-warp-fix.log}"

MODE="fix"            # fix | check
DO_REREGISTER="auto"  # auto | never
DO_E2E="auto"         # auto | never
JSON_OUT=0
ACTION=""             # "" | ru-direct | ru-restore
BOX_CONFIG="$CONFIG_DEFAULT"

RU_HOSTS=(cheburcheck.ru yandex.ru ya.ru mail.ru ozon.ru wildberries.ru rbc.ru www.gosuslugi.ru avito.ru sber.ru)
CTRL_HOSTS=(api.ipify.org www.cloudflare.com www.google.com github.com)
STAB_HOSTS=(mail.ru yandex.ru cheburcheck.ru)

C_OK=0; C_BAD=0; C_WARN=0
RU_OK=0; RU_TOTAL=0
NONRU_OK=0; NONRU_TOTAL=0
STAB_OK=0; STAB_TOTAL=0
E2E_OK=0; E2E_TOTAL=0
WARP_IP=""
VERDICT="unknown"

# ---------------------------------------------------------------- util --------
ts() { date '+%Y-%m-%d %H:%M:%S'; }

say()  { printf '%s\n' "$*"; printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG_FILE" 2>/dev/null; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; printf '\n== %s ==\n' "$*" >>"$LOG_FILE" 2>/dev/null; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; C_OK=$((C_OK+1)); printf '[%s] OK   %s\n' "$(ts)" "$*" >>"$LOG_FILE" 2>/dev/null; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; C_BAD=$((C_BAD+1)); printf '[%s] FAIL %s\n' "$(ts)" "$*" >>"$LOG_FILE" 2>/dev/null; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; C_WARN=$((C_WARN+1)); printf '[%s] WARN %s\n' "$(ts)" "$*" >>"$LOG_FILE" 2>/dev/null; }
info() { printf '       %s\n' "$*"; printf '[%s]      %s\n' "$(ts)" "$*" >>"$LOG_FILE" 2>/dev/null; }

die() { printf '\033[31mОШИБКА:\033[0m %s\n' "$*" >&2; exit 2; }

warp() { warp-cli --accept-tos "$@"; }

usage() {
  cat <<'USAGE'
ssb-warp-fix — ремонт и проверка Cloudflare WARP (warp-cli) на Linux-ноде

ИСПОЛЬЗОВАНИЕ
  ssb-warp-fix                  диагностика + ремонт (лестница) + проверка .ru
  ssb-warp-fix --check          только чтение: диагностика и проверка
  ssb-warp-fix --no-reregister  ремонт без смены WARP-регистрации
  ssb-warp-fix --port 40000     другой порт SOCKS-прокси WARP
  ssb-warp-fix --json           короткий JSON-итог в stdout
  ssb-warp-fix --ru-direct      резерв: .ru/.su через direct в sing-box
  ssb-warp-fix --ru-restore     откатить --ru-direct
  ssb-warp-fix --h2             принудительно MASQUE over HTTP/2 (с автооткатом)
  ssb-warp-fix --no-e2e         не проверять через цепочку sing-box
  ssb-warp-fix --config PATH    другой путь к конфигу sing-box

КОДЫ ВОЗВРАТА
  0 WARP здоров и .ru проходят порог | 1 .ru/стабильность ниже порога | 2 фатально

ОДНОЙ КОМАНДОЙ (свежий сервер)
  curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-warp-fix/main/ssb-warp-fix.sh | bash
USAGE
  exit 0
}

# --------------------------------------------------------------- args --------
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--dry-run) MODE="check" ;;
    --fix)             MODE="fix" ;;
    --no-reregister)   DO_REREGISTER="never" ;;
    --reregister)      DO_REREGISTER="auto" ;;
    --no-e2e)          DO_E2E="never" ;;
    --e2e)             DO_E2E="auto" ;;
    --port)            shift; WARP_PORT="${1:?--port требует значение}" ;;
    --config)          shift; BOX_CONFIG="${1:?--config требует путь}" ;;
    --json)            JSON_OUT=1 ;;
    --ru-direct)       ACTION="ru-direct" ;;
    --ru-restore)      ACTION="ru-restore" ;;
    --h2)              ACTION="h2" ;;
    -h|--help)         usage ;;
    -V|--version)      echo "ssb-warp-fix $VERSION"; exit 0 ;;
    *)                 die "неизвестный аргумент: $1 (--help)" ;;
  esac
  shift
done

PROXY="${PROXY_HOST}:${WARP_PORT}"

# --------------------------------------------------------------- probes ------
# http_code <url> [socks|socksh] -> HTTP-код или 000
http_code() {
  local url="$1" scheme="${2:-socks5h}" out
  out=$(curl -x "${scheme}://${PROXY}" -s -m "$TIMEOUT" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
  [ -n "$out" ] || out="000"
  printf '%s' "$out"
}

# reachable = любой HTTP-код 1xx-5xx (403/307/302 — тоже «дошли»)
is_reachable() { case "$1" in [1-5][0-9][0-9]) return 0 ;; *) return 1 ;; esac; }

pct() { [ "${2:-0}" -gt 0 ] && echo $(( $1 * 100 / $2 )) || echo 0; }

probe_ctrl() {
  local host code pass=0
  NONRU_TOTAL=0; NONRU_OK=0
  for host in "${CTRL_HOSTS[@]}"; do
    code=$(http_code "https://$host")
    NONRU_TOTAL=$((NONRU_TOTAL+1))
    if is_reachable "$code"; then
      pass=$((pass+1)); NONRU_OK=$((NONRU_OK+1)); ok "$host -> $code"
    else
      bad "$host -> нет ответа через WARP"
    fi
  done
  [ "$pass" -ge 3 ]
}

probe_ru() {
  local host code pass=0
  RU_TOTAL=0; RU_OK=0
  for host in "${RU_HOSTS[@]}"; do
    code=$(http_code "https://$host")
    RU_TOTAL=$((RU_TOTAL+1))
    if is_reachable "$code"; then
      pass=$((pass+1)); RU_OK=$((RU_OK+1)); ok "$host -> $code"
    else
      bad "$host -> нет ответа через WARP"
    fi
  done
  [ "$RU_TOTAL" -gt 0 ] && [ "$(pct "$pass" "$RU_TOTAL")" -ge "$RU_THRESHOLD" ]
}

# series: несколько попыток на домен — ловит «флап» (h3 нестабилен на части аплинков)
probe_stability() {
  local host code pass=0 total=0 i host_ok
  STAB_OK=0; STAB_TOTAL=0
  for host in "${STAB_HOSTS[@]}"; do
    host_ok=0
    for i in $(seq "$STAB_TRIES"); do
      total=$((total+1))
      code=$(http_code "https://$host")
      if is_reachable "$code"; then pass=$((pass+1)); host_ok=$((host_ok+1)); fi
    done
    printf '  %-18s %d/%d\n' "$host" "$host_ok" "$STAB_TRIES"
  done
  STAB_OK=$pass; STAB_TOTAL=$total
  local p; p=$(pct "$pass" "$total")
  if [ "$p" -ge "$STAB_THRESHOLD" ]; then
    ok "стабильность: $pass/$total (${p}%, порог ${STAB_THRESHOLD}%)"
    return 0
  fi
  bad "стабильность: $pass/$total (${p}%, порог ${STAB_THRESHOLD}%)"
  return 1
}

probe_all() { probe_ctrl; probe_ru; probe_stability; }

healthy() {
  [ "$NONRU_OK" -ge 3 ] \
    && [ "$(pct "$RU_OK" "$RU_TOTAL")" -ge "$RU_THRESHOLD" ] \
    && [ "$(pct "$STAB_OK" "$STAB_TOTAL")" -ge "$STAB_THRESHOLD" ]
}

# ------------------------------------------------------------- warp state ----
warp_mode()     { warp settings 2>/dev/null | awk -F'\t' '/Mode:/ {print $2}' | head -1; }
warp_protocol() { warp settings 2>/dev/null | awk -F': ' '/WARP tunnel protocol/ {print $2}' | head -1; }
warp_http()     { warp settings 2>/dev/null | awk -F': ' '/HTTP Version/ {print $2}' | head -1; }
warp_port_cfg() { warp settings 2>/dev/null | sed -n 's/.*WarpProxy on port \([0-9]*\).*/\1/p' | head -1; }

# текущая MASQUE-опция в виде значения для "tunnel masque-options set"
warp_masque_opt() {
  local v
  v=$(warp_http || true)
  case "$v" in
    *"HTTP/3 with HTTP/2 fallback"*) echo "h3-with-h2-fallback" ;;
    *"HTTP/2"*)                      echo "h2-only" ;;
    *"HTTP/3"*)                      echo "h3-only" ;;
    *)                               echo "reset" ;;
  esac
}

# быстрая проверка «WARP выпускает»: минимум 2 из 3 доменов
quick_ok() {
  local d c ok=0
  for d in mail.ru yandex.ru cheburcheck.ru; do
    c=$(http_code "https://$d")
    is_reachable "$c" && ok=$((ok+1))
  done
  [ "$ok" -ge 2 ]
}

warp_connected() { warp status 2>/dev/null | grep -qi '^Status update: Connected'; }

wait_connected() {
  local limit="${1:-40}" i=0
  while [ "$i" -lt "$limit" ]; do
    warp_connected && return 0
    sleep 2; i=$((i+2))
  done
  return 1
}

proxy_listening() { ss -lnt 2>/dev/null | grep -q "${PROXY}"; }

warp_ip() {
  local ip
  ip=$(curl -x "socks5h://${PROXY}" -s -m "$TIMEOUT" https://api.ipify.org 2>/dev/null | tr -d '\n')
  case "$ip" in
    *[!0-9.]*|"") echo "" ;;
    *) echo "$ip" ;;
  esac
}

reconnect() {
  local limit="${1:-40}"
  warp disconnect >/dev/null 2>&1
  sleep 2
  warp connect >/dev/null 2>&1
  wait_connected "$limit"
}

# ---------------------------------------------------------------- sing-box ---
box_log_path() {
  local p
  p=$(jq -r '.log.output // empty' "$BOX_CONFIG" 2>/dev/null)
  if [ -n "$p" ] && [ "$p" != "stdout" ]; then
    case "$p" in
      /*) echo "$p" ;;
      *)  echo "/var/lib/sing-box/$p" ;;
    esac
  else
    echo "$BOXLOG_DEFAULT"
  fi
}

box_log_lines() { [ -f "$1" ] && wc -l <"$1" || echo 0; }

# E2E: временный клиент sing-box ходит в родной trojan-inbound этой же ноды,
# проверяем .ru сквозь реальную цепочку (клиент -> нода -> WARP) и лог.
e2e_test() {
  local bin cfg_tmp log_tmp port user pass wpath mux ok_cnt=0 total=0
  local logf log_before log_after code host pid
  bin=$(command -v sing-box 2>/dev/null) || { warn "sing-box не найден — E2E пропущен"; return 1; }
  [ -r "$BOX_CONFIG" ] || { warn "нет $BOX_CONFIG — E2E пропущен"; return 1; }

  user=$(jq -r 'first(.inbounds[]? | select(.type=="trojan") | .users[0].name) // empty' "$BOX_CONFIG")
  pass=$(jq -r 'first(.inbounds[]? | select(.type=="trojan") | .users[0].password) // empty' "$BOX_CONFIG")
  wpath=$(jq -r 'first(.inbounds[]? | select(.type=="trojan") | .transport.path) // empty' "$BOX_CONFIG")
  mux=$(jq -c 'first(.inbounds[]? | select(.type=="trojan") | .multiplex) // empty' "$BOX_CONFIG")
  [ -n "$user" ] && [ -n "$pass" ] || { warn "в конфиге нет trojan-пользователей — E2E пропущен"; return 1; }

  port=$(( (RANDOM % 4000) + 21000 ))
  while ss -lnt 2>/dev/null | grep -q ":${port} "; do port=$((port+1)); done

  cfg_tmp=$(mktemp /tmp/ssb-warp-fix-e2e.XXXXXX.json)
  log_tmp=$(mktemp /tmp/ssb-warp-fix-e2e.XXXXXX.log)

  if [ -n "$wpath" ]; then
    jq -n --argjson p "$port" --arg pass "$pass" --arg path "$wpath" --argjson mux "${mux:-null}" '
      {
        log: {level: "warn", output: "/dev/stderr"},
        inbounds: [{type: "socks", tag: "in", listen: "127.0.0.1", listen_port: $p}],
        outbounds: [({
          type: "trojan", tag: "out", server: "127.0.0.1", server_port: 10443,
          password: $pass, transport: {type: "ws", path: $path}
        } + (if $mux != null then {multiplex: $mux} else {} end))]
      }' >"$cfg_tmp"
  else
    jq -n --argjson p "$port" --arg pass "$pass" --argjson mux "${mux:-null}" '
      {
        log: {level: "warn", output: "/dev/stderr"},
        inbounds: [{type: "socks", tag: "in", listen: "127.0.0.1", listen_port: $p}],
        outbounds: [({
          type: "trojan", tag: "out", server: "127.0.0.1", server_port: 10443, password: $pass
        } + (if $mux != null then {multiplex: $mux} else {} end))]
      }' >"$cfg_tmp"
  fi

  "$bin" run -c "$cfg_tmp" >"$log_tmp" 2>&1 &
  pid=$!
  E2E_PID=$pid; E2E_TMP="$cfg_tmp $log_tmp"

  sleep 3
  if ! kill -0 "$pid" 2>/dev/null; then
    warn "временный клиент не стартовал: $(tail -2 "$log_tmp" | tr '\n' ' ')"
    return 1
  fi

  logf=$(box_log_path)
  log_before=$(box_log_lines "$logf")

  for host in cheburcheck.ru yandex.ru ozon.ru wildberries.ru rbc.ru; do
    total=$((total+1))
    code=$(curl -x "socks5h://127.0.0.1:${port}" -s -m "$TIMEOUT" -o /dev/null -w '%{http_code}' "https://$host" 2>/dev/null)
    [ -n "$code" ] || code="000"
    if is_reachable "$code"; then ok_cnt=$((ok_cnt+1)); ok "  e2e $host -> $code"; else bad "  e2e $host -> нет ответа"; fi
  done

  E2E_OK=$ok_cnt; E2E_TOTAL=$total

  log_after=$(box_log_lines "$logf")
  if [ -f "$logf" ] && [ "$log_after" -gt "$log_before" ]; then
    local tail_log used errors
    tail_log=$(tail -n "$((log_after - log_before))" "$logf")
    used=$(printf '%s\n' "$tail_log" | grep -c 'outbound/socks\[warp\]')
    errors=$(printf '%s\n' "$tail_log" | grep -c 'using outbound/socks\[warp\].*code=4')
    [ "$used" -gt 0 ] && info "в логе ноды: $used соединений реально ушли в outbound warp" \
                      || warn "в логе ноды нет строк outbound/socks[warp] — правило могло не сработать"
    if [ "$errors" -eq 0 ]; then
      ok "отказов WARP (code=4) за время теста нет"
    elif [ "$used" -gt 0 ] && [ "$errors" -lt "$used" ]; then
      warn "в логе $errors отказов code=4 при $used успешных (часть — чужой трафик/единичный сбой)"
    else
      bad "в логе $errors отказов code=4 — WARP отказывает"
    fi
  fi

  [ "$total" -gt 0 ] && [ "$(pct "$ok_cnt" "$total")" -ge "$RU_THRESHOLD" ]
}

e2e_cleanup() {
  if [ -n "${E2E_PID:-}" ] && kill -0 "$E2E_PID" 2>/dev/null; then
    kill "$E2E_PID" 2>/dev/null; sleep 1; kill -9 "$E2E_PID" 2>/dev/null
  fi
  [ -n "${E2E_TMP:-}" ] && rm -f $E2E_TMP
}
trap 'e2e_cleanup' EXIT

# ---------------------------------------------------------------- fix steps --
step_config() {
  local mode port changed=0
  mode=$(warp_mode || true)
  port=$(warp_port_cfg || true)
  if ! printf '%s' "$mode" | grep -qi 'warpProxy on port'; then
    warp mode proxy >/dev/null 2>&1 && { ok "режим -> proxy"; changed=1; }
  fi
  if [ "$port" != "$WARP_PORT" ]; then
    warp proxy port "$WARP_PORT" >/dev/null 2>&1 && { ok "порт прокси -> $WARP_PORT"; changed=1; }
  fi
  if [ "$changed" -eq 0 ]; then info "настройки уже эталонные"; return 2; fi
  reconnect && { ok "WARP переподключён с новыми настройками"; return 0; }
  bad "не поднялся после смены настроек"; return 1
}

step_reconnect() {
  reconnect && ok "WARP переподключён" || { bad "не поднялся за 40 c"; return 1; }
  sleep 2
  proxy_listening && ok "прокси слушает ${PROXY}" || { bad "прокси не слушает ${PROXY}"; return 1; }
}

step_masque_reset() {
  warp tunnel masque-options reset >/dev/null 2>&1 || true
  warp tunnel protocol reset >/dev/null 2>&1 || true
  reconnect || { bad "не поднялся"; return 1; }
}

step_h2() {
  local prev
  prev=$(warp_masque_opt)
  if [ "$prev" = "h2-only" ]; then info "уже включён h2-only"; return 2; fi
  info "MASQUE h3 (QUIC) на части аплинков флапает — пробуем HTTP/2 (TCP/443)"
  warp tunnel masque-options set h2-only >/dev/null 2>&1 || { bad "не смог выставить h2-only"; return 1; }
  if reconnect 90 && proxy_listening && quick_ok; then
    info "HTTP Version: $(warp_http || echo '?')"
    return 0
  fi
  bad "на h2-only WARP не поднялся/не выпускает — откатываю на $prev"
  warp tunnel masque-options set "$prev" >/dev/null 2>&1 \
    || warp tunnel masque-options reset >/dev/null 2>&1
  reconnect 90 >/dev/null 2>&1
  if proxy_listening && quick_ok; then
    ok "откат прошёл — WARP снова выпускает (остаёмся на $prev)"
    return 1
  fi
  bad "откат не поднял WARP — нужен ручной разбор (warp-cli settings | grep 'HTTP Version')"
  return 1
}

step_wireguard() {
  warp tunnel protocol set WireGuard >/dev/null 2>&1
  if reconnect; then
    info "WireGuard подключился"
    return 0
  fi
  warn "WireGuard не подключился (UDP/2408 закрыт у провайдера) — возвращаем MASQUE"
  warp tunnel protocol reset >/dev/null 2>&1
  reconnect >/dev/null 2>&1
  return 1
}

step_reregister() {
  local old_id new_id
  old_id=$(warp registration show 2>/dev/null | awk -F': ' '/^ID:/ {print $2}')
  info "старый ID: ${old_id:-?}"
  warp disconnect >/dev/null 2>&1
  warp registration delete >/dev/null 2>&1
  warp registration new >/dev/null 2>&1 || { bad "registration new не удался (нет сети/блокировка Cloudflare API)"; return 1; }
  warp mode proxy >/dev/null 2>&1
  warp proxy port "$WARP_PORT" >/dev/null 2>&1
  reconnect || { bad "после перерегистрации WARP не поднялся"; return 1; }
  sleep 2
  new_id=$(warp registration show 2>/dev/null | awk -F': ' '/^ID:/ {print $2}')
  ok "новая регистрация: ${new_id:-?}"
}

# run_step <имя> <функция>: выполняет шаг и заново замеряет
#   0 = шаг применён и WARP здоров, 1 = не помогло, 2 = шаг не требуется (без изменений)
run_step() {
  hdr "$1"
  "$2"
  local rc=$?
  if [ "$rc" -eq 2 ]; then
    info "шаг не требуется — пропускаем"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    warn "шаг не удался"
    return 1
  fi
  probe_all
  if healthy; then
    ok "после шага WARP здоров (.ru $(pct "$RU_OK" "$RU_TOTAL")%, стабильность $(pct "$STAB_OK" "$STAB_TOTAL")%)"
    return 0
  fi
  warn "после шага: .ru $(pct "$RU_OK" "$RU_TOTAL")%, стабильность $(pct "$STAB_OK" "$STAB_TOTAL")%"
  return 1
}

# -------------------------------------------------------------- ru-direct ----
box_backup() {
  local f="$BACKUP_DIR/${BACKUP_PREFIX}-$(date +%Y%m%d-%H%M%S).json"
  cp -a "$BOX_CONFIG" "$f" || return 1
  echo "$f"
}

box_restart() {
  systemctl restart sing-box 2>/dev/null || return 1
  sleep 3
  systemctl is-active --quiet sing-box
}

ru_direct_apply() {
  hdr "Резервный режим: .ru/.su -> direct в sing-box"
  [ -r "$BOX_CONFIG" ] || die "нет $BOX_CONFIG"
  local backup tmp
  backup=$(box_backup) || die "не смог сделать бэкап конфига"
  info "бэкап: $backup"

  tmp=$(mktemp)
  jq '
    .route.rules |= (
      ([{domain_suffix: [".ru", ".su", ".ru.com", ".ru.net", "ntc.party"], outbound: "direct"}]
       + .) as $all
      | reduce $all[] as $r (
          [];
          if (($r.domain_suffix // []) == [".ru", ".su", ".ru.com", ".ru.net", "ntc.party"] and $r.outbound == "direct")
          then (if any(.[]; (.domain_suffix // []) == [".ru", ".su", ".ru.com", ".ru.net", "ntc.party"] and .outbound == "direct")
                then . else . + [$r] end)
          else . + [$r]
          end
        )
    )
  ' "$BOX_CONFIG" >"$tmp" || { rm -f "$tmp"; die "jq не смог обработать конфиг"; }

  jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "получился невалидный JSON — конфиг не тронут"; }
  cat "$tmp" >"$BOX_CONFIG"; rm -f "$tmp"

  if ! sing-box check -c "$BOX_CONFIG" >/dev/null 2>&1; then
    bad "sing-box check не прошёл — откатываю из $backup"
    cp -a "$backup" "$BOX_CONFIG"; box_restart >/dev/null 2>&1
    return 1
  fi
  ok "sing-box check пройден"

  if ! box_restart; then
    bad "sing-box не поднялся — откатываю из $backup"
    cp -a "$backup" "$BOX_CONFIG"; box_restart >/dev/null 2>&1
    return 1
  fi
  ok "sing-box перезапущен, .ru/.su идут напрямую (IP ноды)"
  info "откат: $0 --ru-restore   (или cp $backup $BOX_CONFIG)"
}

action_h2() {
  hdr "Принудительно MASQUE over HTTP/2 (h2-only)"
  step_h2 || return 1
  probe_all
  WARP_IP=$(warp_ip); [ -n "$WARP_IP" ] && info "WARP exit IP: $WARP_IP"
  if healthy; then
    ok "h2-only: .ru $(pct "$RU_OK" "$RU_TOTAL")%, стабильность $(pct "$STAB_OK" "$STAB_TOTAL")%"
    return 0
  fi
  bad "h2-only не помог: .ru $(pct "$RU_OK" "$RU_TOTAL")%, стабильность $(pct "$STAB_OK" "$STAB_TOTAL")%"
  return 1
}

ru_direct_restore() {
  hdr "Откат резервного режима .ru -> direct"
  [ -r "$BOX_CONFIG" ] || die "нет $BOX_CONFIG"
  local backup tmp
  backup=$(ls -1t "${BACKUP_DIR}/${BACKUP_PREFIX}"-*.json 2>/dev/null | head -1)
  [ -n "$backup" ] || die "не нашёл бэкап ${BACKUP_DIR}/${BACKUP_PREFIX}-*.json"

  tmp=$(mktemp)
  jq '.route.rules |= map(select(((.domain_suffix // []) != [".ru", ".su", ".ru.com", ".ru.net", "ntc.party"]) or .outbound != "direct"))' \
      "$BOX_CONFIG" >"$tmp" || { rm -f "$tmp"; die "jq не смог обработать конфиг"; }
  jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "невалидный JSON — конфиг не тронут"; }
  cat "$tmp" >"$BOX_CONFIG"; rm -f "$tmp"

  sing-box check -c "$BOX_CONFIG" >/dev/null 2>&1 || { bad "sing-box check не прошёл — восстанавливаю из $backup"; cp -a "$backup" "$BOX_CONFIG"; }
  box_restart || { bad "sing-box не поднялся — восстанавливаю из $backup"; cp -a "$backup" "$BOX_CONFIG"; box_restart; }
  ok "правило .ru -> direct удалено, конфиг перезапущен"
}

# ------------------------------------------------------------------ main -----
[ "$(id -u)" -eq 0 ] || die "нужен root"
command -v warp-cli >/dev/null 2>&1 || die "warp-cli не установлен"
command -v jq >/dev/null 2>&1 || die "jq не установлен (apt install jq)"
command -v curl >/dev/null 2>&1 || die "curl не установлен"

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

say "ssb-warp-fix $VERSION — режим: $MODE, прокси ${PROXY}"

if [ "$ACTION" = "ru-direct" ];  then ru_direct_apply;   exit $?; fi
if [ "$ACTION" = "ru-restore" ]; then ru_direct_restore; exit $?; fi
if [ "$ACTION" = "h2" ];         then action_h2;         exit $?; fi

hdr "0. Состояние WARP до вмешательства"
systemctl is-active --quiet warp-svc && ok "warp-svc active" || bad "warp-svc не active"
warp_connected && ok "туннель: Connected" || bad "туннель: не Connected"
info "режим: $(warp_mode || echo '?')"
info "протокол: $(warp_protocol || echo '?'), MASQUE $([ -n "$(warp_http || true)" ] && echo "$(warp_http)" || echo '-')"
info "порт в настройках: $(warp_port_cfg || echo '?'), ожидаем $WARP_PORT"
proxy_listening && ok "SOCKS-прокси слушает ${PROXY}" || bad "SOCKS-прокси не слушает ${PROXY}"

if [ "$MODE" = "check" ]; then
  hdr "Проверка выхода через WARP (без изменений)"
  probe_all
  WARP_IP=$(warp_ip); [ -n "$WARP_IP" ] && info "WARP exit IP: $WARP_IP"
  if [ "$DO_E2E" != "never" ]; then
    hdr "Сквозной тест через sing-box (клиент -> нода -> WARP)"
    if e2e_test; then ok "E2E: .ru идут через WARP (${E2E_OK}/${E2E_TOTAL})"; else warn "E2E: .ru ниже порога (${E2E_OK}/${E2E_TOTAL})"; fi
    e2e_cleanup
  fi
  hdr "Итог"
  printf '  WARP exit           : %s\n' "${WARP_IP:-?}"
  printf '  контрольные домены  : %d/%d\n' "$NONRU_OK" "$NONRU_TOTAL"
  printf '  .ru через WARP      : %d/%d (%d%%, порог %d%%)\n' "$RU_OK" "$RU_TOTAL" "$(pct "$RU_OK" "$RU_TOTAL")" "$RU_THRESHOLD"
  printf '  стабильность        : %d/%d (%d%%, порог %d%%)\n' "$STAB_OK" "$STAB_TOTAL" "$(pct "$STAB_OK" "$STAB_TOTAL")" "$STAB_THRESHOLD"
  [ "$E2E_TOTAL" -gt 0 ] && printf '  сквозной тест       : %d/%d\n' "$E2E_OK" "$E2E_TOTAL"
  if healthy; then VERDICT="ok"; else VERDICT="broken"; fi
  [ "$JSON_OUT" -eq 1 ] && printf '{"verdict":"%s","warp_ip":"%s","ru_ok":%d,"ru_total":%d,"stab_ok":%d,"stab_total":%d,"nonru_ok":%d,"nonru_total":%d,"e2e_ok":%d,"e2e_total":%d}\n' \
    "$VERDICT" "$WARP_IP" "$RU_OK" "$RU_TOTAL" "$STAB_OK" "$STAB_TOTAL" "$NONRU_OK" "$NONRU_TOTAL" "$E2E_OK" "$E2E_TOTAL"
  [ "$VERDICT" = "ok" ] && exit 0 || exit 1
fi

hdr "1. Базовый замер (до ремонта)"
probe_all
FIXED=0
if healthy; then
  ok "WARP уже здоров — ремонт не требуется"
  FIXED=1
fi

[ "$FIXED" -eq 0 ] && run_step "Шаг 1: режим/порт WARP"        step_config       && FIXED=1
[ "$FIXED" -eq 0 ] && run_step "Шаг 2: переподключение"        step_reconnect    && FIXED=1
[ "$FIXED" -eq 0 ] && run_step "Шаг 3: сброс MASQUE-опций"     step_masque_reset && FIXED=1
[ "$FIXED" -eq 0 ] && run_step "Шаг 4: MASQUE over HTTP/2 (h2-only)" step_h2     && FIXED=1
[ "$FIXED" -eq 0 ] && run_step "Шаг 5: WireGuard-транспорт"    step_wireguard    && FIXED=1
if [ "$FIXED" -eq 0 ]; then
  if [ "$DO_REREGISTER" = "never" ]; then
    warn "перерегистрация отключена (--no-reregister), WARP остаётся сломанным"
  else
    run_step "Шаг 6: новая регистрация WARP" step_reregister && FIXED=1
  fi
fi

hdr "2. Финальная проверка .ru через WARP"
probe_all
WARP_IP=$(warp_ip)
[ -n "$WARP_IP" ] && info "WARP exit IP: $WARP_IP"
warp tunnel stats 2>/dev/null | grep -E 'Tunnel Protocol|Colo|Estimated loss|handshake' | while read -r l; do info "$l"; done

if [ "$DO_E2E" != "never" ]; then
  hdr "3. Сквозной тест через sing-box (клиент -> нода -> WARP)"
  if e2e_test; then ok "E2E: .ru идут через WARP (${E2E_OK}/${E2E_TOTAL})"; else warn "E2E: .ru ниже порога (${E2E_OK}/${E2E_TOTAL})"; fi
  e2e_cleanup
fi

hdr "4. Итог"
printf '  WARP exit IP          : %s\n' "${WARP_IP:-нет}"
printf '  MASQUE HTTP version   : %s\n' "$(warp_http || echo '-')"
printf '  контрольные домены    : %d/%d\n' "$NONRU_OK" "$NONRU_TOTAL"
printf '  .ru через WARP        : %d/%d (%d%%, порог %d%%)\n' "$RU_OK" "$RU_TOTAL" "$(pct "$RU_OK" "$RU_TOTAL")" "$RU_THRESHOLD"
printf '  стабильность          : %d/%d (%d%%, порог %d%%)\n' "$STAB_OK" "$STAB_TOTAL" "$(pct "$STAB_OK" "$STAB_TOTAL")" "$STAB_THRESHOLD"
[ "$E2E_TOTAL" -gt 0 ] && printf '  сквозной тест         : %d/%d\n' "$E2E_OK" "$E2E_TOTAL"

if healthy; then
  VERDICT="ok"
  printf '\n\033[32mWARP РАБОТАЕТ\033[0m — .ru открываются через WARP (%s)\n' "${WARP_IP:-?}"
  [ "$JSON_OUT" -eq 1 ] && printf '{"verdict":"ok","warp_ip":"%s","ru_ok":%d,"ru_total":%d,"stab_ok":%d,"stab_total":%d,"nonru_ok":%d,"nonru_total":%d,"e2e_ok":%d,"e2e_total":%d,"fixed":%d}\n' \
    "${WARP_IP:-}" "$RU_OK" "$RU_TOTAL" "$STAB_OK" "$STAB_TOTAL" "$NONRU_OK" "$NONRU_TOTAL" "$E2E_OK" "$E2E_TOTAL" "$FIXED"
  exit 0
fi

VERDICT="broken"
printf '\n\033[31mWARP НЕ РАБОТАЕТ КАК НУЖНО\033[0m — .ru %d/%d, стабильность %d/%d\n' \
  "$RU_OK" "$RU_TOTAL" "$STAB_OK" "$STAB_TOTAL"
info "Рекомендация: перевести .ru/.su на прямой маршрут:  $0 --ru-direct"
[ "$JSON_OUT" -eq 1 ] && printf '{"verdict":"broken","warp_ip":"%s","ru_ok":%d,"ru_total":%d,"stab_ok":%d,"stab_total":%d,"nonru_ok":%d,"nonru_total":%d,"e2e_ok":%d,"e2e_total":%d,"fixed":%d}\n' \
  "${WARP_IP:-}" "$RU_OK" "$RU_TOTAL" "$STAB_OK" "$STAB_TOTAL" "$NONRU_OK" "$NONRU_TOTAL" "$E2E_OK" "$E2E_TOTAL" "$FIXED"
exit 1
