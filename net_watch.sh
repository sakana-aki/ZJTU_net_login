#!/bin/sh
# campus-net watchdog: detect connectivity, auto-relogin if offline (OpenWrt/busybox).
# Online == a domestic HTTP 204 succeeds (real data path); a dead proxy path and the
# campus state at each outage are recorded to error.log for later classification.
# Called by cron every minute (internally throttled to CHECK_INTERVAL); boot runs "once".
# Logs (English, compact): access.log in LOG_DIR (tmpfs), error.log in ERR_LOG_DIR (flash,
# survives reboot); both rotated via logrotate.
#
# usage: net_watch.sh [cron|once|check]   (no-arg/check=check now if due; cron=throttled
#                                          minute call; once=force now)
DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$DIR/config.json"
LOGIN_SH="$DIR/net_login.sh"

cfg_get() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"*\([^\",}]*\)\"*.*/\1/p" "$CONF" | head -n 1
}

LOG_DIR=$(cfg_get LOG_DIR);   [ -z "$LOG_DIR" ]   && LOG_DIR=/var/log/net_login
# access.log lives on tmpfs (volatile, high volume); error.log persists to flash (rare, worth keeping)
ERR_LOG_DIR=$(cfg_get ERR_LOG_DIR); [ -z "$ERR_LOG_DIR" ] && ERR_LOG_DIR="$DIR/logs"
ACCESS_LOG="$LOG_DIR/access.log"
ERROR_LOG="$ERR_LOG_DIR/error.log"
CHECK_INTERVAL=$(cfg_get CHECK_INTERVAL); [ -z "$CHECK_INTERVAL" ] && CHECK_INTERVAL=300
PING_TARGETS=$(cfg_get PING_TARGETS);     [ -z "$PING_TARGETS" ]   && PING_TARGETS="223.5.5.5 114.114.114.114"
PING_COUNT=$(cfg_get PING_COUNT);         [ -z "$PING_COUNT" ]     && PING_COUNT=2
PING_WAIT=$(cfg_get PING_WAIT);           [ -z "$PING_WAIT" ]      && PING_WAIT=2
LOGIN_URL=$(cfg_get LOGIN_URL);           [ -z "$LOGIN_URL" ]      && LOGIN_URL="http://10.18.1.3/gportal/web/login"
# Liveness is decided by a domestic HTTP 204 through the real (DIRECT) data path,
# NOT by ICMP: on a captive/authenticated campus ICMP often still passes while
# TCP/DNS is blocked, so a ping-only check misses de-auth and never re-logins.
HTTP_CHECK_URLS=$(cfg_get HTTP_CHECK_URLS)
[ -z "$HTTP_CHECK_URLS" ] && HTTP_CHECK_URLS="http://wifi.vivo.com.cn/generate_204 http://connectivitycheck.platform.hicloud.com/generate_204"
HTTP_CHECK_CODE=$(cfg_get HTTP_CHECK_CODE); [ -z "$HTTP_CHECK_CODE" ] && HTTP_CHECK_CODE=204
HTTP_TIMEOUT=$(cfg_get HTTP_TIMEOUT);       [ -z "$HTTP_TIMEOUT" ]   && HTTP_TIMEOUT=5
# Optional proxied probe to tell a dead proxy apart from a dead campus link.
# Empty => skipped (only useful when a proxy/OpenClash is in front of foreign traffic).
FOREIGN_CHECK_URL=$(cfg_get FOREIGN_CHECK_URL)

# stamp in /tmp: cleared on reboot => first cron after boot always checks
STAMP="${TMPDIR:-/tmp}/.net_login.last"
STATE="${TMPDIR:-/tmp}/.net_login.state"   # last verdict: ok|proxy|campus
LOCK="$LOG_DIR/.watch.lock"

