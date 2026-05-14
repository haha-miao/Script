import os
import json
import logging
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Iterable, Mapping, Optional
from urllib.parse import unquote

import requests
from flask import Flask, jsonify, request

app = Flask(__name__)
logger = logging.getLogger("lvyatech-relay")
executor = ThreadPoolExecutor(max_workers=int(os.environ.get("RELAY_WORKERS", "2")))
_CONFIG: Optional["RelayConfig"] = None


class RelayConfigError(ValueError):
    """Raised when relay configuration is missing or invalid."""


@dataclass(frozen=True)
class RelayConfig:
    tg_token: str
    tg_chat: str
    device_keys: set
    timeout: float


def parse_device_keys(value: str) -> set:
    keys = {item.strip().strip('"').strip("'").strip() for item in value.split(",") if item.strip()}
    if not keys:
        raise RelayConfigError("请设置 DEVICE_KEYS（逗号分隔的 Bark device_key 列表）")
    return keys


def parse_timeout(value: str) -> float:
    try:
        timeout = float(value)
    except (TypeError, ValueError) as exc:
        raise RelayConfigError("TG_TIMEOUT 必须是数字。") from exc
    if timeout <= 0:
        raise RelayConfigError("TG_TIMEOUT 必须大于 0。")
    return timeout


def load_config(env: Optional[Mapping[str, str]] = None) -> RelayConfig:
    source = os.environ if env is None else env
    tg_token = source.get("TG_TOKEN", "").strip()
    tg_chat = source.get("TG_CHAT", "").strip()
    if not tg_token or not tg_chat:
        raise RelayConfigError("请设置 TG_TOKEN 和 TG_CHAT 环境变量")
    return RelayConfig(
        tg_token=tg_token,
        tg_chat=tg_chat,
        device_keys=parse_device_keys(source.get("DEVICE_KEYS", "")),
        timeout=parse_timeout(source.get("TG_TIMEOUT", "10")),
    )


def get_config() -> RelayConfig:
    global _CONFIG
    if _CONFIG is None:
        _CONFIG = load_config(os.environ)
    return _CONFIG

def bark_ok():
    return jsonify({"code": 200, "message": "success"})

def bark_err(code=403, msg="unauthorized"):
    # 与 Bark 习惯类似的返回结构
    return jsonify({"code": code, "message": msg}), code

def configured_keys() -> set:
    return get_config().device_keys


def allowed_key_present(candidates: Iterable[str]) -> bool:
    return any(key in configured_keys() for key in candidates if key)


def normalize_key_values(value) -> list:
    if value is None:
        return []
    if isinstance(value, str):
        keys = []
        for item in value.split(","):
            key = item.strip().strip('"').strip("'").strip()
            if key:
                keys.append(key)
        return keys
    if isinstance(value, (list, tuple, set)):
        keys = []
        for item in value:
            keys.extend(normalize_key_values(item))
        return keys
    return []


def extract_keys_from_request():
    """
    从请求中提取 device_key 候选：
    优先顺序：
    1) HTTP Header: X-Device-Key
    2) Query: device_key / key / token / device_keys
    3) Path 第一段（在 bark_path_compatible 中处理）
    """
    keys = []
    hdr = request.headers.get("X-Device-Key")
    keys.extend(normalize_key_values(hdr))
    for k in ("device_key", "key", "token"):
        v = request.args.get(k)
        keys.extend(normalize_key_values(v))
    keys.extend(request.args.getlist("device_keys"))
    return keys


def add_multidict_values(target: dict, source) -> None:
    for key in source:
        values = source.getlist(key)
        if not values:
            continue
        target[key] = values if len(values) > 1 else values[0]


def send_to_tg(text: str):
    config = get_config()
    r = requests.post(
        f"https://api.telegram.org/bot{config.tg_token}/sendMessage",
        data={"chat_id": config.tg_chat, "text": text[:4096]},
        timeout=config.timeout,
    )
    return r.status_code == 200, r.status_code


@app.before_request
def ensure_runtime_config():
    try:
        get_config()
    except RelayConfigError as exc:
        logger.error("relay configuration error: %s", exc)
        return bark_err(500, str(exc))
    return None

