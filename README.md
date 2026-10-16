# 黄河交通学院（ZJTU）校园网自动登录 — OpenWrt 路由版

> 路由器专用套件，主体为 Shell 版，在 OpenWrt / busybox 上运行：
> **周期检测连通性 → 离线自动恢复（链路断则重跑 DHCP，掉线则重登门户）→ access/error 日志 + logrotate 轮转**。
> 定时交给系统 cron（分钟级触发、json 里配检测间隔），开机后自动先检测一次。
>
> 另附早期的 Python 登录脚本 `net_login.py`，**保留作参考**；路由器上请用
> `net_login.sh`。仅含 Shell 版的精简版见 `openwrt` 分支。

---

## ⚠️ 免责声明（请务必阅读）

本套件由 **AI 辅助生成**，仅用于**学习与交流**目的，**不附带任何形式的保证**。

- 你**只能**使用自己的账号，通过正规渠道完成校园网认证登录。
- 严禁将本套件用于或变相用于任何**未经授权**的行为：登录他人账号、撞库 /
  爆破 / 批量尝试、绕过或干扰认证与网络、盗用他人身份、二次分发或商业售卖等。
- 校园网认证涉及账号、网络与信息安全，违规使用可能违反学校管理规定及相关
  法律法规，需承担相应法律责任。
- 作者不对脚本正确性、可用性、安全性作任何担保；因网络环境、门户改版等原因
  造成的失效不负责；使用者一切后果（含网络故障、账号封禁、学校处分、法律纠纷）
  均由使用者自行承担。

不同意请勿使用。

---

## 文件说明

部署目录建议 `/root/net_login/`：

| 文件 | 作用 |
| --- | --- |
| `net_login.sh` | **登录**脚本（抓表单 → AES 加密 → POST `/gportal/web/authLogin`）。保持纯输出，供检测脚本调用 |
| `net_login.py` | 早期 Python 版登录脚本，**保留作参考**（不参与路由器套件） |
| `net_watch.sh` | **检测/自愈**主脚本：HTTP 204 探测判离线（ICMP 不可靠，见下文）→ 网关 ARP 死则 `ifup wan` 重跑 DHCP、链路正常则调 `net_login.sh` 重登 → 写日志 |
| `net_switch.sh` | **日常开关**：回校 `on` / 放假 `off` / `status`，只启停检测 cron 与开机自启 |
| `config.json` | 配置（账号密码 + 检测间隔 + 日志/连通目标）。**为示例占位，需填入真实账号** |
| `install.sh` | 一次性部署 / 状态查看 / 卸载 |

依赖工具：`curl`、`openssl-util`（登录）、`logrotate`（日志轮转）、`jq`（安装时校验配置，可选）。
`net_login.sh` / `net_watch.sh` / `net_switch.sh` 运行时只用 busybox 自带工具解析配置，**不依赖 jq**。

---

## 一、快速开始（一键）

把所有文件放到路由器 `/root/net_login/`，编辑 `config.json` 填入真实账号后：

```sh
# 需 root（OpenWrt ssh 登录即 root）
cd /root/net_login
sh install.sh
```

`install.sh` 会：检测 `curl/openssl-util/logrotate/jq`，缺失则 `opkg` 自动安装 →
写 `/etc/logrotate.d/net_login` → 往 `/etc/crontabs/root` 加每分钟检测项 →
注册开机自启 `/etc/init.d/net_watch` → 立即检测一次。

> 依赖安装失败（如没网）可先手动：`opkg update && opkg install curl openssl-util logrotate jq`，再重跑。

---

## 二、纯手动部署

不想用安装脚本时，按下面步骤操作，效果等价。

### 1. 放文件并改配置

```sh
mkdir -p /root/net_login
# 把 net_login.sh net_watch.sh net_switch.sh config.json install.sh 放进来
vi /root/net_login/config.json   # 填真实账号密码，按需调 CHECK_INTERVAL 等
chmod +x /root/net_login/net_login.sh /root/net_login/net_watch.sh /root/net_login/net_switch.sh
```

