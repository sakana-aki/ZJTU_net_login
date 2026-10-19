#!/bin/sh
# campus-net watchdog: detect connectivity, auto-recover if offline (OpenWrt/busybox).
# Online == a domestic HTTP 204 succeeds (real data path). Two offline modes are handled:
#   - link/DHCP/auth path broken (no default route, dead gateway ARP, or the portal
#     itself unreachable): re-DHCP the WAN via `ifup wan` (throttled by HEAL_INTERVAL)
#     — a portal login cannot fix a dead local link;
#   - link fine and portal reachable but de-authed: re-login (net_login.sh).
# A dead proxy path and the campus state at each outage are recorded to error.log.
# Called by cron every minute (internally throttled to CHECK_INTERVAL); boot runs "once".
# Logs (English, compact): both access.log and error.log live in LOG_DIR (flash on
# OpenWrt, so they survive reboot); both rotated via logrotate.
#
# usage: net_watch.sh [cron|once|check]   (no-arg/check=check now if due; cron=throttled
#                                          minute call; once=force now)
# cron invokes us with a minimal PATH (/usr/bin:/bin); OpenWrt keeps ip/ifup in sbin.
PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin"
export PATH
DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$DIR/config.json"
LOGIN_SH="$DIR/net_login.sh"

cfg_get() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"*\([^\",}]*\)\"*.*/\1/p" "$CONF" | head -n 1
}

LOG_DIR=$(cfg_get LOG_DIR);   [ -z "$LOG_DIR" ]   && LOG_DIR="$DIR/logs"
# both logs share LOG_DIR (persistent under the install dir on OpenWrt)
ACCESS_LOG="$LOG_DIR/access.log"
ERROR_LOG="$LOG_DIR/error.log"
CHECK_INTERVAL=$(cfg_get CHECK_INTERVAL); [ -z "$CHECK_INTERVAL" ] && CHECK_INTERVAL=300
ERROR_REPEAT_INTERVAL=$(cfg_get ERROR_REPEAT_INTERVAL); [ -z "$ERROR_REPEAT_INTERVAL" ] && ERROR_REPEAT_INTERVAL=3600
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
STATE="${TMPDIR:-/tmp}/.net_login.state"   # last verdict: ok|proxy|campus|l2
ERR_STATE="${TMPDIR:-/tmp}/.net_error.state"  # last throttled error: epoch\nmessage
HEAL_STAMP="${TMPDIR:-/tmp}/.net_heal.last"  # last time we re-DHCP'd the WAN
HEAL_INTERVAL=$(cfg_get HEAL_INTERVAL); [ -z "$HEAL_INTERVAL" ] && HEAL_INTERVAL=600
LOCK="${TMPDIR:-/tmp}/.net_watch.lock"  # keep the lock in RAM, not on flash

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
http_code() { curl -s --noproxy '*' -o /dev/null -m "$HTTP_TIMEOUT" -w '%{http_code}' "$1" 2>/dev/null; }

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

# default IPv4 gateway of the WAN link (empty if none)
default_gw() { ip route 2>/dev/null | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -n 1; }

# ARP state of a neighbor (empty if there is no entry)
neigh_state() { ip neigh show "$1" 2>/dev/null | awk 'NF{print $NF; exit}'; }

# Link-level reachability of the gateway: INCOMPLETE/FAILED ARP means the access
# layer stopped answering ARP. Sets $GW/$ARP_STATE for the caller (logging).
# Note: a healthy/stale ARP entry does NOT prove the link is usable — the access
# layer can stop forwarding L3 while still answering ARP (2026-10-17 outage).
gw_l2_down() {
    GW=$(default_gw)
    ARP_STATE=
    [ -n "$GW" ] || return 1
    ARP_STATE=$(neigh_state "$GW")
    case "$ARP_STATE" in INCOMPLETE|FAILED) return 0 ;; esac
    return 1
}

# Reachability of the campus portal itself. 000 => the portal cannot be reached,
# so the fault is below the portal (local link/DHCP/access-layer auth), not a
# lost portal session; a login retry cannot fix that.
portal_code() {
    ph=$(printf '%s' "$LOGIN_URL" | sed -n 's#^\([a-z]*://[^/]*\).*#\1#p')
    [ -n "$ph" ] || { printf '000'; return; }
    http_code "$ph"
}

