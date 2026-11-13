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
INSTALL_DOCKER=""      # yes / no / 空（交互模式下询问，非交互模式下不装）
HAS_SSHD=1
INTERACTIVE=1
# 各发行版云镜像自带的默认登录用户
DEFAULT_USERS=(debian ubuntu admin ec2-user centos rocky almalinux cloud-user opc fedora)

IN_CHINA=0
APT_UPDATED=0
SSHD_RESTART_FAILED=0
SSHD_BACKUP=""         # 本次改动 sshd 配置前的备份，非空表示改过
SSH_CONFIRMED=0        # 新的登录方式是否已确认可用
PUBLIC_IP=""
CONFIRM_TIMEOUT=300
ROLLBACK_UNIT=init-ssh-rollback
ROLLBACK_SCRIPT=/root/init-ssh-rollback.sh
SCRIPT_URL=https://raw.githubusercontent.com/ceeim/toolbox/master/shell/init.sh
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-init.conf

info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: bash <(curl -Ls https://raw.githubusercontent.com/ceeim/toolbox/master/shell/init.sh) [选项]

未用参数指定的 SSH 端口、root 密码登录、SSH 公钥、是否安装 Docker 会交互式询问；
加 -y 则不询问：SSH 三项保持现状，Docker 只在指定 --docker 时安装。

改动 SSH 后会要求你另开窗口实际登录一次再确认；300 秒内未确认或当前窗口断开，
SSH 配置自动还原。确认成功后才会删除系统自带的默认用户。
-y 模式下无人确认：改了端口就不删默认用户，没改端口则按 sshd 配置检查决定。

  --port, --ssh-port PORT 修改 SSH 端口
  --passwd-login yes|no   开启 / 关闭 root 密码登录
  --passwd 'PASS'         设置 root 密码并开启 root 密码登录
  --key, --ssh-key 'KEY'  添加 SSH 公钥（可重复指定）
  --keep-user             不删除系统自带的默认用户（debian、ubuntu 等）
  --docker                安装 Docker
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

默认用户指 debian、ubuntu、ec2-user 等云镜像自带账号，删除时连同家目录。
出口 IP 位于中国大陆时软件源改为中科大镜像。
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
      --docker) INSTALL_DOCKER=yes; shift; continue ;;
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
  local reply confirm

  # 管道运行（curl | bash）时 stdin 不是终端，统一从 /dev/tty 读取
  if [ "$INTERACTIVE" -eq 1 ] && ! { : </dev/tty; } 2>/dev/null; then
    warn "没有可用终端，按非交互模式运行"
    INTERACTIVE=0
  fi
  if [ "$INTERACTIVE" -eq 0 ]; then return 0; fi

  if [ "$HAS_SSHD" -eq 1 ]; then collect_ssh_input; fi

  # 内存不足 1GB 时默认不装（标称 1GB 的机器 MemTotal 通常只有 950MB 左右，以 900MB 为界）
  while [ -z "$INSTALL_DOCKER" ]; do
    if [ "$(mem_mb)" -ge 900 ]; then
      read -r -p "是否安装 Docker [Y/n]: " reply </dev/tty
      reply=${reply:-y}
    else
      read -r -p "是否安装 Docker（内存 $(mem_mb)MB 不足 1GB，不建议）[y/N]: " reply </dev/tty
      reply=${reply:-n}
    fi
    case "$reply" in
      y|Y|yes) INSTALL_DOCKER=yes ;;
      n|N|no) INSTALL_DOCKER=no ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

mem_mb() { awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo; }

collect_ssh_input() {
  local reply confirm
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

  # IFS= 与 -r -s：密码原样读取（含首尾空格和反斜杠）且不回显
  while [ "$ROOT_LOGIN" = yes ] && [ -z "$ROOT_PASSWORD" ]; do
    IFS= read -r -s -p "root 新密码 [回车沿用现有密码]: " reply </dev/tty; echo
    if [ -z "$reply" ]; then break; fi
    IFS= read -r -s -p "再次输入 root 新密码: " confirm </dev/tty; echo
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
    if [ -z "$PUBLIC_IP" ]; then PUBLIC_IP=$ip; fi
    # CN 仅指中国大陆，港澳台有各自的代码
    if [ "$cc" = CN ]; then IN_CHINA=1; fi
  done
}

