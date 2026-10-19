# 校园网自动登录（OpenWrt 路由版）

在 OpenWrt / busybox 路由器上定时检测网络：在线时保持静默；掉认证自动重新登录；
链路 / DHCP 异常（校园接入层故障）时自动 `ifup wan` 重跑 DHCP 恢复。

登录为纯 Shell 实现，不依赖 Python。协议：抓取登录页隐藏字段 →
AES-128-CBC（ZeroPadding）加密 → POST `/gportal/web/authLogin`。

> `net_login.py` 是早期 Python 参考实现，不参与路由器套件。

## 免责声明

本套件仅用于学习与交流，请只使用**自己的账号**通过正规渠道完成认证。

禁止用于登录他人账号、撞库、爆破、批量尝试、绕过或干扰认证、盗用身份、
二次分发或商业售卖。因使用本套件造成的一切后果由使用者自行承担；
作者不对脚本的可用性与安全性作任何担保。不同意请勿使用。

## 文件与依赖

| 文件 | 作用 |
| --- | --- |
| `net_login.sh` | 登录脚本：抓表单 → AES 加密 → 提交认证 |
| `net_watch.sh` | 检测 / 自愈：HTTP 204 判在线，掉认证重登，链路异常时重跑 DHCP |
| `net_switch.sh` | 日常开关：回校 `on`、放假 `off`、`status` 查看 |
| `install.sh` | 一键安装 / 状态 / 卸载 |
| `config.json` | 账号与检测参数（仓库内为占位示例） |
| `net_login.py` | 早期 Python 参考实现 |

运行依赖：`curl`、`openssl-util`、`logrotate`。`jq` 可选，仅用于安装时校验 JSON 语法。

## 快速开始

```sh
# 1. 把文件放到路由器 /root/net_login，填入真实账号
vi /root/net_login/config.json

# 2. 安装（需要 root，OpenWrt ssh 登录即 root）
cd /root/net_login && sh install.sh
```

`install.sh` 会补齐缺失依赖，写入 logrotate 配置、每分钟检测 cron 和开机自启，
然后立即检测一次。

```sh
sh install.sh status      # 查看部署状态与最近日志
sh install.sh uninstall   # 移除 cron / 自启 / logrotate 配置（保留脚本、配置与日志）
```

## 日常开关

```sh
sh net_switch.sh on       # 回校：恢复每分钟检测 + 开机自启
sh net_switch.sh off      # 放假：停止检测与开机自启（保留日志与 logrotate 配置）
sh net_switch.sh status   # 查看当前状态与最近日志
```

`on` 不会立即登录；需要马上检测时运行 `net_watch.sh once`。
回校后路由器开机自启会先检测一次，通常无需手动操作。

## 配置

```json
{
  "USERID": "your_student_id",
  "PASSWD": "your_password",
  "LOGIN_URL": "http://10.18.1.3/gportal/web/login",
  "AES_KEY": "1234567887654321",
  "TRYTIME_MAX": 3,
  "TIMEOUT": 3,
  "CHECK_INTERVAL": 300,
  "ERROR_REPEAT_INTERVAL": 3600,
  "HEAL_INTERVAL": 600,
  "LOG_DIR": "/root/net_login/logs",
  "PING_TARGETS": "223.5.5.5 114.114.114.114",
  "PING_COUNT": 2,
  "PING_WAIT": 2,
  "HTTP_CHECK_URLS": "http://wifi.vivo.com.cn/generate_204 http://connectivitycheck.platform.hicloud.com/generate_204",
  "HTTP_CHECK_CODE": 204,
  "HTTP_TIMEOUT": 5,
  "FOREIGN_CHECK_URL": ""
}
```

