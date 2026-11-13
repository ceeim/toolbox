#!/usr/bin/env bash
# Linux 服务器初始化脚本（Debian / Ubuntu / RHEL 系）
# 用法见 --help

set -euo pipefail

# su 提权时可能沿用普通用户的 PATH，其中没有 sbin
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SSH_PORT=""
ROOT_LOGIN=""          # yes / no / 空（保持现状）
ROOT_PASSWORD=""
SSH_KEYS=()
BBR_MODE=fq            # fq / fq_pie / cake / off
TIMEZONE="Asia/Singapore"
DNS_SERVERS=()
DEFAULT_DNS=(1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001)
REMOVE_DEFAULT_USERS=1
INTERACTIVE=1
# 各发行版云镜像自带的默认登录用户
DEFAULT_USERS=(debian ubuntu admin ec2-user centos rocky almalinux cloud-user opc fedora)

IN_CHINA=0
APT_UPDATED=0
SSHD_RESTART_FAILED=0
SCRIPT_URL=https://raw.githubusercontent.com/ceeim/toolbox/master/shell/init.sh
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-init.conf

info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: bash <(curl -Ls https://raw.githubusercontent.com/ceeim/toolbox/master/shell/init.sh) [选项]

未用参数指定的 SSH 端口、root 密码登录、SSH 公钥会交互式询问；
加 -y 则不询问，这三项保持现状。

  --port, --ssh-port PORT 修改 SSH 端口
  --passwd-login yes|no   开启 / 关闭 root 密码登录
  --passwd 'PASS'         设置 root 密码并开启 root 密码登录
  --key, --ssh-key 'KEY'  添加 SSH 公钥（可重复指定）
  --keep-user             不删除系统自带的默认用户（debian、ubuntu 等）
  --bbr MODE              BBR 及其队列算法，默认 fq：
                            fq      BBR + fq（官方推荐搭配）
                            fq_pie  BBR + fq_pie（内核 5.6+）
                            cake    BBR + cake（内核 4.19+）
                            off     不设置 BBR
  --timezone TZ           时区，默认 Asia/Singapore
  --dns 'A,B,...'         DNS 服务器，逗号或空格分隔，可重复指定；
                          默认 Cloudflare IPv4 + IPv6
  -y, --yes               非交互模式
  -h, --help              显示帮助

密码和公钥含特殊字符或空格，必须用单引号包裹；值本身含单引号时写成 '\''：
  init.sh --port 2222 --passwd 'p@$$w0rd!&' \
          --key 'ssh-ed25519 AAAAC3... me@host' --dns '8.8.8.8,2001:4860:4860::8888'

本次设置了 root 密码或 SSH 公钥、且确认 root 可以登录后，会删除系统自带的默认用户
（debian、ubuntu、ec2-user 等）及其家目录。
内存 >= 1GB 时自动安装 Docker；出口 IP 位于中国大陆时软件源改为中科大镜像。
EOF
}

