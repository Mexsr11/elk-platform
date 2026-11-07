#!/usr/bin/env bash
# =============================================================================
# gen-env.sh —— 从 .env.example 生成本机 .env
#
# 用法（在仓库根目录或 scripts/ 下执行均可）：
#   ./scripts/gen-env.sh <节点名> <本机IP> <种子列表>
#
# 示例：
#   ./scripts/gen-env.sh es01 192.168.132.11 "192.168.132.12:9300,192.168.132.13:9300"
#   ./scripts/gen-env.sh es02 192.168.132.12 "192.168.132.11:9300,192.168.132.13:9300"
#   ./scripts/gen-env.sh es03 192.168.132.13 "192.168.132.11:9300,192.168.132.12:9300"
#
# 只用三个参数，避免手改 .env 敲错 IP。
# =============================================================================
set -euo pipefail

NODE_NAME="${1:?用法: $0 <节点名> <本机IP> <种子列表>}"
NODE_IP="${2:?缺少本机 IP，例: 192.168.132.11}"
SEEDS="${3:?缺少种子列表，例: 192.168.132.12:9300,192.168.132.13:9300}"

# 定位到仓库根目录（脚本所在目录的上一级）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env.example ]]; then
  echo "找不到 .env.example，请确认在仓库根目录" >&2
  exit 1
fi

# 简单校验 IP 格式，防止少写一个点这类错误
if ! [[ "$NODE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "IP 格式不合法: $NODE_IP（应形如 192.168.132.11）" >&2
  exit 1
fi

if [[ "$SEEDS" == *"$NODE_IP"* ]]; then
  echo "提示：SEED_HOSTS 里包含本机 IP（$NODE_IP），通常只需要填另外两台" >&2
fi

sed -e "s|^NODE_NAME=.*|NODE_NAME=${NODE_NAME}|" \
    -e "s|^NODE_IP=.*|NODE_IP=${NODE_IP}|" \
    -e "s|^SEED_HOSTS=.*|SEED_HOSTS=${SEEDS}|" \
    .env.example > .env

echo "已生成 .env（来自 .env.example）"
echo "----------------------------------------"
grep -E '^(NODE_NAME|NODE_IP|NODE_ROLES|SEED_HOSTS|INITIAL_MASTER_NODES)=' .env
echo "----------------------------------------"
echo "下一步： docker compose config   # 确认变量替换结果"
