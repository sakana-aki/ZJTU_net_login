#!/bin/sh
# Enable/disable the campus-net auto-detect + auto-login (OpenWrt/busybox).
# Use "on" when at school, "off" on holiday/at home. "off" only stops:
#   - the every-minute detection cron entry
#   - boot autostart (/etc/init.d/net_watch)
# logrotate config + schedule are left alone (no-op when no logs); scripts, config
# and old logs are never deleted.
#
# usage (as root): net_switch.sh on|start|enable | off|stop|disable | status | help
set -u
DEST=$(cd "$(dirname "$0")" && pwd)
CONF="$DEST/config.json"
CRONTAB=${CRONTAB:-/etc/crontabs/root}
INIT=${INIT:-/etc/init.d/net_watch}
LOG_DIR_DEFAULT=/var/log/net_login

cfg_get() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"*\([^\",}]*\)\"*.*/\1/p" "$CONF" | head -n 1
}

LOG_DIR=$(cfg_get LOG_DIR); [ -z "$LOG_DIR" ] && LOG_DIR=$LOG_DIR_DEFAULT
ACCESS="$LOG_DIR/access.log"

info() { printf '[net_switch] %s\n' "$@"; }
die()  { printf '[net_switch][ERROR] %s\n' "$@"; exit 1; }

need_root() {
    [ "${NET_SWITCH_TEST:-0}" = 1 ] && return 0
    [ "$(id -u)" -eq 0 ] || die "need root, run as root"
}

# one audit line in access.log (so state history is queryable)
log_trace() {
    mkdir -p "$LOG_DIR" 2>/dev/null
    printf '%s INFO  net_switch: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$ACCESS" 2>/dev/null
}

cron_line="* * * * * PATH=/usr/bin:/bin $DEST/net_watch.sh cron"

# idempotent add/remove of our cron entry (matched by marker comment, other entries untouched)
add_cron() {
    mkdir -p /etc/crontabs 2>/dev/null
    sed -i '/^# net_login:watch$/d;/net_watch.sh cron/d' "$CRONTAB" 2>/dev/null
    {
        echo '# net_login:watch'
        echo "$cron_line"
    } >> "$CRONTAB"
}
del_cron() {
    sed -i '/^# net_login:watch$/d;/net_watch.sh cron/d' "$CRONTAB" 2>/dev/null
}

restart_cron() {
    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron restart 2>/dev/null && return 0
    fi
    pkill -x crond 2>/dev/null
    crond -b 2>/dev/null
}

write_init() {
    cat > "$INIT" <<EOF
#!/bin/sh /etc/rc.common
# run one connectivity check right after boot (periodic checks are cron's job)
START=99
start() {
    $DEST/net_watch.sh once
}
EOF
    chmod +x "$INIT"
    [ -x /etc/rc.common ] && "$INIT" enable 2>/dev/null
}

remove_init() {
    if [ -f "$INIT" ]; then
        "$INIT" disable 2>/dev/null
        rm -f "$INIT"
    fi
}

# kill any net_watch still running (so "off" takes effect immediately)
stop_running() {
    pkill -f "$DEST/net_watch.sh" 2>/dev/null
}

do_on() {
    need_root
    add_cron
    write_init
    restart_cron
    log_trace "watch enabled"
    echo
    info "enabled: minute cron + boot autostart restored."
    info "to check/login right now: $DEST/net_watch.sh once"
}

do_off() {
    need_root
    del_cron
    remove_init
    stop_running
    restart_cron
    log_trace "watch disabled (logrotate kept)"
    echo
    info "disabled: minute cron + boot autostart removed. logrotate kept; scripts/logs untouched."
    info "back at school: run $0 on"
}

do_status() {
    need_root
    cron_on=$(grep -c '/net_watch.sh cron' "$CRONTAB" 2>/dev/null)
    # on OpenWrt "enabled" == /etc/rc.d/S*net_watch symlink exists (rc.common enable)
    init_on=0
    if ls /etc/rc.d/S*net_watch >/dev/null 2>&1; then
        init_on=1
    elif [ -f "$INIT" ]; then
        init_on=1
    fi
    echo "state: $({ [ "$cron_on" -ge 1 ] || [ "$init_on" -eq 1 ]; } && echo ON || echo OFF)"
    echo "  cron entry   : $([ "$cron_on" -ge 1 ] && echo yes || echo no)"
    echo "  boot autostart: $([ "$init_on" -eq 1 ] && echo yes || echo no)"
    echo "  logrotate cfg: $([ -f /etc/logrotate.d/net_login ] && echo present || echo none)"
    echo "  recent logs:"
    tail -n 6 "$LOG_DIR/access.log" 2>/dev/null || echo "    (no access.log yet; run: $DEST/net_watch.sh once)"
}

do_help() {
    sed -n '1,12p' "$0" | sed 's/^# \{0,1\}//'
    echo "  subcommands: on(start/enable) / off(stop/disable) / status / help"
}

case "${1:-status}" in
    on|start|enable)     do_on ;;
    off|stop|disable)    do_off ;;
    status)              do_status ;;
    help|-h|--h)         do_help ;;
    *) echo "unknown subcommand: $1 (on/off/status/help)"; exit 1 ;;
esac