QUIET=0

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# single-line log (multi-line collapsed), also echoes to stdout unless QUIET
say() {
    file=$1 lv=$2; shift 2
    d=$(dirname "$file"); [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
    msg=$(printf '%s' "$*" | tr '\n' ' ')
    printf '%s %-5s %s\n' "$(ts)" "$lv" "$msg" >> "$file"
    if [ "$QUIET" -ne 1 ]; then
        printf '%s %-5s %s\n' "$(ts)" "$lv" "$msg"
    fi
}
say_access() { say "$ACCESS_LOG" INFO "$@"; }
say_error()  { say "$ERROR_LOG" ERROR "$@"; }

# HTTP status code for a URL, or 000 on any failure
http_code() { curl -s -o /dev/null -m "$HTTP_TIMEOUT" -w '%{http_code}' "$1" 2>/dev/null; }

# online if any target answers ping (fallback only, used when curl is missing)
online_ping() {
    for t in $PING_TARGETS; do
        if ping -q -c "$PING_COUNT" -W "$PING_WAIT" "$t" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# campus path: a domestic URL must return the expected code (204) through DIRECT
online_domestic() {
    command -v curl >/dev/null 2>&1 || { online_ping; return $?; }
    for u in $HTTP_CHECK_URLS; do
        [ "$(http_code "$u")" = "$HTTP_CHECK_CODE" ] && return 0
    done
    return 1
}

# foreign/proxy path: only meaningful when FOREIGN_CHECK_URL is set; otherwise
# assume ok so a proxyless deployment never logs proxy noise
online_foreign() {
    [ -n "$FOREIGN_CHECK_URL" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    [ "$(http_code "$FOREIGN_CHECK_URL")" = "$HTTP_CHECK_CODE" ] && return 0
    return 1
}

get_state() { cat "$STATE" 2>/dev/null; }
set_state() { printf '%s' "$1" > "$STATE" 2>/dev/null; }

# one-line forensics so the next outage can be classified (campus de-auth vs
# dead proxy vs dead WAN) instead of guessed
capture_state() {
    s=""
    for t in $PING_TARGETS; do
        if ping -q -c 1 -W 2 "$t" >/dev/null 2>&1; then s="$s $t=ok"; else s="$s $t=no"; fi
    done
    ph=$(printf '%s' "$LOGIN_URL" | sed -n 's#^\([a-z]*://[^/]*\).*#\1#p')
    fh=n/a
    [ -n "$FOREIGN_CHECK_URL" ] && fh=$(http_code "$FOREIGN_CHECK_URL")
    printf 'ping:%s cn_http=%s foreign_http=%s portal_http=%s' \
        "$s" \
        "$(http_code "$(printf '%s' "$HTTP_CHECK_URLS" | cut -d' ' -f1)")" \
        "$fh" \
        "$(http_code "$ph")"
}

is_due() {
    if [ ! -f "$STAMP" ]; then return 0; fi
    last=$(cat "$STAMP" 2>/dev/null) || last=0
    [ -z "$last" ] && last=0
    now=$(date +%s)
    [ $((now - last)) -ge "$CHECK_INTERVAL" ]
}

# lock: store PID; if process alive, skip (prevents cron/boot overlap)
acquire_lock() {
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null || return 1
    if [ -f "$LOCK" ]; then
        pid=$(cat "$LOCK" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        rm -f "$LOCK"
    fi
    printf '%s' "$$" > "$LOCK"
    trap 'rm -f "$LOCK"' EXIT HUP INT TERM
    return 0
}

last_line() {
    printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | tail -n 1
}

run_check() {
    if online_domestic; then
        if ! online_foreign; then
            # campus is fine, only the proxy/foreign path is dead: record once, no login
            if [ "$(get_state)" != proxy ]; then
                say_error "foreign path down (domestic ok) [$(capture_state)]"
                set_state proxy
            fi
            return 0
        fi
        case "$(get_state)" in
            proxy)  say_access "online (foreign recovered)" ;;
            campus) say_access "recovered" ;;
            *)      say_access "online" ;;
        esac
        set_state ok
        return 0
    fi
    # campus path down: snapshot the fault once, then try to re-login
    if [ "$(get_state)" != campus ]; then
        say_error "offline [$(capture_state)]"
        set_state campus
    fi
    if [ ! -x "$LOGIN_SH" ]; then
        say_error "login script missing: $LOGIN_SH"
        return 1
    fi
    out=$("$LOGIN_SH" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        say_access "recovered"
        set_state ok
    else
        last=$(last_line "$out")
        say_error "login failed rc=$rc: ${last:-no detail}"
    fi
    return "$rc"
}

run_now() {  # force one check; exit code reflects result
    run_check
    rc=$?
    date +%s > "$STAMP"
    return "$rc"
}

run_tick() {  # cron minute call, throttled
    if is_due; then
        run_now
    fi
}

main() {
    QUIET=0
    case "${1:-}" in
        once|--now|start) : ;;
        cron|""|check)    QUIET=1 ;;
        *)
            echo "usage: net_watch.sh [cron|once|check]"
            echo "  (no-arg/check=check now if due; cron=for minute cron, throttled; once=force now)"
            exit 2 ;;
    esac
    acquire_lock || { say_access "skip(lock)"; exit 0; }
    if [ "${1:-}" = "once" ] || [ "${1:-}" = "--now" ] || [ "${1:-}" = "start" ]; then
        run_now
    else
        run_tick
    fi
}

if [ -z "${NET_WATCH_TEST:-}" ]; then
    main "$@"
fi
