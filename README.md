# ssb-warp-fix

Диагностика и ремонт Cloudflare WARP на Linux-нодах (SSB): лестница починки `warp-cli`,
функциональная проверка выхода и **отдельная проверка `.ru`-доменов** — и напрямую через
SOCKS-прокси WARP, и сквозь реальную цепочку sing-box (клиент → нода → WARP).

```
ssb-warp-fix.sh            # диагностика + ремонт + проверка .ru (и E2E через sing-box)
ssb-warp-fix.sh --check    # только чтение: ничего не меняет
```

## Симптом

`warp-cli` рапортует `Connected`, `Network: healthy`, но прокси `127.0.0.1:40000`
отдаёт `socks5: request rejected, code=4` почти на всё, кроме доменов самого Cloudflare:

```
curl -x socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace   → 200
curl -x socks5h://127.0.0.1:40000 https://www.google.com                     → 000
curl -x socks5h://127.0.0.1:40000 https://yandex.ru                          → 000
```

В логе sing-box это выглядит так:

```
inbound/trojan[trojan-in]: inbound multiplex connection to yandex.ru:443
outbound/socks[warp]: outbound connection to yandex.ru:443
ERROR connection: open connection to yandex.ru:443 using outbound/socks[warp]:
      socks5: request rejected, code=4
```

Если в маршрутизации sing-box на `outbound: warp` висят `.ru/.su`, AI-сервисы
(`openai`, `anthropic`, `xai`), TikTok и т.п. — у клиентов они просто не открываются.

**Второй симптом (частичный): WARP «вроде работает», но флапает.** Одиночная проверка
проходит, а серия запросов даёт провалы:

```
mail.ru         15/15
yandex.ru        7/15
cheburcheck.ru   5/15
```

В логе sing-box при этом те же `socks5: request rejected, code=4`, но пачками. Причина —
MASQUE over **HTTP/3 (QUIC)** на этом аплинке: `Estimated loss` показывает 0.01 %, а QUIC
всё равно рассыпается. Тот же набор на **HTTP/2 (TCP/443)** даёт **45/45**.

Флап эпизодический: через час тот же дефолт выдал 90/90, а `h2-only` в другой раз не
поднялся вовсе. Поэтому h2 в скрипте — попытка с автоматическим откатом, а не постоянная
настройка.

## Причина

### 1. «Разъехавшаяся» регистрация Cloudflare

Регистрация устройства на стороне Cloudflare «разъезжается»: MASQUE/WireGuard-хендшейк
живой, туннель поднят, но выход обслуживает только периферию Cloudflare, а выход в обычный
интернет не работает. Переподключение и смена транспорта (WireGuard/MASQUE, h2/h3) **не
помогают** — помогает только новая регистрация:

```bash
warp-cli --accept-tos registration delete
warp-cli --accept-tos registration new
```

Побочный эффект: меняется WARP-identity и выходной IP (из `104.28.0.0/16`) — это нормально.

### 2. Нестабильный MASQUE h3

Если WARP выпускает, но часть запросов отваливается — виноват QUIC-транспорт. Лечение
без перерегистрации:

```bash
warp-cli --accept-tos tunnel masque-options set h2-only   # MASQUE over HTTP/2 (TCP/443)
warp-cli --accept-tos disconnect && warp-cli --accept-tos connect
```

⚠️ `warp-cli tunnel stats` продолжает печатать `MASQUE (HTTP/3)` даже после `h2-only` —
это баг вывода. Смотреть надо `warp-cli settings | grep "HTTP Version"` (будет
`MASQUE (HTTP/2)`) и серию запросов, а не stats.

Применить одной командой: `ssb-warp-fix --h2` (ставит `h2-only`, переподключает, проверяет
выход и **сам откатывается** на прежнюю настройку, если на h2 туннель не поднялся или не
выпускает). Наблюдение с живой ноды: h2-only то даёт 45/45, то вообще не поднимается —
поэтому шаг всегда с откатом, а не «включить и забыть».

## Лестница ремонта (останавливается на первом успехе)

| Шаг | Действие |
|---|---|
| 0 | привести настройки к эталону: `mode proxy`, `proxy port <N>` |
| 1 | `disconnect` / `connect` + ожидание `Connected` |
| 2 | сброс MASQUE-опций и протокола (`tunnel masque-options reset`, `tunnel protocol reset`) |
| 3 | **MASQUE over HTTP/2**: `tunnel masque-options set h2-only` (лечит флапы h3) |
| 4 | проба WireGuard-транспорта (если провайдер не режет UDP) |
| 5 | **новая регистрация WARP** (главное лечение `code=4`) |

После каждого шага выполняется замер: 4 контрольных домена, 10 `.ru` и серия стабильности
(3 домена × 5 попыток). Порог `.ru` — 80 % (некоторые сайты, например `www.gosuslugi.ru`,
режут зарубежные IP принципиально и всегда дают `000` — это не баг WARP), порог
стабильности — 90 %.

## Проверка `.ru`