### 2. 写 logrotate

日志分两处：`access.log` 在 `LOG_DIR`（默认 `/var/log/net_login`，tmpfs，重启即清）；
`error.log` 在 `ERR_LOG_DIR`（默认脚本同目录的 `logs/`，**落 flash，重启保留**）。

```sh
mkdir -p /root/net_login/logs        # error.log 的持久化目录（按 config 的 ERR_LOG_DIR 调整）
cat > /etc/logrotate.d/net_login <<'EOF'
# 策略：access 按大小 0.5MB（tmpfs）；error 按天，保留 3 天，昨天的(.1)不压缩(delaycompress)
/var/log/net_login/access.log {
    size 500k
    rotate 2
    compress
    missingok
    notifempty
    create 0644 root root
}
/root/net_login/logs/error.log {
    daily
    rotate 3
    delaycompress
    compress
    missingok
    notifempty
    create 0644 root root
}
EOF
# 若改了 config.json 的 LOG_DIR / ERR_LOG_DIR，请同步改上面两段里的日志路径
```

### 3. 加每分钟 cron

```sh
cat >> /etc/crontabs/root <<'EOF'
# net_login:watch
* * * * * PATH=/usr/bin:/bin /root/net_login/net_watch.sh cron
EOF
```

logrotate 本身也需定时触发（若无全局调度则补一条每日）：

```sh
grep -q 'logrotate /etc/logrotate.conf' /etc/crontabs/root || cat >> /etc/crontabs/root <<'EOF'
# net_login:logrotate
0 4 * * * /usr/sbin/logrotate /etc/logrotate.conf
EOF
```

### 4. 开机后立即检测一次

```sh
cat > /etc/init.d/net_watch <<'EOF'
#!/bin/sh /etc/rc.common
# 开机后立即检测一次（周期检测由 cron 负责）
START=99
start() {
    /root/net_login/net_watch.sh once
}
EOF
chmod +x /etc/init.d/net_watch
/etc/init.d/net_watch enable
```

### 5. 首次手动验证

```sh
/root/net_login/net_watch.sh once
tail -f /var/log/net_login/access.log
```

---

## 三、日常开关（放假 `off` / 回校 `on`）

放假在家不需要自动登录时，关掉检测与开机自启即可；回校再打开。以 root 运行：

```sh
# 回校/需要自动登录：开启每分钟检测 + 开机自启
sh /root/net_login/net_switch.sh on        # 或 start / enable

# 放假/在家：关闭（无需再动 config、logrotate、脚本与日志）
sh /root/net_login/net_switch.sh off       # 或 stop / disable

# 查看当前开关状态与最近日志
sh /root/net_login/net_switch.sh status
```

行为说明：

- **`off` 只停掉**：每分钟检测 cron 条目 + 开机自启（`/etc/init.d/net_watch`），并终止
  正在运行的检测进程。logrotate 配置与其每日调度**保留**（无新日志时 `notifempty`
  自动跳过，无副作用，回校也无需重配）。
- **`on`**：幂等恢复上述 cron 与开机自启。不会立即登录；若想马上检测一次，执行
  `net_watch.sh once`。回校一般路由器开机即由自启触发登录，无需手动。
- 每次开关都会往 `access.log` 写一条 `net_switch: ...` 历史记录，方便回看。
- 开关基于「cron 条目 / init 文件是否存在」判定，状态通过 `status` 随时可查。

---

## 四、`config.json` 字段

