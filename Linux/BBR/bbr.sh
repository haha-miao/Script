#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.6"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.conf}"

AUTO_YES=0
DRY_RUN=0
DO_RESTORE=0
RESTORE_FILE=""
FORCED_PROFILE=""

IPV4_FORWARD_VALUE="0"
ICMP_ECHO_IGNORE_VALUE="0"

PROFILE=""
PROFILE_DESC=""
RMEM_DEFAULT=""
WMEM_DEFAULT=""
BUFFER_BYTES=""
NETDEV_BACKLOG=""
TW_BUCKETS=""
SWAPPINESS=""
DIRTY_RATIO=""
VFS_CACHE_PRESSURE=""
MIN_FREE_KBYTES=""

BACKUP_FILE=""
UNSUPPORTED_KEYS=""
TMP_FILE="$(mktemp /tmp/gnar-sysctl.XXXXXX)"

trap 'rm -f "$TMP_FILE"' EXIT

die() {
  echo "错误: $*" >&2
  exit 1
}

warn() {
  echo "警告: $*" >&2
}

script_name() {
  local src="${BASH_SOURCE[0]:-$0}"
  if [ -f "$src" ]; then
    printf "%s" "$src"
  else
    printf "%s" "$0"
  fi
}

usage() {
  cat <<'EOF'
gnar TCP sysctl 调优脚本

用法:
  bash bbr.sh
  bash bbr.sh --profile P2
  bash bbr.sh --dry-run
  bash bbr.sh --restore latest
  bash bbr.sh --restore /etc/sysctl.conf.bak.20260101010101

档位:
  P0  MemTotal <=900MB，32MB buffer
  P1  MemTotal >900MB 且 <=1800MB，64MB buffer
  P2  MemTotal >1800MB，128MB buffer，推荐默认档
  P3  极致暴力，256MB buffer，仅建议 8G-16G + 5G-10G 高 RTT 场景

参数:
  --profile P0|P1|P2|P3   强制指定档位
  --dry-run                只打印将生成的配置，不写入
  --yes, -y                跳过确认，使用默认选择
  --restore [latest|file]  从备份恢复并应用
  -h, --help               显示帮助
EOF
}

need_root() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行，例如 sudo -i 后再执行。"
}

normalize_profile() {
  case "$1" in
    P0|p0) echo "P0" ;;
    P1|p1) echo "P1" ;;
    P2|p2) echo "P2" ;;
    P3|p3) echo "P3" ;;
    *) die "未知档位: $1。只能使用 P0/P1/P2/P3。" ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)
        shift
        [ "$#" -gt 0 ] || die "--profile 需要参数 P0/P1/P2/P3。"
        FORCED_PROFILE="$(normalize_profile "$1")"
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --yes|-y)
        AUTO_YES=1
        ;;
      --restore)
        DO_RESTORE=1
        if [ "${2:-}" != "" ] && ! echo "$2" | grep -q '^-'; then
          RESTORE_FILE="$2"
          shift
        else
          RESTORE_FILE="latest"
        fi
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
    shift
  done
}

detect_mem_total_mb() {
  awk '
    /MemTotal:/ { printf "%d\n", ($2 + 1023) / 1024; found=1 }
    END { if (!found) print 0 }
  ' /proc/meminfo 2>/dev/null || echo 0
}

detect_mem_available_mb() {
  awk '
    /MemAvailable:/ { printf "%d\n", ($2 + 1023) / 1024; found=1 }
    END { if (!found) print 0 }
  ' /proc/meminfo 2>/dev/null || echo 0
}

profile_for_mem() {
  local mb="$1"

  # VPS 的 MemTotal 通常低于标称内存。
  # 规则：
  #   >900MB  视为 1G 档
  #   >1800MB 视为 2G 档
  if [ "$mb" -gt 1800 ] 2>/dev/null; then
    echo "P2"
  elif [ "$mb" -gt 900 ] 2>/dev/null; then
    echo "P1"
  else
    echo "P0"
  fi
}