parse_args() {
  local opt val list dns
  while [ $# -gt 0 ]; do
    opt=$1
    case "$opt" in
      -h|--help) usage; exit 0 ;;
      -y|--yes) INTERACTIVE=0; shift; continue ;;
      --keep-user) REMOVE_DEFAULT_USERS=0; shift; continue ;;
      --*=*) val=${opt#*=}; opt=${opt%%=*}; shift ;;
      --*) [ $# -ge 2 ] || die "$opt 缺少参数值"; val=$2; shift 2 ;;
      *) die "未知参数: $opt（见 --help）" ;;
    esac
    case "$opt" in
      --port|--ssh-port) SSH_PORT=$val ;;
      --passwd-login) ROOT_LOGIN=$val ;;
      --bbr) BBR_MODE=$val ;;
      --passwd) [ -n "$val" ] || die "root 密码不能为空"; ROOT_PASSWORD=$val; ROOT_LOGIN=yes ;;
      --key|--ssh-key) SSH_KEYS+=("$val") ;;
      --timezone) TIMEZONE=$val ;;
      --dns) read -r -a list <<<"${val//,/ }"; DNS_SERVERS+=(${list[@]+"${list[@]}"}) ;;
      *) die "未知参数: $opt（见 --help）" ;;
    esac
  done

  if [ -n "$SSH_PORT" ] && ! valid_port "$SSH_PORT"; then die "无效的 SSH 端口: $SSH_PORT"; fi
  case "$ROOT_LOGIN" in ""|yes|no) ;; *) die "--passwd-login 只接受 yes 或 no" ;; esac
  case "$BBR_MODE" in fq|fq_pie|cake|off) ;; *) die "--bbr 只接受 fq、fq_pie、cake 或 off" ;; esac
  if [ ${#DNS_SERVERS[@]} -eq 0 ]; then DNS_SERVERS=("${DEFAULT_DNS[@]}"); fi
  for dns in "${DNS_SERVERS[@]}"; do
    [[ $dns =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || ( $dns == *:* && $dns =~ ^[0-9a-fA-F:.]+$ ) ]] || die "无效的 DNS 地址: $dns"
  done
}

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# 首次登录的可能是普通用户：有 sudo 用 sudo，否则用 su 输入 root 密码
ensure_root() {
  local script=$0
  if [ "$(id -u)" -eq 0 ]; then return 0; fi
  info "当前不是 root，正在提权..."
  # bash <(curl ...) 方式运行时 $0 是已读完的管道，提权后无法再读，需重新下载一份
  if [ ! -f "$script" ]; then
    script=$(mktemp)
    curl -fsSL "$SCRIPT_URL" -o "$script" || die "下载脚本失败: $SCRIPT_URL"
  fi
  if command -v sudo >/dev/null 2>&1; then exec sudo bash "$script" "$@"; fi
  # %q 逐个转义参数，密码、公钥中的特殊字符不会被 su 启动的 shell 再次解析
  exec su root -c "$(printf '%q ' bash "$script" "$@")"
}

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

valid_ssh_key() {
  local tmp rc=0
  tmp=$(mktemp)
  printf '%s\n' "$1" >"$tmp"
  ssh-keygen -l -f "$tmp" >/dev/null 2>&1 || rc=1
  rm -f "$tmp"
  return $rc
}

current_ssh_port() {
  local port
  port=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')
  printf '%s' "${port:-22}"
}

# 所有询问集中在最前面，之后的步骤无需人工值守
collect_input() {
  local i reply confirm
  for i in "${!SSH_KEYS[@]}"; do
    SSH_KEYS[i]=$(trim "${SSH_KEYS[i]}")
    valid_ssh_key "${SSH_KEYS[i]}" || die "无效的 SSH 公钥: ${SSH_KEYS[i]}"
  done

  # 管道运行（curl | bash）时 stdin 不是终端，统一从 /dev/tty 读取
  if [ "$INTERACTIVE" -eq 1 ] && ! { : </dev/tty; } 2>/dev/null; then
    warn "没有可用终端，按非交互模式运行"
    INTERACTIVE=0
  fi
  if [ "$INTERACTIVE" -eq 0 ]; then return 0; fi

  while [ -z "$SSH_PORT" ]; do
    read -r -p "新的 SSH 端口 [回车保持 $(current_ssh_port)]: " reply </dev/tty
    if [ -z "$reply" ]; then break; fi
    if valid_port "$reply"; then SSH_PORT=$reply; else warn "端口必须是 1-65535 的数字"; fi
  done

  while [ -z "$ROOT_LOGIN" ]; do
    read -r -p "是否开启 root 密码登录 [y 开启 / n 关闭 / 回车保持现状]: " reply </dev/tty
    case "$reply" in
      "") break ;;
      y|Y|yes) ROOT_LOGIN=yes ;;
      n|N|no) ROOT_LOGIN=no ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done

  # -r 与 -s：密码原样读取且不回显，任何特殊字符都不会被解释
  while [ "$ROOT_LOGIN" = yes ] && [ -z "$ROOT_PASSWORD" ]; do
    read -r -s -p "root 新密码 [回车沿用现有密码]: " reply </dev/tty; echo
    if [ -z "$reply" ]; then break; fi
    read -r -s -p "再次输入 root 新密码: " confirm </dev/tty; echo
    if [ "$reply" = "$confirm" ]; then ROOT_PASSWORD=$reply; else warn "两次输入不一致"; fi
  done

  while [ ${#SSH_KEYS[@]} -eq 0 ]; do
    read -r -p "粘贴 SSH 公钥 [回车跳过]: " reply </dev/tty
    reply=$(trim "$reply")
    if [ -z "$reply" ]; then break; fi
    if valid_ssh_key "$reply"; then SSH_KEYS+=("$reply"); else warn "不是有效的 SSH 公钥"; fi
  done
}

detect_os() {
  [ -r /etc/os-release ] || die "无法识别系统：缺少 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-unknown}
  if command -v apt-get >/dev/null 2>&1; then
    PKG=apt
  elif command -v dnf >/dev/null 2>&1; then
    PKG=dnf
  elif command -v yum >/dev/null 2>&1; then
    PKG=yum
  else
    die "不支持的系统: $OS_ID（需要 apt 或 dnf/yum）"
  fi
}

pkg_install() {
  if [ "$PKG" != apt ]; then "$PKG" install -y -q "$@"; return; fi
  if [ "$APT_UPDATED" -eq 0 ]; then apt-get update -q; APT_UPDATED=1; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"
}

# 裸的 ipip.ng 只返回 IP，地区信息在 /geoip 接口
detect_region() {
  local v json cc ip
  command -v curl >/dev/null 2>&1 || pkg_install curl ca-certificates
  for v in 4 6; do
    json=$(curl "-$v" -fsS -m 10 ipip.ng/geoip 2>/dev/null || true)
    cc=$(sed -n 's/.*"country_code":"\([A-Za-z]*\)".*/\1/p' <<<"$json")
    ip=$(sed -n 's/.*"ip":"\([^"]*\)".*/\1/p' <<<"$json")
    if [ -z "$cc" ]; then info "IPv$v: 不可用"; continue; fi
    info "IPv$v: $ip ($cc)"
    # CN 仅指中国大陆，港澳台有各自的代码
    if [ "$cc" = CN ]; then IN_CHINA=1; fi
  done
}

# 只替换官方源域名；云厂商自带的内网镜像等其他源保持不动
use_ustc_mirror() {
  local f files=()
  case "$OS_ID" in
    debian)
      for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do
        if [ -f "$f" ]; then sed -ri.bak 's#(https?://)(deb|security)\.debian\.org#\1mirrors.ustc.edu.cn#g' "$f"; fi
      done ;;
    ubuntu)
      for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
        if [ -f "$f" ]; then sed -ri.bak 's#(https?://)([a-z0-9-]+\.)*(archive|security|ports)\.ubuntu\.com#\1mirrors.ustc.edu.cn#g' "$f"; fi
      done ;;
    rocky)
      files=(/etc/yum.repos.d/[Rr]ocky*.repo)
      sed -i.bak -e 's|^mirrorlist=|#mirrorlist=|g' \
        -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.ustc.edu.cn/rocky|g' "${files[@]}" ;;
    *)
      warn "中科大镜像没有 $OS_ID 的源或暂未适配，保持默认"
      return 0 ;;
  esac
  info "软件源已切换为中科大镜像（原文件备份为 .bak）"
}

