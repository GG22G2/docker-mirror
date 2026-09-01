#!/usr/bin/env bash
# 将公网镜像同步到阿里云 ACR 的 ck 仓库
# 用法:
#   bash sync.sh                  同步 images.txt 中的全部镜像
#   bash sync.sh nginx:1.27 ...   同步命令行指定的镜像
set -euo pipefail

REGISTRY="${REGISTRY:-crpi-xm8affxmcnbpks63.cn-shanghai.personal.cr.aliyuncs.com}"
DEST_REPO="${DEST_REPO:-gg22g2/ck}"
IMAGES_FILE="${IMAGES_FILE:-images.txt}"

FAILED=()
COUNT=0

trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$1"; }
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
sanitize() { lower "$1" | sed 's/[^a-z0-9._-]/_/g' | cut -c1-128; }

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
  local src="$1" custom="${2:-}" dst tag
  if [[ -n "$custom" ]]; then
    tag="$(sanitize "$custom")"
  else
    tag="$(make_tag "$src")"
  fi
  dst="${REGISTRY}/${DEST_REPO}:${tag}"
  echo "::group::[$((COUNT+1))] $src  ->  $dst"
  if skopeo copy --all --retry-times 3 "docker://$src" "docker://$dst"; then
    echo "✅ 完成: $dst"
  else
    echo "::error::同步失败: $src"
    FAILED+=("$src")
  fi
  echo "::endgroup::"
  COUNT=$((COUNT+1))
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
    if [[ "$line" == *"|"* ]]; then
      sync_one "$(trim "${line%%|*}")" "$(trim "${line#*|}")"
    else
      sync_one "$line"
    fi
  done < "$IMAGES_FILE"
fi

echo
echo "共处理 $COUNT 个镜像，失败 ${#FAILED[@]} 个"
if (( ${#FAILED[@]} > 0 )); then
  printf '❌ %s\n' "${FAILED[@]}"
  exit 1
fi
