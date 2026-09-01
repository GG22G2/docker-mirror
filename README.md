# docker-mirror

一个基于 GitHub Actions 的 Docker 镜像搬运工具：把公网镜像仓库（Docker Hub、GHCR、Quay 等）的镜像同步到阿里云容器镜像服务 ACR，供国内服务器拉取。

适用场景：国内环境无法直接访问国外镜像源时，以 GitHub Actions 作为中转，把需要的镜像先搬到自己的 ACR 仓库里。

## 功能特性

- **手动触发**：编辑镜像清单提交后，到 Actions 页面一键运行，或用 `gh workflow run` 触发
- **多源支持**：Docker Hub、GHCR、Quay.io、registry.k8s.io 等任何公开镜像源
- **平台可控**：默认同步 amd64，可按镜像标记 arm64 或全部架构
- **直传不落盘**：使用 skopeo registry-to-registry 直传，不占用 Runner 磁盘，速度快
- **完整性校验**：每个镜像同步后自动比对镜像ID（镜像配置的 sha256）与源站是否一致
- **可用性验证**：内置验证工作流，可对任意 tag 做真实拉取 + 运行测试
- **失败隔离**：单个镜像同步失败不影响其他镜像，结束时汇总报告

## 工作原理

```
images.txt（镜像清单） → sync.yml（手动触发） → sync.sh（解析 / 命名 / 校验）
                                                → skopeo copy → 阿里云 ACR
```

所有镜像统一推送到 ACR 的同一个仓库，用 tag 区分不同镜像。

## 配置

| 配置项 | 位置 | 说明 |
|---|---|---|
| Registry 登录凭据 | 仓库 Secrets：`ALIYUN_ACR_USERNAME` / `ALIYUN_ACR_PASSWORD` | ACR 的用户名和固定密码 |
| Registry 地址 | `sync.yml` 的 env（`REGISTRY` / `DEST_REPO`），`sync.sh` 中有同名默认值 | 目标 ACR 实例域名和仓库路径 |

## 镜像清单格式

`images.txt` 每行一个镜像，`#` 开头为注释，字段用 `|` 分隔：

| 字段 | 必填 | 说明 |
|---|---|---|
| 1. 镜像地址 | ✅ | 支持短名或全称，如 `nginx:1.27`、`quay.io/foo/bar:v1` |
| 2. 自定义 tag | | 不填则自动生成（见下方命名规则） |
| 3. 平台标记 | | `all`=全部架构，`arm`=ARM64；不填默认 amd64 |

示例：

```
nginx:1.27                    → ck:nginx_1.27          (amd64)
redis:7.4 | my_redis          → ck:my_redis            (amd64)
alpine:3.20 | | arm           → ck:alpine_3.20         (arm64)
alpine:3.20 | my_tag | all    → ck:my_tag              (全部架构)
```

## 命名规则

自动生成的 tag：**去掉 registry 域名，路径中的 `/` 替换为 `_`，追加 `_版本号`**，整体转小写：

| 源镜像 | 生成的 tag |
|---|---|
| `nginx:1.27` | `nginx_1.27` |
| `quay.io/prometheus/prometheus:v2.53.0` | `prometheus_prometheus_v2.53.0` |
| `nginx`（无版本号） | `nginx_latest` |

说明：

- 不同 registry 下路径相同的镜像（如 `quay.io/a/b` 与 `ghcr.io/a/b`）会生成相同 tag，后推的覆盖先推的，需要时用自定义 tag 区分
- `all` 模式推送多架构清单（manifest list），控制台通常不显示镜像ID/大小，属正常现象，拉取与运行不受影响
- 指定架构（amd64/arm）时，源站没有该架构会直接报错；`all` 模式则是源站有什么搬什么，不会因缺架构失败

## 使用

**同步镜像**：编辑 `images.txt` 提交后：

- Actions 页面：**同步镜像到阿里云ACR → Run workflow**
- 或命令行（也可用 `-f images="nginx:1.27 redis:7.4"` 临时指定，默认同步整个清单）：

```bash
gh workflow run sync.yml
```

**验证镜像**：对已同步的 tag 做真实拉取运行测试（amd64 原生运行，arm64 通过 QEMU 模拟）：

```bash
gh workflow run verify.yml -f image=nginx_1.27 \
  -f run_command="nginx -v" \
  -f source_image=nginx:1.27   # 可选，用于对比镜像ID
```

**从 ACR 拉取**：

```bash
docker pull <Registry域名>/<仓库路径>:<tag>
```

## 依赖与限制

- Ubuntu Runner 上自动安装 skopeo（apt）
- 验证工作流使用 docker/setup-qemu-action 模拟运行 arm64
- 仅支持从公开镜像源同步；私有源需要额外增加登录步骤
