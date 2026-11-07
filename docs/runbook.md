# 故障处置手册（Runbook）

> 记录实际遇到并解决的问题。格式：现象 → 排查 → 根因 → 解决 → 预防。

## #1 Docker 安装失败：download.docker.com 连接被重置

**现象**

```
+ sh -c curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" -o /etc/apt/keyrings/docker.asc
curl: (35) Recv failure: Connection reset by peer
```

`curl -I https://get.docker.com` 返回 HTTP 000，完全不可达。

**排查**

先确认不是本机网络问题（apt update 正常），再单独测 `download.docker.com`，
发现 TCP 能建连但 TLS 握手阶段被重置——典型的链路层干扰，不是配置错误。

**根因**

Docker 官方域名（get.docker.com / download.docker.com）在境内网络不可稳定访问。

**解决**

改用国内镜像源的 docker-ce 仓库，并确认目标发行版目录存在：

```bash
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")   # 26.04 -> resolute
curl -fsSL https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] \
https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

**预防**

脚本中保留兜底路径：镜像源失败时回退 `apt install docker.io docker-compose-v2`。

---

## #2 改静态 IP 时初始化脚本被中断

**现象**

脚本执行到第 6 步后没了下文：hostname、IP、max_map_count、时区、swap 都生效，
但 Docker 未安装、`/data/elasticsearch` 未创建。

**排查**

`netplan apply` 的瞬间 IP 从 `.135` 变为 `.11`，SSH 连接断开。
脚本原本依赖 `SSH_CONNECTION` 环境变量判断是否在远程会话中，但 `sudo` 的
`env_reset` 会清掉该变量，导致自保护逻辑没触发，进程被 SIGHUP 杀死。

**根因**

判断依据选错了环境变量。`sudo` 默认重置环境，`SSH_*` 系列不一定保留。

**解决**

改用 `[[ -t 0 ]]` 判断 stdin 是否为终端；外部启动时用 systemd 托管彻底脱离会话：

```bash
sudo systemd-run --unit=elk-bootstrap --collect \
  -p StandardOutput=file:/var/log/elk-bootstrap.log \
  -p StandardError=append:/var/log/elk-bootstrap.log \
  /bin/bash /tmp/bootstrap.sh es01 192.168.132.11/24 192.168.132.2
```

**预防**

脚本保持幂等，任何步骤中断后重跑即可补齐。

---

## #3 磁盘 40G 但系统只看到 19G

**现象**

```bash
$ sudo growpart /dev/sda 3
CHANGE: partition 3 could only be grown by 2015 [fudge=2048]

$ sudo resize2fs /dev/sda3
resize2fs: Device or resource busy while trying to open /dev/sda3
Couldn't find valid filesystem superblock.

$ df -h /
/dev/mapper/ubuntu--vg-ubuntu--lv   19G  7.6G  11G  44% /
```

**排查**

逐层往下看容量，不要跳：

```bash
df -h /      # 19G
lvs          # LV 只有 19G
vgs          # VFree 19G  ← 空间卡在这一层
pvs          # PFree 19G
lsblk        # sda 40G, sda3 38G
```

分区已经贴着磁盘末尾（所以 growpart 只能扩 2KB），
`/dev/sda3` 是 LVM 的 PV，上面没有文件系统，`resize2fs` 必然失败。

**根因**

Ubuntu 安装器使用 LVM 时，root 逻辑卷只分配了部分空间，
剩余留在卷组（VG）中未分配。

**解决**

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv      # ext4 支持在线扩容
```

**预防**

口诀：`df` 小看 `lvs` → `lvs` 小看 `vgs` 的 VFree → VFree 小看 `pvs` 的 PFree
→ PFree 也小才是分区/磁盘层的问题。

---

## #4 清空 INITIAL_MASTER_NODES 后节点无限重启（退出码 70）

**现象**

集群 green 后按手册执行「清空 `cluster.initial_master_nodes`」，把 `.env` 改成：

```bash
INITIAL_MASTER_NODES=
```

重建容器后节点陷入重启循环：

```
$ docker ps -a
NAMES   STATUS
es02    Restarting (70) 14 seconds ago
```

日志反复输出同一段堆栈：

```
org.elasticsearch.ElasticsearchParseException:
null-valued setting found for key [cluster.initial_master_nodes]
        at org.elasticsearch.common.settings.Settings.validateValue(Settings.java:840)
        at org.elasticsearch.node.InternalSettingsPreparer.loadOverrides(...)
        at org.elasticsearch.cli.Command.main(...)
```

