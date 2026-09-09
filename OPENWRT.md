# OpenWrt 部署说明（路由专用分支）

本分支只保留 Shell 版 `net_login.sh` 与示例 `config.json`，适合
GL-MT3600BE 等 busybox 路由器（OpenWrt 上不装 Python 依赖）。

## 安装所需工具

```bash
opkg update && opkg install curl openssl-util
```

## 部署

把 `net_login.sh` 和 `config.json` 放到路由器同一目录，例如 `/root/net_login/`：

```bash
mkdir -p /root/net_login
# 将两个文件放入 /root/net_login/ 后，编辑 config.json 填入真实账号密码
sh /root/net_login/net_login.sh
```

> 脚本只负责发起登录、不做在线检查；登录页没有登录表单时视为已在线，直接正常退出。

## 定时自动登录（断线重连）

```cron
*/10 * * * * PATH=/usr/bin:/bin /bin/sh /root/net_login/net_login.sh
```