# Re-DHCP the WAN, throttled: recovery is not instant (DHCP + re-auth takes a few
# minutes), so back off HEAL_INTERVAL between attempts instead of hammering ifup.
heal_wan() {
    now=$(date +%s); last=$(cat "$HEAL_STAMP" 2>/dev/null); last=${last:-0}
    [ $((now - last)) -ge "$HEAL_INTERVAL" ] || return 0
    printf '%s' "$now" > "$HEAL_STAMP"
    out=$(ifup wan 2>&1); rc=$?
    # ifup exits 0 even when the interface is missing (bare `exit` in /sbin/ifup),
    # so any output at all is suspicious and worth surfacing.
    if [ -n "$out" ]; then
        say_error_throttled "ifup wan rc=$rc: $(last_line "$out")"
    else
        say_access "re-DHCP: ifup wan"
    fi
}

get_state() { cat "$STATE" 2>/dev/null; }

# A state transition clears dedupe history so the first failure in the new
# state is always logged in full.
reset_error_throttle() { rm -f "$ERR_STATE"; }
set_state() {
    old=$(get_state)
    printf '%s' "$1" > "$STATE" 2>/dev/null
    [ "$old" = "$1" ] || reset_error_throttle
}

# Identical repeated failures are logged once, then suppressed for
# ERROR_REPEAT_INTERVAL; after that they reappear as "still: ...".
say_error_throttled() {
    msg=$*
    now=$(date +%s)
    prev_ts=0 prev_msg=
    if [ -f "$ERR_STATE" ]; then
        prev_ts=$(sed -n '1p' "$ERR_STATE")
        prev_msg=$(sed -n '2p' "$ERR_STATE")
    fi
    [ -n "$prev_ts" ] || prev_ts=0
    if [ "$msg" = "$prev_msg" ]; then
        [ $((now - prev_ts)) -ge "$ERROR_REPEAT_INTERVAL" ] || return 0
        say_error "still: $msg"
    else
        say_error "$msg"
    fi
    printf '%s\n%s\n' "$now" "$msg" > "$ERR_STATE"
}

# one-line forensics so the next outage can be classified (campus de-auth vs
# dead proxy vs dead WAN) instead of guessed
capture_state() {
    s=""
    for t in $PING_TARGETS; do
        if ping -q -c 1 -W 2 "$t" >/dev/null 2>&1; then s="$s $t=ok"; else s="$s $t=no"; fi
    done
    gw=$(default_gw); arp=none
    [ -n "$gw" ] && arp=$(neigh_state "$gw")
    fh=n/a
    [ -n "$FOREIGN_CHECK_URL" ] && fh=$(http_code "$FOREIGN_CHECK_URL")
    printf 'ping:%s cn_http=%s foreign_http=%s portal_http=%s gw=%s arp=%s' \
        "$s" \
        "$(http_code "$(printf '%s' "$HTTP_CHECK_URLS" | cut -d' ' -f1)")" \
        "$fh" \
        "$(portal_code)" \
        "${gw:-none}" "$arp"
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
            l2)     say_access "recovered (L2 link back)" ;;
            *)      say_access "online" ;;
        esac
        set_state ok
        return 0
    fi
    # Campus path down. A de-authed client can still reach the portal, so decide
    # by portal reachability: unreachable portal, missing default route, or dead
    # gateway ARP all mean the local link/DHCP path is broken — only a fresh DHCP
    # (ifup wan) can help, and a portal login would just fail for hours.
    gw_l2_down; l2=$?
    pcode=$(portal_code)
    if [ -z "$GW" ] || [ "$l2" -eq 0 ] || [ "$pcode" = 000 ]; then
        if [ "$(get_state)" != l2 ]; then
            say_error "link/DHCP down (gw=${GW:-none} arp=${ARP_STATE:-none} portal=$pcode), re-DHCP: ifup wan"
            set_state l2
        fi
        heal_wan
        return 0
    fi
    # Link fine and portal reachable: snapshot the fault once, then re-login
    if [ "$(get_state)" != campus ]; then
        say_error "offline [$(capture_state)]"
        set_state campus
    fi
    if [ ! -x "$LOGIN_SH" ]; then
        say_error_throttled "login script missing: $LOGIN_SH"
        return 1
    fi
    out=$("$LOGIN_SH" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        say_access "recovered"
        set_state ok
    else
        last=$(last_line "$out")
        say_error_throttled "login failed rc=$rc: ${last:-no detail}"
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