# 只替换官方源域名；云厂商自带的内网镜像等其他源保持不动
use_ustc_mirror() {
  local f files=()
  case "$OS_ID" in
    debian)
      # Debian 12+ 云镜像的源地址写在 /etc/apt/mirrors/*.list，debian.sources 只是引用它
      for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources /etc/apt/mirrors/*.list; do
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
  local user home file key blob tmp users=(root)
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
      # 云镜像会把同一把公钥以 command="echo Please login as the user ..." 的受限形式预置在 root 下，
      # sshd 取第一条匹配的记录，不删掉它，后面追加的正常记录永远轮不到。所以先清掉同一公钥的所有旧行。
      blob=$(awk '{ for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $(i + 1); exit } }' <<<"$key")
      if [ -n "$blob" ]; then
        tmp=$(mktemp)
        grep -vF -- "$blob" "$file" >"$tmp" || true
        cat "$tmp" >"$file"
        rm -f "$tmp"
      fi
      printf '%s\n' "$key" >>"$file"
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
  local settings=() keys f backup tmp listen

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
  SSHD_BACKUP=$backup
  if ! restart_sshd; then
    SSHD_RESTART_FAILED=1
    warn "sshd 重启失败，请手动重启后配置才会生效"
  fi
  # 配置写对了不代表真的在监听：以实际监听端口为准
  if [ -n "$SSH_PORT" ] && command -v ss >/dev/null 2>&1; then
    sleep 1
    listen=$(ss -ltnH 2>/dev/null | awk '{ print $4 }')
    if ! grep -Eq "[:.]$SSH_PORT\$" <<<"$listen"; then
      SSHD_RESTART_FAILED=1
      warn "sshd 没有在端口 $SSH_PORT 上监听"
    fi
  fi
  info "sshd 已更新: $(IFS=,; echo "${settings[*]}")（备份: $backup）"
}

# 还原脚本独立成文件：既供本脚本直接调用，也供 systemd 定时器在会话断开后执行
write_rollback_script() {
  cat >"$ROLLBACK_SCRIPT" <<EOF
#!/bin/sh
rm -f $SSHD_DROPIN
tar -xzf $SSHD_BACKUP -C /
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl try-restart ssh.socket 2>/dev/null
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
else
  service ssh restart 2>/dev/null || service sshd restart
fi
EOF
  chmod 700 "$ROLLBACK_SCRIPT"
}

# 脚本只能确认 sshd 配置正确，确认不了安全组、防火墙是否放行，
# 所以改动 SSH 后必须由人用新连接实际登录一次；没人确认就自动还原。
confirm_ssh_access() {
  local reply="" how=() timer=0
  if [ -z "$SSHD_BACKUP" ] && [ ${#SSH_KEYS[@]} -eq 0 ]; then return 0; fi

  if [ "$INTERACTIVE" -eq 0 ]; then
    if [ -n "$SSH_PORT" ]; then
      warn "非交互模式下改了 SSH 端口，无法确认新端口能从外部连上"
    elif [ "$SSHD_RESTART_FAILED" -eq 0 ] && root_can_login; then
      SSH_CONFIRMED=1
    fi
    return 0
  fi

  if [ -n "$SSHD_BACKUP" ]; then
    write_rollback_script
    if [ -d /run/systemd/system ]; then
      systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
      systemctl reset-failed "$ROLLBACK_UNIT.service" 2>/dev/null || true
      if systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="$CONFIRM_TIMEOUT" "$ROLLBACK_SCRIPT"; then timer=1; fi
    fi
  fi

  if [ ${#SSH_KEYS[@]} -gt 0 ]; then how+=("公钥"); fi
  if [ "$ROOT_LOGIN" = yes ]; then how+=("密码"); fi
  echo
  warn "请保持当前窗口不要关闭，另开一个终端窗口验证 root 能否登录${how[0]+（$(IFS=/; echo "${how[*]}")）}："
  warn "    ssh -p $(current_ssh_port) root@${PUBLIC_IP:-服务器IP}"
  if [ -n "$SSHD_BACKUP" ]; then warn "${CONFIRM_TIMEOUT} 秒内未确认，或当前窗口断开，SSH 配置将自动还原。"; fi
  read -r -t "$CONFIRM_TIMEOUT" -p "新窗口登录成功了吗？[y 成功 / n 失败并还原]: " reply </dev/tty || true
  echo

  if [ "$timer" -eq 1 ]; then systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true; fi
  case "$reply" in
    y|Y|yes)
      SSH_CONFIRMED=1
      rm -f "$ROLLBACK_SCRIPT"
      info "已确认 root 可以登录" ;;
    *)
      if [ -n "$SSHD_BACKUP" ]; then
        "$ROLLBACK_SCRIPT" || true
        warn "未确认登录成功，SSH 配置已还原到运行前的状态（root 密码和已写入的公钥不会撤销）"
        SSH_PORT=""
      else
        warn "未确认登录成功"
      fi ;;
  esac
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
  if [ "$SSH_CONFIRMED" -eq 0 ] || [ "$SSHD_RESTART_FAILED" -eq 1 ] || ! root_can_login; then
    warn "未确认 root 可以登录，保留系统默认用户；确认后可手动执行 userdel -r 用户名"
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
  if [ "$removed" -eq 1 ]; then warn "默认用户已删除：当前会话结束后请改用 root 登录"; fi
}

install_docker() {
  local script
  if command -v docker >/dev/null 2>&1; then info "Docker 已安装，跳过"; return 0; fi

  info "开始安装 Docker..."
  script=$(mktemp)
  # Docker 装不上不应中断其余初始化步骤
  if ! curl -fsSL https://get.docker.com -o "$script"; then warn "下载 Docker 安装脚本失败，已跳过"; return 0; fi
  if [ "$IN_CHINA" -eq 1 ]; then export DOWNLOAD_URL=https://mirrors.ustc.edu.cn/docker-ce; fi
  if ! sh "$script"; then warn "Docker 安装失败，已跳过"; return 0; fi
  rm -f "$script"
  systemctl enable --now docker 2>/dev/null || true
  info "Docker 安装完成: $(docker --version)"
}

main() {
  parse_args "$@"
  ensure_root "$@"
  detect_os
  local i
  if command -v sshd >/dev/null 2>&1; then
    for i in "${!SSH_KEYS[@]}"; do
      SSH_KEYS[i]=$(trim "${SSH_KEYS[i]}")
      valid_ssh_key "${SSH_KEYS[i]}" || die "无效的 SSH 公钥: ${SSH_KEYS[i]}"
    done
  else
    warn "未安装 sshd，跳过全部 SSH 设置"
    HAS_SSHD=0; SSH_PORT=""; ROOT_LOGIN=""; SSH_KEYS=()
  fi
  collect_input

  detect_region
  if [ "$IN_CHINA" -eq 1 ]; then use_ustc_mirror; else info "位于中国大陆以外，软件源保持默认"; fi

  setup_timezone
  setup_dns
  setup_ipv4_first
  if [ "$BBR_MODE" != off ]; then setup_bbr; fi
  # Docker 安装耗时较长，放在 SSH 改动之前，避免占用登录确认的倒计时
  if [ "$INSTALL_DOCKER" = yes ]; then install_docker; fi
  if [ ${#SSH_KEYS[@]} -gt 0 ]; then add_ssh_keys; fi
  setup_sshd
  confirm_ssh_access
  if [ "$REMOVE_DEFAULT_USERS" -eq 1 ]; then remove_default_users; fi

  info "初始化完成"
  if [ -n "$SSH_PORT" ] && [ "$SSH_CONFIRMED" -eq 0 ]; then
    warn "SSH 端口已改为 $SSH_PORT：请在云厂商安全组和系统防火墙放行该端口，并先开新窗口确认能登录，再关闭当前会话"
  fi
}

main "$@"
