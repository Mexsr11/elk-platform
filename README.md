# 三节点 ELK 日志平台（Elasticsearch 8.19 + Filebeat + Kibana）

一套可复现的多主机日志平台：**采集 → 传输加密 → 结构化解析 → 生命周期治理 → 可视化**，
全部用 Docker Compose 编排，配置与密钥分离，带 13 条真实故障记录与压测数据。

## 架构

```
                 Windows 宿主机（VMware Workstation / VMnet8 NAT 192.168.132.0/24）
                 │
   ┌─────────────┼──────────────────┬──────────────────┐
   │             │                  │                  │
 es01(.11)     es02(.12)          es03(.13)          （网关 .2）
 4G / 2C       2.5G / 2C          2.5G / 2C
 ├─ es01 容器  ├─ es02 容器       ├─ es03 容器        集群 elk-prod
 │  9200/9300  │  9200/9300       │  9200/9300        master×3 + data×3 + ingest×3
 ├─ filebeat   │                  │                   数据流 supplier-logs-*
 └─ kibana     │                  │                   ILM: hot 1GB/1d → delete 7d
```

| 组件 | 版本 | 说明 |
|---|---|---|
| Elasticsearch | 8.19.0 | 3 节点，host 网络，双层 TLS（9200 客户端 / 9300 节点间） |
| Filebeat | 8.19.0 | filestream 采集 + 多行合并，HTTPS + `filebeat_writer` 最小权限 |
| Kibana | 8.19.0 | 仅 es01，`kibana_system` 服务账号，bridge 网络 + 端口映射 |

## 目录结构

```
elk-platform/
├── docker-compose.yml              # Lab 4：多主机集群（明文版）
├── docker-compose.tls.yml          # Lab 6：TLS 版集群
├── docker-compose.filebeat.yml     # Lab 5：Filebeat HTTP 版
├── docker-compose.filebeat-tls.yml # Lab 6：Filebeat HTTPS 版（三节点 hosts）
├── docker-compose.kibana.yml       # Lab 9：Kibana TLS 版
├── docker-compose.sandbox.yml      # Lab 3：单机三节点沙盒
├── filebeat.yml / filebeat-tls.yml # 采集配置
├── es-pipeline.json                # ingest pipeline（grok + date，4 个处理器）
├── filebeat-role.json              # 最小权限角色定义
├── instance.yml                    # 节点证书申请清单（SAN）
├── gen-app-logs.sh                 # 样例日志生成器（406 行，含堆栈）
├── scripts/
│   ├── bootstrap.sh                # 主机基线（幂等）
│   ├── gen-env.sh                  # 生成各机 .env
│   └── init-security.sh            # 角色 / 用户 / kibana_system 密码（幂等）
├── docs/
│   ├── architecture.md             # 架构与设计取舍
│   ├── runbook.md                  # 13 条真实故障（现象→排查→根因→解决→面试讲法）
│   └── metrics.md                  # 实测指标（TLS、压测、ILM、资源）
└── certs/                          # 不进 Git
    ├── ca/ca.crt                   # 根证书（三台都有）
    ├── ca/ca.key                   # 根私钥（只在 es01，权限 600）
    └── <node>/<node>.crt|.key      # 节点证书（SAN 含 IP + 主机名 + 回环）
```

## 快速开始（从裸机到可用，约 40 分钟）

