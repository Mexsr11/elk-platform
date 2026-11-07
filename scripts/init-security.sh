#!/usr/bin/env bash
# =============================================================================
# init-security.sh —— 幂等初始化 ES 的安全对象（可反复执行）
#
# 作用：
#   ① 创建/更新角色 filebeat_writer（最小权限，只能写 supplier-logs*）
#   ② 创建/更新用户 filebeat_writer（密码取自 .env 的 FILEBEAT_PASSWORD）
#   ③ 设置 Kibana 服务账号 kibana_system 的密码（取自 KIBANA_SYSTEM_PASSWORD）
#   ④ 自检：写入应 201、读取应 403
#
# 用法：
#   cd ~/elk-platform
#   ./scripts/init-security.sh
#
# 前置：.env 里有 ELASTIC_PASSWORD / FILEBEAT_PASSWORD / KIBANA_SYSTEM_PASSWORD，
#       且 certs/ca/ca.crt 存在（Lab 6 的产出）
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

API="https://${NODE_IP}:9200"
CURL=(curl --cacert certs/ca/ca.crt -s -u "elastic:${ELASTIC_PASSWORD}")

for v in ELASTIC_PASSWORD FILEBEAT_PASSWORD KIBANA_SYSTEM_PASSWORD NODE_IP; do
  if [ -z "${!v:-}" ]; then
    echo "✗ .env 缺少 ${v}，请先补齐" >&2
    exit 1
  fi
done

echo "== 1/4 创建角色 filebeat_writer =="
"${CURL[@]}" -X PUT "$API/_security/role/filebeat_writer" \
  -H 'Content-Type: application/json' -d '{
  "cluster": ["monitor", "manage_index_templates", "manage_ilm"],
  "indices": [{
    "names": ["supplier-logs*", ".ds-supplier-logs*"],
    "privileges": ["create_doc", "auto_configure", "view_index_metadata"]
  }]
}' -w "  HTTP=%{http_code}\n"

echo "== 2/4 创建用户 filebeat_writer =="
"${CURL[@]}" -X POST "$API/_security/user/filebeat_writer" \
  -H 'Content-Type: application/json' -d "{
  \"password\": \"${FILEBEAT_PASSWORD}\",
  \"roles\": [\"filebeat_writer\"],
  \"full_name\": \"Filebeat log shipper\"
}" -w "  HTTP=%{http_code}\n"

echo "== 3/4 设置 kibana_system 密码 =="
"${CURL[@]}" -X POST "$API/_security/user/kibana_system/_password" \
  -H 'Content-Type: application/json' -d "{
  \"password\": \"${KIBANA_SYSTEM_PASSWORD}\"
}" -w "  HTTP=%{http_code}\n"

echo "== 4/4 权限自检 =="
FB=(curl --cacert certs/ca/ca.crt -s -u "filebeat_writer:${FILEBEAT_PASSWORD}")
W=$("${FB[@]}" -o /dev/null -w '%{http_code}' -X POST "$API/supplier-logs-2026.11.03/_doc" \
  -H 'Content-Type: application/json' -d "{\"@timestamp\":\"$(date -Iseconds)\",\"message\":\"init-security probe\"}")
R=$("${FB[@]}" -o /dev/null -w '%{http_code}' "$API/supplier-logs-2026.11.03/_search")
echo "  写入=${W}（期望 201）  读取=${R}（期望 403）"

if [ "$W" = "201" ] && [ "$R" = "403" ]; then
  echo "✓ 安全对象初始化完成"
else
  echo "✗ 自检未通过，请检查角色定义与密码" >&2
  exit 1
fi