set_profile_vars() {
  PROFILE="$(normalize_profile "$1")"

  case "$PROFILE" in
    P0)
      PROFILE_DESC="P0 - MemTotal <=900MB / 32MB buffer"
      RMEM_DEFAULT="262144"
      WMEM_DEFAULT="262144"
      BUFFER_BYTES="33554432"
      NETDEV_BACKLOG="100000"
      TW_BUCKETS="500000"
      SWAPPINESS="20"
      DIRTY_RATIO="10"
      VFS_CACHE_PRESSURE="80"
      MIN_FREE_KBYTES="32768"
      ;;
    P1)
      PROFILE_DESC="P1 - MemTotal >900MB 且 <=1800MB / 64MB buffer"
      RMEM_DEFAULT="524288"
      WMEM_DEFAULT="524288"
      BUFFER_BYTES="67108864"
      NETDEV_BACKLOG="150000"
      TW_BUCKETS="1000000"
      SWAPPINESS="10"
      DIRTY_RATIO="15"
      VFS_CACHE_PRESSURE="70"
      MIN_FREE_KBYTES="49152"
      ;;
    P2)
      PROFILE_DESC="P2 - MemTotal >1800MB / 128MB buffer / 推荐"
      RMEM_DEFAULT="1048576"
      WMEM_DEFAULT="1048576"
      BUFFER_BYTES="134217728"
      NETDEV_BACKLOG="250000"
      TW_BUCKETS="2000000"
      SWAPPINESS="5"
      DIRTY_RATIO="15"
      VFS_CACHE_PRESSURE="50"
      MIN_FREE_KBYTES="65536"
      ;;
    P3)
      PROFILE_DESC="P3 - 极致暴力 / 256MB buffer / 8G-16G 高 RTT 吞吐"
      RMEM_DEFAULT="1048576"
      WMEM_DEFAULT="1048576"
      BUFFER_BYTES="268435456"
      NETDEV_BACKLOG="250000"
      TW_BUCKETS="2000000"
      SWAPPINESS="5"
      DIRTY_RATIO="15"
      VFS_CACHE_PRESSURE="50"
      MIN_FREE_KBYTES="65536"
      ;;
  esac
}

confirm_p3() {
  local ans=""

  [ "$AUTO_YES" = "1" ] && return 0

  echo ""
  warn "P3 会使用 256MB TCP buffer。"
  warn "仅建议 8G-16G 内存、5G-10G 带宽、高 RTT、跨境大吞吐场景使用。"
  warn "不建议 2G/4G 小内存机器默认使用 P3。"
  read -r -p "如果确认要用 P3，请输入 YES: " ans || ans=""
  [ "$ans" = "YES" ] || die "已取消 P3。"
}

choose_profile() {
  local detected_mb available_mb auto_profile choice

  if [ -n "$FORCED_PROFILE" ]; then
    [ "$FORCED_PROFILE" = "P3" ] && confirm_p3
    set_profile_vars "$FORCED_PROFILE"
    return 0
  fi

  detected_mb="$(detect_mem_total_mb || echo 0)"
  available_mb="$(detect_mem_available_mb || echo 0)"
  auto_profile="$(profile_for_mem "$detected_mb")"

  if [ "$AUTO_YES" = "1" ]; then
    set_profile_vars "$auto_profile"
    return 0
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " gnar TCP sysctl 调优档位选择器 v${VERSION}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "检测到总内存 MemTotal:       ${detected_mb} MB"
  echo "检测到可用内存 MemAvailable: ${available_mb} MB"
  echo "自动推荐档位: ${auto_profile}"
  echo ""
  echo "说明：分档按 MemTotal 总内存判断，不按当前剩余内存判断。"
  echo "规则：<=900MB=P0，>900MB=P1，>1800MB=P2。"
  echo ""
  echo "1. 自动按检测内存选择：<=900MB=P0，>900MB=P1，>1800MB=P2，默认"
  echo "2. 强制 P0：32MB buffer，推荐 <=900MB"
  echo "3. 强制 P1：64MB buffer，推荐 >900MB 且 <=1800MB"
  echo "4. 强制 P2：128MB buffer，推荐 >1800MB"
  echo "5. 极致暴力 P3：256MB buffer，仅建议 8G-16G / 5G-10G 高 RTT"
  echo "0. 退出"
  echo ""

  read -r -p "请选择 [回车=自动 ${auto_profile}]: " choice || choice=""
  choice="${choice:-1}"

  case "$choice" in
    1)
      set_profile_vars "$auto_profile"
      ;;
    2)
      set_profile_vars "P0"
      ;;
    3)
      set_profile_vars "P1"
      ;;
    4)
      set_profile_vars "P2"
      ;;
    5)
      confirm_p3
      set_profile_vars "P3"
      ;;
    0)
      exit 0
      ;;
    *)
      die "无效选择。"
      ;;
  esac
}

