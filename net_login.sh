#!/bin/sh
# version: 1.1.0
# 校园网自动登录（纯 shell，busybox/OpenWrt 与桌面 Linux 通用，仅依赖 curl + openssl）
#
# 协议：抓登录页拿隐藏字段(sign/iv 等) -> 表单序列化成 query string
#       -> AES-128-CBC(ZeroPadding) 加密 -> base64 -> POST /gportal/web/authLogin
#       若服务端返回 reasoncode=43（账号已绑定其他设备），默认自动 POST /gportal/web/reBindMac
#       重绑到当前设备后再登录一次；设 REBIND=0 可关闭自动重绑。
#
# 运行依赖：curl、openssl（enc 加密 + base64 编码；OpenWrt: opkg install curl openssl-util）
# 其余只用 busybox/GNU 都带的基础工具：sed grep tr printf dd
# 注：不用 od/base64（部分 OpenWrt busybox 未编译这两个 applet），hex/base64 均由 openssl/printf 实现
DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$DIR/config.json"

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# 从扁平 config.json 里取字符串/数字值（仅适用于这种 KEY: value 的简单结构）
cfg_get() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"*\([^\",}]*\)\"*.*/\1/p" "$CONF" | head -n 1
}

USERID=$(cfg_get USERID)
PASSWD=$(cfg_get PASSWD)
LOGIN_URL=$(cfg_get LOGIN_URL)
AES_KEY=$(cfg_get AES_KEY)
TRYTIME_MAX=$(cfg_get TRYTIME_MAX)
[ -z "$TRYTIME_MAX" ] && TRYTIME_MAX=1
TIMEOUT=$(cfg_get TIMEOUT)
[ -z "$TIMEOUT" ] && TIMEOUT=3
REBIND=$(cfg_get REBIND)
[ -z "$REBIND" ] && REBIND=1

# 等价于 JS 的 encodeURIComponent。注：省略了 '!()* 这些不会出现的字符——
# 百分号编码可逆，服务端解密后再统一解码，得到的是同一份字段值。
urlencode() {
    s=$1 out= i=0
    while [ "$i" -lt "${#s}" ]; do
        c=${s:$i:1}
        case "$c" in
            [a-zA-Z0-9._~-]) out="${out}${c}" ;;
            *) out="${out}$(printf '%%%02X' "'$c")" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# 由码点输出该字符的 UTF-8 字节（\uXXXX 解码用）
utf8() {
    c=$1
    if [ "$c" -lt 128 ]; then
        printf "\\$(printf '%03o' "$c")"
    elif [ "$c" -lt 2048 ]; then
        printf "\\$(printf '%03o' "$((192 | (c >> 6)))")\\$(printf '%03o' "$((128 | (c & 63)))")"
    else
        printf "\\$(printf '%03o' "$((224 | (c >> 12)))")\\$(printf '%03o' "$((128 | ((c >> 6) & 63)))")\\$(printf '%03o' "$((128 | (c & 63)))")"
    fi
}

# 解码服务端 JSON 转义（\uXXXX、\n、\"、\\ 等），让日志显示可读中文而非 认 之类
deesc() {
    s=$1 out= i=0 n=${#s}
    while [ "$i" -lt "$n" ]; do
        c=${s:$i:1}
        if [ "$c" = '\' ]; then
            i=$((i + 1))
            c=${s:$i:1}
            case "$c" in
                u)  h=${s:$((i + 1)):4}; i=$((i + 4))
                    cp=$(printf '%d' "0x$h" 2>/dev/null) || cp=63
                    utf8 "$cp" ;;
                n)  printf '\n' ;;
                r)  printf '\r' ;;
                t)  printf '\t' ;;
                '"') printf '"' ;;
                '\') printf '\' ;;
                *)  printf '%s' '\' ; printf '%s' "$c" ;;
            esac
        else
            printf '%s' "$c"
        fi
        i=$((i + 1))
    done
}