**排查过程**

1. `docker ps -a` 看到 `Restarting (70)`——70 是 ES 的**配置错误**退出码，不是 OOM（OOM 是 137），先排除内存问题
2. `docker logs --tail 30 es02` 抓到完整堆栈，异常类型 `ElasticsearchParseException` 说明是配置解析失败，不是运行时错误
3. 关键行：`null-valued setting found for key [cluster.initial_master_nodes]`
   —— compose 里写的是 `- cluster.initial_master_nodes=${INITIAL_MASTER_NODES}`，
   `.env` 为空 → 渲染成 `cluster.initial_master_nodes=""` → ES 解析为 null → 拒绝启动
4. 用 `docker compose config` 交叉验证，输出确实是 `cluster.initial_master_nodes: ""`，
   证明是「值存在但为空」，而不是「配置缺失」

**根因**

ES 对这个 key 的校验不允许「存在但值为 null」。

在 ES 的语义里，「清空」不等于「设成空字符串」，而是「整个 key 不存在」。
这一点在多数配置项上无所谓，但 `cluster.initial_master_nodes` 校验严格，直接拒绝启动。

**解决**

不要动 `.env`，改 `docker-compose.yml`：**把整行注释掉**。

```yaml
      # - cluster.initial_master_nodes=${INITIAL_MASTER_NODES}
```

确认最终配置里确实没这个字段：

```bash
docker compose config | grep -i initial_master_nodes     # 应该无输出
```

**验证**

逐台重建，确认都能在无引导名单的情况下加入集群：

```bash
docker exec es02 env | grep -i initial_master     # 无输出 = 变量已移除
docker compose up -d elasticsearch                # 重建容器
curl -s http://192.168.132.11:9200/_cluster/health | grep status
```

实测三台逐一重启的结果：

| 重启节点 | 角色 | 恢复耗时 | 结果 |
|---|---|---|---|
| es02 | 数据节点 | 16 秒 | green / 3 节点 |
| es03 | 数据节点 | 24 秒 | green / 3 节点 |
| es01 | **master** | 21 秒 | es03 在 5 秒内接任 master |

**预防**

- 集群组建完成后，该配置必须「整行移除」，不能设空值
- 只有集群数据全部丢失、需要从零重新组建时，才取消注释并填名单
- 说明已写入 `.env.example` 与 `docker-compose.yml` 的注释，避免下次再踩

**面试怎么讲（30 秒）**

> ES 的 `cluster.initial_master_nodes` 只在首次引导时有效，官方要求组建完成后移除。
> 我最初的理解是「清空」，把它设成空值，结果节点直接退出码 70，因为 ES 把这个 key 的
> null 值判定为配置错误，抛 `ElasticsearchParseException`。正确做法是整行注释掉，
> 让这个 key 根本不存在。改完后我逐台重启验证，包括重启 master——es03 在 5 秒内接任，
> 集群 21 秒恢复 green。

---

## #5 host 网络模式下 curl localhost:9200 无响应

**现象**

三个容器 `docker ps` 显示全部 `Up`，但健康检查命令没有任何输出：

```bash
$ curl -s localhost:9200/_cluster/health
                      # ← 什么都没有，像卡住了
```

**排查过程**

1. `-s` 把错误信息也吞掉了，先看端口到底监听在哪：

```bash
$ ss -tlnp | grep -E ':(9200|9300)'
LISTEN  [::ffff:192.168.132.11]:9200
LISTEN  [::ffff:192.168.132.11]:9300
```

只监听内网 IP，**`127.0.0.1` 上没有任何进程**。

2. 换成 `-sS` 重跑，错误才露出来：

```bash
$ curl -sS -m 5 localhost:9200
curl: (7) Failed to connect to localhost port 9200: Connection refused
```

3. 用正确地址验证，集群其实是好的：

```bash
$ curl -s http://192.168.132.11:9200/_cluster/health?pretty
  "status" : "green",  "number_of_nodes" : 3
```

**根因**

`network.host=${NODE_IP}` 让 ES 只绑定内网 IP。host 模式下容器直接使用宿主机网络栈，
**没有 Docker 的 DNAT 把 `127.0.0.1:9200` 转发进去**，所以 localhost 必然连不上。