choose_ipv4_forward() {
  local ans=""

  if [ "$AUTO_YES" = "1" ]; then
    IPV4_FORWARD_VALUE="1"
    return 0
  fi

  echo ""
  echo "是否开启 IPv4 内核转发？[Y/n]"
  echo "用途：Docker/Compose 容器出网、IPv4 NAT、网关、TProxy、透明代理、iptables/nftables 转发。"
  echo "默认：Y，开启 net.ipv4.ip_forward。"
  echo "说明：脚本不修改 IPv6 转发。需要 IPv6 转发的人应手动配置。"
  read -r -p "请选择 [Y/n]: " ans || ans=""
  ans="${ans:-y}"

  case "$ans" in
    y|Y)
      IPV4_FORWARD_VALUE="1"
      ;;
    n|N)
      IPV4_FORWARD_VALUE="0"
      ;;
    *)
      die "IPv4 转发选项无效，只能输入 y 或 n。"
      ;;
  esac
}

choose_icmp() {
  local ans=""

  if [ "$AUTO_YES" = "1" ]; then
    ICMP_ECHO_IGNORE_VALUE="0"
    return 0
  fi

  echo ""
  echo "是否禁止 ICMP Echo，也就是禁 ping？[y/N]"
  echo "默认：N，不禁止。"
  echo "输入 y 表示禁止 IPv4 和 IPv6 ping。"
  echo "注意：这里不禁整个 ICMPv6，只禁 echo，避免破坏 IPv6 邻居发现和 PMTUD。"
  read -r -p "请选择 [y/N]: " ans || ans=""
  ans="${ans:-n}"

  case "$ans" in
    y|Y)
      ICMP_ECHO_IGNORE_VALUE="1"
      ;;
    n|N)
      ICMP_ECHO_IGNORE_VALUE="0"
      ;;
    *)
      die "ICMP 选项无效，只能输入 y 或 n。"
      ;;
  esac
}

generate_config() {
  cat > "$TMP_FILE" <<EOF
# gnar sysctl 调优配置
# 生成时间: $(date -Is 2>/dev/null || date)
# 选择档位: ${PROFILE_DESC}
#
# 带宽假设: 2.5G-10G
# 业务假设: 代理、隧道、跨境转发、高吞吐网络服务
# 分档逻辑: 默认认为机器是大带宽，按 MemTotal 总内存选择 TCP buffer 上限。

# [通用] 系统级文件句柄池。
# 高并发连接需要足够的全局文件句柄。
# 这不是单进程 nofile；服务进程还要配合 ulimit 或 systemd LimitNOFILE。
fs.file-max = 6815744

# [通用] 单进程 nofile 可设置的系统上限。
# 如果 systemd LimitNOFILE 配到 1048576，这里必须允许到这个值。
fs.nr_open = 1048576

# [通用] BBR + fq 核心组合。
# BBR 负责拥塞控制，fq 负责 pacing；两者建议成套使用。
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# [通用] listen accept 队列上限。
# 大带宽机器更容易遇到连接突增；65535 比 8192 更不容易把应用层 accept 队列顶满。
net.core.somaxconn = 65535

# [通用] SYN 半连接队列。
# 与 tcp_syncookies 搭配，提高公网入口面对突发连接时的抗压能力。
net.ipv4.tcp_max_syn_backlog = 16384

# [按档位] 网卡入口 backlog。
# P0/P1 降低该值，避免小内存机器在内核队列里堆太多包。
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}

