#!/usr/bin/env bash
# 将公网镜像同步到阿里云 ACR 的 ck 仓库
# 用法:
#   bash sync.sh                  同步 images.txt 中的全部镜像
#   bash sync.sh nginx:1.27 ...   同步命令行指定的镜像（默认 amd64）
set -euo pipefail

REGISTRY="${REGISTRY:-crpi-xm8affxmcnbpks63.cn-shanghai.personal.cr.aliyuncs.com}"
DEST_REPO="${DEST_REPO:-gg22g2/ck}"
IMAGES_FILE="${IMAGES_FILE:-images.txt}"

FAILED=()
COUNT=0

trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$1"; }
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
sanitize() { lower "$1" | sed 's/[^a-z0-9._-]/_/g' | cut -c1-128; }

is_platform_keyword() {
  case "$(lower "$1")" in
    all|arm|arm64|amd64|x86|x86_64) return 0 ;;
    *) return 1 ;;
  esac
}

# 平台标记 -> skopeo copy 参数
platform_flags() {
  case "$(lower "$1")" in
    ""|amd64|x86|x86_64) echo "--override-arch amd64" ;;
    arm|arm64)           echo "--override-arch arm64" ;;
    all)                 echo "--all" ;;
    *)                   echo "--override-arch $1" ;;
  esac
}

# 由源镜像地址生成目标 tag:
#   nginx:1.27                             -> nginx_1.27
#   quay.io/prometheus/prometheus:v2.53.0  -> prometheus_prometheus_v2.53.0
make_tag() {
  local ref repo_path first tag digest
  ref="$(trim "$1")"
  first="${ref%%/*}"
  if [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]] && [[ "$ref" == */* ]]; then
    repo_path="${ref#*/}"   # 去掉 registry 域名
  else
    repo_path="$ref"
  fi
  digest=""
  if [[ "$repo_path" == *@* ]]; then
    digest="${repo_path#*@}"   # 形如 sha256:xxxx
    repo_path="${repo_path%%@*}"
  fi
  if [[ -n "$digest" ]]; then
    tag="${digest//:/_}"
  elif [[ "$repo_path" == *:* ]]; then
    tag="${repo_path##*:}"
    repo_path="${repo_path%%:*}"
  else
    tag="latest"
  fi
  sanitize "${repo_path//\//_}_${tag}"
}

sync_one() {
  local src="$1" custom="${2:-}" platform="${3:-amd64}" dst tag copy_flags insp_flags
  if [[ -n "$custom" ]]; then tag="$(sanitize "$custom")"; else tag="$(make_tag "$src")"; fi
  dst="${REGISTRY}/${DEST_REPO}:${tag}"
  copy_flags="$(platform_flags "$platform")"
  if [[ "$(lower "$platform")" == "all" ]]; then
    insp_flags="--override-arch amd64"   # all 模式下校验清单里的 amd64 项
  else
    insp_flags="$copy_flags"
  fi
  echo "::group::[$((COUNT+1))] [$(lower "$platform")] $src  ->  $dst"
  COUNT=$((COUNT+1))
  if ! skopeo copy $copy_flags --retry-times 3 "docker://$src" "docker://$dst"; then
    echo "::error::同步失败: $src"
    FAILED+=("$src")
    echo "::endgroup::"
    return
  fi
  # 校验镜像ID（镜像配置的 sha256）与源站一致
  local src_id dst_id
  src_id="$(skopeo inspect $insp_flags --config "docker://$src" 2>/dev/null | sha256sum | awk '{print $1}' || true)"
  dst_id="$(skopeo inspect $insp_flags --config "docker://$dst" 2>/dev/null | sha256sum | awk '{print $1}' || true)"
  if [[ -n "$src_id" && "$src_id" == "$dst_id" ]]; then
    echo "✅ 同步完成，镜像ID校验一致: sha256:$dst_id"
  elif [[ -z "$src_id" || -z "$dst_id" ]]; then
    echo "⚠️ 同步完成，但镜像ID未能校验"
  else
    echo "::error::镜像ID不一致: 源=$src_id 目标=$dst_id"
    FAILED+=("$src")
  fi
  echo "::endgroup::"
}

if [[ $# -gt 0 ]]; then
  for src in "$@"; do
    sync_one "$src"
  done
else
  if [[ ! -f "$IMAGES_FILE" ]]; then
    echo "::error::找不到 $IMAGES_FILE"
    exit 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *"|"* ]]; then
      sync_one "$line"
      continue
    fi
    src="$(trim "${line%%|*}")"
    rest="${line#*|}"
    if [[ "$rest" == *"|"* ]]; then
      f2="$(trim "${rest%%|*}")"; f3="$(trim "${rest#*|}")"
    else
      f2="$(trim "$rest")"; f3=""
    fi
    custom="" ; platform="amd64"
    if [[ -n "$f2" ]]; then
      if is_platform_keyword "$f2"; then platform="$f2"; else custom="$f2"; fi
    fi
    if [[ -n "$f3" ]]; then
      if is_platform_keyword "$f3"; then platform="$f3"; else echo "::warning::忽略无法识别的字段: $f3"; fi
    fi
    sync_one "$src" "$custom" "$platform"
  done < "$IMAGES_FILE"
fi

echo
echo "共处理 $COUNT 个镜像，失败 ${#FAILED[@]} 个"
if (( ${#FAILED[@]} > 0 )); then
  printf '❌ %s\n' "${FAILED[@]}"
  exit 1
fi
