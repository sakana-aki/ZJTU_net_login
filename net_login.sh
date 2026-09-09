#!/bin/sh
# 校园网自动登录（纯 shell，busybox/OpenWrt 与桌面 Linux 通用，无第三方依赖）
#
# 协议：抓登录页拿隐藏字段(sign/iv 等) -> 表单序列化成 query string
#       -> AES-128-CBC(ZeroPadding) 加密 -> base64 -> POST /gportal/web/authLogin
#
# 运行依赖：curl、openssl enc（OpenWrt: opkg install curl openssl-util）
# 其余只用 busybox/GNU 都带的基础工具：sed grep od tr base64 printf dd
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

# 取页面里 name 属性等于 $1 的 input 的 value（该页 name 恒在 value 之前，
# 各表单的隐藏字段块完全相同，取第一个即可）
html_field() {
    sed -n "s/.*name=\"$1\"[^>]*value=\"\([^\"]*\)\".*/\1/p" "$LOGIN_HTML" | head -n 1
}

# 按固定顺序把表单序列化成 query string（与浏览器/jQuery 一致）
build_qs() {
    qs=
    for f in nasName nasIp userIp userMac ssid apMac pid vlan sign iv is_mobile; do
        v=$(html_field "$f")
        qs="${qs:+$qs&}$(urlencode "$f")=$(urlencode "$v")"
    done
    qs="${qs}&$(urlencode name)=$(urlencode "$USERID")&$(urlencode password)=$(urlencode "$PASSWD")"
    printf '%s' "$qs"
}

# 返回码：0=已得到服务器结果(经 stdout 返回 OK:/FAIL:)，1=网络/页面出错，2=页面无表单(视为已在线)
do_login() {
    curl -sS -m "$TIMEOUT" -A "$UA" -c "$COOKIE" -b "$COOKIE" -o "$LOGIN_HTML" "$LOGIN_URL" || return 1
    grep -q frmLogin "$LOGIN_HTML" || { echo "页面里没有登录表单 frmLogin：可能已在线或门户改版"; return 2; }

    iv=$(html_field iv)
    qs=$(build_qs)

    # AES 前要把 key/iv 的"ASCII 字节"转 hex 喂给 openssl。
    # 页面 iv 如 ff4bf146fa787de3 是 16 个字符当 UTF-8 字节用，不是十六进制解码。
    KEY_HEX=$(printf '%s' "$AES_KEY" | od -A n -t x1 | tr -d ' \n')
    IV_HEX=$(printf '%s' "$iv"      | od -A n -t x1 | tr -d ' \n')
    # ZeroPadding：openssl 默认是 PKCS7，需 -nopad + 手工补 0x00；明文整块时也要补满一块
    len=$(printf '%s' "$qs" | wc -c)
    pad=$((16 - len % 16))
    data=$({ printf '%s' "$qs"; dd if=/dev/zero bs=1 count="$pad" 2>/dev/null; } \
           | openssl enc -aes-128-cbc -e -nopad -K "$KEY_HEX" -iv "$IV_HEX" \
           | base64 | tr -d '\n')

    auth_url=$(printf '%s' "$LOGIN_URL" | sed 's|/login$|/authLogin|')
    curl -sS -m "$TIMEOUT" -A "$UA" -b "$COOKIE" -c "$COOKIE" \
        -H "Referer: $LOGIN_URL" \
        -H "Accept: application/json, text/javascript, */*; q=0.01" \
        --data-urlencode "data=$data" --data-urlencode "iv=$iv" \
        -o "$RESP" "${auth_url}?round=$$" || return 1

    st=$(sed -n 's/.*"status":[[:space:]]*\([0-9]*\).*/\1/p' "$RESP" | head -n 1)
    info=$(sed -n 's/.*"info":"\([^"]*\)".*/\1/p' "$RESP" | head -n 1)
    if [ "$st" = 1 ]; then
        echo "OK:$info"
    else
        echo "FAIL:$info"
    fi
}

main() {
    TMP=$(mktemp -d) || { echo "无法创建临时目录"; exit 1; }
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
            echo "[第 $attempt/$TRYTIME_MAX 次] 网络/请求出错"
            [ "$attempt" -lt "$TRYTIME_MAX" ] && sleep 5
            continue
        fi
        case "$res" in
            OK:*)
                echo "登录成功：${res#OK:}"
                return 0 ;;
            FAIL:*)
                echo "[第 $attempt/$TRYTIME_MAX 次] 登录失败：${res#FAIL:}"
                [ "$attempt" -lt "$TRYTIME_MAX" ] && sleep 5  # 服务端约 5s 限流
                ;;
        esac
    done
    return 1
}

# 运行时执行主流程；被 source 做单元测试时先 export NET_LOGIN_TEST=1 跳过
if [ -z "${NET_LOGIN_TEST:-}" ]; then
    main "$@"
fi