# [通用] SYN cookies。
# SYN backlog 有压力时兜底，降低半连接队列被打满的影响。
net.ipv4.tcp_syncookies = 1

# [通用] accept 队列溢出时不立刻 RST。
# 0 更适合代理、WebSocket、隧道类长连接；1 会让新连接快速失败。
net.ipv4.tcp_abort_on_overflow = 0

# [按档位] socket 默认缓冲。
# 小内存档位降低默认值，减少每条连接的基础内存压力。
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}

# [按档位] socket 缓冲上限。
# 这是 2.5G-10G 大带宽调优里最关键的分档参数。
# P0=32MB, P1=64MB, P2=128MB, P3=256MB.
net.core.rmem_max = ${BUFFER_BYTES}
net.core.wmem_max = ${BUFFER_BYTES}

# [按档位] TCP 收发缓冲: 最小值 默认值 最大值。
# 第三个值建议与 rmem_max/wmem_max 成套一致。
# 配合 tcp_moderate_rcvbuf=1，Linux 会按连接需求自动增长接收缓冲。
net.ipv4.tcp_rmem = 4096 87380 ${BUFFER_BYTES}
net.ipv4.tcp_wmem = 4096 65536 ${BUFFER_BYTES}

# [通用] 开启 TCP 接收缓冲自动调节。
net.ipv4.tcp_moderate_rcvbuf = 1

# [通用] 接收窗口通告策略。
# 2 更偏向给高 BDP 链路暴露更大的可用接收窗口。
net.ipv4.tcp_adv_win_scale = 2

# [通用] TCP 窗口缩放。
# 大于 64KB 的 TCP 窗口必须依赖它。
net.ipv4.tcp_window_scaling = 1

# [通用] TCP Fast Open，同时允许客户端和服务端角色。
net.ipv4.tcp_fastopen = 3

# [通用] 连接空闲后不重新进入慢启动。
# 对 WebSocket、代理长连接、间歇性突发流量更友好。
net.ipv4.tcp_slow_start_after_idle = 0

# [通用] 不保存旧 TCP metrics。
# 避免历史路径指标影响新的代理、CDN、跨境目标连接。
net.ipv4.tcp_no_metrics_save = 1

# [通用] 关闭 ECN，优先保证复杂路径兼容性。
net.ipv4.tcp_ecn = 0

# [通用] 开启 MTU 黑洞探测。
# 隧道、跨境、Cloudflare、复杂中转路径建议开启。
net.ipv4.tcp_mtu_probing = 1

# [通用] SACK 选择性确认。
# 高 BDP 链路丢包恢复更依赖它。
net.ipv4.tcp_sack = 1

# [通用] TCP timestamps。
# 用于 RTT 测量和 PAWS，保留开启。
net.ipv4.tcp_timestamps = 1

# [通用] 限制未发送 TCP 队列。
# 降低应用写入过快但还没真正发到线路上的排队量。
net.ipv4.tcp_notsent_lowat = 16384

# [通用] 更快清理 FIN 状态。
# 适合高并发代理类工作负载。
net.ipv4.tcp_fin_timeout = 15

# [通用] 复用符合条件的 TIME_WAIT socket。
# 对大量出站短连接、代理转发有帮助。
net.ipv4.tcp_tw_reuse = 1

# [按档位] TIME_WAIT 数量上限。
# 小内存档位降低上限，避免 TIME_WAIT 占用过多内核内存。
net.ipv4.tcp_max_tw_buckets = ${TW_BUCKETS}

# [通用] TCP keepalive。
# 应用开启 SO_KEEPALIVE 后，用于更快发现失效长连接。
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# [通用] SYN 重试次数。
# 目标不可达时更快失败，减少连接状态占用时间。
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

# [通用] UDP 最小缓冲。
# 为 QUIC、Hysteria、UDP relay 等场景保留。
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# [通用] 本地临时端口范围。
# 给大量出站连接提供更宽的端口池。
net.ipv4.ip_local_port_range = 1024 65535

