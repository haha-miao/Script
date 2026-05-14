#!/usr/bin/env bash
set -euo pipefail

# 需 root
if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0"
  exit 1
fi

echo "== BBR/内核网络参数配置器 =="

# 交互：内存是否 >= 1G
read -r -p "当前机器内存是否 >= 1GB ? [Y/n] " mem_ans
mem_ans=${mem_ans:-Y}

# 交互：是否禁止 ICMP（不回应 ping）
read -r -p "是否要【禁止 ICMP】（不回应 ping）? [y/N] " icmp_ans
icmp_ans=${icmp_ans:-N}

# 根据回答设置参数
if [[ $mem_ans =~ ^[Yy]$ ]]; then
  TRMEM="8192 87380 67108864"
  TWMEM="4096 87380 67108864"
  RMAX=67108864
  WMAX=67108864
else
  TRMEM="8192 87380 33554432"
  TWMEM="4096 87380 33554432"
  RMAX=33554432
  WMAX=33554432
fi

if [[ $icmp_ans =~ ^[Yy]$ ]]; then
  ICMP=1   # 禁止 ICMP
else
  ICMP=0   # 允许 ICMP
fi

# 备份并写入 /etc/sysctl.conf
backup="/etc/sysctl.conf.$(date +%F-%H%M%S).bak"
if [[ -f /etc/sysctl.conf ]]; then
  cp -a /etc/sysctl.conf "$backup"
  echo "已备份旧配置到: $backup"
fi

cat > /etc/sysctl.conf <<EOF
fs.file-max=6815744
net.ipv4.tcp_abort_on_overflow=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_rmem=${TRMEM}
net.ipv4.tcp_wmem=${TWMEM}
net.core.rmem_max=${RMAX}
net.core.wmem_max=${WMAX}
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_timestamps=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.icmp_echo_ignore_all=${ICMP}
EOF

# 尝试加载 BBR 模块（若存在）
if modprobe -n tcp_bbr >/dev/null 2>&1; then
  modprobe tcp_bbr || true
fi

# 应用配置
echo "应用 sysctl 配置..."
sysctl -p
sysctl --system

echo "验证关键项："
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.icmp_echo_ignore_all | sed 's/^/  ✓ /'

echo "完成。"