```json
{
  "USERID": "your_student_id",
  "PASSWD": "your_password",
  "LOGIN_URL": "http://10.18.1.3/gportal/web/login",
  "AES_KEY": "1234567887654321",
  "TRYTIME_MAX": 3,
  "TIMEOUT": 3,
  "CHECK_INTERVAL": 300,
  "HEAL_INTERVAL": 600,
  "LOG_DIR": "/var/log/net_login",
  "ERR_LOG_DIR": "/root/net_login/logs",
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
| `USERID` / `PASSWD` | 占位 | **真实**学号/手机号/宽带账号 与 密码 |
| `LOGIN_URL` | `http://10.18.1.3/gportal/web/login` | 认证登录页（黄河交通/ZJTU 门户） |
| `AES_KEY` | `1234567887654321` | 门户前端固定加密密钥，一般勿改 |
| `TRYTIME_MAX` | `3` | 登录失败最大重试次数 |
| `TIMEOUT` | `3` | 单次网络请求超时（秒） |
| `CHECK_INTERVAL` | `300` | 检测间隔（**秒**）。cron 每分钟触发一次，内部按此节流，故实际粒度 ≥60s |
| `HEAL_INTERVAL` | `600` | 判定「链路断（网关 ARP 死）」后重跑 DHCP（`ifup wan`）的最小间隔（**秒**）。恢复需数分钟，故两次自愈之间至少间隔这么久，避免猛刷 |
| `LOG_DIR` | `/var/log/net_login` | **access.log** 目录（默认 tmpfs，重启清空） |
| `ERR_LOG_DIR` | 脚本同目录 `logs/` | **error.log** 目录，**应指向 flash**（如 `/root/net_login/logs`），重启后仍保留历史错误 |
| `HTTP_CHECK_URLS` | vivo/hicloud 两个 `generate_204` | 空格分隔的**在线判据**：任一返回 `HTTP_CHECK_CODE` 即视为在线。走 DIRECT，测的是校园真实数据面，**不用 ICMP**（见下方说明） |
| `HTTP_CHECK_CODE` | `204` | 期望的 HTTP 状态码；门户劫持/重定向时会返回 302/200，即判为离线 |
| `HTTP_TIMEOUT` | `5` | 单次 HTTP 探测超时（秒） |
| `FOREIGN_CHECK_URL` | 空（跳过） | 可选。填一个境外 `generate_204`（如 `http://www.gstatic.com/generate_204`）可区分「代理挂了」还是「校园挂了」；留空则不探测 |
| `PING_TARGETS` | `223.5.5.5 114.114.114.114` | 仅在无 `curl` 时作为在线判据的兜底；同时用于离线快照里的 ping 记录 |
| `PING_COUNT` / `PING_WAIT` | `2` / `2` | 每个目标的 ping 次数与每包等待秒数 |

> **为什么不用 ping 判在线**：校园认证失效/被踢时，ICMP 常常**仍然通**（很多门户只拦
> TCP/DNS），此时纯 ping 会一直判 `online`，永远不会触发重登——这正是「重启才好一次」
> 的根源之一。改用国内 HTTP 204 探测后，「ICMP 通但数据面死」也会被判离线并自动重登。

> ⚠️ `config.json` 含账号密码，**请勿提交到公开仓库**。本仓库仅提供占位示例。

---

## 五、日志与排错

### 日志文件（英文、精简）

两个日志**分开放**，各取所需：

- `$LOG_DIR/access.log`（默认 `/var/log/net_login`，**tmpfs，重启清空**）：每次实际检测的
  结果 —— `online` / `online (foreign recovered)` / `recovered` /
  `net_switch: enabled|disabled`（开关轨迹）。高频、体积大，故留在内存盘。
- `$ERR_LOG_DIR/error.log`（默认脚本同目录 `logs/`，**落 flash，重启保留**）：写**故障现场**
  与登录失败原因。校园侧异常按「状态变化」记一条带快照的行；`foreign path down` 记代理侧
  异常；登录失败记退出码与服务端原因。低频、体积小，且是排错时最想回看的，故持久化。

行格式（统一单行，方便 `grep`）：

```
2026-09-10 08:00:00 INFO  online
2026-09-10 08:05:00 INFO  recovered
2026-09-10 08:06:00 ERROR L2 down (gw=10.20.1.1 arp INCOMPLETE), re-DHCP: ifup wan
2026-09-10 08:12:00 INFO  recovered (L2 link back)
2026-09-10 08:20:00 ERROR offline [ping: 223.5.5.5=no 114.114.114.114=no cn_http=000 foreign_http=000 portal_http=000]
2026-09-10 08:21:00 ERROR foreign path down (domestic ok) [ping: 223.5.5.5=ok cn_http=204 foreign_http=000 portal_http=403]
2026-09-10 08:22:00 ERROR login failed rc=1: [3/3] login failed: 账号或密码错误
```