def enqueue_delivery(text: str):
    def deliver():
        ok, status = send_to_tg(text)
        if not ok:
            logger.warning("telegram delivery failed: HTTP %s", status)

    executor.submit(deliver)

def collect_request_data() -> dict:
    data = {}
    if request.args:
        add_multidict_values(data, request.args)
    if request.form:
        add_multidict_values(data, request.form)
    try:
        if request.is_json:
            payload = request.get_json(force=True)
            if isinstance(payload, dict):
                data.update(payload)
    except Exception:
        pass
    if isinstance(data.get("p"), str):
        try:
            payload = json.loads(data["p"])
            if isinstance(payload, dict):
                data.update(payload)
        except json.JSONDecodeError:
            pass
    return data

def format_payload_message(data: Mapping) -> str:
    title = data.get("title")
    body = data.get("body")
    subtitle = data.get("subtitle", "")
    group = data.get("group", "")

    if title or body or subtitle or group:
        msg = f"📢 {title or '推送'}"
        if subtitle:
            msg += f"\n{subtitle}"
        if body:
            msg += f"\n\n{body}"
        if group:
            msg += f"\n\n📦 分组：{group}"
        return msg

    msg_type = data.get("type", "unknown")
    dev_id = data.get("devId", "")
    lines = [f"📢 绿邮消息 {msg_type}"]
    if dev_id:
        lines.append(f"设备：{dev_id}")
    for key in (
        "slot", "phNum", "smsBd", "msgTs", "smsTs", "tid", "cnt",
        "ip", "ssid", "dbm", "netCh", "note", "code",
    ):
        if key in data and data.get(key) not in (None, ""):
            lines.append(f"{key}: {data.get(key)}")
    return "\n".join(lines)

@app.route("/healthz", methods=["GET"])
def healthz():
    return jsonify({"ok": True, "device_keys": len(get_config().device_keys)})

@app.route("/push", methods=["POST", "GET"])
def push_bark_compatible():
    """
    兼容 Bark 的 /push 接口：
    - GET /push?device_key=...&title=...&body=...
    - POST JSON {"device_key":"...","title":"...","body":"..."}
    - POST JSON {"device_keys":["..."],"title":"...","body":"..."}
    也兼容 key/token 参数名，以及 X-Device-Key 头。
    """
    data = collect_request_data()

    device_keys = []
    for key_name in ("device_key", "key", "token", "device_keys"):
        device_keys.extend(normalize_key_values(data.get(key_name)))
    device_keys.extend(extract_keys_from_request())

    if not allowed_key_present(device_keys):
        return bark_err(403, "unauthorized")

    enqueue_delivery(format_payload_message(data))
    return bark_ok()

@app.route("/", defaults={"path": ""}, methods=["GET", "POST"])
@app.route("/<path:path>", methods=["GET", "POST"])
def bark_path_compatible(path):
    """
    兼容 Bark 的路径形式：
    - /<device_key>/<title>/<body>
    - /<device_key>/<title>
    - /<title>/<body> （这时需要 query 里带 device_key / key / token）
    - 同时支持 X-Device-Key 头
    """
    # 优先从 Header/Query 取 key
    device_keys = extract_keys_from_request()

    # 尝试从 path 第一段识别 device_key
    title = "推送"
    body = ""

    if path:
        parts = path.split("/", 2)  # 最多切三段
        # 如果第一段就是一个有效的 device_key，则后面才是标题/内容
        if parts and parts[0] in configured_keys():
            device_keys.append(parts[0])
            if len(parts) >= 2: title = unquote(parts[1]) or title
            if len(parts) >= 3: body  = unquote(parts[2]) or body
        else:
            # 否则按 /title(/body) 处理，device_key 必须从 query/header 获得
            segs = path.split("/", 1)
            title = unquote(segs[0]) or title
            if len(segs) > 1:
                body = unquote(segs[1]) or body

    if not allowed_key_present(device_keys):
        return bark_err(403, "unauthorized")

    msg = f"📩 {title}"
    if body:
        msg += f"\n\n{body}"

    enqueue_delivery(msg)
    return bark_ok()

if __name__ == "__main__":
    # 默认 8787 端口
    app.run(host="0.0.0.0", port=8787)
