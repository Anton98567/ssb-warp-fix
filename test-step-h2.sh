#!/usr/bin/env bash
# Локальный тест step_h2 из ssb-warp-fix.sh со стабами (нода не затрагивается).
set -uo pipefail

SRC="${1:-/private/tmp/opencode/ssb-warp-fix/ssb-warp-fix.sh}"
FUNCS=/tmp/warp-fix-funcs.sh
awk '/# ------------------------------------------------------------------ main -----/{exit} {print}' "$SRC" >"$FUNCS"
[ -s "$FUNCS" ] || { echo "не смог выделить функции"; exit 1; }

PROXY_HOST=127.0.0.1
WARP_PORT=40000
PROXY="127.0.0.1:40000"
TIMEOUT=1
LOG_FILE=/tmp/warp-fix-test.log
C_OK=0; C_BAD=0; C_WARN=0
STATE=/tmp/warp-fix-state
MODE=connected
SUCCEED_H2=0

sleep() { :; }
ss()    { echo "LISTEN 0 1024 127.0.0.1:40000 0.0.0.0:*"; }
curl()  { if [ "$MODE" = connected ]; then echo -n "200"; else echo -n "000"; fi; }

warp-cli() {
  [ "${1:-}" = "--accept-tos" ] && shift
  case "${1:-}" in
    settings)
      echo "(user set)	Mode: WarpProxy on port 40000"
      echo "(user set)	MASQUE Protocol Settings:"
      printf '  HTTP Version: MASQUE (%s)\n' "$(cat "$STATE")"
      echo "(network policy)	WARP tunnel protocol: MASQUE"
      ;;
    status)
      if [ "$MODE" = connected ]; then echo "Status update: Connected"; else echo "Status update: Disconnected"; fi
      ;;
    disconnect) MODE=disconnected ;;
    connect)
      if [ "$(cat "$STATE")" = "HTTP/2" ] && [ "$SUCCEED_H2" -eq 0 ]; then MODE=dead; else MODE=connected; fi
      ;;
    tunnel)
      shift
      case "${1:-}" in
        masque-options)
          shift
          case "${1:-}" in
            set)   if [ "${2:-}" = "h2-only" ]; then echo "HTTP/2" >"$STATE"; else echo "HTTP/3 with HTTP/2 fallback" >"$STATE"; fi ;;
            reset) echo "HTTP/3 with HTTP/2 fallback" >"$STATE" ;;
          esac
          ;;
      esac
      ;;
  esac
}

warp() { warp-cli --accept-tos "$@"; }

# shellcheck disable=SC1090
. "$FUNCS"

rc_case() { :; }

run() {
  local name="$1" state="$2" succeed="$3" expect="$4"
  printf '%s\n' "$state" >"$STATE"
  MODE=connected; SUCCEED_H2="$succeed"
  local out rc
  out=$(step_h2 2>&1); rc=$?
  echo "=== $name ==="
  echo "$out" | sed 's/^/    /'
  echo "    rc=$rc (ожидался $expect), настройка: $(cat "$STATE"), tunnel: $MODE"
  [ "$rc" -eq "$expect" ] && echo "    RESULT: OK" || echo "    RESULT: FAIL"
}

run "A. h2 не поднимается -> откат" "HTTP/3 with HTTP/2 fallback" 0 1
run "B. h2 поднимается -> успех"     "HTTP/3 with HTTP/2 fallback" 1 0
run "C. уже h2-only -> пропуск"      "HTTP/2"                      0 2