对比 Lab 3 的 bridge 模式：那里有 `ports: 127.0.0.1:9200:9200`，Docker 做端口映射，
所以 `curl localhost` 能通——**那是 DNAT 的功劳，不是 ES 监听在 localhost**。

| | bridge（Lab 3） | host（Lab 4） |
|---|---|---|
| compose | `ports: 127.0.0.1:9200:9200` | 无 ports 段 |
| ES 实际监听 | 容器内 `0.0.0.0:9200` | 宿主机 `192.168.132.11:9200` |
| `curl localhost` | ✅ 通（DNAT） | ❌ 不通 |

**解决**

用内网 IP 或主机名：

```bash
curl -s http://192.168.132.11:9200/_cluster/health?pretty
curl -s http://es01:9200/_cluster/health?pretty        # /etc/hosts 已映射
```

**预防**

- 排查时不要用 `curl -s`，用 `curl -sS`——`-s` 静默会把错误也吞掉，看起来像「服务没响应」
- Lab 4 之后所有 curl 走 IP / 主机名，不用 localhost
- 判断绑定地址的第一条命令永远是 `ss -tlnp | grep 9200`

---

## #6 Filebeat 配置校验报 must be owned by uid=0 or root

**现象**

```bash
$ docker run --rm -v "$PWD/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro" \
    --user root docker.elastic.co/beats/filebeat:8.19.0 test config -e

Exiting: error loading config file: config file ("filebeat.yml")
must be owned by the user identifier (uid=0) or root
```

加了 `--user root` 也没用，甚至加了 `sudo` 也没用。

**排查过程**

1. 确认加了 `--user root`——是的，但报错不变，说明问题不在运行用户
2. 看文件属主：`ls -l filebeat.yml` → `-rw-rw-r-- 1 root1 root1`，uid 1000
3. 关键认知：`--user root` 改变的是**容器里进程以谁的身份运行**，
   而**文件属主是文件系统属性**，由宿主机上那个文件决定，挂载不会改它
4. 所以容器里以 root 运行，但读到的文件还是属于 uid 1000，检查依然失败

**根因**

Filebeat 有个安全策略：配置文件不能被 group/world 写入，且必须属于 root。
容器场景下挂载进来的文件属主是宿主用户（uid 1000），天然不满足。

**解决**

加 `--strict.perms=false` 跳过权限检查：

```bash
docker run --rm \
  -v "$PWD/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro" \
  --user root \
  docker.elastic.co/beats/filebeat:8.19.0 \
  test config -e --strict.perms=false
```

或者改文件属主（但 rsync 到别的机器又要改一次）：

```bash
sudo chown root:root filebeat.yml
```

**验证**

输出末行应为 `Config OK`。

**预防**

- `docker-compose.filebeat.yml` 的 `command` 里已经带 `--strict.perms=false`，
  正常 `up -d` 不受影响
- **只有手动跑 `test config` 时最容易漏**——因为那是一条手敲的完整命令

**面试怎么讲（20 秒）**

> Filebeat 会检查配置文件不能被 group/world 写入、且必须属于 root。容器里挂载的
> 文件属主是宿主机上的用户 uid 1000，加 `--user root` 只改了运行进程的身份，
> 改不了文件属主，所以照样报错。正确做法是 `--strict.perms=false`——文件是只读
> 挂载的，篡改风险已经消除了。

---

## #7 Filebeat 报 processor action grok does not exist

**现象**

```
Exiting: error initializing processors: the processor action grok does not exist.
Valid actions: include_fields, truncate_fields, ... dissect, decode_json_fields,
add_fields, ...
```

配置里写 `processors: - grok: ...`，Filebeat 直接拒绝启动。

**根因**

**Filebeat 的 processors 不支持 grok。** 可用动作列表里有 `dissect`，
没有 `grok`。grok 是 **Logstash** 和 **ES ingest pipeline** 的能力。

网上大量教程写「在 Filebeat 里配 grok」，其实是从 Logstash 配置抄来的。

**为什么不能用 dissect 替代**

`dissect` 按固定分隔符切分，而 Spring Boot 日志的级别是右对齐的：

```
2026-11-03 09:58:02.463 ERROR 12345 ...    ← ERROR 前 1 个空格
2026-11-03 09:58:02.482  INFO 12345 ...    ← INFO  前 2 个空格
```

连续两个空格会被 `dissect` 切成空字段，导致整条记录错位。
`grok` 用 `\s+` 一个 pattern 就能通吃。

