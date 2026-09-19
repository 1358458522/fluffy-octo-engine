#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
天天油报 · 移动端（iOS）云库配置导出工具   export_mobile_config.py
================================================================================
用途
    从主软件加密配置中解出全部站点的「独立云库」连接信息，导出为手机端（iOS）
    可直接导入的 JSON 文件，供天天油报 iOS 版用手机流量直连云库读取营业额。

支持读取的配置来源（自动按顺序识别，也可用 --input 显式指定）
    1) config.pkg   —— 主软件运行期配置包（AES-256-GCM + PBKDF2-HMAC-SHA256 20 万次迭代）
                       解锁口令 = 主软件 GUI 的启动密码（主软件 CLI 的 --config-pwd 同义）
    2) *.gasenc     —— 主软件「导出配置包」生成的加密文件（同一加密容器，含 magic 标识）
    3) config.json  —— 历史明文配置（仅兼容老版本；存在即读取，并在终端给出明文提示）

默认查找位置（可用 --data-dir / --input 覆盖）
    - 本脚本所在目录
    - 当前工作目录
    - macOS: ~/Library/Application Support/TianTianYouBao
    - Windows 主软件把 config.pkg 放在 exe 同目录，把本脚本放到 exe 同目录即可

输出 JSON（默认「对象形式」）
    {
      "app": "天天油报",
      "schema": "ttyb-mobile-config/1",
      "exported_at": "2026-09-18T10:00:00",
      "count": 19,
      "stations": [
        {"id": "8F3B…（自动生成，iOS 端必填）", "name": "站点名", "server": "云库IP,端口",
         "db": "moms", "user": "云库账号", "pwd": "云库密码", "useTLS": false},
        ...
      ]
    }
    --flat-array 时输出裸数组 [ {...}, {...} ]（仍含 id 字段，不含外层元信息）

字段说明
    id       站点 UUID（每次导出随机生成，iOS 端解码必需；缺失会导致导入失败）
    name     站点名（主软件站点列表中的名称）
    server   云库地址，主软件原始写法 "<主机>,<端口>"（兼容 "<主机>:<端口>"）；
             移动端请按「最后一个 , 或 :」切分主机与端口，缺端口时默认 1433
    db       数据库名，默认 "moms"
    user     SQL 账号（非 Windows 集成认证；配置中缺省时按主软件口径回填 "sa"）
    pwd      SQL 密码（配置中缺失时原样输出空串，并在终端给出提示）
    useTLS   是否启用 TLS（默认 false；iOS 端加密连接会闪退，云库本身不要求加密；
             确需加密时可加 --tls，但不推荐）

用法示例
    python export_mobile_config.py                        # 自动找配置，交互式输入口令
    python export_mobile_config.py --data-dir "D:\\天天油报"
    python export_mobile_config.py --input "D:\\天天油报\\config.pkg"
    python export_mobile_config.py --input "站点配置.gasenc" --out mobile_config.json
    python export_mobile_config.py --data-dir "D:\\天天油报" --pwd-env TTYB_PWD
    python export_mobile_config.py --data-dir "D:\\天天油报" --flat-array
    python export_mobile_config.py --dry-run              # 只统计不写文件
    python export_mobile_config.py --tls                  # 导出 useTLS=true（iOS 端会闪退，勿用）

安全约定
    · 本脚本不打印任何明文账号 / 密码；终端只输出站点数量、站名与脱敏地址。
    · 输出 JSON 为明文（手机导入需要），请自行妥善保管，勿公开传输。
    · 口令仅用于本地解密，不写入任何文件、不回显。

依赖
    pip install pycryptodome      （若缺失，脚本会自动尝试 cryptography）
