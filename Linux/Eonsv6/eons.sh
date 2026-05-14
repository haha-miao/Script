#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
ts=$(date +%F-%H%M%S)

HN=$(hostnamectl --static 2>/dev/null || hostname)
echo "主机名: $HN"

# ===== 1) 只改“不含 localhost”的那一行 =====
cp -a /etc/hosts /etc/hosts.bak.$ts

changed=0
# 先尝试改 127.0.1.1 这一行（如果存在）
if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]+' /etc/hosts; then
  sed -i -E "s@^[[:space:]]*127\.0\.1\.1[[:space:]]+.*@127.0.1.1\t$HN@" /etc/hosts
  changed=1
else
  # 找到第一个：不是注释/空行，且“不含 单词localhost”的 IPv4 行
  ln=$(awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    {
      if ($0 ~ /(^|[[:space:]])localhost([[:space:]]|$)/) next
      if ($1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) { print NR; exit }
    }' /etc/hosts)
  if [[ -n "${ln:-}" ]]; then
    ip=$(awk -v n="$ln" 'NR==n{print $1}' /etc/hosts)
    sed -i "${ln}s@^.*@${ip}\t${HN}@" /etc/hosts
    changed=1
  fi
fi

# 如果以上都没改动，就在第一行后面新增一行
if [[ $changed -eq 0 ]]; then
  sed -i "1a 127.0.1.1\t${HN}" /etc/hosts
fi

# 不重写任何含 localhost 的行；只尝试重启主机名服务
systemctl try-restart systemd-hostnamed.service >/dev/null 2>&1 || true

# ===== 2) IPv6 静态配置（/etc/network/interfaces）=====
# 选网卡：优先 eth0；否则默认路由网卡；再不行取第一个非 lo
IFACE=eth0
ip link show "$IFACE" >/dev/null 2>&1 || IFACE=$(ip -o route show default 2>/dev/null | awk 'NR==1{print $5}')
[[ -n "${IFACE:-}" ]] || IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
echo "使用网卡: $IFACE"

read -rp "请输入 IPv6 地址(不带 /64): " V6ADDR
read -rp "请输入 IPv6 网关地址: " V6GW
[[ "$V6ADDR" == *:* && "$V6GW" == *:* ]] || { echo "IPv6 地址/网关格式不对"; exit 1; }

cp -a /etc/network/interfaces /etc/network/interfaces.bak.$ts
sed -i '/^# BEGIN-STATIC-IPv6/,/^# END-STATIC-IPv6/d' /etc/network/interfaces
cat >> /etc/network/interfaces <<EOF2

# BEGIN-STATIC-IPv6 (added $(date -R))
allow-hotplug $IFACE
iface $IFACE inet6 static
    address $V6ADDR
    netmask 64
    gateway $V6GW
# END-STATIC-IPv6
EOF2

systemctl restart networking

echo "完成 ✅"
echo "备份：/etc/hosts.bak.$ts  /etc/network/interfaces.bak.$ts"
echo "当前 ${IFACE} 的 IPv6 地址："
ip -6 addr show dev "$IFACE" | sed -n 's/ \+inet6 \([0-9a-f:]*\)\/.*/  - \1/p'
echo "默认 IPv6 路由："
ip -6 route show default || true