```bash
# ① 主机基线（每台一次）：主机名、静态 IP、hosts、chrony、max_map_count、关 swap、Docker
sudo ./scripts/bootstrap.sh es01 192.168.132.11/24 192.168.132.2

# ② 生成各机配置（差异只有 3 个变量）
./scripts/gen-env.sh es01 192.168.132.11 "192.168.132.12:9300,192.168.132.13:9300"

# ③ 证书：CA + 节点证书（三套），分发时排除 ca.key
docker run --rm --user root -v "$PWD/certs:/certs" \
  docker.elastic.co/elasticsearch/elasticsearch:8.19.0 \
  bin/elasticsearch-certutil ca --silent --pem --out /certs/elastic-stack-ca.zip
# 解压 → 用 instance.yml 签节点证书 → rsync --exclude='ca.key' 到另两台

# ④ 起 TLS 集群（三台同时，不能滚动）
docker compose -f docker-compose.tls.yml up -d

# ⑤ 下发解析管道
curl --cacert certs/ca/ca.crt -u "elastic:$ELASTIC_PASSWORD" \
  -X PUT "https://192.168.132.11:9200/_ingest/pipeline/supplier-mgmt-parse" \
  -H 'Content-Type: application/json' --data-binary @es-pipeline.json

# ⑥ 安全对象（角色/用户/Kibana 服务账号），幂等
./scripts/init-security.sh

# ⑦ 采集
docker compose -f docker-compose.filebeat-tls.yml up -d

# ⑧ 可视化
docker compose -f docker-compose.kibana.yml up -d
# 浏览器 http://192.168.132.11:5601  用 elastic 登录（不是 kibana_system）
```

## 常用运维命令

```bash
cd ~/elk-platform && set -a && . ./.env && set +a
C="--cacert certs/ca/ca.crt -s -u elastic:$ELASTIC_PASSWORD"
API="https://192.168.132.11:9200"

curl $C "$API/_cluster/health?pretty"                       # 集群健康
curl $C "$API/_cat/nodes?v&h=name,master,heap.percent,ram.percent"
curl $C "$API/_cat/thread_pool/write?v&h=node_name,active,queue,rejected"
curl $C "$API/_cat/indices/.ds-supplier*?h=index,docs.count,store.size"
curl $C "$API/.ds-supplier-logs-2026.11.03-2026.11.03-000001/_ilm/explain?pretty"  # ILM 阶段与原因
docker compose -f docker-compose.filebeat-tls.yml logs --tail 50                   # 采集日志
docker logs --tail 50 kibana | grep -E "available|FATAL"
```

## 关键设计取舍

| 决策 | 原因 |
|---|---|
| ES 用 `network_mode: host` | transport 需要固定端口与真实 IP，bridge 会让 `publish_address` 通告错误 |
| 没有 Logstash | 每台 2.5 GiB，Logstash 是 JVM 重组件；解析放 ES ingest pipeline，改规则不用重启采集端 |
| 堆 768m | 不超过物理内存一半；512m 时压测会 OOM（`exit 137`） |
| transport 用 `verification_mode: certificate` | 节点以 IP 互连，宽松模式只校验证书链，避免多网卡导致握手失败 |
| 三台同时切 TLS | transport 加密是全局约束，不能滚动升级 |
| ILM 只配 hot + delete | 没有专用 warm 节点，配 `allocate` 会让索引卡在 ERROR |
| Kibana 用 bridge + `SERVER_HOST=0.0.0.0` | 容器内没有宿主机 IP，对外暴露交给 `ports` |

## 已知限制

- Kibana 的 5601 仍是 HTTP（TLS 只覆盖 ES 层），生产应由 Nginx 反代做 TLS 终止
- 采集的是脚本生成的样例日志（`gen-app-logs.sh`），未接入真实阿里云上的业务系统
- 无监控告警体系（可接 Metricbeat + 告警规则），无快照备份（可接 S3/OSS 仓库）
- 单机磁盘 26 GiB，仅适合学习与小流量验证

## 文档

| 文件 | 内容 |
|---|---|
| `docs/runbook.md` | 13 条真实故障：docker 源被墙、LVM 扩容、`INITIAL_MASTER_NODES` 空值、90 插件、CA 路径、`.env` 重复、Kibana `EADDRNOTAVAIL` 等 |
| `docs/metrics.md` | 证书参数、TLS 实测、权限矩阵、bulk 压测、ILM 时序、资源占用 |
| `docs/architecture.md` | 分层架构与取舍 |