| 字段 | 默认 | 含义 |
| --- | --- | --- |
| `USERID` / `PASSWD` | 占位 | 真实学号 / 手机号与密码 |
| `LOGIN_URL` | 校园门户地址 | 认证登录页 |
| `AES_KEY` | `1234567887654321` | 门户前端固定密钥，一般勿改 |
| `TRYTIME_MAX` | `3` | 登录失败重试次数 |
| `TIMEOUT` | `3` | 单次请求超时（秒） |
| `CHECK_INTERVAL` | `300` | 检测间隔（秒）。cron 每分钟触发，内部按此节流 |
| `ERROR_REPEAT_INTERVAL` | `3600` | 同一故障写 error.log 的抑制窗口（秒） |
| `HEAL_INTERVAL` | `600` | 两次 `ifup wan` 自愈之间的最小间隔（秒） |
| `LOG_DIR` | `/root/net_login/logs` | access.log 与 error.log 的共同目录 |
| `HTTP_CHECK_URLS` | 国内两个 `generate_204` | 在线判据：任一返回期望状态码即在线 |
| `HTTP_CHECK_CODE` | `204` | 期望的 HTTP 状态码 |
| `HTTP_TIMEOUT` | `5` | 单次 HTTP 探测超时（秒） |
| `FOREIGN_CHECK_URL` | 空（跳过） | 可选境外 204 地址，用于区分「代理挂了」和「校园挂了」 |
| `PING_TARGETS` / `PING_COUNT` / `PING_WAIT` | 见示例 | 仅用于离线快照与无 curl 时的兜底判据 |

> `config.json` 含账号密码，请勿提交到公开仓库。

## 日志

两个日志同目录，默认 `/root/net_login/logs`（在 flash 上，重启保留）：

- `access.log`：每次实际检测与恢复动作，如 `online`、`recovered`、`ifup wan`。
- `error.log`：故障现场、登录失败原因、代理 / 外网异常。

```sh
tail -f /root/net_login/logs/access.log
tail -f /root/net_login/logs/error.log
```

轮转由 `/etc/logrotate.d/net_login` 控制：`access.log` 每日切分保留 2 份；
`error.log` 每日切分保留 3 份（当前 + `.1` + 压缩的 `.2.gz`）。
重复的同一故障按 `ERROR_REPEAT_INTERVAL` 去重，不会刷日志。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| `error.log` 不存在或为空 | 正常：只记录故障，一直在线就没有内容 |
| 一直 `login failed: 账号不存在 / 密码错误` | 检查 `config.json` 中的账号密码 |
| 提示 `操作过于频繁 / 请求过快` | 门户限流约 5 秒，脚本已内置重试间隔，降低触发频率即可 |
| `access.log` 一直 `online` 但实际断网 | 探测地址可能被网络拦截，换一个可达的国内 204 地址或调整 `HTTP_CHECK_CODE` |
| 反复出现 `foreign path down (domestic ok)` | 校园网正常、代理节点故障：更换节点或改用自动测速分组 |
| 出现 `link/DHCP down (...), re-DHCP: ifup wan` | 校园接入层异常，脚本已自动重跑 DHCP；状态变为 `recovered` 即恢复 |
| 日志不再更新 | 检查 cron 是否运行、`/etc/crontabs/root` 是否有检测条目，并手动运行 `net_watch.sh once` 看报错 |
| 日志时间错乱 | 系统时钟未同步：`ntpd -n -q -p ntp.aliyun.com` |
| 忘记检测是否开启 | `sh net_switch.sh status` 查看 `state: ON/OFF` |

## 工作原理

- cron 每分钟触发一次，脚本按 `CHECK_INTERVAL` 节流；开机时由 init 脚本先检测一次。
- 在线判据是国内 HTTP 204，而不是 ICMP——认证失效时 ICMP 往往仍通。
- 离线时自动分类：门户不可达 / 无默认路由 / 网关 ARP 失败 → `ifup wan` 重跑 DHCP；
  门户可达但认证失效 → 调用 `net_login.sh` 重新登录。
- 锁文件防止重复执行；运行状态保存在 `/tmp`，重启后第一次检查必然执行。
- 配置 `FOREIGN_CHECK_URL` 后，可额外区分代理故障与校园网故障。

## License

仅用于学习交流，请遵守相关法律法规与学校网络管理规定。
