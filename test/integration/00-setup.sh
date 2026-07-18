#!/usr/bin/env bash
# 集成测试环境准备：minikube + cert-manager + metrics-server + operator 部署
# 用法: bash test/integration/00-setup.sh
# 幂等：可重复执行，已存在的资源会跳过或更新
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
die()  { echo -e "${RED}[setup]${NC} $*" >&2; exit 1; }

# ===== 0. 前置检查 =====
command -v kubectl >/dev/null || die "kubectl 未安装"
command -v minikube >/dev/null || die "minikube 未安装"
command -v make >/dev/null || die "make 未安装"

# minikube 运行中
minikube status >/dev/null 2>&1 || die "minikube 未运行，先执行: minikube start"
kubectl config current-context | grep -q minikube || warn "当前 context 非 minikube（$(kubectl config current-context)）"
log "minikube 运行中"

# ===== 1. metrics-server addon =====
if kubectl get deployment -n kube-system metrics-server >/dev/null 2>&1; then
  log "metrics-server 已存在，跳过 enable"
else
  log "启用 metrics-server addon ..."
  minikube addons enable metrics-server
fi

# minikube addon 用的带 sha 镜像在国内拉取失败，patch 为阿里云无 sha 版本
MS_IMG="registry.cn-hangzhou.aliyuncs.com/google_containers/metrics-server:v0.7.1"
CURRENT_MS_IMG=$(kubectl get deployment -n kube-system metrics-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
if [ "$CURRENT_MS_IMG" != "$MS_IMG" ]; then
  warn "patch metrics-server 镜像为国内可达版本 ..."
  kubectl patch deployment -n kube-system metrics-server --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"$MS_IMG\"}]" >/dev/null
  kubectl delete pod -n kube-system -l k8s-app=metrics-server --grace-period=0 --force >/dev/null 2>&1 || true
fi
log "等待 metrics-server ready ..."
kubectl wait deployment -n kube-system metrics-server --for=condition=available --timeout=240s

# ===== 2. cert-manager =====
CERT_MGR_VER="v1.16.0"
if kubectl get namespace cert-manager >/dev/null 2>&1; then
  log "cert-manager namespace 已存在，跳过安装（如需重装: kubectl delete namespace cert-manager）"
else
  log "安装 cert-manager $CERT_MGR_VER ..."
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MGR_VER}/cert-manager.yaml"
fi
log "等待 cert-manager ready ..."
kubectl wait deployment -n cert-manager --for=condition=available --all --timeout=240s

# ===== 3. 构建并加载 manager 镜像到 minikube =====
log "构建 manager 镜像到 minikube（国内 GOPROXY）..."
eval "$(minikube docker-env)"

# 预拉基础镜像并 retag 为原名（国内无法直连 docker.io / gcr.io）
ensure_image() {
  local official="$1" mirror="$2"
  if ! docker image inspect "$official" >/dev/null 2>&1; then
    log "拉取 $official（经 $mirror）..."
    docker pull "$mirror" >/dev/null
    docker tag "$mirror" "$official"
  fi
}
ensure_image "golang:1.26" "docker.m.daocloud.io/library/golang:1.26"
ensure_image "gcr.io/distroless/static:nonroot" "docker.m.daocloud.io/library/alpine:3.20"

GOPROXY="https://goproxy.cn,direct" make docker-build
log "manager 镜像构建完成: $(docker images controller:latest --format '{{.Repository}}:{{.Tag}} {{.Size}}')"

# ===== 4. 部署 operator =====
log "部署 operator（make deploy）..."
make deploy
log "等待 operator ready ..."
kubectl wait deployment -n operator-demo-system operator-demo-controller-manager \
  --for=condition=available --timeout=120s

# ===== 5. 验证 webhook 证书已注入 =====
log "验证 webhook caBundle 已注入 ..."
if [ -n "$(kubectl get validatingwebhookconfiguration operator-demo-validating-webhook-configuration \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null)" ]; then
  log "webhook caBundle 已注入（cert-manager 签发完成）"
else
  die "webhook caBundle 为空，cert-manager 可能未就绪"
fi

# ===== 6. 等待 metrics API 可用 =====
log "等待 metrics API 可用 ..."
for i in $(seq 1 30); do
  if kubectl top nodes >/dev/null 2>&1; then
    log "metrics API 就绪"
    kubectl top nodes
    break
  fi
  sleep 5
done

echo
log "环境准备完成。可运行全部测试场景: bash test/integration/run-all.sh"
