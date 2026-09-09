# 黄河交通学院（ZJTU）校园网自动登录

> 适配黄河交通 / ZJTU 校园网认证门户的自动登录脚本。Python 与 Shell 双版本，
> 逻辑一致、可互相替代；仅负责**发起登录**，不做在线状态检查等其他事情。

---

## ⚠️ 免责声明（请务必阅读）

本仓库所有脚本内容由 **AI 辅助生成**，仅用于**学习与交流**目的，**不附带任何形式的保证**。

- 你**只能**使用自己的账号，通过正规渠道完成校园网认证登录。
- 严禁将本脚本用于或变相用于任何**未经授权**的行为，包括但不限于：
  登录他人账号、撞库 / 爆破 / 批量尝试、绕过或干扰认证与网络、盗用他人身份、
  二次分发或商业售卖等。
- 校园网认证涉及账号、网络与信息安全，违规使用可能违反学校管理规定及
  相关法律法规，甚至需承担相应法律责任。

**责任划分**

- 作者仅提供脚本本身，**不对脚本的正确性、可用性、安全性作任何明示或
  默示的担保**；因网络环境、门户改版等原因造成的失效亦不负责。
- 使用者因下载、使用、复制、修改或分发本脚本而产生的一切后果——
  包括但不限于网络故障、账号封禁、学校处分、法律纠纷、经济损失——
  **均由使用者自行承担**。
- 若使用者存在不正确、非法或违规使用本脚本的行为，**作者不承担任何形式的责任**。

不同意上述条款，请勿下载、使用或分发本仓库内容。

---

## 文件说明

仓库根目录共三个文件（一层结构）：

| 文件 | 作用 | 运行环境 / 依赖 |
| --- | --- | --- |
| `net_login.py` | Python 版登录脚本 | Python 3 + `requests`、`beautifulsoup4`、`pycryptodome` |
| `net_login.sh` | Shell 版登录脚本 | `curl`、`openssl` + 基础工具（桌面 Linux / OpenWrt 通用） |
| `config.json` | 配置文件（示例） | 账号、密码、门户地址等参数，脚本启动时读取 |

> `config.json` 中为**示例占位内容**，使用前请填入你自己的信息。

---

## 使用教程

### 1. 修改配置 `config.json`

用文本编辑器打开 `config.json`，填入自己的账号密码：

```json
{
  "USERID": "your_student_id",
  "PASSWD": "your_password",
  "LOGIN_URL": "http://10.18.1.3/gportal/web/login",
  "AES_KEY": "1234567887654321",
  "TRYTIME_MAX": 3,
  "TIMEOUT": 3
}
```

| 字段 | 含义 |
| --- | --- |
| `USERID` | 学号 / 手机号 / 宽带账号 |
| `PASSWD` | 登录密码 |
| `LOGIN_URL` | 校园网认证登录页地址（默认黄河交通/ZJTU 门户） |
| `AES_KEY` | 门户前端加密使用的固定密钥（一般无需改动） |
| `TRYTIME_MAX` | 失败后最大重试次数 |
| `TIMEOUT` | 单次网络请求超时（秒） |

### 2. 运行

**Python 版：**

```bash
# 安装依赖（一次性）
pip install requests beautifulsoup4 pycryptodome

# 运行
python3 net_login.py
```

**Shell 版：**

```bash
# 桌面 Linux 一般自带 curl / openssl，直接运行
sh net_login.sh
# 或
./net_login.sh
```

> 两个版本任选其一即可。脚本输出 `登录成功` 且退出码为 `0` 即表示认证成功；
> 失败会打印服务端返回的原因并自动重试。

### 3. （可选）定时自动登录

脚本只负责登录、不检测在线状态，适合用系统计划任务定时触发（断线重连场景）。

Linux crontab 示例（每 10 分钟执行一次）：

```cron
*/10 * * * * /usr/bin/python3 /path/to/net_login.py
```

> 若使用 Shell 版，注意 cron 环境可能缺少 PATH，先设置完整路径：
>
> ```cron
> */10 * * * * PATH=/usr/bin:/bin /bin/sh /path/to/net_login.sh
> ```

### 4. OpenWrt / 路由器（busybox）环境

Shell 版已按 busybox 兼容写法编写，可在路由器上运行：

```bash
# 安装所需工具（一次性）
opkg update && opkg install curl openssl-util

# 将 net_login.sh 与 config.json 放在同一目录，例如 /root/net_login/
sh /root/net_login/net_login.sh
```

---

## 工作原理（简述）

本脚本是对门户前端登录流程的无浏览器复刻：

1. `GET` 认证登录页，获取 `PHPSESSID` 及表单中动态下发的隐藏字段
   （`sign`、`iv`、`userIp` 等）。
2. 将隐藏字段与账号密码按页面顺序序列化成 query string（等价于
   jQuery `.serialize()`，含 `sign` 的二次 URL 编码）。
3. 使用门户固定密钥对字符串做 **AES-128-CBC + ZeroPadding** 加密并 Base64。
4. `POST` 到 `/gportal/web/authLogin`，服务器返回 JSON；
   其中 `status == 1` 即登录成功。

> 该加密与请求格式是**门户专用**的。若你所在的学校门户不是黄河交通/ZJTU
> 这套（gportal），直接修改 `LOGIN_URL` 可能不够，需要同步调整对应协议。

---

## 常见问题

- **提示「账号不存在」/「密码错误」**：检查 `config.json` 中账号密码。
- **提示「操作过于频繁，请 X 秒后再试」**：门户有登录频率限制，重试间隔已内置
  约 5 秒，请勿短时间高频触发。
- **提示「登录成功」却无法上网**：多发生在路由器/NAT 之后，门户绑定的是外网
  看到的用户 IP，需排查本机到门户之间的地址转换。

---

## License

本项目仅用于学习交流，请遵守相关法律法规与学校网络管理规定。
