# Ivyatech SMSBot

这个目录包含两个小服务：

- `smsbot`：Telegram Bot，通过 Ivyatech/ENTJ 网关发送短信。
- `relay`：可选的 Bark 兼容 HTTP 推送入口，把设备事件转发到 Telegram。

默认只启动 `smsbot`。需要设备事件推送时，再用 Compose profile 启动 `relay`。

## 文件说明

```text
.
├── bot.py               # Telegram 短信 Bot 入口
├── bot_core.py          # Bot 的配置解析和短信参数构造
├── relay.py             # Bark 兼容推送入口
├── compose.yml          # Docker Compose 部署
├── Dockerfile           # 固定依赖的镜像构建
├── requirements.txt     # Python 运行依赖
├── .env.example         # 环境变量模板
├── example.json         # Ivyatech 设备基础配置示例，保持合法 JSON
└── push-templates.txt   # 设备事件推送模板
```

## 快速部署短信 Bot

```bash
mkdir -p /opt/smsbot && cd /opt/smsbot
git clone --depth 1 https://github.com/haha-miao/Script.git /tmp/Script
cp -r /tmp/Script/Linux/lvyatech /opt/smsbot/Ivyatech
rm -rf /tmp/Script
cd /opt/smsbot/Ivyatech
cp .env.example .env
nano .env
```

在 `.env` 里至少填写：

```dotenv
TELEGRAM_BOT_TOKEN=xxxx:yyyyyyyyyyyyyyyyyyyy
ENTJ_API_TOKEN=your_gateway_token
BASE_URL=https://your.gateway.domain/ctrl
HTTP_TIMEOUT=12
ALLOWED_IDS=12345678,87654321
```

启动：

```bash
docker compose up -d --build
docker logs -f smsbot
```

日志里出现 `Application started` 后，在 Telegram 对机器人发送 `/start`。

## 短信 Bot 使用

1. 在 Telegram 输入 `/start`。
2. 选择 `卡1` 或 `卡2`。
3. 输入目标手机号，支持 `+` 区号，例如 `+8613812345678`。
4. 输入短信内容。
5. 确认发送。

发送请求固定使用 GET，参数保持网关原始约定：

```text
token=<ENTJ_API_TOKEN>
cmd=sendsms
tid=<当前时间戳>
p1=<卡槽>
p2=<手机号>
p3=<短信内容>
```

## 启动可选 relay

relay 用于接收设备推送，并转发到 Telegram。绿邮文档推荐设备端使用 `POST + FORM`，relay 已兼容 `POST + FORM`、`POST + JSON`、`GET + FORM` 和 `GET + JSON` 的 `p` 参数。

先在 `.env` 填写：

```dotenv
TG_TOKEN=xxxx:yyyyyyyyyyyyyyyyyyyy
TG_CHAT=12345678
DEVICE_KEYS=KEY1,KEY2,KEY3
TG_TIMEOUT=10
RELAY_WORKERS=2
RELAY_PORT=8787
```

启动：

```bash
docker compose --profile relay up -d --build
docker logs -f lvyatech-relay
```

接口示例：

```bash
curl 'http://127.0.0.1:8787/push?device_key=KEY1&title=测试&body=hello'

curl -X POST 'http://127.0.0.1:8787/push?device_key=KEY1' \
  -d 'type=501' \
  -d 'devId=498060912345' \
  -d 'slot=1' \
  -d 'phNum=10086' \
  -d 'smsBd=hello'

curl -X POST 'http://127.0.0.1:8787/push' \
  -H 'Content-Type: application/json' \
  -d '{"device_keys":["KEY1","KEY2"],"title":"新短信","body":"hello"}'

curl 'http://127.0.0.1:8787/push?device_key=KEY1&p={"type":998,"devId":"498060912345","cnt":7}'

curl 'http://127.0.0.1:8787/KEY1/标题/内容'
```

`device_key`、`key`、`token`、`device_keys` 数组、`X-Device-Key` Header 都可以作为授权 key。只要请求里的任意 key 命中 `.env` 的 `DEVICE_KEYS`，relay 就会接受请求。

relay 收到合法请求后会立即返回 HTTP 200，再后台转发 Telegram，避免开发板等待第三方接口导致超时。

设备后台建议这样填：

```text
接口地址设置：http://your-server:8787/push?device_key=KEY1
HTTP 请求方式：POST
Content-Type：FORM
```

如果你选择 `GET + JSON`，绿邮会把整段 JSON 放到固定参数 `p` 里，relay 也会自动解析。

## 示例文件

- `example.json` 是设备基础配置示例，现在保持为合法 JSON，便于导入或用工具校验；导入前把里面的 `http://your-server:8787/push?device_key=KEY1` 换成你的公网地址。
- `push-templates.txt` 保存事件码 `100/101/102/204/205/209/501/502/603` 对应的推送模板。
- 模板里的 `device_keys` 数组可直接发给 relay，relay 已兼容数组格式。

## 常用命令

```bash
cd /opt/smsbot/Ivyatech

docker compose restart
docker compose down
docker logs -f smsbot

docker compose --profile relay restart relay
docker logs -f lvyatech-relay
```

## 本地自查

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python -m py_compile bot.py bot_core.py relay.py
python -m json.tool example.json >/dev/null
```