```
  OK   cheburcheck.ru -> 200
  OK   yandex.ru -> 302
  OK   ya.ru -> 302
  OK   mail.ru -> 302
  OK   ozon.ru -> 307
  OK   wildberries.ru -> 307
  OK   rbc.ru -> 307
  FAIL www.gosuslugi.ru -> нет ответа через WARP
  OK   avito.ru -> 301
  OK   sber.ru -> 200
       WARP exit IP: 104.28.x.x
```

Плюс сквозной тест: скрипт поднимает временный клиент sing-box, который ходит в родной
trojan/vless-inbound этой же ноды, гоняет через него `.ru` и сверяет, что трафик реально
ушёл в `outbound/socks[warp]` и что в логе нет отказов `code=4`. Временный клиент и его
файлы удаляются на выходе (trap).

## Использование

```bash
# поставить
curl -fsSL -o /usr/local/sbin/ssb-warp-fix \
  https://raw.githubusercontent.com/Anton98567/ssb-warp-fix/main/ssb-warp-fix.sh
chmod 700 /usr/local/sbin/ssb-warp-fix

ssb-warp-fix --check                 # только диагностика и проверка
ssb-warp-fix                         # диагностика + ремонт + проверка + E2E
ssb-warp-fix --no-reregister         # ремонт без смены WARP-регистрации
ssb-warp-fix --port 40000            # другой порт SOCKS-прокси WARP
ssb-warp-fix --json                  # машинный итог одной строкой
ssb-warp-fix --no-e2e                # без сквозного теста через sing-box
ssb-warp-fix --h2                    # принудительно MASQUE over HTTP/2 (с автооткатом)
```

Переменные окружения (все необязательные):

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `WARP_PORT` | `40000` | порт SOCKS-прокси WARP |
| `TIMEOUT` | `10` | таймаут одного запроса, сек |
| `RU_THRESHOLD` | `80` | минимальный % успешных `.ru` |
| `STAB_TRIES` | `5` | попыток на домен в серии стабильности |
| `STAB_THRESHOLD` | `90` | минимальный % успешных в серии |
| `LOG_FILE` | `/var/log/ssb-warp-fix.log` | журнал (дублирует вывод) |

Пример: `STAB_TRIES=7 TIMEOUT=6 ssb-warp-fix`.

Резервный сценарий, если WARP починить не удалось, а `.ru` нужны клиентам:

```bash
ssb-warp-fix --ru-direct     # вставить правило ".ru/.su -> direct" в sing-box
ssb-warp-fix --ru-restore    # откатить его
```

`--ru-direct` делает бэкап `/root/sb-config-backup-ssbwarpfix-*.json`, проверяет
`sing-box check`, перезапускает службу и **автоматически откатывается**, если проверка
или старт не прошли.

## Коды возврата

| Код | Значение |
|---|---|
| `0` | WARP отдаёт трафик, `.ru` и стабильность выше порогов |
| `1` | WARP отвечает, но `.ru` или стабильность ниже порога (либо E2E провален) |
| `2` | фатально: нет root / `warp-cli` / `jq` / `curl` |

## ⚠️ Важно

* **Никогда не выполняйте `warp-cli --accept-tos mode warp` на удалённом сервере.**
  Это полнотуннельный режим: WARP забирает и ответные пакеты на входящие SSH-сессии,
  и сервер мгновенно становится недоступен по сети. Перезагрузка не спасает — режим
  сохраняется, а `Always On` поднимает туннель при старте. Возврат — только через
  KVM-консоль панели: `mode proxy` + `proxy port 40000` + `connect`.
  Скрипт этого не делает: он работает исключительно в режиме `proxy`.
* Если нода уже «поймана» в `mode warp` и недоступна по SSH — восстановление
  через KVM-консоль панели:
  ```bash
  warp-cli --accept-tos mode proxy
  warp-cli --accept-tos proxy port 40000
  warp-cli --accept-tos connect
  systemctl restart sing-box
  ```
  Проверено: после перезагрузки `mode warp` **не** сохраняется — клиент поднимается
  в последнем proxy-режиме, но порт прокси остаётся тем, что был выставлен (у нас после
  аварии поднялся на `41000`, хотя sing-box смотрит в `40000`). Поэтому после
  восстановления всегда сверяйте `warp-cli settings | grep Mode` с портом, на который
  смотрит `outbound: warp` в sing-box (это делает шаг 0 скрипта).
* Перерегистрация меняет WARP egress IP. Если у клиента что-то завязано на IP `104.28.*`,
  учитывайте это.
* Скрипт исходит из того, что WARP-прокси слушает `127.0.0.1:<порт>` и что sing-box ходит
  в него как в `socks`-outbound (стандартная схема SSB).

## Требования

Linux, root, `warp-cli` 2024+, `curl`, `jq`, `ss` (iproute2). Для E2E — бинарь `sing-box`
и читаемый `/etc/sing-box/config.json` (или укажите `--config`).

## Лицензия

MIT
