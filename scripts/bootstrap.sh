#!/usr/bin/env bash
# =============================================================================
# bootstrap-26.04.sh  —  ELK 节点主机基线初始化
#
# 适配：Ubuntu Server 24.04 / 26.04 LTS（systemd-networkd 渲染）
# 用途：把一台刚装好的 Ubuntu Server 一次性调成 ELK 节点基线
# 幂等：可重复执行，不会因为跑第二遍出问题
#
# 用法：
#   sudo ./bootstrap-26.04.sh <节点名> <本机IP/CIDR> [网关]
#
# 示例：
#   sudo ./bootstrap-26.04.sh es01 10.0.0.11/24 10.0.0.1
#   sudo ./bootstrap-26.04.sh es02 10.0.0.12/24 10.0.0.1
#   sudo ./bootstrap-26.04.sh es03 10.0.0.13/24 10.0.0.1
# =============================================================================

set -euo pipefail

# ---------- 可调参数 ----------
CLUSTER_HOSTS=(
  "192.168.132.11 es01"
  "192.168.132.12 es02"
  "192.168.132.13 es03"
)
DNS_SERVERS="223.5.5.5,192.168.132.2"
TIMEZONE="Asia/Shanghai"
DISABLE_SWAP=1          # 1=关 swap（≥4G 内存建议关）；2.5G 虚机改成 0
DATA_DIR="/data/elasticsearch"

# ---------- 参数校验 ----------
if [[ $EUID -ne 0 ]]; then
  echo "请用 sudo 运行：sudo $0 es01 10.0.0.11/24 10.0.0.1" >&2
  exit 1
fi

NODE_NAME="${1:-}"
NODE_CIDR="${2:-}"
GATEWAY="${3:-10.0.0.1}"

if [[ -z "$NODE_NAME" || -z "$NODE_CIDR" ]]; then
  echo "用法：sudo $0 <节点名> <本机IP/CIDR> [网关]" >&2
  echo "示例：sudo $0 es01 10.0.0.11/24 10.0.0.1" >&2
  exit 1
fi

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
step() { printf '\n\033[1;34m[%s]\033[0m %s\n' "$1" "$2"; }

# =============================================================================
# SSH 会话自保护
# 改静态 IP 会立刻切断当前 SSH 连接，脚本随之被 SIGHUP 杀死，结果只改了一半。
# 判断依据用 stdin 是否为 tty：手动 ssh 进去敲命令时为真 → 自动转后台。
# 非交互调用（管道喂密码）时为假 → 由调用方用 systemd-run 脱离会话。
# =============================================================================
if [[ -t 0 && "${_BOOTSTRAP_DETACHED:-0}" != "1" ]]; then
  LOG=/var/log/elk-bootstrap.log
  echo
  echo "⚠  检测到交互式会话：第 3 步改静态 IP 会断开当前连接。"
  echo "   脚本将自动转入后台继续执行，不会中断。"
  echo "   日志：$LOG"
  echo "   改完后用新地址重连：ssh ${SUDO_USER:-root}@${NODE_CIDR%/*}"
  echo
  _BOOTSTRAP_DETACHED=1 setsid "$0" "$@" >"$LOG" 2>&1 </dev/null &
  echo "已转入后台运行。查看进度： tail -f $LOG"
  exit 0
fi

# =============================================================================
step 1/8 "设置主机名"
# =============================================================================
hostnamectl set-hostname "$NODE_NAME"
ok "主机名 -> $NODE_NAME"

# =============================================================================
step 2/8 "配置 /etc/hosts"
# =============================================================================
cp -n /etc/hosts "/etc/hosts.bak.$(date +%s)" 2>/dev/null || true
# 先清掉本脚本以前写过的段，保证幂等
sed -i '/# >>> elk-cluster >>>/,/# <<< elk-cluster <<</d' /etc/hosts
{
  echo "# >>> elk-cluster >>>"
  for h in "${CLUSTER_HOSTS[@]}"; do echo "$h"; done
  echo "# <<< elk-cluster <<<"
} >> /etc/hosts
ok "已写入 ${#CLUSTER_HOSTS[@]} 条节点解析"