"""

import argparse
import datetime
import getpass
import hashlib
import json
import os
import re
import sys
import uuid

# ---------------------------------------------------------------- 常量（与主软件保持一致）
KDF_ITERS_DEFAULT = 200000          # 主软件 _KDF_ITERS
EXPORT_MAGIC = "GAS-EXPORT-1"       # 主软件 _EXPORT_MAGIC（.gasenc 专用）
CFG_PKG_NAME = "config.pkg"         # 主软件 CONFIG_PKG_PATH 文件名
CFG_PKG_EXT = ".gasenc"             # 主软件 CFG_PKG_EXT
CFG_JSON_NAME = "config.json"       # 历史明文配置
DEFAULT_DB = "moms"                 # 主软件 DEFAULT_DB
DEFAULT_USER = "sa"                 # 主软件 db_connect 的 user 缺省值
SERVER_RE = re.compile(r"^[0-9.]+[,:][0-9]+$")


def fail(msg):
    sys.stderr.write("错误: %s\n" % msg)
    sys.exit(1)


# ---------------------------------------------------------------- 脱敏工具（终端输出用）
def mask_hostport(server):
    """把 '<主机>,<端口>' 脱敏为 '1.*.*.4:5****'，仅用于终端展示。"""
    s = str(server or "")
    host, port = s, ""
    for sep in (",", ":"):
        if sep in s:
            host, _, port = s.rpartition(sep)
            break
    parts = host.split(".")
    if len(parts) == 4:
        host_m = "%s.*.*.%s" % (parts[0], parts[3])
    elif len(parts) > 1:
        host_m = parts[0] + ".*" * (len(parts) - 1)
    else:
        host_m = (host[:1] + "***") if host else "-"
    if port:
        return "%s:%s" % (host_m, port[:1] + "*" * max(len(port) - 1, 1))
    return host_m


def mask_user(user):
    u = str(user or "")
    if not u:
        return "-"
    return u[:1] + "*" * max(len(u) - 1, 1)


# ---------------------------------------------------------------- 解密（与主软件算法一致）
def derive_key(pwd, salt_hex, iters):
    """PBKDF2-HMAC-SHA256，dkLen=32，与主软件 _derive_key 等价。"""
    salt = bytes.fromhex(salt_hex)
    return hashlib.pbkdf2_hmac("sha256", pwd.encode("utf-8"), salt, int(iters), dklen=32)


def aes_gcm_decrypt(key, nonce, data, tag):
    """AES-256-GCM 解密校验；优先 pycryptodome，缺失时回退 cryptography。"""
    try:
        from Crypto.Cipher import AES  # pycryptodome
    except ImportError:
        AES = None
    if AES is not None:
        cipher = AES.new(key, AES.MODE_GCM, nonce=nonce)
        return cipher.decrypt_and_verify(data, tag)
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError:
        fail("缺少加密依赖，请先执行：  pip install pycryptodome")
    return AESGCM(key).decrypt(nonce, data + tag, None)


def decrypt_blob(pwd, blob):
    """解密 _encrypt_json 产物（config.pkg / .gasenc 同一容器格式）。"""
    for k in ("salt", "nonce", "tag", "data"):
        if not blob.get(k):
            fail("配置容器字段缺失：%s" % k)
    iters = blob.get("iter") or KDF_ITERS_DEFAULT
    key = derive_key(pwd, blob["salt"], iters)
    try:
        raw = aes_gcm_decrypt(key,
                              bytes.fromhex(blob["nonce"]),
                              bytes.fromhex(blob["data"]),
                              bytes.fromhex(blob["tag"]))
    except Exception:
        fail("解密失败：口令不正确，或配置包已损坏 / 被篡改")
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        fail("解密成功但内容不是合法 JSON（配置包格式异常）")


# ---------------------------------------------------------------- 配置定位与读取
def candidate_dirs(script_dir, data_dir_arg):
    out = []
    if data_dir_arg:
        out.append(os.path.abspath(data_dir_arg))
    out.append(script_dir)
    out.append(os.getcwd())
    mac_dir = os.path.join(os.path.expanduser("~/Library/Application Support"), "TianTianYouBao")
    if os.path.isdir(mac_dir):
        out.append(mac_dir)
    seen, uniq = set(), []
    for d in out:
        if d and d not in seen:
            seen.add(d)
            uniq.append(d)
    return uniq


def find_input(script_dir, data_dir_arg, input_arg):
    """返回 (路径, 类型)；类型 ∈ {'pkg','gasenc','json'}；未找到返回 (None, None)。"""
    if input_arg:
        p = os.path.abspath(input_arg)
        if not os.path.isfile(p):
            fail("指定的配置来源不存在：%s" % p)
        low = p.lower()
        if low.endswith(".gasenc"):
            return p, "gasenc"
        if low.endswith(".json"):
            return p, "json"
        return p, "pkg"
    for d in candidate_dirs(script_dir, data_dir_arg):
        p = os.path.join(d, CFG_PKG_NAME)
        if os.path.isfile(p):
            return p, "pkg"
    for d in candidate_dirs(script_dir, data_dir_arg):
        try:
            names = sorted(n for n in os.listdir(d) if n.lower().endswith(CFG_PKG_EXT))
        except OSError:
            names = []
        if names:
            return os.path.join(d, names[0]), "gasenc"
    for d in candidate_dirs(script_dir, data_dir_arg):
        p = os.path.join(d, CFG_JSON_NAME)
        if os.path.isfile(p):
            return p, "json"
    return None, None


def read_payload(path, kind, pwd):
    """读取并返回配置 dict（含 stations）。口令不匹配 / 格式错误时 fail。"""
    if kind == "json":
        sys.stderr.write("提示: 读取的是历史明文 config.json（明文配置，建议尽快迁移为加密配置包）。\n")
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    with open(path, "r", encoding="utf-8") as f:
        blob = json.load(f)
    if kind == "gasenc" and blob.get("magic") and blob.get("magic") != EXPORT_MAGIC:
        fail("不是本工具的配置导出文件（magic=%s）" % blob.get("magic"))
    if not pwd:
        fail("需要解锁口令（主软件 GUI 启动密码）：请用 --pwd / --pwd-env，或交互式输入")
    return decrypt_blob(pwd, blob)


def collect_stations(cfg):
    """从配置 dict 中抽取站点云库信息，返回 (导出列表, 跳过明细, 提示明细)。"""
    stations = cfg.get("stations") or []
    # 兼容 v3 的历史顶层 cloud 缓存：迁移给首个未配置 cloud 的站点（与主软件逻辑一致）
    legacy = cfg.get("cloud")
    if isinstance(legacy, dict) and legacy:
        for s in stations:
            if not s.get("cloud"):
                s["cloud"] = legacy
                break
    out, skipped, notes = [], [], []
    for s in stations:
        name = str(s.get("name") or s.get("ip") or "").strip() or "未命名站点"
        cloud = s.get("cloud") or {}
        server = str(cloud.get("server") or "").strip()
        # 与主软件 db_connect 的取值口径一致：user 缺省 sa，pwd 缺省空串
        user = str(cloud.get("user") or "").strip() or DEFAULT_USER
        pwd = str(cloud.get("pwd") or "")
        db = str(cloud.get("db") or "").strip() or DEFAULT_DB
        if not server:
            skipped.append((name, "未配置独立云库（缺 server）"))
            continue
        if not SERVER_RE.match(server):
            skipped.append((name, "云库地址格式异常（非 <主机>,<端口>）"))
            continue
        out.append({"id": str(uuid.uuid4()).upper(),
                    "name": name, "server": server, "db": db,
                    "user": user, "pwd": pwd, "useTLS": True})
        if not pwd:
            notes.append((name, "云库密码为空，手机端可能连不上；建议先在主软件中对本站执行一次抓取以缓存凭据"))
    return out, skipped, notes


# ---------------------------------------------------------------- 主流程
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="天天油报 · 移动端（iOS）云库配置导出工具",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", default="", help="配置来源：config.pkg / *.gasenc / config.json（默认自动查找）")
    ap.add_argument("--data-dir", default="", help="主软件数据目录（Windows 为 exe 同目录）")
    ap.add_argument("--out", default="", help="输出 JSON 路径（默认：脚本同目录 mobile_config.json）")
    ap.add_argument("--pwd", default="", help="配置包解锁口令（不推荐：会留在命令行历史）")
    ap.add_argument("--pwd-env", default="", help="从该环境变量读取解锁口令（推荐）")
    ap.add_argument("--flat-array", action="store_true", help="输出裸数组（不含外层元信息）")
    ap.add_argument("--tls", action="store_true",
                    help="useTLS 置为 true（不推荐：iOS 端加密连接会闪退）")
    ap.add_argument("--no-tls", action="store_true", help=argparse.SUPPRESS)  # 历史参数，默认即不加密
    ap.add_argument("--dry-run", action="store_true", help="只解析统计，不写文件")
    ap.add_argument("--quiet", action="store_true", help="不打印站点明细（仍打印结果行）")
    args = ap.parse_args(argv)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    path, kind = find_input(script_dir, args.data_dir, args.input)
    if not path:
        fail("未找到 config.pkg / *.gasenc / config.json。请用 --data-dir 指定主软件目录，"
             "或用 --input 指定配置文件")
    print("[1/3] 配置来源: %s (%s)" % (path, kind))

    pwd = args.pwd or (os.environ.get(args.pwd_env, "") if args.pwd_env else "")
    if not pwd and kind != "json":
        try:
            pwd = getpass.getpass("请输入配置包解锁口令（主软件启动密码，不回显）: ")
        except Exception:
            pwd = ""
    cfg = read_payload(path, kind, pwd)

    rows, skipped, notes = collect_stations(cfg)
    print("[2/3] 解析完成：可用站点 %d 个，跳过 %d 个" % (len(rows), len(skipped)))
    for name, why in skipped:
        print("      - 跳过「%s」：%s" % (name, why))
    for name, why in notes:
        print("      - 注意「%s」：%s" % (name, why))
    if not rows:
        fail("没有任何可用站点（均未配置独立云库）。请先在主软件中编辑站点并保存云库信息")

    if not args.quiet:
        print("      站点明细（地址 / 账号已脱敏）:")
        for r in rows:
            print("      - %s  %s  db=%s  user=%s  useTLS=%s"
                  % (r["name"], mask_hostport(r["server"]), r["db"],
                     mask_user(r["user"]), str(r["useTLS"]).lower()))

    # iOS 端加密连接会触发底层陷阱直接闪退（真机实测 SIGTRAP），而云库本身不要求加密
    # （PRELOGIN 实测 22 站均返回「不支持加密」）：因此默认按不加密导出。
    for r in rows:
        r["useTLS"] = bool(args.tls)

    if args.dry_run:
        print("[3/3] --dry-run：未写出文件")
        return 0

    out_path = args.out or os.path.join(script_dir, "mobile_config.json")
    out_path = os.path.abspath(out_path)
    out_dir = os.path.dirname(out_path)
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    if args.flat_array:
        payload = rows
    else:
        payload = {
            "app": "天天油报",
            "schema": "ttyb-mobile-config/1",
            "exported_at": datetime.datetime.now().isoformat(timespec="seconds"),
            "count": len(rows),
            "stations": rows,
        }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    print("[3/3] 已写出: %s（%d 个站点，明文 JSON，请妥善保管）" % (out_path, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
