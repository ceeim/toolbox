#!/bin/bash

# ============================================================
# GoEdge 边缘节点 自动部署脚本
# ============================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()   { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()   { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()   { echo -e "${CYAN}[STEP]${NC}  $1"; }
log_banner() { echo -e "${BLUE}$1${NC}"; }

# ============================================================
# 打印横幅
# ============================================================
print_banner() {
  log_banner "======================================================"
  log_banner "        GoEdge 边缘节点 自动部署脚本 v1.1            "
  log_banner "======================================================"
  echo ""
}

# ============================================================
# 检查是否为 root 用户
# ============================================================
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 用户或 sudo 运行此脚本"
    exit 1
  fi
}

# ============================================================
# 安装依赖工具
# ============================================================
install_deps() {
  log_step "检查依赖工具..."
  local deps=()

  command -v wget &>/dev/null || deps+=(wget)
  command -v curl &>/dev/null || deps+=(curl)

  if [[ ${#deps[@]} -gt 0 ]]; then
    log_step "安装缺少的依赖: ${deps[*]}"
    if command -v apt-get &>/dev/null; then
      apt-get update -y && apt-get install -y "${deps[@]}"
    elif command -v yum &>/dev/null; then
      yum install -y "${deps[@]}"
    else
      log_error "无法自动安装依赖，请手动安装: ${deps[*]}"
      exit 1
    fi
  fi

  log_info "依赖工具检查完成"
}

# ============================================================
# 安装 Docker
# ============================================================
install_docker() {
  log_step "检查 Docker 是否已安装..."

  if command -v docker &>/dev/null; then
    log_info "Docker 已安装: $(docker --version)"
  else
    log_step "开始安装 Docker..."
    wget -qO- https://get.docker.com | bash
    log_info "Docker 安装完成"
  fi

  log_step "启动 Docker 服务..."
  systemctl start docker
  systemctl enable docker
  log_info "Docker 服务已启动并设置开机自启"
}

# ============================================================
# 检查 Docker Compose
# ============================================================
check_docker_compose() {
  log_step "检查 Docker Compose 是否可用..."

  if docker compose version &>/dev/null; then
    log_info "Docker Compose 可用: $(docker compose version)"
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose &>/dev/null; then
    log_info "docker-compose 可用: $(docker-compose --version)"
    COMPOSE_CMD="docker-compose"
  else
    log_error "Docker Compose 不可用，请检查 Docker 是否正确安装"
    exit 1
  fi
}

# ============================================================
# URL Decode 函数
# 将 %XX 编码还原为原始字符
# ============================================================
url_decode() {
  local encoded="${1//+/ }"
  printf '%b' "${encoded//%/\\x}"
}

# ============================================================
# 从 URL 的 text 参数中解析配置
# 支持两种模式：
#   1. 解析 URL 中的 text 参数（无需网络请求）
#   2. 直接请求 URL 获取返回内容
# ============================================================
fetch_config_from_url() {
  local url="$1"
  local yaml_content=""

  log_step "正在解析配置 URL..."

  # ── 优先从 URL 的 text 参数中提取配置内容 ────────────────
  if echo "$url" | grep -q 'text='; then
    log_info "检测到 text 参数，直接从 URL 解析配置内容"

    # 提取 text= 之后的内容（兼容 & 后续参数截断）
    local raw_text
    raw_text=$(echo "$url" | grep -oP '(?<=text=)[^#]*')

    # URL Decode
    yaml_content=$(url_decode "$raw_text")

  # ── 回退：直接请求 URL 获取内容 ──────────────────────────
  else
    log_info "未检测到 text 参数，尝试请求 URL 获取配置..."
    yaml_content=$(curl -sL --connect-timeout 10 --max-time 15 "$url" 2>/dev/null) || {
      log_warn "无法连接到配置 URL，请检查网络或改为手动输入"
      return 1
    }
  fi

  # ── 检查内容是否为空 ──────────────────────────────────────
  if [[ -z "$yaml_content" ]]; then
    log_warn "配置内容为空，解析失败"
    return 1
  fi

  log_info "原始配置内容："
  echo -e "${BLUE}------------------------------------------------------${NC}"
  echo "$yaml_content"
  echo -e "${BLUE}------------------------------------------------------${NC}"

  # ── 解析 rpc.endpoints ───────────────────────────────────
  local endpoints
  endpoints=$(echo "$yaml_content" \
    | grep -oP 'rpc\.endpoints:\s*\[\s*"\K[^"]+' \
    | head -n1)

  # ── 解析 clusterId ────────────────────────────────────────
  local cluster_id
  cluster_id=$(echo "$yaml_content" \
    | grep -oP 'clusterId:\s*"\K[^"]+' \
    | head -n1)

  # ── 解析 secret ───────────────────────────────────────────
  local secret
  secret=$(echo "$yaml_content" \
    | grep -oP 'secret:\s*"\K[^"]+' \
    | head -n1)

  # ── 校验解析结果 ──────────────────────────────────────────
  if [[ -z "$endpoints" || -z "$cluster_id" || -z "$secret" ]]; then
    log_warn "配置解析不完整，详情如下："
    [[ -z "$endpoints"  ]] && log_warn "  → rpc.endpoints 未解析到"
    [[ -z "$cluster_id" ]] && log_warn "  → clusterId     未解析到"
    [[ -z "$secret"     ]] && log_warn "  → secret        未解析到"
    return 1
  fi

  ENDPOINTS="$endpoints"
  CLUSTERID="$cluster_id"
  SECRET="$secret"

  echo ""
  log_info "配置解析成功："
  echo -e "  ENDPOINTS : ${GREEN}${ENDPOINTS}${NC}"
  echo -e "  CLUSTERID : ${GREEN}${CLUSTERID}${NC}"
  echo -e "  SECRET    : ${GREEN}******${NC}"
  return 0
}

# ============================================================
# 交互式收集配置参数
# ============================================================
collect_config() {
  echo ""
  log_step "请选择配置方式"
  echo -e "${YELLOW}------------------------------------------------------${NC}"
  echo -e "  ${CYAN}1)${NC} 从 URL 自动获取配置（粘贴配置 URL）"
  echo -e "  ${CYAN}2)${NC} 手动输入配置"
  echo -e "${YELLOW}------------------------------------------------------${NC}"

  read -rp "$(echo -e "${YELLOW}请选择 [1/2]（默认: 1）: ${NC}")" CONFIG_MODE
  CONFIG_MODE="${CONFIG_MODE:-1}"
  echo ""

  # ── 模式1：URL 获取 ──────────────────────────────────────
  if [[ "$CONFIG_MODE" == "1" ]]; then
    while true; do
      read -rp "$(echo -e "${CYAN}请输入配置 URL${NC}: ")" CONFIG_URL

      if [[ -z "$CONFIG_URL" ]]; then
        log_warn "URL 不能为空，请重新输入"
        continue
      fi

      echo ""
      if fetch_config_from_url "$CONFIG_URL"; then
        break
      fi

      echo ""
      read -rp "$(echo -e "${YELLOW}是否重新输入 URL？[y/N]: ${NC}")" RETRY
      if [[ ! "$RETRY" =~ ^[Yy]$ ]]; then
        log_warn "切换为手动输入模式"
        CONFIG_MODE="2"
        break
      fi
      echo ""
    done
  fi

  # ── 模式2：手动输入 ──────────────────────────────────────
  if [[ "$CONFIG_MODE" == "2" ]]; then
    log_step "请手动输入配置参数"
    echo -e "${YELLOW}------------------------------------------------------${NC}"

    while true; do
      read -rp "$(echo -e "${CYAN}请输入 ENDPOINTS${NC} (例: http://xxx.com:8001): ")" ENDPOINTS
      [[ -n "$ENDPOINTS" ]] && break
      log_warn "ENDPOINTS 不能为空，请重新输入"
    done

    while true; do
      read -rp "$(echo -e "${CYAN}请输入 CLUSTERID${NC}: ")" CLUSTERID
      [[ -n "$CLUSTERID" ]] && break
      log_warn "CLUSTERID 不能为空，请重新输入"
    done

    while true; do
      read -rsp "$(echo -e "${CYAN}请输入 SECRET${NC}: ")" SECRET
      echo ""
      [[ -n "$SECRET" ]] && break
      log_warn "SECRET 不能为空，请重新输入"
    done
  fi

  # ── 最终确认 ─────────────────────────────────────────────
  echo ""
  echo -e "${YELLOW}------------------------------------------------------${NC}"
  log_info "最终配置确认："
  echo -e "  ENDPOINTS : ${GREEN}${ENDPOINTS}${NC}"
  echo -e "  CLUSTERID : ${GREEN}${CLUSTERID}${NC}"
  echo -e "  SECRET    : ${GREEN}******${NC}"
  echo -e "${YELLOW}------------------------------------------------------${NC}"
  echo ""

  read -rp "$(echo -e "${YELLOW}确认以上配置并继续部署？[y/N]: ${NC}")" CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_warn "已取消部署"
    exit 0
  fi
}

# ============================================================
# 创建部署目录及配置文件
# ============================================================
setup_deploy_dir() {
  DEPLOY_DIR="/home/goedge-node"
  log_step "创建部署目录: ${DEPLOY_DIR}"

  mkdir -p "${DEPLOY_DIR}/cache"
  mkdir -p "${DEPLOY_DIR}/configs"
  cd "${DEPLOY_DIR}"

  log_info "生成 docker-compose.yml..."
  cat > docker-compose.yml <<EOF
services:
  edge-node:
    image: icodex/edge-node:1.3.9
    container_name: edge-node
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - ENDPOINTS=${ENDPOINTS}
      - CLUSTERID=${CLUSTERID}
      - SECRET=${SECRET}
    volumes:
      - ./cache:/opt/cache
      - ./configs:/usr/local/goedge/edge-node/configs
    restart: always
EOF

  log_info "docker-compose.yml 已生成: ${DEPLOY_DIR}/docker-compose.yml"
}

# ============================================================
# 启动服务
# ============================================================
start_service() {
  log_step "拉取镜像并启动 GoEdge 边缘节点..."
  cd /home/goedge-node
  $COMPOSE_CMD pull
  $COMPOSE_CMD up -d

  echo ""
  log_info "GoEdge 边缘节点部署成功！"
  echo -e "${YELLOW}------------------------------------------------------${NC}"
  echo -e "  部署目录  : ${GREEN}/home/goedge-node${NC}"
  echo -e "  查看日志  : ${GREEN}cd /home/goedge-node && $COMPOSE_CMD logs -f${NC}"
  echo -e "  停止服务  : ${GREEN}cd /home/goedge-node && $COMPOSE_CMD down${NC}"
  echo -e "  重启服务  : ${GREEN}cd /home/goedge-node && $COMPOSE_CMD restart${NC}"
  echo -e "${YELLOW}------------------------------------------------------${NC}"
}

# ============================================================
# 主流程
# ============================================================
main() {
  print_banner
  check_root
  install_deps
  install_docker
  check_docker_compose
  collect_config
  setup_deploy_dir
  start_service
}

main "$@"