# [按档位] VM 内存策略。
# 小内存档位更积极回收；P2/P3 更偏向服务稳定和吞吐。
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = ${DIRTY_RATIO}
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}
vm.min_free_kbytes = ${MIN_FREE_KBYTES}

# [通用] 服务器调度倾向。
# 减少桌面交互调度和自动 NUMA 迁移带来的噪声。
kernel.sched_autogroup_enabled = 0
kernel.numa_balancing = 0

# [交互] IPv4 内核转发。
# 1 表示开启 Docker/Compose 容器出网、IPv4 NAT、TProxy、网关、透明代理转发。
# 默认 1，避免 Docker/Compose、NAT、转发机因为 ip_forward=0 断网。
# 脚本不修改 IPv6 转发；需要 IPv6 转发的人应手动配置。
net.ipv4.ip_forward = ${IPV4_FORWARD_VALUE}

# [交互] 禁止 ICMP Echo，也就是禁 ping。
# IPv6 这里只禁 echo，不禁整个 ICMPv6，避免破坏邻居发现和 PMTUD。
# 默认 0，不禁止。
net.ipv4.icmp_echo_ignore_all = ${ICMP_ECHO_IGNORE_VALUE}
net.ipv6.icmp.echo_ignore_all = ${ICMP_ECHO_IGNORE_VALUE}

# [特殊场景提示] route_localnet 不作为通用调优项默认写入。
# 如果你明确需要 DNAT/REDIRECT 到 127.0.0.1、本机代理回环路由、特殊透明代理，
# 可以手动开启下面这一项；普通 Docker/Compose 容器出网通常不需要。
# net.ipv4.conf.all.route_localnet = 1

EOF
}

collect_unsupported_keys() {
  local key
  UNSUPPORTED_KEYS=""

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! sysctl -n "$key" >/dev/null 2>&1; then
      UNSUPPORTED_KEYS="${UNSUPPORTED_KEYS}${key}
"
    fi
  done < <(
    awk -F= '/^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
      key=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      print key
    }' "$TMP_FILE"
  )
}

check_bbr_support() {
  local available=""

  if [ "$(id -u)" = "0" ] && command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr 2>/dev/null || true
  fi

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! echo "$available" | grep -qw bbr; then
    warn "当前内核可用拥塞控制里没有看到 bbr: ${available:-未知}"
    warn "脚本仍会写入配置，但 tcp_congestion_control=bbr 可能应用失败。"
  fi
}

preflight() {
  local ans=""

  [ "$DRY_RUN" = "1" ] && return 0

  check_bbr_support
  collect_unsupported_keys

  if [ -n "$UNSUPPORTED_KEYS" ]; then
    echo ""
    warn "当前系统可能不支持以下 sysctl 参数:"
    printf "%s" "$UNSUPPORTED_KEYS" | sed 's/^/  - /'
    warn "脚本会用 sysctl -e -p 应用，未知参数会被忽略；请留意应用输出。"
  fi

  [ "$AUTO_YES" = "1" ] && return 0

  echo ""
  echo "即将覆盖写入: ${SYSCTL_FILE}"
  echo "选择档位: ${PROFILE_DESC}"
  echo "TCP buffer: ${BUFFER_BYTES} bytes"
  echo "IPv4 内核转发: ${IPV4_FORWARD_VALUE}"
  echo "禁止 ICMP Echo: ${ICMP_ECHO_IGNORE_VALUE}"
  echo ""
  echo "会先创建备份，格式类似: ${SYSCTL_FILE}.bak.YYYYmmddHHMMSS"
  echo "应用后如需恢复，可执行: bash $(script_name) --restore latest"
  echo ""
  read -r -p "确认备份、覆盖 /etc/sysctl.conf，并执行 sysctl -p？[Y/n]: " ans || ans=""
  ans="${ans:-Y}"

  case "$ans" in
    y|Y|yes|YES) ;;
    *) die "已取消，没有写入任何内容。" ;;
  esac
}