> **离线快照**：`offline [...]` 那一行是现场证据，用来一眼分清是谁挂了——
> - `cn_http=204` + `foreign_http=000`：校园好、**代理/节点挂了**；
> - `cn_http` 非 204/000：**校园侧**（掉线/被踢/门户劫持）；
> - 全 `000` 且 ping 全 `no`：WAN 链路或上游问题。
>
> 失败原因取自门户返回，可能是中文；access 只保留极短标记，诊断详情全部进 error.log。

查看方式：

```sh
tail -f /var/log/net_login/access.log          # 实时看检测/登录（tmpfs）
tail -f /root/net_login/logs/error.log         # 只看失败（flash，重启后仍能回看）
sh /root/net_login/install.sh status           # 一行看配置+两份日志摘要
```

### 轮转

`/etc/logrotate.d/net_login`（install.sh 写入，两段各自独立策略）：

| 日志 | 位置 | 策略 |
| --- | --- | --- |
| `access.log` | tmpfs | `size 500k` 超过 0.5MB 触发；保留 2 份 gzip |
| `error.log` | flash | `daily` 每天切一次；保留 3 份；`delaycompress` 昨天的（`.1`）不压缩 |

触发时机：系统 cron 里的 logrotate 条目（install.sh 默认加每日 04:00；
若系统已有全局 logrotate 调度则跳过）。手动验证：

```sh
/usr/sbin/logrotate -d /etc/logrotate.conf      # 试运行(dry-run)
ls /var/log/net_login/ /root/net_login/logs/    # 看到 .1 / .1.gz 即已轮转
```

### 减小存储占用（路由器 flash / RAM）

- **只有 error.log 落 flash**：高频的 `access.log` 留在 tmpfs（内存盘），只有低频、体积小、
  排错最想回看的 `error.log` 写到 flash，兼顾省 flash 与可追溯。用 `df /var/log` 先确认
  `/var/log` 是否软链到 `/tmp`（OpenWrt 常见）。
- 日志文案已精简为英文短标记；离线失败只写**一条** error（此前会重复整段重试记录）。
- 检测时间戳、互斥锁都放 `/tmp`（`LOG_DIR/.watch.lock`），不落 flash。
- logrotate 用 rename+create（非 copytruncate），轮转时**不整份拷贝**日志，少写 flash。
- 脚本自身很小；想再省可删除各 `.sh` 内注释后部署。
- 不想让 error.log 也落 flash 时，把 `ERR_LOG_DIR` 指回 tmpfs（如 `/var/log/net_login`）即可，
  代价是重启后历史错误丢失。

### 常见问题

