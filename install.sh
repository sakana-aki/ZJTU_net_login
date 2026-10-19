#!/bin/sh
# campus-net login suite: one-shot OpenWrt install / status / uninstall
# Run as root from the deployed directory (recommend /root/net_login):
#   sh install.sh            # install: check/install deps, write cron+logrotate+boot item, check once
#   sh install.sh status     # show integration state + recent logs
#   sh install.sh uninstall  # remove what this script wrote (keeps scripts & logs)
#   sh install.sh help
#
# deps: curl, openssl-util (login), logrotate (log rotation); jq optional (config check)
# missing ones are auto-installed via opkg; non-OpenWrt (no opkg) prints a hint instead.
set -u
DEST=$(cd "$(dirname "$0")" && pwd)
CONF="$DEST/config.json"
CRONTAB=/etc/crontabs/root
LOG_DIR_DEFAULT="$DEST/logs"

cfg_get() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"*\([^\",}]*\)\"*.*/\1/p" "$CONF" | head -n 1
}

info() { printf '[install] %s\n' "$@"; }
warn() { printf '[install][WARN] %s\n' "$@"; }
die()  { printf '[install][ERROR] %s\n' "$@"; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "need root, run as root (OpenWrt ssh login is root)"
}

need_files() {
    [ -f "$DEST/net_login.sh" ] || die "missing $DEST/net_login.sh"
    [ -f "$DEST/net_watch.sh" ] || die "missing $DEST/net_watch.sh"
    [ -f "$CONF" ]              || die "missing $CONF"
    chmod +x "$DEST/net_login.sh" "$DEST/net_watch.sh" "$DEST/install.sh" 2>/dev/null
}

# ---------- dependency check / install ----------
have() { command -v "$1" >/dev/null 2>&1; }