backup_current() {
  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  BACKUP_FILE="${SYSCTL_FILE}.bak.${ts}"

  if [ -f "$SYSCTL_FILE" ]; then
    cp -a "$SYSCTL_FILE" "$BACKUP_FILE"
    echo "已备份: $BACKUP_FILE"
  fi
}

apply_config() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "━━━━━━━━━━━━━━━━ 将生成的配置 ━━━━━━━━━━━━━━━━"
    cat "$TMP_FILE"
    echo "━━━━━━━━━━━━━━━━ 配置结束 ━━━━━━━━━━━━━━━━"
    return 0
  fi

  backup_current
  install -m 0644 "$TMP_FILE" "$SYSCTL_FILE"

  echo ""
  echo "正在应用: sysctl -e -p ${SYSCTL_FILE}"
  if sysctl -e -p "$SYSCTL_FILE"; then
    echo "sysctl 应用完成。"
  else
    warn "sysctl 应用时返回错误，请检查上方输出。"
  fi
}

latest_backup() {
  ls -1t "${SYSCTL_FILE}".bak.* 2>/dev/null | head -n 1 || true
}

restore_config() {
  local src ts

  if [ -z "$RESTORE_FILE" ] || [ "$RESTORE_FILE" = "latest" ]; then
    src="$(latest_backup)"
  else
    src="$RESTORE_FILE"
  fi

  [ -n "${src:-}" ] || die "没有找到备份: ${SYSCTL_FILE}.bak.*"
  [ -f "$src" ] || die "备份文件不存在: $src"

  ts="$(date +%Y%m%d%H%M%S)"
  if [ -f "$SYSCTL_FILE" ]; then
    cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.pre-restore.${ts}" 2>/dev/null || true
    echo "恢复前当前配置已另存为: ${SYSCTL_FILE}.pre-restore.${ts}"
  fi

  install -m 0644 "$src" "$SYSCTL_FILE"
  echo "已恢复: $src -> $SYSCTL_FILE"

  echo ""
  echo "正在应用: sysctl -e -p ${SYSCTL_FILE}"
  if sysctl -e -p "$SYSCTL_FILE"; then
    echo "恢复配置应用完成。"
  else
    warn "恢复配置应用时返回错误，请检查上方输出。"
  fi
}

verify_config() {
  local keys key value

  keys="
net.ipv4.tcp_congestion_control
net.core.default_qdisc
net.core.rmem_max
net.core.wmem_max
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.core.somaxconn
net.ipv4.tcp_max_syn_backlog
net.core.netdev_max_backlog
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_abort_on_overflow
net.ipv4.ip_forward
net.ipv4.icmp_echo_ignore_all
net.ipv6.icmp.echo_ignore_all
"

  echo ""
  echo "关键参数当前值:"
  for key in $keys; do
    value="$(sysctl -n "$key" 2>/dev/null || echo "unsupported")"
    printf "  %-38s %s\n" "$key" "$value"
  done

  echo ""
  if ! sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw bbr; then
    warn "当前拥塞控制不是 bbr，请检查: sysctl net.ipv4.tcp_available_congestion_control"
  fi

  if [ -n "${BACKUP_FILE:-}" ]; then
    echo ""
    echo "恢复本次备份:"
    echo "  bash $(script_name) --restore $BACKUP_FILE"
    echo "恢复最新备份:"
    echo "  bash $(script_name) --restore latest"
  fi

  echo ""
  echo "说明：脚本没有执行 sysctl --system。"
  echo "原因：sysctl --system 会同时加载 sysctl.d 里的配置，可能覆盖 /etc/sysctl.conf 的结果。"
}

main() {
  parse_args "$@"

  if [ "$DO_RESTORE" = "1" ]; then
    need_root
    restore_config
    verify_config
    exit 0
  fi

  if [ "$DRY_RUN" != "1" ]; then
    need_root
  fi

  choose_profile
  choose_ipv4_forward
  choose_icmp
  generate_config
  preflight
  apply_config

  if [ "$DRY_RUN" != "1" ]; then
    verify_config
  fi
}

main "$@"
