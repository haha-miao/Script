import asyncio
import os
import time
import logging
import html
import requests

from telegram import (
    Update,
    ReplyKeyboardMarkup, ReplyKeyboardRemove,
    InlineKeyboardButton, InlineKeyboardMarkup,
)
from telegram.ext import (
    Application,
    CommandHandler, MessageHandler, CallbackQueryHandler,
    ConversationHandler, ContextTypes, filters,
)

from bot_core import (
    BotConfig,
    ConfigError,
    build_sms_params,
    load_config,
    normalize_phone,
    summarize_response_body,
)

# ===== 日志 =====
logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    level=logging.INFO
)
# 隐藏 httpx/PTB 请求细节，防止 token 暴露
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("telegram.vendor.ptbclient.httpx").setLevel(logging.WARNING)
logger = logging.getLogger("sms-bot")

# ===== 会话状态 =====
CHOOSING_SIM, GET_PHONE, GET_TEXT, CONFIRM = range(4)

SIM_KEYBOARD = ReplyKeyboardMarkup([["卡1", "卡2"]], one_time_keyboard=True, resize_keyboard=True)

def user_allowed(update: Update, context: ContextTypes.DEFAULT_TYPE) -> bool:
    uid = update.effective_user.id if update.effective_user else None
    config: BotConfig = context.bot_data["config"]
    return uid in config.allowed_ids

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not user_allowed(update, context):
        await update.message.reply_text("抱歉，你没有使用权限。")
        return ConversationHandler.END

    context.user_data.clear()
    await update.message.reply_text(
        "你好～准备发短信。\n请选择要使用的卡槽：",
        reply_markup=SIM_KEYBOARD
    )
    return CHOOSING_SIM

async def choose_sim(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = (update.message.text or "").strip()
    if text not in ("卡1", "卡2"):
        await update.message.reply_text("请点击按钮选择：卡1 或 卡2。", reply_markup=SIM_KEYBOARD)
        return CHOOSING_SIM
    sim = "1" if text == "卡1" else "2"
    context.user_data["sim"] = sim
    await update.message.reply_text(
        "请输入接收手机号（可带+区号，如 +8613812345678）：",
        reply_markup=ReplyKeyboardRemove()
    )
    return GET_PHONE

async def get_phone(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        phone = normalize_phone(update.message.text or "")
    except ValueError as exc:
        await update.message.reply_text(str(exc))
        return GET_PHONE
    context.user_data["phone"] = phone
    await update.message.reply_text("好的。请发送短信内容（多行也可以）：")
    return GET_TEXT

async def get_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    content = (update.message.text or "").strip()
    if not content:
        await update.message.reply_text("内容不能为空，请重新输入：")
        return GET_TEXT
    context.user_data["text"] = content

    sim = context.user_data["sim"]
    phone = context.user_data["phone"]
    preview = (
        f"请确认：\n"
        f"• 卡槽：卡{sim}\n"
        f"• 手机号：{phone}\n"
        f"• 内容：\n{content}\n\n"
        f"是否发送？"
    )
    keyboard = InlineKeyboardMarkup([
        [InlineKeyboardButton("✅ 发送", callback_data="CONFIRM_SEND"),
         InlineKeyboardButton("❌ 取消", callback_data="CANCEL")],
        [InlineKeyboardButton("✏️ 改手机号", callback_data="EDIT_PHONE"),
         InlineKeyboardButton("✏️ 改内容", callback_data="EDIT_TEXT")],
    ])
    await update.message.reply_text(preview, reply_markup=keyboard)
    return CONFIRM

async def confirm_buttons(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not user_allowed(update, context):
        await update.callback_query.answer("无权限")
        return ConversationHandler.END

    q = update.callback_query
    await q.answer()
    action = q.data

    if action == "CANCEL":
        await q.edit_message_text("已取消。")
        return ConversationHandler.END
    if action == "EDIT_PHONE":
        await q.edit_message_text("请重新输入手机号：")
        return GET_PHONE
    if action == "EDIT_TEXT":
        await q.edit_message_text("请重新输入短信内容：")
        return GET_TEXT

    if action == "CONFIRM_SEND":
        config: BotConfig = context.bot_data["config"]
        sim   = context.user_data.get("sim")
        phone = context.user_data.get("phone")
        text  = context.user_data.get("text", "")
        if not sim or not phone or not text:
            await q.edit_message_text("会话已过期，请重新输入 /start。")
            return ConversationHandler.END

        params = build_sms_params(config.gateway_token, sim, phone, text, int(time.time()))

        try:
            # 固定使用 GET（与浏览器点击一致）；附常见浏览器 UA
            resp = await asyncio.to_thread(
                requests.get,
                config.base_url,
                params=params,
                timeout=config.http_timeout,
                headers={"User-Agent": "Mozilla/5.0"}
            )
            body = summarize_response_body(resp.text)
            if resp.status_code == 200:
                await q.edit_message_text(
                    f"✅ 已发送！（GET）\nHTTP {resp.status_code}\n响应：\n{body}"
                )
            else:
                await q.edit_message_text(
                    f"❌ 发送失败（HTTP {resp.status_code}）。\n响应：\n{body}"
                )
        except requests.RequestException as e:
            await q.edit_message_text(f"❌ 请求异常：{html.escape(str(e))}")
        return ConversationHandler.END

async def cmd_cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("已取消。", reply_markup=ReplyKeyboardRemove())
    return ConversationHandler.END

async def on_error(update: object, context: ContextTypes.DEFAULT_TYPE):
    logger.warning("Bot 异常：%s", str(context.error)[:200])

def build_application(config: BotConfig):
    app = Application.builder().token(config.telegram_bot_token).build()
    app.bot_data["config"] = config

    conv = ConversationHandler(
        entry_points=[CommandHandler("start", cmd_start)],
        states={
            CHOOSING_SIM: [MessageHandler(filters.TEXT & ~filters.COMMAND, choose_sim)],
            GET_PHONE:    [MessageHandler(filters.TEXT & ~filters.COMMAND, get_phone)],
            GET_TEXT:     [MessageHandler(filters.TEXT & ~filters.COMMAND, get_text)],
            CONFIRM:      [CallbackQueryHandler(confirm_buttons)],
        },
        fallbacks=[CommandHandler("cancel", cmd_cancel)],
        allow_reentry=True,
    )

    app.add_handler(conv)
    app.add_error_handler(on_error)
    return app

def main():
    try:
        config = load_config(os.environ)
    except ConfigError as exc:
        raise SystemExit(str(exc)) from exc

    app = build_application(config)
    app.run_polling(close_loop=False)

if __name__ == "__main__":
    main()