**解决**

把解析从 Filebeat 移到 ES 的 ingest pipeline：

① 在 ES 创建 pipeline（内容见 `es-pipeline.json`）

```bash
curl -s -XPUT "http://192.168.132.11:9200/_ingest/pipeline/supplier-mgmt-parse?pretty" \
  -H "Content-Type: application/json" -d @es-pipeline.json
```

② Filebeat 侧删掉 grok processor，改为指定 pipeline

```yaml
output.elasticsearch:
  hosts: ["http://192.168.132.11:9200"]
  pipeline: "supplier-mgmt-parse"
```

**验证**

```bash
# 用 _simulate 单独测 pipeline，不用等数据进来
curl -s -XPOST "http://192.168.132.11:9200/_ingest/pipeline/supplier-mgmt-parse/_simulate?pretty" \
  -H "Content-Type: application/json" -d "{\"docs\":[{\"_source\":{\"message\":\"2026-11-03 09:58:02.482  INFO 12345 --- [x] c.l.s.X : msg, 耗时 341ms\"}}]}"
```

返回里应有 `spring.level` = INFO、`spring.duration_ms` = 341、`spring.slow` = true。

**意外收获**

这个分层其实更好：**改解析规则只动 pipeline，不用重启采集器**。
生产上重启 Filebeat 意味着中间几十秒日志采集是断的。

**面试怎么讲（30 秒）**

> 我一开始想当然地在 Filebeat 里配了 grok，结果它直接拒绝启动——Filebeat 的
> processors 只有 dissect，没有 grok，grok 是 Logstash 和 ES ingest pipeline 的能力。
> 而 dissect 按固定分隔符切，处理不了 Spring Boot 日志里级别右对齐的多空格。
> 所以我把结构化解析移到了 ES 的 ingest pipeline，Filebeat 只负责采集和多行合并。
> 这样改解析规则不用重启采集器，生产上这点很重要。


---

## #8 切 TLS 后容器无限重启：ca.crt 路径少了一层目录

**现象**

三台 `docker compose -f docker-compose.tls.yml up -d` 后，`/_cluster/health` 连续 3 分钟无响应。

```bash
$ docker inspect es01 --format 'state={{.State.Status}} restarts={{.RestartCount}}'
state=running restarts=8            # 一直在重启循环
```

容器日志里的致命错误：

```
fatal exception while booting Elasticsearch
ElasticsearchSecurityException: failed to load SSL configuration [xpack.security.http.ssl]
- cannot read configured PEM certificate_authorities
[/usr/share/elasticsearch/config/certs/ca.crt] because the file does not exist
```

**排查过程**