setup_timezone() {
  if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then pkg_install tzdata; fi
  [ -f "/usr/share/zoneinfo/$TIMEZONE" ] || die "无效的时区: $TIMEZONE"
  if ! timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    if [ -f /etc/timezone ]; then echo "$TIMEZONE" >/etc/timezone; fi
  fi
  info "时区: $TIMEZONE"
}

setup_dns() {
  local dns v4=() v6=()
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    # Domains=~. 让全局 DNS 优先于各网卡从 DHCP 拿到的 DNS
    printf '[Resolve]\nDNS=%s\nDomains=~.\n' "${DNS_SERVERS[*]}" >/etc/systemd/resolved.conf.d/90-init.conf
    systemctl restart systemd-resolved
    info "DNS (systemd-resolved): ${DNS_SERVERS[*]}"
    return 0
  fi

  # 阻止 NetworkManager / dhclient 在续租时改回 resolv.conf
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    printf '[main]\ndns=none\n' >/etc/NetworkManager/conf.d/90-init-dns.conf
    systemctl reload NetworkManager
  fi
  if [ -f /etc/dhcp/dhclient.conf ]; then
    for dns in "${DNS_SERVERS[@]}"; do
      if [[ $dns == *:* ]]; then v6+=("$dns"); else v4+=("$dns"); fi
    done
    sed -ri '/^supersede (domain-name-servers|dhcp6\.name-servers) /d' /etc/dhcp/dhclient.conf
    if [ ${#v4[@]} -gt 0 ]; then echo "supersede domain-name-servers $(IFS=,; echo "${v4[*]}");" >>/etc/dhcp/dhclient.conf; fi
    if [ ${#v6[@]} -gt 0 ]; then echo "supersede dhcp6.name-servers $(IFS=,; echo "${v6[*]}");" >>/etc/dhcp/dhclient.conf; fi
  fi

  # resolv.conf 可能是指向已停用服务的软链，此时删掉改写成普通文件。
  # glibc 只使用前 3 个 nameserver，多出的会被忽略。
  if [ -L /etc/resolv.conf ]; then rm -f /etc/resolv.conf; fi
  printf 'nameserver %s\n' "${DNS_SERVERS[@]}" >/etc/resolv.conf
  info "DNS (/etc/resolv.conf): ${DNS_SERVERS[*]}"
}

setup_ipv4_first() {
  if ! grep -Eqs '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' /etc/gai.conf; then
    echo 'precedence ::ffff:0:0/96  100' >>/etc/gai.conf
  fi
  info "已设置 IPv4 优先"
}

setup_bbr() {
  local qdisc=$BBR_MODE
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    warn "当前内核不支持 BBR（需要 4.9+），已跳过"
    return 0
  fi
  if [ "$qdisc" != fq ] && ! modprobe "sch_$qdisc" 2>/dev/null; then
    warn "当前内核没有 $qdisc 队列算法，改用 fq"
    qdisc=fq
  fi
  mkdir -p /etc/sysctl.d
  printf 'net.core.default_qdisc = %s\nnet.ipv4.tcp_congestion_control = bbr\n' "$qdisc" >/etc/sysctl.d/99-bbr.conf
  # 拥塞控制立即生效；队列算法对已存在的网卡要重启后才切换
  if sysctl -q -p /etc/sysctl.d/99-bbr.conf; then info "已启用 BBR + $qdisc"; else warn "BBR 参数写入失败（容器内可能无权修改）"; fi
}

add_ssh_keys() {
  local user home file key users=(root)
  # 通过 sudo / su 提权时，把公钥同时加给最初登录的普通用户
  user=${SUDO_USER:-$(logname 2>/dev/null || true)}
  if [ -n "$user" ] && [ "$user" != root ] && id "$user" >/dev/null 2>&1; then users+=("$user"); fi

  for user in "${users[@]}"; do
    home=$(getent passwd "$user" | cut -d: -f6)
    file=$home/.ssh/authorized_keys
    install -d -m 700 -o "$user" -g "$(id -gn "$user")" "$home/.ssh"
    touch "$file"
    # 原文件末尾没有换行时先补上，避免新公钥接在上一行后面
    if [ -n "$(tail -c1 "$file")" ]; then echo >>"$file"; fi
    for key in "${SSH_KEYS[@]}"; do
      grep -qxF -- "$key" "$file" || printf '%s\n' "$key" >>"$file"
    done
    chmod 600 "$file"
    chown "$user:$(id -gn "$user")" "$file"
    info "SSH 公钥已写入 $file"
  done
}

has_authorized_keys() {
  local user home
  for user in root "${SUDO_USER:-}"; do
    if [ -z "$user" ]; then continue; fi
    home=$(getent passwd "$user" | cut -d: -f6)
    # 只认无前缀选项的公钥，排除云镜像放在 root 下的 command="echo Please login as ..." 占位公钥
    if grep -Eqs '^(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys"; then return 0; fi
  done
  return 1
}

open_ssh_port() {
  local port=$1
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != Disabled ]; then
    command -v semanage >/dev/null 2>&1 || pkg_install policycoreutils-python-utils
    semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$port"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd -q --state 2>/dev/null; then
    firewall-cmd -q --permanent --add-port="$port/tcp"
    firewall-cmd -q --reload
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow "$port/tcp" >/dev/null
  fi
}

restart_sshd() {
  # /run/systemd/system 存在才说明 systemd 是当前的 init
  if [ ! -d /run/systemd/system ]; then
    service ssh restart 2>/dev/null || service sshd restart
    return
  fi
  # Ubuntu 22.10+ 由 ssh.socket 监听端口，端口取自 daemon-reload 时重新生成的配置
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket; then systemctl restart ssh.socket; fi
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
}

setup_sshd() {
  local settings=() keys f backup tmp

  if [ "$ROOT_LOGIN" = no ] && ! has_authorized_keys; then
    warn "未发现任何 SSH 公钥，关闭 root 密码登录可能导致无法登录，已跳过"
    ROOT_LOGIN=""
  fi
  if [ -n "$SSH_PORT" ]; then settings+=("Port $SSH_PORT"); fi
  case "$ROOT_LOGIN" in
    yes) settings+=("PermitRootLogin yes" "PasswordAuthentication yes") ;;
    no) settings+=("PermitRootLogin prohibit-password") ;;
  esac
  if [ ${#settings[@]} -eq 0 ]; then return 0; fi

  if [ -n "$ROOT_PASSWORD" ]; then
    # 密码经 stdin 原样传给 chpasswd，不经过 shell 解析
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
    info "root 密码已更新"
  elif [ "$ROOT_LOGIN" = yes ] && [ "$(passwd -S root | awk '{ print $2 }')" != P ]; then
    warn "root 当前没有可用密码，请运行 passwd root 设置后才能用密码登录"
  fi

  backup=/root/sshd-config-backup-$(date +%Y%m%d%H%M%S).tar.gz
  tar -czf "$backup" -C / etc/ssh/sshd_config $([ -d /etc/ssh/sshd_config.d ] && echo etc/ssh/sshd_config.d)

  # sshd 对同一指令取首次出现的值，Port 则会叠加监听，所以先停用所有旧值
  keys=$(printf '%s\n' "${settings[@]}" | cut -d' ' -f1 | sort -u | paste -sd'|')
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    if [ ! -f "$f" ]; then continue; fi
    if [ "$f" = "$SSHD_DROPIN" ]; then
      sed -ri "/^($keys)[[:space:]]/d" "$f"
    else
      sed -ri "s/^[[:space:]]*($keys)[[:space:]]/#&/I" "$f"
    fi
  done

  if grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
    mkdir -p /etc/ssh/sshd_config.d
    printf '%s\n' "${settings[@]}" >>"$SSHD_DROPIN"
  else
    tmp=$(mktemp)
    { printf '%s\n' "${settings[@]}"; cat /etc/ssh/sshd_config; } >"$tmp"
    cat "$tmp" >/etc/ssh/sshd_config
    rm -f "$tmp"
  fi

  if ! sshd -t; then
    rm -f "$SSHD_DROPIN"
    tar -xzf "$backup" -C /
    die "sshd 配置校验失败，已还原（备份: $backup）"
  fi

  if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != 22 ]; then open_ssh_port "$SSH_PORT"; fi
  if ! restart_sshd; then
    SSHD_RESTART_FAILED=1
    warn "sshd 重启失败，请手动重启后配置才会生效"
  fi
  info "sshd 已更新: $(IFS=,; echo "${settings[*]}")（备份: $backup）"
}

# 按 sshd 的最终生效配置判断 root 能否用公钥或密码登录
root_can_login() {
  local cfg permit
  cfg=$(sshd -T 2>/dev/null) || return 1
  permit=$(awk '$1 == "permitrootlogin" { print $2 }' <<<"$cfg")
  if [ "$permit" = no ]; then return 1; fi
  if grep -q '^pubkeyauthentication yes' <<<"$cfg" && grep -Eqs '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys; then
    return 0
  fi
  [ "$permit" = yes ] && grep -q '^passwordauthentication yes' <<<"$cfg" && [ "$(passwd -S root | awk '{ print $2 }')" = P ]
}

remove_default_users() {
  local user removed=0
  if [ ${#SSH_KEYS[@]} -eq 0 ] && [ -z "$ROOT_PASSWORD" ] && [ "$ROOT_LOGIN" != yes ]; then return 0; fi
  if [ "$SSHD_RESTART_FAILED" -eq 1 ] || ! root_can_login; then
    warn "无法确认 root 可以登录，保留系统默认用户"
    return 0
  fi
  for user in "${DEFAULT_USERS[@]}"; do
    # UID < 1000 的是系统账号，不动
    if ! id "$user" >/dev/null 2>&1 || [ "$(id -u "$user")" -lt 1000 ]; then continue; fi
    # -f：当前会话可能正是以该用户登录的，不加会因其有进程在运行而拒绝删除
    userdel -rf "$user" 2>/dev/null || true
    if id "$user" >/dev/null 2>&1; then warn "删除默认用户 $user 失败"; continue; fi
    # cloud-init 为默认用户写的免密 sudo 规则，一并清掉，避免日后同名用户自动获得 sudo
    if [ -f /etc/sudoers.d/90-cloud-init-users ]; then sed -i "/^$user[[:space:]]/d" /etc/sudoers.d/90-cloud-init-users; fi
    info "已删除默认用户 $user 及其家目录"
    removed=1
  done
  if [ "$removed" -eq 1 ]; then warn "默认用户已删除：当前会话结束后请改用 root 登录，断开前先开新窗口确认"; fi
}

install_docker() {
  local mem_mb script
  mem_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
  # 标称 1GB 的机器扣除内核保留后 MemTotal 通常只有 950MB 左右，以 900MB 为界
  if [ "$mem_mb" -lt 900 ]; then info "内存 ${mem_mb}MB 不足 1GB，不安装 Docker"; return 0; fi
  if command -v docker >/dev/null 2>&1; then info "Docker 已安装，跳过"; return 0; fi

  info "内存 ${mem_mb}MB，开始安装 Docker..."
  script=$(mktemp)
  curl -fsSL https://get.docker.com -o "$script"
  if [ "$IN_CHINA" -eq 1 ]; then
    DOWNLOAD_URL=https://mirrors.ustc.edu.cn/docker-ce sh "$script"
  else
    sh "$script"
  fi
  rm -f "$script"
  systemctl enable --now docker 2>/dev/null || true
  info "Docker 安装完成: $(docker --version)"
}

main() {
  parse_args "$@"
  ensure_root "$@"
  detect_os
  if command -v sshd >/dev/null 2>&1; then
    collect_input
  else
    warn "未安装 sshd，跳过全部 SSH 设置"
    SSH_PORT=""; ROOT_LOGIN=""; SSH_KEYS=()
  fi

  detect_region
  if [ "$IN_CHINA" -eq 1 ]; then use_ustc_mirror; else info "位于中国大陆以外，软件源保持默认"; fi

  setup_timezone
  setup_dns
  setup_ipv4_first
  if [ "$BBR_MODE" != off ]; then setup_bbr; fi
  if [ ${#SSH_KEYS[@]} -gt 0 ]; then add_ssh_keys; fi
  setup_sshd
  install_docker
  if [ "$REMOVE_DEFAULT_USERS" -eq 1 ]; then remove_default_users; fi

  info "初始化完成"
  if [ -n "$SSH_PORT" ]; then
    warn "SSH 端口已改为 $SSH_PORT：请在云厂商安全组放行该端口，并先开新窗口确认能登录，再关闭当前会话"
  fi
}

main "$@"