ensure_deps() {
    missing_list=""
    for pair in "curl:curl" "openssl:openssl-util" "logrotate:logrotate"; do
        bin=${pair%%:*}; pkg=${pair#*:}
        have "$bin" || missing_list="$missing_list $pkg"
    done
    [ -z "$missing_list" ] && { info "deps ok (curl openssl-util logrotate)"; return 0; }

    if command -v opkg >/dev/null 2>&1; then
        info "installing missing packages via opkg:$missing_list"
        opkg update || die "opkg update failed, check network"
        # shellcheck disable=SC2086
        opkg install $missing_list || die "opkg install failed, install manually:$missing_list"
    else
        warn "no opkg (non-OpenWrt). make sure these exist: curl openssl logrotate"
    fi
}

# jq is optional: when present, catch a malformed config before it silently
# turns every cfg_get into an empty value.
check_config() {
    if command -v jq >/dev/null 2>&1; then
        jq empty "$CONF" >/dev/null 2>&1 || die "config.json is not valid JSON"
        info "config.json syntax ok"
    fi
}

# ---------- logrotate (access: daily, keep 2; error: daily, keep 3 with delaycompress) ----------
write_logrotate() {
    LOG_DIR=$(cfg_get LOG_DIR)
    [ -z "$LOG_DIR" ] && LOG_DIR=$LOG_DIR_DEFAULT
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/net_login <<EOF
# campus-net_login logs: access daily (current + yesterday); error current + .1 + .2.gz.
$LOG_DIR/access.log {
    daily
    rotate 1
    missingok
    notifempty
    create 0644 root root
}
$LOG_DIR/error.log {
    daily
    rotate 2
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF
    info "wrote /etc/logrotate.d/net_login (access: daily x2; error: daily x3, current+.1+.2.gz)"
}

# ---------- cron: every-minute detection (net_watch throttles to json interval) ----------
add_cron_watch() {
    mkdir -p /etc/crontabs 2>/dev/null
    sed -i '/^# net_login:watch$/d;/net_watch.sh cron/d' "$CRONTAB" 2>/dev/null
    {
        echo '# net_login:watch'
        echo "* * * * * PATH=/usr/sbin:/usr/bin:/sbin:/bin $DEST/net_watch.sh cron"
    } >> "$CRONTAB"
    info "added minute-detection cron -> $CRONTAB"
}

# logrotate needs its own trigger (skip if a global one already exists)
add_cron_logrotate() {
    if grep -qF 'logrotate /etc/logrotate.conf' "$CRONTAB" 2>/dev/null; then
        info "a global logrotate schedule exists, skipping"
        return 0
    fi
    sed -i '/^# net_login:logrotate$/d;/logrotate \/etc\/logrotate.conf/d' "$CRONTAB" 2>/dev/null
    {
        echo '# net_login:logrotate'
        echo '0 4 * * * /usr/sbin/logrotate /etc/logrotate.conf'
    } >> "$CRONTAB"
    info "added daily logrotate schedule (04:00)"
}

restart_cron() {
    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron enable 2>/dev/null
        /etc/init.d/cron restart 2>/dev/null && return 0
    fi
    pkill -x crond 2>/dev/null
    crond -b 2>/dev/null
    info "tried to restart crond"
}

# ---------- run one check right after boot ----------
write_boot_init() {
    cat > /etc/init.d/net_watch <<EOF
#!/bin/sh /etc/rc.common
# run one connectivity check right after boot (periodic checks are cron's job)
START=99
start() {
    $DEST/net_watch.sh once
}
EOF
    chmod +x /etc/init.d/net_watch
    if [ -x /etc/rc.common ]; then
        /etc/init.d/net_watch enable 2>/dev/null && info "registered boot autostart /etc/init.d/net_watch" \
            || warn "init enable failed, run manually: /etc/init.d/net_watch enable"
    else
        warn "no /etc/rc.common (non-OpenWrt), boot item not enabled"
    fi
}

# ---------- log dir: access.log + error.log share LOG_DIR ----------
init_logs() {
    LOG_DIR=$(cfg_get LOG_DIR)
    [ -z "$LOG_DIR" ] && LOG_DIR=$LOG_DIR_DEFAULT
    mkdir -p "$LOG_DIR" 2>/dev/null
    # create if missing without truncating an existing log (`: >>` appends nothing)
    : >> "$LOG_DIR/access.log" 2>/dev/null
    : >> "$LOG_DIR/error.log" 2>/dev/null
    info "log dir: $LOG_DIR (access.log + error.log)"
}

# ---------- actions ----------
do_install() {
    need_root
    need_files
    check_config
    warn_if_placeholder
    ensure_deps
    init_logs
    write_logrotate
    add_cron_watch
    add_cron_logrotate
    restart_cron
    write_boot_init
    echo
    info "install done, running one check now:"
    "$DEST/net_watch.sh" once || echo "[install] check/login did not pass (offline or no real account), see logs above"
    echo
    echo "  logs:    tail -f $LOG_DIR/access.log"
    echo "           tail -f $LOG_DIR/error.log"
    echo "  inspect: sh $DEST/install.sh status"
}

warn_if_placeholder() {
    uid=$(cfg_get USERID)
    case "$uid" in
        your_student_id|"") warn "config.json still has placeholder account; fill real USERID/PASSWD first" ;;
    esac
}

do_status() {
    need_root
    echo "== dir =="; ls -l "$DEST"/net_login.sh "$DEST"/net_watch.sh "$DEST"/install.sh 2>/dev/null
    echo; echo "== boot item =="
    if [ -f /etc/init.d/net_watch ]; then
        if ls /etc/rc.d/S*net_watch >/dev/null 2>&1; then
            echo "enabled (/etc/init.d/net_watch)"
        else
            echo "present but not enabled"
        fi
    else
        echo "(no /etc/init.d/net_watch)"
    fi
    echo; echo "== cron =="; grep -e net_login -e net_watch -e logrotate "$CRONTAB" 2>/dev/null || echo "(none)"
    echo; echo "== logrotate =="; [ -f /etc/logrotate.d/net_login ] && cat /etc/logrotate.d/net_login || echo "(no /etc/logrotate.d/net_login)"
    LOG_DIR=$(cfg_get LOG_DIR); [ -z "$LOG_DIR" ] && LOG_DIR=$LOG_DIR_DEFAULT
    echo; echo "== logs ($LOG_DIR) =="
    ls -l "$LOG_DIR" 2>/dev/null || echo "(no logs yet, run once: $DEST/net_watch.sh once)"
    [ -f "$LOG_DIR/access.log" ] && { echo "--- access.log last 10 ---"; tail -n 10 "$LOG_DIR/access.log"; }
    [ -f "$LOG_DIR/error.log" ]  && { echo "--- error.log last 10 ---"; tail -n 10 "$LOG_DIR/error.log"; }
}

do_uninstall() {
    need_root
    if [ -f /etc/init.d/net_watch ]; then
        /etc/init.d/net_watch disable 2>/dev/null
        rm -f /etc/init.d/net_watch
        info "removed boot item /etc/init.d/net_watch"
    fi
    sed -i '/^# net_login:watch$/d;/net_watch.sh cron/d' "$CRONTAB" 2>/dev/null
    # remove the logrotate schedule only if we added it (marked by our comment)
    if grep -qF '# net_login:logrotate' "$CRONTAB" 2>/dev/null; then
        sed -i '/^# net_login:logrotate$/d;/logrotate \/etc\/logrotate.conf/d' "$CRONTAB" 2>/dev/null
    fi
    info "removed suite cron entries from $CRONTAB"
    [ -f /etc/logrotate.d/net_login ] && { rm -f /etc/logrotate.d/net_login; info "removed /etc/logrotate.d/net_login"; }
    echo
    info "uninstalled. scripts & logs kept in $DEST and the log dir; delete manually if wanted."
}

do_help() {
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    echo "  subcommands: install(default) / status / uninstall / help"
}

case "${1:-install}" in
    install)     do_install ;;
    status)      do_status ;;
    uninstall)   do_uninstall ;;
    help|-h|--h) do_help ;;
    *) echo "unknown subcommand: $1 (install/status/uninstall/help)"; exit 1 ;;
esac
