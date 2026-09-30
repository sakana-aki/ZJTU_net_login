#!/bin/sh
# campus-net watchdog: detect connectivity, auto-relogin if offline (OpenWrt/busybox).
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

# stamp in /tmp: cleared on reboot => first cron after boot always checks
STAMP="${TMPDIR:-/tmp}/.net_login.last"
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

# online if any target answers ping
online_ping() {
    for t in $PING_TARGETS; do
        if ping -q -c "$PING_COUNT" -W "$PING_WAIT" "$t" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
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
    if online_ping; then
        say_access "online"
        return 0
    fi
    # offline: log a single outcome (no separate "offline" line -> less log bytes)
    if [ ! -x "$LOGIN_SH" ]; then
        say_error "offline, login script missing: $LOGIN_SH"
        return 1
    fi
    out=$("$LOGIN_SH" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        say_access "recovered"          # keep access small & english; reason goes to error log
    else
        last=$(last_line "$out")
        say_error "offline, login failed rc=$rc: ${last:-no detail}"
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
