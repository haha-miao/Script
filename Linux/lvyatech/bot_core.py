import os
import re
from dataclasses import dataclass
from typing import Mapping, Optional, Set


PHONE_REGEX = re.compile(r"^\+?\d{5,18}$")


class ConfigError(ValueError):
    """Raised when environment configuration is missing or invalid."""


@dataclass(frozen=True)
class BotConfig:
    telegram_bot_token: str
    gateway_token: str
    base_url: str
    http_timeout: float
    allowed_ids: Set[int]


def parse_float(value: str, name: str) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{name} 必须是数字。") from exc
    if parsed <= 0:
        raise ConfigError(f"{name} 必须大于 0。")
    return parsed


def parse_allowed_ids(value: str) -> Set[int]:
    try:
        ids = {int(item.strip()) for item in value.split(",") if item.strip()}
    except ValueError as exc:
        raise ConfigError("ALLOWED_IDS 格式错误，应为逗号分隔的整数，例如：43308009,457678。") from exc
    if not ids:
        raise ConfigError("为安全起见，必须设置 ALLOWED_IDS（逗号分隔的 Telegram 数字 ID）。")
    return ids


def require_env(env: Mapping[str, str], key: str) -> str:
    value = env.get(key, "").strip()
    if not value:
        raise ConfigError(f"请设置 {key} 环境变量。")
    return value


def load_config(env: Optional[Mapping[str, str]] = None) -> BotConfig:
    source = os.environ if env is None else env
    return BotConfig(
        telegram_bot_token=require_env(source, "TELEGRAM_BOT_TOKEN"),
        gateway_token=require_env(source, "ENTJ_API_TOKEN"),
        base_url=require_env(source, "BASE_URL"),
        http_timeout=parse_float(source.get("HTTP_TIMEOUT", "12"), "HTTP_TIMEOUT"),
        allowed_ids=parse_allowed_ids(source.get("ALLOWED_IDS", "")),
    )


def normalize_phone(value: str) -> str:
    phone = "".join((value or "").strip().split())
    if not PHONE_REGEX.match(phone):
        raise ValueError("手机号格式不对，请重输（支持 + 区号，5-18 位数字）：")
    return phone


def build_sms_params(token: str, sim: str, phone: str, text: str, tid: int) -> dict:
    if str(sim) not in {"1", "2"}:
        raise ValueError("卡槽参数无效，只能是 1 或 2。")
    if not phone:
        raise ValueError("手机号不能为空。")
    if not (text or "").strip():
        raise ValueError("短信内容不能为空。")
    return {
        "token": token,
        "cmd": "sendsms",
        "tid": tid,
        "p1": sim,
        "p2": phone,
        "p3": text,
    }


def summarize_response_body(body: str, limit: int = 1200) -> str:
    return (body or "").strip()[:limit]


def mask_secret(value: str) -> str:
    if len(value) < 8:
        return "*" * len(value)
    return f"{value[:4]}...{value[-3:]}"
