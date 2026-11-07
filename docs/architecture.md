# 架构设计

> 待补充：Lab 3 跑通后填写实测拓扑与关键决策。

## 关键决策

### 1. 多主机为什么用 host 网络

默认 bridge 网络下容器 IP 只在主机本地有效，跨主机不可路由；
且 Elasticsearch 会把容器内网 IP 作为 `publish_address` 通告给集群，
其他节点据此连接必然失败。改用 `network_mode: host`，
ES 直接监听主机内网 IP，`discovery.seed_hosts` 填真实内网 IP。

代价：一台主机只能跑一个 ES 实例（本项目一机一节点，可接受）。

### 2. 为什么用 Docker Compose 而非 K8s

3 台机器上 K8s 控制面开销接近业务本身，属于过度设计。
节点数上到 10+ 或需要滚动发布/自动扩缩容时再考虑迁移。

### 3. 一份 compose 模板 + 每机 .env

三台共用同一份 `docker-compose.yml`，差异收敛到 `.env` 的三个变量：
`NODE_NAME` / `NODE_IP` / `SEED_HOSTS`。