1. 先确认证书真的存在：`ls -R certs/` → `certs/ca/ca.crt` 和 `certs/es01/es01.crt` 都在
2. 再看挂载：`- ./certs:/usr/share/elasticsearch/config/certs:ro`
   → 宿主机 `certs/ca/ca.crt` 映射到容器是 `config/certs/ca/ca.crt`（**多一层 ca/**）
3. 而 compose 里写的是 `config/certs/ca.crt` —— 少了 `ca/` 这一级
4. 对照节点证书路径 `${NODE_NAME}/${NODE_NAME}.crt` 是对的（certs/es01/es01.crt 正好两级）

**根因**

证书目录是 `certs/<名字>/<文件>` 的两级结构，CA 也是 `certs/ca/ca.crt`，
但写配置时按“certs 下直接放 ca.crt”的一级结构写了。**挂载点 + 相对路径没对齐**。

**解决**

transport 和 http 两处都要改（`sed` 一次替换）：

```bash
sed -i 's#config/certs/ca.crt#config/certs/ca/ca.crt#g' docker-compose.tls.yml
docker compose -f docker-compose.tls.yml up -d --force-recreate
```

**验证**

```bash
curl -k -s -u "elastic:密码" https://192.168.132.11:9200/_cluster/health
# 约 30 秒内：status=green, number_of_nodes=3
```

**预防**

改完 compose 先算一遍“容器内路径”：
`挂载目标 + 宿主机相对路径`。或者直接进容器看一眼：

```bash
docker compose -f docker-compose.tls.yml run --rm --entrypoint ls elasticsearch \
  -l /usr/share/elasticsearch/config/certs/ca
```

**面试怎么讲（30 秒）**

> 切 TLS 时三个节点全在重启循环，日志说找不到 ca.crt。证书其实都在，问题是
> 挂载是 `./certs:/…/config/certs`，而 CA 在 certs 下的 ca/ 子目录里，容器内
> 应该是 config/certs/ca/ca.crt，我写成了 config/certs/ca.crt，少一层。
> 这类问题的通用排查方法是把“挂载点 + 相对路径”拼出来跟宿主机 ls 的结果对齐，
> 而不是反复重建容器碰运气。

**关键词**：`certificate_authorities` `file does not exist` `restarts` `挂载路径`

---

## #9 三台 .env 密码行数 2/3/1：模板里的假密码 + 追加不幂等

**现象**

手册要求三台都是 1，实测各不相同：

```bash
$ for h in es01 es02 es03; do echo "  $h: $(ssh $h 'grep -c ELASTIC_PASSWORD ~/elk-platform/.env')"; done
  es01: 2
  es02: 3
  es03: 1
```

**排查过程**

1. 打印实际内容，而不是只看数量：

```bash
ssh es01 'grep -n "PASSWORD" ~/elk-platform/.env'
```

结果三台都有一行来自模板的 `ELASTIC_PASSWORD=ChangeMe_2026!`（基线 1 行），
es01 又追加了 1 次，es02 追加了 2 次（其中一次是 `FILEBEAT_PASSWORD=Lx!` 这种 5 位短密码），
es03 一次都没追加 → 它生效的值还是模板占位值。

2. 确认生效规则：`.env` 是 dotenv 语义，**同一个 key 后面出现的覆盖前面的**，
   所以 es01/es02 实际用最后一行，es03 用模板值 —— 三台密码不一致。

3. 顺手发现 `xpack.security.enabled=false` 时，用 curl 试三个密码全是 200，
   **不能用“能不能登录”反推哪个值生效**，必须在切换前就对齐。

**根因**

两个叠加：① `.env.example` 里放了看起来像真密码的占位值 `ChangeMe_2026!`，
`gen-env.sh` 原样复制；② 手册步骤用 `cat >> .env` **追加**，重复执行就叠加。

**解决**

先删后加，保证每个变量只出现一次（已加备份）：

```bash
cd ~/elk-platform && cp .env .env.bak.$(date +%m%d-%H%M%S)
sed -i "/^ELASTIC_PASSWORD=/d; /^FILEBEAT_PASSWORD=/d" .env
cat >> .env <<'EOT'

# ---------- 安全（Lab 6）----------
ELASTIC_PASSWORD=<你的elastic密码>  # ← 真实值在 .env，不入库
FILEBEAT_PASSWORD=<你的filebeat密码>  # ← 真实值在 .env，不入库
EOT
```

模板也改掉，不再放假密码：

```bash
sed -i 's/^ELASTIC_PASSWORD=ChangeMe_2026!$/# ELASTIC_PASSWORD=   ← Lab 6 步骤 5 追加/' .env.example
```

**验证**

```bash
for h in es01 es02 es03; do
  echo "$h 行数=$(ssh $h 'grep -c ELASTIC_PASSWORD ~/elk-platform/.env') 值=$(ssh $h 'grep "^ELASTIC_PASSWORD=" ~/elk-platform/.env | tail -1')"
done
```

三台都应为 `行数=1`，且值完全相同。

**面试怎么讲（30 秒）**

> 我做一个一致性检查时发现三台 .env 里密码行数是 2/3/1，本该都是 1。
> 根因是模板文件里放了一个假密码，而加密码那步用的是 cat >> 追加，重复执行会叠加。
> dotenv 是后者覆盖前者，所以三台实际生效的密码不一样，切 TLS 时 elastic 的初始
> 密码就变成了“看哪台先启动”。修法是先删后加，并把模板里的假密码改成注释。

**关键词**：`.env` `dotenv 覆盖` `幂等` `占位值`

---

## #10 隔天开机后集群 503：master 凑不齐多数派

**现象**

早上连上去查模板，所有 API 返回 503：

```json
{"error":{"type":"master_not_discovered_exception","reason":null},"status":503}
```

但 es01 的 SSH 正常、容器 `Up 38 hours`、`/_cat` 都不通。

**排查过程**

1. 先看三台是否都活着：

```bash
for h in es01 es02 es03; do echo -n "$h: "; ssh -o ConnectTimeout=5 $h 'docker ps --format "{{.Names}} {{.Status}}" | tr "\n" " "' || echo 不可达; done
```

结果 es01 正常，**es02/es03 SSH 连接超时**。

2. 宿主机上确认虚机状态：

```bash
"/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe" list
# Total running VMs: 1     ← 只有 es01
```

3. 结论：两台虚机被挂起（Windows 睡眠/重启导致），es01 单节点无法选举 master。

**根因**

ES 的 master 选举要**多数派**（3 节点集群需要 2 票）。
`cluster.initial_master_nodes` 早在 Lab 4 就注释掉了（防止脑裂），所以不能靠“重新引导”拉起集群，
只能等其余节点回来。单节点不会"自动降级成单机模式"。

**解决**

```bash
V="/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
"$V" -T ws start "C:/Users/<user>/Documents/Virtual Machines/Ubuntu 64 位 (2)/Ubuntu 64 位 (2).vmx" nogui
"$V" -T ws start "C:/Users/<user>/Documents/Virtual Machines/Ubuntu 64 位 (3)/Ubuntu 64 位 (3).vmx" nogui
```

**验证**

```bash
# SSH 可用后，约 40 秒内集群自行恢复
curl -k -s -u "elastic:密码" https://192.168.132.11:9200/_cluster/health
# {"status":"green","number_of_nodes":3, ...}
```

**预防**

- 宿主机不要睡眠；或睡眠前先 `vmrun suspend` 三台（挂起后恢复比“直接断电”更安全）
- 开机自启：VMware 里勾选“启动时打开此虚拟机”，或写个启动脚本
- 监控上：`/_cluster/health` 返回 503 时先别怀疑数据，先确认 3 个节点都在

**面试怎么讲（30 秒）**

> 有次隔天来发现集群 503，master_not_discovered。我第一反应是数据或配置出了问题，
> 但其实是因为另外两台虚机被挂起了。3 节点集群选举要 2 票，剩一个节点永远选不出
> master，而且 initial_master_nodes 早就注释掉了，所以不会自动重建集群。把两台拉起来
> 40 秒就恢复了。这个事说明：**看到 master_not_discovered，先查节点数，再查配置**。

**关键词**：`master_not_discovered` `503` `quorum` `vmrun` `虚机挂起`

---

## #11 手写多行 JSON 下发 pipeline：Invalid \escape

**现象**

```bash
$ python3 -m json.tool /tmp/p7.json > /dev/null
Invalid \escape: line 5 column 121 (char 254)
```

JSON 文件里明明“看着对”，但解析器直接拒绝。

**排查过程**

1. 定位到报错位置：第 5 行第 121 列，正好是 grok 模式里第一个 `\s` 的位置
2. 检查该处字符：写的是 `\s`（单反斜杠），而 JSON 字符串里必须是 `\\s`
3. 追溯来源：从聊天/文档复制多行 JSON 时，`\\` 被“吃掉”了一层；heredoc 本身不会改内容（`<<'EOF'` 不做变量展开），问题出在复制环节

**根因**

JSON 的转义只有固定几个：`\" \\ \/ \b \f \n \r \t \uXXXX`。`\s` 不在其中，
而正则的 `\s` 想在 JSON 里表达，必须写成 `\\s`（JSON 解一层，剩 `\s` 给正则引擎）。

**解决**

```bash
# ① 把 JSON 落成文件，不要直接贴在命令行
cat > /tmp/p7.json <<'JSON'
{ ... "patterns": ["%{TIMESTAMP_ISO8601:spring.timestamp}\\s+%{LOGLEVEL:spring.level}"] ... }
JSON

# ② 先做语法校验，再发请求
python3 -m json.tool /tmp/p7.json > /dev/null && echo "JSON OK"

# ③ 用 --data-binary @文件 发送（保留原始换行）
curl ... -H 'Content-Type: application/json' --data-binary @/tmp/p7.json
```

**验证**

- `python3 -m json.tool` 无输出即通过
- `PUT` 返回 `{"acknowledged":true}`
- `_simulate` 能拆出 `spring.level` 等字段

**面试怎么讲（30 秒）**

> 下发 ingest pipeline 时报 Invalid \escape。JSON 里正则的 `\s` 必须写成 `\\s`，
> 因为 JSON 自己要先解一层转义。手工在多行文本里维护这种双重转义非常容易出错，
> 所以我把 pipeline 改成“文件 + 校验 + --data-binary @文件”的流程，
> 并且在 CI 里跑 `json.tool` 卡一道，避免脏配置进集群。

**关键词**：`Invalid \escape` `json.tool` `--data-binary` `双重转义`

---

## #12 换了终端就 401 / --cacert 报文件不存在

**现象**

同一条命令，昨天能跑，今天报两种错之一：

```bash
curl: The file 'certs/ca/ca.crt' provided to --cacert does not exist
curl: option --cacert: is badly used here
```

或者认证失败：

```json
{"error":{"root_cause":[{"type":"security_exception","reason":"unable to authenticate user [elastic] ..."}],"status":401}
```

**排查过程**

1. 看提示符：`root1@es01:~$` → 当前目录是 `/home/root1`，而证书在 `/home/root1/elk-platform/certs/ca/ca.crt`
2. 相对路径 `certs/ca/ca.crt` 在 `/home/root1` 下不存在 → curl 在参数阶段就报错（`is badly used here` 是它的连带提示，不是真正的错误原因）
3. 401 则说明命令发出去了，但密码是空的：`-u "elastic:$ELASTIC_PASSWORD"` 中的变量未定义，展开成 `-u "elastic:"`
4. 确认：`echo ${#ELASTIC_PASSWORD}` → `0`

**根因**

`.env` 只是文件，不会自动变成 shell 变量。新开终端 / `su` 切换用户 / 重连 SSH 后都需要重新加载。
同时 curl 的相对路径依赖当前工作目录。

**解决**

固定三步，写进笔记或 alias：

```bash
cd ~/elk-platform              # ① 工作目录
set -a; . ./.env; set +a       # ② 加载变量（set -a 让变量自动导出给子进程）
# ③ 再执行 curl
```

**验证**

```bash
pwd                            # /home/root1/elk-platform
echo ${#ELASTIC_PASSWORD}      # 17（非 0）
ls -l certs/ca/ca.crt          # 文件存在
curl --cacert certs/ca/ca.crt -s -u "elastic:$ELASTIC_PASSWORD" \
  https://192.168.132.11:9200/_security/_authenticate | grep username
```

**面试怎么讲（30 秒）**

> 排查 401 时先分清是“没发出去”还是“发出去了但认证失败”。前者是路径问题——
> curl 的相对路径依赖工作目录；后者是凭据问题——环境变量没加载。我现在固定用
> cd + source .env 两步，并且用 `_security/_authenticate` 先确认身份再执行变更操作，
> 避免在半认证状态下误判。

**关键词**：`401` `--cacert` `相对路径` `source .env`

---

## #13 Kibana 无限重启：EADDRNOTAVAIL address not available

**现象**

Kibana 容器起来就退出，反复重启：

```
FATAL  Error: listen EADDRNOTAVAIL: address not available 192.168.132.11:5601
```

**排查过程**

1. `docker ps` 看到 `kibana Restarting`，日志里只有这一条 FATAL
2. 确认端口没被占用：`ss -lntp | grep 5601` 为空——不是端口冲突
3. 关键：容器用的是 **bridge 网络**，容器内部地址是 `172.x`，根本没有 `192.168.132.11`
4. `SERVER_HOST=192.168.132.11` 让 Kibana 去绑定一个容器内不存在的地址 → 内核返回 `EADDRNOTAVAIL`

**根因**

混淆了“容器内绑定地址”和“宿主机暴露地址”：

- `SERVER_HOST` / `server.host`：**容器内**监听地址，bridge 网络下必须是 `0.0.0.0`
- `ports: "192.168.132.11:5601:5601"`：**宿主机**暴露地址，这里才写内网 IP

**解决**

```yaml
environment:
  - SERVER_HOST=0.0.0.0          # 容器内：所有网卡
ports:
  - "192.168.132.11:5601:5601"   # 宿主机：只暴露到内网 IP
```

**验证**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.132.11:5601/api/status   # 200
docker logs --tail 50 kibana | grep "Kibana is now available"
```

**面试怎么讲（30 秒）**

> Kibana 一直重启，报 EADDRNOTAVAIL。原因是容器在 bridge 网络里，我让它在容器内绑定宿主机
> 的内网 IP，而那个地址在容器内不存在。正确做法是容器内绑 0.0.0.0，宿主机用 ports 限定
> 只暴露到内网 IP。这个坑和 ES 的 host 网络正好相反——host 网络才可以直接绑内网 IP。

**关键词**：`EADDRNOTAVAIL` `SERVER_HOST` `bridge 网络` `ports 映射`
