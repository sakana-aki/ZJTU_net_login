#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校园网自动登录（仅负责发起登录，不做在线状态/日志等额外检查）。

登录协议：ThinkPHP 门户。GET 登录页拿到隐藏字段(sign/iv 等) ->
把表单序列化成 query string -> AES-128-CBC(ZeroPadding) 加密 ->
base64 -> POST 到 /gportal/web/authLogin。
"""
import base64
import json
import os
import random
import sys
import time
from urllib.parse import quote

import requests
from Crypto.Cipher import AES
from bs4 import BeautifulSoup

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")


def load_config():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def enc(s):
    # 等价于 JS 的 encodeURIComponent
    return quote(str(s), safe="!'()*")


def serialize(fields):
    return "&".join(f"{enc(k)}={enc(v)}" for k, v in fields)


def parse_login_fields(html, cfg):
    """遍历 frmLogin 里会随表单提交的输入框，填入学号/密码，保持 DOM 顺序。

    未勾选的 checkbox/radio 和无名 input(登录按钮) jQuery 不会序列化，跳过。
    """
    form = BeautifulSoup(html, "html.parser").find("form", id="frmLogin")
    if form is None:
        return []
    fields = []
    for inp in form.find_all("input"):
        name = inp.get("name")
        if not name:
            continue
        if (inp.get("type") or "text").lower() in ("checkbox", "radio"):
            continue
        if name == "name":
            fields.append((name, cfg["USERID"]))
        elif name == "password":
            fields.append((name, cfg["PASSWD"]))
        else:
            fields.append((name, inp.get("value", "")))
    return fields


def aes_encrypt(plaintext, key, iv):
    """复刻 CryptoJS AES-CBC + ZeroPadding。

    iv 字段是字符串，按 UTF-8 取字节；ZeroPadding 在明文刚好整块时
    仍补满一个块（CryptoJS 行为），所以 pad 恒 >= 1。
    """
    pt = plaintext.encode("utf-8")
    pad = 16 - (len(pt) % 16)
    pt += b"\x00" * pad
    cipher = AES.new(key.encode("utf-8"), AES.MODE_CBC, iv.encode("utf-8"))
    return base64.b64encode(cipher.encrypt(pt)).decode()


def do_login(cfg):
    sess = requests.Session()
    sess.headers.update({"User-Agent": UA})

    login_url = cfg["LOGIN_URL"]
    r = sess.get(login_url, timeout=cfg["TIMEOUT"])
    r.raise_for_status()

    fields = parse_login_fields(r.text, cfg)
    if not fields:
        raise RuntimeError("页面里没找到登录表单 frmLogin，可能是已登录或页面结构变了")
    iv = dict(fields).get("iv", "")

    # sign 等字段在页面里已做过一次 URL 编码，这里序列化时再编码一次，
    # 与 jQuery .serialize() 行为一致。
    encrypted = aes_encrypt(serialize(fields), cfg["AES_KEY"], iv)

    auth_url = (login_url.rsplit("/", 1)[0] + "/authLogin?round="
                + str(random.randint(0, 1000)))
    r2 = sess.post(
        auth_url,
        data={"data": encrypted, "iv": iv},
        headers={"Referer": login_url,
                 "Accept": "application/json, text/javascript, */*; q=0.01"},
        timeout=cfg["TIMEOUT"],
    )
    try:
        return r2.json()
    except ValueError:
        return {"status": 0, "info": r2.text[:200]}


def main():
    cfg = load_config()
    max_try = int(cfg.get("TRYTIME_MAX", 1))

    for i in range(1, max_try + 1):
        try:
            resp = do_login(cfg)
        except Exception as e:
            print(f"[第 {i}/{max_try} 次] 请求异常: {e}")
            resp = None

        if resp is not None and resp.get("status") == 1:
            print(f"登录成功: {resp.get('info', '')}")
            return 0

        print(f"[第 {i}/{max_try} 次] 登录失败: {(resp or {}).get('info', '无响应')}")
        if i < max_try:
            time.sleep(5)  # 服务端对登录接口有约 5s 的限流

    return 1


if __name__ == "__main__":
    sys.exit(main())