# ASCII 字符串按字节转十六进制（替代 od|tr，纯 busybox 兼容）。
# key/iv 恒为 ASCII，逐字符 %02X 即可，无多字节问题。
hex_ascii() {
    s=$1 out= i=0
    while [ "$i" -lt "${#s}" ]; do
        c=${s:$i:1}
        out="${out}$(printf '%02X' "'$c")"
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# 取页面里 name 属性等于 $1 的 input 的 value（该页 name 恒在 value 之前，
# 各表单的隐藏字段块完全相同，取第一个即可）
html_field() {
    sed -n "s/.*name=\"$1\"[^>]*value=\"\([^\"]*\)\".*/\1/p" "$LOGIN_HTML" | head -n 1
}

# 从响应 JSON 取数字/裸值字段
resp_num() {
    sed -n "s/.*\"$1\":[[:space:]]*\"*\([0-9]*\)\"*.*/\1/p" "$RESP" | head -n 1
}

# 从响应 JSON 取字符串字段
resp_str() {
    sed -n "s/.*\"$1\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$RESP" | head -n 1
}

# 取响应 info 并去掉 JSON 转义与首尾空白
resp_info() {
    v=$(deesc "$(resp_str info)")
    printf '%s' "$v" | tr '\n\r' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# 按固定顺序把表单序列化成 query string（与浏览器/jQuery 一致）。
# 可选参数 $1：非空时覆盖 userMac（重绑定流程用服务端返回的 bindmac）。
build_qs() {
    mac_override=$1
    qs=
    for f in nasName nasIp userIp userMac ssid apMac pid vlan sign iv is_mobile; do
        if [ "$f" = userMac ] && [ -n "$mac_override" ]; then
            v=$mac_override
        else
            v=$(html_field "$f")
        fi
        qs="${qs:+$qs&}$(urlencode "$f")=$(urlencode "$v")"
    done
    qs="${qs}&$(urlencode name)=$(urlencode "$USERID")&$(urlencode password)=$(urlencode "$PASSWD")"
    printf '%s' "$qs"
}

# AES-128-CBC + ZeroPadding，输出单行 base64；$1=明文 query string，$2=iv
encrypt_qs() {
    eqs=$1 eiv=$2
    KEY_HEX=$(hex_ascii "$AES_KEY")
    IV_HEX=$(hex_ascii "$eiv")
    # ZeroPadding：openssl 默认是 PKCS7，需 -nopad + 手工补 0x00；明文整块时也要补满一块
    len=$(printf '%s' "$eqs" | wc -c)
    pad=$((16 - len % 16))
    { printf '%s' "$eqs"; dd if=/dev/zero bs=1 count="$pad" 2>/dev/null; } \
        | openssl enc -aes-128-cbc -e -nopad -K "$KEY_HEX" -iv "$IV_HEX" \
        | openssl base64 -A | tr -d '\n'
}

# 抓登录页，成功则设置全局 iv；返回 0=有表单，1=请求出错，2=无表单(已在线)
fetch_page() {
    curl -sS -m "$TIMEOUT" --noproxy '*' -A "$UA" \
        -c "$COOKIE" -b "$COOKIE" -o "$LOGIN_HTML" "$LOGIN_URL" || return 1
    grep -q frmLogin "$LOGIN_HTML" || return 2
    iv=$(html_field iv)
    [ -n "$iv" ] || return 1
    return 0
}

# 以 $1=query string、$2=iv 加密后 POST 到 $3，响应写入 $RESP
post_encrypted() {
    data=$(encrypt_qs "$1" "$2") || return 1
    curl -sS -m "$TIMEOUT" --noproxy '*' -A "$UA" -b "$COOKIE" -c "$COOKIE" \
        -H "Referer: $LOGIN_URL" \
        -H "Accept: application/json, text/javascript, */*; q=0.01" \
        --data-urlencode "data=$data" --data-urlencode "iv=$2" \
        -o "$RESP" "$3" || return 1
    return 0
}

# 返回码：0=已得到服务器结果(经 stdout 返回 OK:/FAIL:)，1=网络/页面出错，2=页面无表单(视为已在线)
do_login() {
    fetch_page; prc=$?
    if [ "$prc" -eq 2 ]; then
        echo "no login form frmLogin: already online or portal changed"; return 2
    fi
    [ "$prc" -eq 0 ] || { echo "login page fetch failed"; return 1; }

    AUTH_URL=$(printf '%s' "$LOGIN_URL" | sed 's|/login$|/authLogin|')
    qs=$(build_qs "")
    post_encrypted "$qs" "$iv" "${AUTH_URL}?round=$$" || return 1

    st=$(resp_num status)
    info=$(resp_info)
    if [ "$st" = 1 ]; then
        echo "OK:$info"
        return 0
    fi

    reason=$(resp_num reasoncode)
    bindmac=$(resp_str bindmac)

    if [ "$reason" = 43 ] && [ "$REBIND" != 0 ]; then
        REBIND_URL=$(printf '%s' "$LOGIN_URL" | sed 's|/login$|/reBindMac|')
        qs2=$(build_qs "$bindmac")
        post_encrypted "$qs2" "$iv" "${REBIND_URL}?round=$$" || { echo "FAIL:rebind request error"; return 0; }
        rst=$(resp_num status)
        rinfo=$(resp_info)
        if [ -z "$rst" ] || [ "$rst" = 0 ]; then
            echo "FAIL:rebind refused: $rinfo"
            return 0
        fi
        echo "rebind ok: $rinfo" >&2

        # 重绑后服务器通常要求重新认证：重新抓页面再登录一次
        fetch_page; prc=$?
        if [ "$prc" -eq 2 ]; then
            echo "OK:rebound, already online"
            return 0
        fi
        [ "$prc" -eq 0 ] || { echo "FAIL:rebound but relogin page fetch failed"; return 0; }
        qs=$(build_qs "")
        post_encrypted "$qs" "$iv" "${AUTH_URL}?round=$$" || { echo "FAIL:rebound but relogin request error"; return 0; }
        st=$(resp_num status)
        info=$(resp_info)
        if [ "$st" = 1 ]; then
            echo "OK:rebound to this device, $info"
            return 0
        fi
        echo "FAIL:rebound but login still failed: $info"
        return 0
    fi

    if [ "$reason" = 43 ] && [ "$REBIND" = 0 ]; then
        echo "FAIL:$info (auto-rebind disabled)"
        return 0
    fi

    echo "FAIL:$info"
    return 0
}

main() {
    TMP=$(mktemp -d) || { echo "cannot create temp dir"; exit 1; }
    trap 'rm -rf "$TMP"' EXIT
    LOGIN_HTML="$TMP/login.html"; COOKIE="$TMP/cookie"; RESP="$TMP/resp.json"

    attempt=0
    while [ "$attempt" -lt "$TRYTIME_MAX" ]; do
        attempt=$((attempt + 1))
        res=$(do_login); rc=$?
        if [ "$rc" -eq 2 ]; then
            echo "$res"; return 0                 # 页面无表单：已在线，无需重试
        fi
        if [ "$rc" -ne 0 ]; then
            echo "[$attempt/$TRYTIME_MAX] network/request error"
            [ "$attempt" -lt "$TRYTIME_MAX" ] && sleep 5
            continue
        fi
        case "$res" in
            OK:*)
                echo "Login success: ${res#OK:}"
                return 0 ;;
            FAIL:*)
                echo "[$attempt/$TRYTIME_MAX] login failed: ${res#FAIL:}"
                [ "$attempt" -lt "$TRYTIME_MAX" ] && sleep 5  # server rate-limits ~5s
                ;;
            *)
                # 中间步骤信息（如 rebind ok），继续看最终结果
                echo "$res" ;;
        esac
    done
    return 1
}

# 运行时执行主流程；被 source 做单元测试时先 export NET_LOGIN_TEST=1 跳过
if [ -z "${NET_LOGIN_TEST:-}" ]; then
    main "$@"
fi