# =============================================================================
step 3/8 "配置静态 IP (netplan + systemd-networkd)"
# =============================================================================
IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
if [[ -z "$IFACE" ]]; then
  IFACE="$(ip -br link | awk '$1!="lo"{print $1; exit}')"
fi
ok "检测到网卡：$IFACE"

NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
if [[ -f "$NETPLAN_FILE" ]]; then
  cp -n "$NETPLAN_FILE" "${NETPLAN_FILE}.bak" 2>/dev/null || true
fi

cat > "$NETPLAN_FILE" <<EOF
# 由 bootstrap-26.04.sh 生成
# 注意：26.04 已移除 gateway4 写法，必须用 routes + to: default
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: no
      dhcp6: no
      addresses: [${NODE_CIDR}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [$(echo "$DNS_SERVERS" | tr ',' ', ')]
EOF

# 26.04 的 netplan 1.2 会对 world-readable 配置报警告
chmod 600 "$NETPLAN_FILE"
ok "已写入 $NETPLAN_FILE"

echo "    正在应用网络配置（如果 SSH 断开说明 IP 变了，用新 IP 重连即可）..."
netplan apply
sleep 2
ok "当前地址：$(ip -4 -o addr show "$IFACE" | awk '{print $4}')"

# =============================================================================
step 4/8 "配置 apt 镜像源 + 时区与时间同步"
# =============================================================================
# 先换国内源，否则后面装 Docker / chrony / open-vm-tools 会慢到怀疑人生
# Ubuntu 24.04 起默认是 deb822 格式的 ubuntu.sources，不再是 sources.list
# =============================================================================
APTSRC=""
if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
  APTSRC=/etc/apt/sources.list.d/ubuntu.sources
elif [[ -f /etc/apt/sources.list ]]; then
  APTSRC=/etc/apt/sources.list
fi
if [[ -n "$APTSRC" ]]; then
  cp -n "$APTSRC" "${APTSRC}.bak" 2>/dev/null || true
  sed -i \
    -e 's|http://archive.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' \
    -e 's|http://security.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' \
    -e 's|http://cn.archive.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' \
    "$APTSRC"
  if DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1; then
    ok "apt 已切换到清华镜像($(grep -c tuna "$APTSRC") 条源)"
  else
    echo "    !! 清华源不可达，回滚为官方源" >&2
    cp "${APTSRC}.bak" "$APTSRC"
    apt-get update -q >/dev/null 2>&1 || true
  fi
fi

timedatectl set-timezone "$TIMEZONE"
if ! dpkg -s chrony >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q chrony >/dev/null 2>&1 || true
fi
systemctl enable --now chrony >/dev/null 2>&1 || true
ok "时区 $(timedatectl show -p Timezone --value)，等待 NTP 同步..."
chronyc -a 'burst 4/4' >/dev/null 2>&1 || true
sleep 3
chronyc tracking 2>/dev/null | grep -E 'Reference ID|System time' | sed 's/^/    /' || true

# VMware 虚机：open-vm-tools 负责「优雅关机」和「时间同步」
# 没有它，从 VMware 菜单强制关机 = 拔电源，ES 的 Lucene 段可能损坏
if command -v systemd-detect-virt >/dev/null 2>&1 && [[ "$(systemd-detect-virt)" == "vmware" ]]; then
  if ! dpkg -s open-vm-tools >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q open-vm-tools >/dev/null 2>&1 || true
  fi
  if dpkg -s open-vm-tools >/dev/null 2>&1; then
    systemctl enable --now open-vm-tools >/dev/null 2>&1 || true
    ok "open-vm-tools 就绪（虚机可优雅关机）"
  else
    echo "    !! open-vm-tools 未安装，建议手动 apt install open-vm-tools" >&2
  fi
fi

# =============================================================================
step 5/8 "内核参数 vm.max_map_count（ES 启动的硬性门槛）"
# =============================================================================
cat > /etc/sysctl.d/99-elasticsearch.conf <<'EOF'
# Elasticsearch 要求：单个进程可用的内存映射区数量
vm.max_map_count=262144
# 尽量不用 swap（配合 bootstrap.memory_lock）
vm.swappiness=1
EOF
sysctl --system >/dev/null 2>&1
ok "vm.max_map_count = $(sysctl -n vm.max_map_count)"

# =============================================================================
step 6/8 "swap 处理"
# =============================================================================
if [[ "$DISABLE_SWAP" == "1" ]]; then
  swapoff -a 2>/dev/null || true
  sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab
  ok "已关闭 swap（/etc/fstab 已注释）"
else
  # 内存不足 4G 时加 2G swap 保命
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  swapon /swapfile 2>/dev/null || true
  ok "swap 已启用：$(free -h | awk '/Swap/{print $2}')"
fi

# =============================================================================
step 7/8 "安装 Docker + Compose 插件"
# =============================================================================
if command -v docker >/dev/null 2>&1; then
  ok "Docker 已存在：$(docker --version)，跳过安装"
else
  echo "    从清华镜像安装 docker-ce（get.docker.com 在国内会被重置）..."
  CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
  install -d -m 0755 /etc/apt/keyrings
  if curl -fsSL -m 30 https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu ${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -q >/dev/null 2>&1
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
         docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
         >/dev/null 2>&1; then
      ok "docker-ce 安装完成（清华源）"
    else
      echo "    !! docker-ce 装失败，回退 Ubuntu 官方源的 docker.io" >&2
      rm -f /etc/apt/sources.list.d/docker.list
      apt-get update -q >/dev/null 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker.io docker-compose-v2 >/dev/null 2>&1 || true
    fi
  else
    echo "    !! 镜像 GPG 获取失败，回退 Ubuntu 官方源的 docker.io" >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker.io docker-compose-v2 >/dev/null 2>&1 || true
  fi
fi
systemctl enable --now docker >/dev/null 2>&1
# systemd-run / cron 等非登录场景下 SUDO_USER 不存在，回退到第一个普通用户
DOCKER_USER="${SUDO_USER:-}"
if [[ -z "$DOCKER_USER" || "$DOCKER_USER" == "root" ]]; then
  DOCKER_USER=$(awk -F: '$3>=1000 && $3<60000 {print $1; exit}' /etc/passwd)
fi
if [[ -n "$DOCKER_USER" ]]; then
  usermod -aG docker "$DOCKER_USER" 2>/dev/null || true
  ok "已将 $DOCKER_USER 加入 docker 组（重新登录后免 sudo）"
fi
ok "docker compose 版本：$(docker compose version --short 2>/dev/null || echo '需重新登录生效')"

# =============================================================================
step 8/8 "创建 ES 数据目录"
# =============================================================================
mkdir -p "$DATA_DIR"
# ES 容器内 elasticsearch 用户 uid=1000
chown -R 1000:1000 "$DATA_DIR"
ok "$DATA_DIR 属主 $(stat -c '%u:%g' "$DATA_DIR")"

# =============================================================================
echo
echo "============================================================"
echo "  节点 $NODE_NAME 初始化完成"
echo "============================================================"
echo "  主机名    : $(hostname)"
echo "  IP        : $(ip -4 -o addr show "$IFACE" | awk '{print $4}')"
echo "  网关      : $GATEWAY"
echo "  max_map   : $(sysctl -n vm.max_map_count)"
echo "  时区      : $(timedatectl show -p Timezone --value)"
echo "  Docker    : $(docker --version 2>/dev/null || echo '未安装')"
echo "  数据目录  : $DATA_DIR"
echo
echo "  下一步："
echo "    1. 退出并重新登录（或 newgrp docker）使 docker 组生效"
echo "    2. 验证互通：ping es02 && nc -zv es02 22"
echo "    3. 部署 ELK：git clone <仓库> ~/elk-platform && cd ~/elk-platform"
echo "============================================================"
