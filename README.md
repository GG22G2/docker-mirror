# docker-mirror

借助 GitHub Actions 把公网镜像（Docker Hub / GHCR / Quay 等）搬运到**阿里云容器镜像服务 ACR**。
阿里云服务器访问不了国外镜像源，本仓库就是中转站。

## 使用步骤

### 1. 配置密钥（只需一次）

仓库 **Settings → Secrets and variables → Actions → New repository secret**，添加两个机密：

| 名称 | 值 |
|---|---|
| `ALIYUN_ACR_USERNAME` | `gg2gg2` |
| `ALIYUN_ACR_PASSWORD` | 阿里云 ACR 的固定密码（容器镜像服务「访问凭证」页面设置的那个） |

也可以在本地用命令设置（密码不会显示在聊天/日志里）：

```bash
gh secret set ALIYUN_ACR_USERNAME -R GG22G2/docker-mirror
gh secret set ALIYUN_ACR_PASSWORD -R GG22G2/docker-mirror
```

### 2. 编辑镜像清单

编辑 [images.txt](images.txt)，每行一个镜像，字段用 `|` 分隔：

```
nginx:1.27                    → 自动推送为 ck:nginx_1.27          (amd64)
quay.io/foo/bar:v1.2          → 自动推送为 ck:foo_bar_v1.2        (amd64)
redis:7.4 | my_redis          → 自定义 tag，推送为 ck:my_redis     (amd64)
alpine:3.20 | | arm           → 推送 arm64 版 ck:alpine_3.20
alpine:3.20 | my_tag | all    → 推送全部架构为 ck:my_tag
```

- 平台字段不填默认 **amd64**（与手动 `docker pull` + `docker push` 的效果一致）
- `all` 模式保留全部架构，但阿里云控制台对这类 tag 不显示镜像ID/大小（镜像本身完好可用）
- 改完提交到 main 分支

### 3. 手动执行

- 网页：**Actions → 同步镜像到阿里云ACR → Run workflow** → Run workflow
- 或本地命令：

```bash
gh workflow run sync.yml -R GG22G2/docker-mirror
```

运行时也可以在输入框里临时指定镜像（空格分隔，默认 amd64），不填就同步整个 `images.txt`。

### 4. 从阿里云拉取

```bash
docker pull crpi-xm8affxmcnbpks63.cn-shanghai.personal.cr.aliyuncs.com/gg22g2/ck:<tag>
```

### 5. 验证某个镜像能不能用

**Actions → 验证ACR镜像 → Run workflow**，填入 tag（如 `postgres_17`）：

- 会从阿里云拉取该镜像并真实运行（amd64 原生跑，arm64 用 QEMU 模拟跑）
- `run_command` 可填容器内要执行的命令（如 `postgres --version`），留空用镜像默认命令
- `source_image` 填源镜像（如 `postgres:17`）可自动对比镜像ID

命令行触发示例：

```bash
gh workflow run verify.yml -R GG22G2/docker-mirror \
  -f image=postgres_17 -f run_command="postgres --version" -f source_image=postgres:17
```

## 命名规则

统一推到 `gg22g2/ck` 这一个仓库，靠 tag 区分用途：`ck:<名称>_<版本>`，
多级路径用 `_` 连接，整体转小写。需要完全自定义就用 `| 自定义tag` 语法。

## 实现说明

- 用 `skopeo copy` **registry 直传**：不在 Runner 上落盘解包，速度快
- 默认同步 amd64 单架构；`| arm` 拉 arm64；`| all` 保留多架构清单
- 每个镜像同步完自动**校验镜像ID**（镜像配置的 sha256）与源站一致，结果打印在 Actions 日志里
- 同步逻辑都在 [sync.sh](sync.sh)，工作流只是壳；改逻辑改这个文件
- 同一时刻只允许一个同步任务在跑（concurrency 排队），不会互相打架
- 默认手动触发；想定时自动跑，把 [.github/workflows/sync.yml](.github/workflows/sync.yml) 里 `schedule` 那几行取消注释
