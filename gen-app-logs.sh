#!/usr/bin/env bash
# =============================================================================
# gen-app-logs.sh —— 生成模拟的 Spring Boot 日志，用于 Lab 5 采集实验
#
# 用法：
#   ./gen-app-logs.sh                      # 默认写 /var/log/app，生成 300 条
#   ./gen-app-logs.sh /var/log/app 1000    # 生成 1000 条
#   ./gen-app-logs.sh /var/log/app 0       # 持续输出，Ctrl+C 停止
#
# 生成的内容刻意包含三类，用来验证 Filebeat 的能力：
#   ① 标准 INFO/WARN 行  → 验证 grok 解析
#   ② 带耗时的慢请求      → 验证 spring.duration_ms 提取
#   ③ 多行 Java 堆栈      → 验证 multiline 合并
# =============================================================================
set -euo pipefail

LOG_DIR="${1:-/var/log/app}"
COUNT="${2:-300}"
LOG_FILE="$LOG_DIR/supplier-app.log"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

LEVELS=(INFO INFO INFO INFO INFO INFO WARN ERROR)
LOGGERS=(
  "c.l.s.controller.SupplierController"
  "c.l.s.service.SupplierService"
  "c.l.s.mapper.SupplierMapper"
  "c.l.s.controller.ContractController"
)
MSGS=(
  "查询供应商列表"
  "新增供应商档案"
  "更新供应商资质"
  "分页查询供应商"
  "导出对账数据"
  "同步合同状态"
  "供应商分级评估"
  "校验供应商准入材料"
)

# -----------------------------------------------------------------------------
# 时间戳：必须精确到毫秒
#
# 注意：Ubuntu 26.04 的 date 是 uutils（Rust 实现），
# 它的 %3N 不是「三位毫秒」，而是输出完整九位纳秒 —— 这是个坑。
# 所以这里用 %N 取全量纳秒再用 cut 截到毫秒，跨实现都安全。
# -----------------------------------------------------------------------------
now_ms() {
  date '+%Y-%m-%d %H:%M:%S.%N' | cut -c1-23
}

emit_normal() {
  local ts lvl logger msg ms tid
  ts=$(now_ms)
  lvl=${LEVELS[$((RANDOM % ${#LEVELS[@]}))]}
  logger=${LOGGERS[$((RANDOM % ${#LOGGERS[@]}))]}
  msg=${MSGS[$((RANDOM % ${#MSGS[@]}))]}
  ms=$((RANDOM % 500 + 5))
  tid=$((RANDOM % 10 + 1))
  # 格式对齐 Spring Boot 默认 logback 输出：级别右对齐 5 位
  printf '%s %5s 12345 --- [http-nio-8081-exec-%d] %s : %s, 耗时 %dms\n' \
    "$ts" "$lvl" "$tid" "$logger" "$msg" "$ms" >>"$LOG_FILE"
}

# 多行堆栈：只有第一行带时间戳，后面四行都是「续行」
emit_stacktrace() {
  local ts
  ts=$(now_ms)
  {
    printf '%s ERROR 12345 --- [http-nio-8081-exec-1] %s : 数据库连接超时\n' \
      "$ts" "c.l.s.service.SupplierService"
    printf 'java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30001ms.\n'
    printf '\tat com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)\n'
    printf '\tat com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:197)\n'
    printf '\tat com.liao.supplier.service.SupplierService.list(SupplierService.java:88)\n'
  } >>"$LOG_FILE"
}

if [[ "$COUNT" == "0" ]]; then
  echo "持续输出模式，写入 $LOG_FILE（Ctrl+C 停止）"
  i=0
  while true; do
    i=$((i + 1))
    if (( i % 25 == 0 )); then emit_stacktrace; else emit_normal; fi
    if (( i % 20 == 0 )); then
      echo "  已生成 $i 条，当前文件 $(wc -l <"$LOG_FILE") 行"
    fi
    sleep 0.3
  done
else
  echo "生成 $COUNT 条模拟日志 -> $LOG_FILE"
  for i in $(seq 1 "$COUNT"); do
    if (( i % 25 == 0 )); then emit_stacktrace; else emit_normal; fi
    sleep 0.01
  done
  echo "完成：文件共 $(wc -l <"$LOG_FILE") 行，大小 $(du -h "$LOG_FILE" | cut -f1)"
  echo ""
  echo "前 3 行预览："
  head -3 "$LOG_FILE" | sed 's/^/  /'
fi