| 现象 | 处理 |
| --- | --- |
| **找不到 error.log**（文件不存在） | 正常：只在出现离线/代理异常/登录失败时才有内容，一直 online 就没有该行；`ls $ERR_LOG_DIR` 确认，或手动 `net_watch.sh once` 触发 |
| error.log 重启后不见了 | 说明 `ERR_LOG_DIR` 落在了 tmpfs。改到 flash（默认 `/root/net_login/logs`），并在 logrotate 里同步该路径 |
| error.log 一直 `login failed: 账号不存在/密码错误` | 检查 config.json 真实账号；看服务端返回原因 |
| error.log 出现 `操作过于频繁/请求过快` | 门户限流约 5s，勿高频触发；已内置重试间隔 |
| error.log 出现 `offline [cn_http=000 ...]` 但门户页能打开 | 探测 URL 被你这的网络拦了。换 `HTTP_CHECK_URLS` 成可达的国内 204 地址，或把 `HTTP_CHECK_CODE` 调成实际返回码 |
| error.log 反复 `foreign path down (domestic ok)` | 校园好、**代理/节点挂了**：这是机场问题，不是脚本。去 OpenClash 换节点，或把兜底规则从手动 `select` 组改到 `fallback`/`url-test` 组以自动切换 |
| error.log 出现 `L2 down (... arp INCOMPLETE), re-DHCP: ifup wan` | 校园**接入层丢二层**（网关不再应答 ARP，多在凌晨），脚本已自动 `ifup wan` 重跑 DHCP 自愈，**无需再手动重启路由器**；号变 `recovered (L2 link back)` 即恢复。若长期频繁，属校园侧问题，可找网络中心 |
| access.log 一直 `online` 但断网没重登 | 旧版用 ping 判在线才会有此问题；现版用 HTTP 204 判据，若仍复现请检查 `HTTP_CHECK_URLS` 是否被劫持 |
| access.log 无新行 | 检查 cron 是否启用（`/etc/init.d/cron start`）、`/etc/crontabs/root` 是否有条目、手动跑一次看报错 |
| 想区分设备/校园/代理故障 | 直接看 error.log 的 `offline [...]` 快照：`cn_http` 正常而 `foreign_http=000` → 代理；`cn_http` 异常 → 校园；全 000 且 ping 全 no → WAN |
| 忘了检测开没开 | `sh /root/net_login/net_switch.sh status` 看 cron/自启/最近日志（state ON/OFF） |
| 想确认关闭后什么都不跑 | `net_switch.sh off` 已移除 cron 与自启并终止在跑的检测；`status` 显示 `OFF` 即为空 |
| 「已在线」却不触发重登 | net_login.sh 若页面无登录表单会视为已在线直接返回，属预期保护，避免重复认证 |
| 路由器重启后日期/时间错乱 | 时间戳与日志时间依赖系统时钟，先同步时间（`ntpd -n -q -p ntp.aliyun.com`） |
| 没装 logrotate / 没轮转 | `opkg install logrotate`，确认 cron 有 logrotate 调度（见上） |

---

## 六、调度原理

- **cron**：`* * * * * net_watch.sh cron` 每分钟唤醒一次；脚本读时间戳，距上次
  实际检测 `< CHECK_INTERVAL` 秒则直接跳过（不写日志），因此间隔由 json 精确控制，
  改值即时生效、无需重装 cron。
- **开机首检**：`/etc/init.d/net_watch`（`START=99`）开机即执行 `once`；时间戳存
  `/tmp`（重启清零），即便 init 未触发，重启后第一次 cron 也必然补检。
- **防重入**：锁文件存 PID，检测过程超过 1 分钟时下一 tick 会跳过，不重复登录。
- **判定与自愈**：逐个请求 `HTTP_CHECK_URLS`（国内、DIRECT），任一返回 `HTTP_CHECK_CODE`
  即在线；全不匹配视为离线。离线时按链路状态分两种：
  - **链路断**：默认网关的 ARP 为 `INCOMPLETE`/`FAILED`（校园接入层不再应答 ARP，本地二层
    已断）→ 记 `L2 down` 并执行 `ifup wan` 重跑 DHCP（两次之间至少隔 `HEAL_INTERVAL` 秒，
    因恢复需数分钟）。链路死时门户登录必然失败，故**不**调登录。
  - **链路正常**（校园 de-auth）：记一行快照（`offline [...]`）后调 `net_login.sh` 一次
    （其内部自带重试与「已在线则免登」判断）。
  - 若配置了 `FOREIGN_CHECK_URL`，国内通而它不通则记为 `foreign path down`（代理侧），
    **不触登录**，仅留证据。

---

## 七、`install.sh` 子命令

| 命令 | 作用 |
| --- | --- |
| `sh install.sh` | 部署（见「快速开始」） |
| `sh install.sh status` | 查看部署目录 / 开机项 / cron / logrotate / 最近日志 |
| `sh install.sh uninstall` | 移除开机项、cron 条目与 logrotate 配置（**不删**脚本、配置与日志） |
| `sh install.sh help` | 帮助 |

---

## License

仅用于学习交流，请遵守相关法律法规与学校网络管理规定。
