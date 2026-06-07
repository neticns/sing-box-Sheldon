#!/usr/bin/env bash
# Sing-box Sheldon 管理系统
# 轻量、省内存、最新 sing-box 协议管理脚本
# Version: 1.2.19

set -o pipefail

SCRIPT_VERSION="1.2.19"
SINGBOX_VERSION="1.13.13"
SINGBOX_DIR="/usr/local/etc/sing-box"
CONFIG_FILE="$SINGBOX_DIR/config.json"
USER_FILE="$SINGBOX_DIR/users.json"
SERVICE_NAME="sing-box"
BIN_PATH="/usr/local/bin/sing-box"
SCRIPT_PATH="/usr/local/bin/sing-box-sheldon"
SP_PATH="/usr/local/bin/sp"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/neticns/sing-box-Sheldon/main/sing-box-sheldon.sh"
PF_FILE="$SINGBOX_DIR/port_forward.rules"
CONNLIMIT_FILE="$SINGBOX_DIR/connlimit.rules"
CONNLIMIT_CHAIN="SING_BOX_SHELDON_CONNLIMIT"
CONNLIMIT_COMMENT="sing-box-sheldon-connlimit"
ARGO_DIR="$SINGBOX_DIR/argo"
ARGO_BIN="/usr/local/bin/cloudflared"
ARGO_SERVICE="cloudflared-sheldon"
ARGO_CONFIG="$ARGO_DIR/config.yml"
ARGO_INFO="$ARGO_DIR/tunnel.info"
SCRIPT_UPDATE_CACHE="/tmp/sing-box-sheldon-update.cache"
SCRIPT_UPDATE_CACHE_TTL=21600

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; WHITE='\033[37m'; NC='\033[0m'
BOLD='\033[1m'

_need_root() { [ "$(id -u)" -eq 0 ] || { echo -e "${RED}请使用 root 运行${NC}"; exit 1; }; }
_has() { command -v "$1" >/dev/null 2>&1; }
_ok() { echo -e "${GREEN}✓ $*${NC}"; }
_warn() { echo -e "${YELLOW}! $*${NC}"; }
_err() { echo -e "${RED}✗ $*${NC}"; }
_pause() { echo; read -r -p "按回车继续..." _; }
_rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || sing-box generate uuid 2>/dev/null || uuidgen; }
_rand_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; echo; }

_pkg_install() {
  _pkg_update_once
  local p ok=0
  for p in "$@"; do
    _pkg_install_one "$p" && ok=1 || true
  done
  [ "$ok" = "1" ] || { _err "未知包管理器或依赖安装失败: $*"; return 1; }
}

_realpath_self() {
  if _has readlink; then readlink -f "$0" 2>/dev/null && return; fi
  echo "$0"
}

_detect_os() {
  if [ -f /etc/os-release ]; then . /etc/os-release; echo "${ID:-unknown}"; else echo unknown; fi
}

_pkg_update_once() {
  [ "${PKG_UPDATED:-0}" = "1" ] && return 0
  PKG_UPDATED=1
  if _has apk; then apk update || true; return 0; fi
  if _has apt-get; then apt-get update -y || apt-get update || true; return 0; fi
  if _has dnf; then dnf makecache -y || true; return 0; fi
  if _has yum; then yum makecache -y || true; return 0; fi
  if _has zypper; then zypper --non-interactive refresh || true; return 0; fi
  return 0
}

_pkg_install_one() {
  local pkg="$1"
  if _has apk; then apk add --no-cache "$pkg" && return 0; apk add "$pkg" && return 0; fi
  if _has apt-get; then DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" && return 0; fi
  if _has dnf; then dnf install -y "$pkg" && return 0; fi
  if _has yum; then yum install -y "$pkg" && return 0; fi
  if _has zypper; then zypper --non-interactive install -y "$pkg" && return 0; fi
  return 1
}

_ensure_cmd() {
  local cmd="$1"; shift
  _has "$cmd" && return 0
  _pkg_update_once
  local p
  for p in "$@"; do
    [ -n "$p" ] || continue
    _warn "缺少 $cmd，尝试安装依赖包: $p"
    _pkg_install_one "$p" && _has "$cmd" && return 0
  done
  _has "$cmd" && return 0
  _err "无法自动安装依赖: $cmd"
  return 1
}

_ensure_core_deps() {
  _pkg_update_once
  _ensure_cmd curl curl ca-certificates || _ensure_cmd wget wget ca-certificates || return 1
  _ensure_cmd tar tar || return 1
  _ensure_cmd gzip gzip || true
  _ensure_cmd jq jq || true
  _ensure_cmd ss iproute2 iproute iproute2-ss || true
  _ensure_cmd uuidgen uuid-runtime util-linux || true
  _ensure_cmd base64 coreutils || true
  _ensure_cmd openssl openssl || true
  _ensure_cmd nohup coreutils || true
  if ! _has curl && _has wget; then _warn "curl 不可用，将使用 wget 下载"; fi
  return 0
}

_fetch() {
  local url="$1" out="$2"
  if _has curl; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 240 "$url" -o "$out" && return 0
  fi
  if _has wget; then
    wget -O "$out" --tries=3 --timeout=30 "$url" && return 0
  fi
  return 1
}

# 兼容旧调用名，脚本自更新和后续下载统一走这里。
_download() {
  _fetch "$@"
}

_install_script_shortcut() {
  local self
  self="$(_realpath_self)"
  if [ -f "$self" ]; then
    install -m 755 "$self" "$SCRIPT_PATH" 2>/dev/null || cp "$self" "$SCRIPT_PATH"
  elif [ -f "$0" ]; then
    cp "$0" "$SCRIPT_PATH" 2>/dev/null || true
  fi
  if [ -f "$SCRIPT_PATH" ]; then
    chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    ln -sf "$SCRIPT_PATH" "$SP_PATH" 2>/dev/null || true
  else
    _warn "当前是管道执行，无法复制脚本本体；如需 sp 快捷命令，请先下载脚本文件再运行安装"
  fi
}

_get_public_ip() {
  local ip
  ip=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(curl -4 -s --max-time 6 https://ifconfig.me 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "$ip"
}

_open_firewall_port() {
  local port="$1" proto="${2:-tcp}"
  if _has ufw; then ufw allow "${port}/${proto}" >/dev/null 2>&1 || true; fi
  if _has firewall-cmd; then firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi
}

_iptables_has_connlimit() {
  _has iptables || return 1
  iptables -m connlimit -h >/dev/null 2>&1 || return 1
}

_ip6tables_has_connlimit() {
  _has ip6tables || return 1
  ip6tables -m connlimit -h >/dev/null 2>&1 || return 1
}

_connlimit_proto_enforceable() {
  case "$1" in
    hysteria2|hy2|tuic) return 1 ;;
    *) return 0 ;;
  esac
}

_port_in_use() {
  local port="$1"
  if _has ss; then ss -lntup 2>/dev/null | grep -qE ":${port}[[:space:]]" && return 0; fi
  if _has netstat; then netstat -lntup 2>/dev/null | grep -qE ":${port}[[:space:]]" && return 0; fi
  return 1
}

_latest_singbox_version() {
  local tag api="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
  if _has curl; then tag=$(curl -fsSL --connect-timeout 10 --max-time 20 "$api" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1); fi
  if [ -z "$tag" ] && _has wget; then tag=$(wget -qO- --timeout=20 "$api" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1); fi
  echo "${tag:-$SINGBOX_VERSION}"
}

_sync_latest_version() {
  local latest
  _ensure_core_deps >/dev/null 2>&1 || true
  latest="$(_latest_singbox_version)"
  if [ -n "$latest" ]; then
    SINGBOX_VERSION="$latest"
    _ok "已使用最新 sing-box 稳定版: v${SINGBOX_VERSION}"
  fi
}

_generate_reality_keypair() {
  if _has sing-box; then sing-box generate reality-keypair 2>/dev/null; return; fi
  if [ -x "$BIN_PATH" ]; then "$BIN_PATH" generate reality-keypair 2>/dev/null; return; fi
  _warn "sing-box 未安装，安装核心后可生成 Reality 密钥"
}

_generate_reality_material() {
  local out bin sid profile alpn
  bin="$BIN_PATH"; _has sing-box && bin="$(command -v sing-box)"
  [ -x "$bin" ] || { _err "Reality 协议需要先安装 sing-box 核心"; return 1; }
  out="$($bin generate reality-keypair 2>/dev/null)" || return 1
  REALITY_PRIVATE=$(printf '%s
' "$out" | awk -F': ' '/PrivateKey/{print $2; exit}')
  REALITY_PUBLIC=$(printf '%s
' "$out" | awk -F': ' '/PublicKey/{print $2; exit}')
  sid=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)
  profile="$(_random_reality_profile)"
  REALITY_HANDSHAKE_SERVER="${profile%%|*}"
  profile="${profile#*|}"; REALITY_SERVER_NAME="${profile%%|*}"
  alpn="${profile##*|}"
  REALITY_ALPN="${alpn:-h2,http/1.1}"
  REALITY_SHORT_ID="${sid:-0123456789abcdef}"
  [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || { _err "生成 Reality 密钥失败"; return 1; }
}

_random_reality_profile() {
  # 默认使用真实大型站点作为 Reality 握手伪装；不需要自有域名/证书。
  # 输出: server|sni|alpn_csv
  local profiles idx
  profiles="www.microsoft.com|www.microsoft.com|h2,http/1.1
www.apple.com|www.apple.com|h2,http/1.1
www.cloudflare.com|www.cloudflare.com|h2,http/1.1
www.samsung.com|www.samsung.com|h2,http/1.1
www.bing.com|www.bing.com|h2,http/1.1"
  idx=$(awk -v max=5 'BEGIN{srand(); print int(rand()*max)+1}')
  printf '%s
' "$profiles" | sed -n "${idx}p"
}

_ensure_ntp_config() {
  _jq
  _init_dirs
  local tmp="$CONFIG_FILE.tmp"
  jq '
    .ntp = ((.ntp // {}) + {
      enabled: true,
      server: "time.apple.com",
      server_port: 123,
      interval: "30m",
      detour: "direct"
    })
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

_generate_uuid() {
  if _has sing-box; then sing-box generate uuid 2>/dev/null && return; fi
  _rand_uuid
}

_protocol_menu_choice() {
  echo -e "${CYAN}请选择协议:${NC}" >&2
  echo "  1. sheldon（推荐，VLESS + Reality + Vision）" >&2
  echo "  2. sheldon-vless / vless-reality" >&2
  echo "  3. sheldon-anytls / anytls-reality" >&2
  echo "  4. vless" >&2
  echo "  5. vmess" >&2
  echo "  6. trojan" >&2
  echo "  7. hysteria2" >&2
  echo "  8. tuic" >&2
  echo "  9. shadowsocks" >&2
  echo "  10. anytls" >&2
  echo "  11. socks" >&2
  read -r -p "协议编号 [1]: " proto_choice
  case "${proto_choice:-1}" in
    1) echo "sheldon" ;;
    2) echo "sheldon-vless" ;;
    3) echo "sheldon-anytls" ;;
    4) echo "vless" ;;
    5) echo "vmess" ;;
    6) echo "trojan" ;;
    7) echo "hysteria2" ;;
    8) echo "tuic" ;;
    9) echo "shadowsocks" ;;
    10) echo "anytls" ;;
    11) echo "socks" ;;
    *) _err "协议编号错误" >&2; return 1 ;;
  esac
}

_random_free_port() {
  local p tries=0
  while [ "$tries" -lt 80 ]; do
    p=$(awk 'BEGIN{srand(); print int(20000 + rand() * 40000)}')
    if ! _port_in_use "$p"; then echo "$p"; return 0; fi
    tries=$((tries+1))
    sleep 0.02 2>/dev/null || true
  done
  _err "随机端口生成失败" >&2
  return 1
}

_read_listen_port() {
  local prompt="${1:-监听端口（留空随机）: }" port
  read -r -p "$prompt" port
  if [ -z "$port" ]; then
    port="$(_random_free_port)" || return 1
    _ok "已随机选择端口: $port" >&2
  fi
  [[ "$port" =~ ^[0-9]+$ ]] || { _err "端口错误" >&2; return 1; }
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { _err "端口范围必须是 1-65535" >&2; return 1; }
  if _port_in_use "$port"; then _err "端口已占用" >&2; return 1; fi
  echo "$port"
}

_uninstall_all() {
  _need_root
  read -r -p "确认卸载 sing-box Sheldon 和 sing-box 服务？输入 yes: " yes
  [ "$yes" = "yes" ] || { _warn "已取消"; return; }
  _service stop >/dev/null 2>&1 || true
  if _has systemctl; then systemctl disable sing-box >/dev/null 2>&1 || true; rm -f /etc/systemd/system/sing-box.service; rm -rf /etc/systemd/system/sing-box.service.d; systemctl daemon-reload || true; fi
  if _has rc-update; then rc-update del sing-box default >/dev/null 2>&1 || true; rm -f /etc/init.d/sing-box; fi
  rm -f "$BIN_PATH" "$SP_PATH" "$SCRIPT_PATH" /etc/sysctl.d/99-sing-box-sheldon.conf
  _ok "已卸载二进制/服务/sp 快捷命令；配置目录保留: $SINGBOX_DIR"
}

_system_tools_menu() {
  while true; do
    clear
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "${BOLD}${WHITE}                    系统工具${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "    ${BLUE}1.${NC} ${GREEN}安装/修复依赖库${NC}"
    echo -e "    ${BLUE}2.${NC} ${GREEN}开启 BBR/系统优化${NC}"
    echo -e "    ${BLUE}3.${NC} ${GREEN}查看端口监听${NC}"
    echo -e "    ${BLUE}4.${NC} ${GREEN}查看系统信息${NC}"
    echo -e "    ${BLUE}5.${NC} ${GREEN}生成 UUID${NC}"
    echo -e "    ${BLUE}6.${NC} ${GREEN}生成 Reality 密钥对${NC}"
    echo -e "    ${BLUE}7.${NC} ${GREEN}应用轻量配置优化${NC}"
    echo -e "    ${BLUE}8.${NC} ${GREEN}脚本自检/可用性检测${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}返回主菜单${NC}"
    read -r -p "请选择操作: " c
    case "$c" in
      1) _ensure_core_deps; _pause ;;
      2) _optimize_system; _pause ;;
      3) (_has ss && ss -tulnp) || (_has netstat && netstat -tulnp) || echo "缺少 ss/netstat"; _pause ;;
      4) uname -a; echo; free -h 2>/dev/null || true; df -h 2>/dev/null || true; _pause ;;
      5) _generate_uuid; _pause ;;
      6) _generate_reality_keypair; _pause ;;
      7) _optimize_config_light; _pause ;;
      8) _self_check; _pause ;;
      0) break ;;
    esac
  done
}





_repair_missing_tls_certs() {
  _jq
  [ -f "$CONFIG_FILE" ] || return 0
  local pairs name cert key tmp
  pairs=$(jq -r '.inbounds[]? | select(.tls.enabled == true) | [.tag, .tls.certificate_path, .tls.key_path] | @tsv' "$CONFIG_FILE" 2>/dev/null || true)
  [ -n "$pairs" ] || return 0
  while IFS=$'\t' read -r name cert key; do
    [ -n "$name" ] || continue
    if [ ! -s "$cert" ] || [ ! -s "$key" ]; then
      if _has openssl; then
        mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
          -subj "/CN=sing-box-sheldon" \
          -keyout "$key" -out "$cert" >/dev/null 2>&1 || true
        chmod 600 "$key" 2>/dev/null || true
      fi
    fi
  done <<EOF
$pairs
EOF
}

_migrate_config_latest() {
  _jq
  [ -f "$CONFIG_FILE" ] || return 0
  local tmp="$CONFIG_FILE.tmp"
  jq '
    if (.dns.servers? | type) == "array" then
      .dns.servers |= map(
        if (.address? and (.type? | not)) then
          .type = "udp" | .server = .address | del(.address)
        else . end
      )
    else . end |
    .ntp = ((.ntp // {}) + {enabled:true, server:"time.apple.com", server_port:123, interval:"30m", detour:"direct"}) |
    .route.default_domain_resolver = (.route.default_domain_resolver // ((.dns.servers[0].tag // "cf"))) |
    if (.dns.rules? | type) == "array" then
      .dns.rules |= map(del(.outbound, .domain_resolver))
    else . end
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

_version_gt() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ] && [ "$1" != "$2" ]
}

_remote_script_version() {
  local data ver
  if _has curl; then
    data=$(curl -fsSL --connect-timeout 3 --max-time 6 "$SCRIPT_UPDATE_URL" 2>/dev/null || true)
  elif _has wget; then
    data=$(wget -qO- --timeout=6 "$SCRIPT_UPDATE_URL" 2>/dev/null || true)
  fi
  ver=$(printf '%s\n' "$data" | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -1)
  echo "$ver"
}

_check_script_update_hint() {
  local now cache_ts cache_ver remote_ver
  now=$(date +%s 2>/dev/null || echo 0)
  if [ -s "$SCRIPT_UPDATE_CACHE" ]; then
    IFS='|' read -r cache_ts cache_ver < "$SCRIPT_UPDATE_CACHE" || true
    if [ -n "$cache_ts" ] && [ $((now - cache_ts)) -lt "$SCRIPT_UPDATE_CACHE_TTL" ]; then
      remote_ver="$cache_ver"
    fi
  fi
  if [ -z "$remote_ver" ]; then
    remote_ver="$(_remote_script_version)"
    [ -n "$remote_ver" ] && printf '%s|%s\n' "$now" "$remote_ver" > "$SCRIPT_UPDATE_CACHE" 2>/dev/null || true
  fi
  if [ -n "$remote_ver" ] && _version_gt "$remote_ver" "$SCRIPT_VERSION"; then
    echo -e "${YELLOW}提醒：发现 Sheldon 脚本新版本 v${remote_ver}，当前 v${SCRIPT_VERSION}。主菜单选 10 或运行 sp script-update 更新。${NC}"
  fi
}

_self_check() {
  echo -e "${CYAN}sing-box Sheldon 自检${NC}"
  echo "脚本版本: ${SCRIPT_VERSION}"
  _check_script_update_hint
  echo "系统架构: $(uname -m)"
  echo "系统类型: $(_detect_os 2>/dev/null || echo unknown)"
  echo
  local ok=0 fail=0 warn=0
  _check_item() {
    local name="$1" cmd="$2" level="${3:-required}"
    if eval "$cmd" >/dev/null 2>&1; then
      echo -e "${GREEN}✓${NC} $name"
      ok=$((ok+1))
    else
      if [ "$level" = "warn" ]; then
        echo -e "${YELLOW}!${NC} $name"
        warn=$((warn+1))
      else
        echo -e "${RED}✗${NC} $name"
        fail=$((fail+1))
      fi
    fi
  }

  _check_item "root 权限" '[ "$(id -u)" -eq 0 ]'
  _check_item "包管理器" '_has apk || _has apt-get || _has dnf || _has yum || _has zypper'
  _check_item "下载工具 curl/wget" '_has curl || _has wget' warn
  _check_item "解压工具 tar" '_has tar' warn
  _check_item "JSON 工具 jq" '_has jq' warn
  _check_item "端口工具 ss/netstat" '_has ss || _has netstat' warn
  _check_item "防火墙转发 iptables" '_has iptables' warn
  _check_item "服务管理 systemd/OpenRC" '_has systemctl || _has rc-service' warn
  _check_item "sing-box 核心" '[ -x "$BIN_PATH" ] || _has sing-box' warn
  _check_item "配置目录可写" 'mkdir -p "$SINGBOX_DIR" && [ -w "$SINGBOX_DIR" ]'
  _migrate_config_latest >/dev/null 2>&1 || true
  _repair_missing_tls_certs >/dev/null 2>&1 || true

  if [ -x "$BIN_PATH" ] && [ -f "$CONFIG_FILE" ]; then
    _check_item "sing-box 配置检查" '"$BIN_PATH" check -c "$CONFIG_FILE"'
  else
    echo -e "${YELLOW}!${NC} sing-box 配置检查：核心或配置不存在，安装后再测"
    warn=$((warn+1))
  fi

  echo
  echo "结果: 通过 ${ok}，警告 ${warn}，失败 ${fail}"
  if [ "$fail" -eq 0 ]; then
    _ok "基础环境可用"
    return 0
  fi
  _err "存在必须修复的问题，可先执行：$0 deps"
  return 1
}

_port_forward_apply() {
  _need_root
  mkdir -p "$SINGBOX_DIR"
  [ -f "$PF_FILE" ] || touch "$PF_FILE"
  _ensure_cmd iptables iptables iptables-nft || { _err "缺少 iptables"; return 1; }
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  while IFS='|' read -r lport rhost rport proto remark; do
    [ -n "$lport" ] || continue
    proto="${proto:-tcp}"
    iptables -t nat -C PREROUTING -p "$proto" --dport "$lport" -j DNAT --to-destination "${rhost}:${rport}" 2>/dev/null || \
      iptables -t nat -A PREROUTING -p "$proto" --dport "$lport" -j DNAT --to-destination "${rhost}:${rport}"
    iptables -t nat -C POSTROUTING -p "$proto" -d "$rhost" --dport "$rport" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -p "$proto" -d "$rhost" --dport "$rport" -j MASQUERADE
    _open_firewall_port "$lport" "$proto"
  done < "$PF_FILE"
  _ok "端口转发规则已应用"
}

_port_forward_add() {
  _need_root
  mkdir -p "$SINGBOX_DIR"
  read -r -p "本地监听端口: " lport
  [[ "$lport" =~ ^[0-9]+$ ]] || { _err "端口错误"; return; }
  read -r -p "目标 IP/域名: " rhost
  [ -n "$rhost" ] || { _err "目标不能为空"; return; }
  read -r -p "目标端口 [$lport]: " rport; rport="${rport:-$lport}"
  [[ "$rport" =~ ^[0-9]+$ ]] || { _err "目标端口错误"; return; }
  read -r -p "协议 tcp/udp/both [tcp]: " proto; proto="${proto:-tcp}"
  read -r -p "备注: " remark
  case "$proto" in
    tcp|udp)
      echo "${lport}|${rhost}|${rport}|${proto}|${remark}" >> "$PF_FILE" ;;
    both)
      echo "${lport}|${rhost}|${rport}|tcp|${remark}" >> "$PF_FILE"
      echo "${lport}|${rhost}|${rport}|udp|${remark}" >> "$PF_FILE" ;;
    *) _err "协议只能是 tcp/udp/both"; return ;;
  esac
  _port_forward_apply
}

_port_forward_list() {
  mkdir -p "$SINGBOX_DIR"
  [ -f "$PF_FILE" ] || touch "$PF_FILE"
  echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"
  printf "${GREEN}%-5s %-8s %-24s %-8s %-8s %-20s${NC}\n" "序号" "本地端口" "目标" "目标端口" "协议" "备注"
  echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"
  local i=1
  while IFS='|' read -r lport rhost rport proto remark; do
    [ -n "$lport" ] || continue
    printf "%-5s %-8s %-24s %-8s %-8s %-20s\n" "$i" "$lport" "$rhost" "$rport" "$proto" "$remark"
    i=$((i+1))
  done < "$PF_FILE"
}

_port_forward_delete() {
  _need_root
  _port_forward_list
  read -r -p "要删除的序号: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || return
  local line lport rhost rport proto remark tmp
  line=$(sed -n "${idx}p" "$PF_FILE")
  [ -n "$line" ] || { _err "序号不存在"; return; }
  IFS='|' read -r lport rhost rport proto remark <<EOF
$line
EOF
  iptables -t nat -D PREROUTING -p "$proto" --dport "$lport" -j DNAT --to-destination "${rhost}:${rport}" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p "$proto" -d "$rhost" --dport "$rport" -j MASQUERADE 2>/dev/null || true
  tmp="${PF_FILE}.tmp"
  awk -v n="$idx" 'NR!=n' "$PF_FILE" > "$tmp" && mv "$tmp" "$PF_FILE"
  _ok "已删除端口转发规则"
}

_port_forward_clear() {
  _need_root
  [ -f "$PF_FILE" ] || { _ok "没有端口转发规则"; return; }
  while IFS='|' read -r lport rhost rport proto remark; do
    [ -n "$lport" ] || continue
    iptables -t nat -D PREROUTING -p "$proto" --dport "$lport" -j DNAT --to-destination "${rhost}:${rport}" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -p "$proto" -d "$rhost" --dport "$rport" -j MASQUERADE 2>/dev/null || true
  done < "$PF_FILE"
  : > "$PF_FILE"
  _ok "已清空端口转发规则"
}

_port_forward_persist() {
  _need_root
  _ensure_cmd iptables iptables iptables-nft || return 1
  cat >/etc/systemd/system/sing-box-sheldon-port-forward.service <<EOF
[Unit]
Description=sing-box Sheldon port forward rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH port-forward-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  if _has systemctl; then systemctl daemon-reload; systemctl enable sing-box-sheldon-port-forward >/dev/null 2>&1 || true; fi
  _ok "已设置 systemd 开机自动应用端口转发"
}

_port_forward_menu() {
  while true; do
    clear
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "${BOLD}${WHITE}                    端口转发管理${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    _port_forward_list
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "    ${BLUE}1.${NC} ${GREEN}新增端口转发${NC}"
    echo -e "    ${BLUE}2.${NC} ${GREEN}删除端口转发${NC}"
    echo -e "    ${BLUE}3.${NC} ${GREEN}应用转发规则${NC}"
    echo -e "    ${BLUE}4.${NC} ${GREEN}清空转发规则${NC}"
    echo -e "    ${BLUE}5.${NC} ${GREEN}设置开机自动应用${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}返回主菜单${NC}"
    read -r -p "请选择操作: " c
    case "$c" in
      1) _port_forward_add; _pause ;;
      2) _port_forward_delete; _pause ;;
      3) _port_forward_apply; _pause ;;
      4) _port_forward_clear; _pause ;;
      5) _port_forward_persist; _pause ;;
      0) break ;;
    esac
  done
}

_connlimit_refresh_state() {
  _jq
  mkdir -p "$SINGBOX_DIR"
  [ -f "$USER_FILE" ] || echo '{"users":[]}' > "$USER_FILE"
  local tmp="${CONNLIMIT_FILE}.tmp"
  jq -r '
    .users[]? |
    (.connection_limit_count // 0) as $conn |
    select($conn > 0) |
    [
      (.name // ""),
      (.tag // ""),
      (.port // 0),
      (.protocol // ""),
      ($conn | tostring)
    ] | @tsv
  ' "$USER_FILE" | while IFS=$'\t' read -r name tag port proto conn; do
    [ -n "$name" ] || continue
    [ "$port" -gt 0 ] 2>/dev/null || continue
    case "$proto" in
      hysteria2|hy2|tuic)
        printf '#WARN|%s|%s|%s|%s|%s\n' "$conn" "$name" "$tag" "$proto" "$port"
        ;;
      *)
        printf '%s|%s|%s|%s|%s\n' "$port" "$conn" "$name" "$tag" "$proto"
        ;;
    esac
  done > "$tmp" && mv "$tmp" "$CONNLIMIT_FILE"
}

_connlimit_detach_input_cmd() {
  local cmd="$1"
  while "$cmd" -C INPUT -j "$CONNLIMIT_CHAIN" -m comment --comment "$CONNLIMIT_COMMENT" >/dev/null 2>&1; do
    "$cmd" -D INPUT -j "$CONNLIMIT_CHAIN" -m comment --comment "$CONNLIMIT_COMMENT" >/dev/null 2>&1 || break
  done
}

_connlimit_reset_chain_cmd() {
  local cmd="$1"
  "$cmd" -N "$CONNLIMIT_CHAIN" >/dev/null 2>&1 || true
  "$cmd" -F "$CONNLIMIT_CHAIN" >/dev/null 2>&1 || true
  _connlimit_detach_input_cmd "$cmd"
}

_connlimit_drop_empty_chain_cmd() {
  local cmd="$1"
  _connlimit_detach_input_cmd "$cmd"
  "$cmd" -F "$CONNLIMIT_CHAIN" >/dev/null 2>&1 || true
  "$cmd" -X "$CONNLIMIT_CHAIN" >/dev/null 2>&1 || true
}

_connlimit_apply_cmd() {
  local cmd="$1" mask="$2" port conn name tag proto warn=0 applied=0
  _connlimit_reset_chain_cmd "$cmd"
  "$cmd" -I INPUT 1 -j "$CONNLIMIT_CHAIN" -m comment --comment "$CONNLIMIT_COMMENT"

  while IFS='|' read -r port conn name tag proto _msg; do
    [ -n "$port" ] || continue
    if [ "$port" = "#WARN" ]; then
      warn=1
      continue
    fi
    [ "$port" -gt 0 ] 2>/dev/null || continue
    [ "$conn" -gt 0 ] 2>/dev/null || continue
    "$cmd" -A "$CONNLIMIT_CHAIN" -p tcp --syn --dport "$port" \
      -m connlimit --connlimit-above "$conn" --connlimit-mask "$mask" \
      -m comment --comment "${CONNLIMIT_COMMENT}:${port}:${conn}" -j REJECT --reject-with tcp-reset
    applied=$((applied+1))
  done < "$CONNLIMIT_FILE"

  if [ "$applied" -eq 0 ]; then
    _connlimit_drop_empty_chain_cmd "$cmd"
  fi
  echo "$applied|$warn"
}

_connlimit_apply() {
  _need_root
  mkdir -p "$SINGBOX_DIR"
  _connlimit_refresh_state || return 1
  _ensure_cmd iptables iptables iptables-nft || { _err "缺少 iptables"; return 1; }

  local applied4=0 applied6=0 warn=0 out
  if _iptables_has_connlimit; then
    out="$(_connlimit_apply_cmd iptables 32)"
    applied4="${out%%|*}"; warn="${out##*|}"
  else
    _warn "iptables connlimit 模块不可用；IPv4 连接数限制已保存但无法执行"
  fi

  if _ip6tables_has_connlimit; then
    out="$(_connlimit_apply_cmd ip6tables 128)"
    applied6="${out%%|*}"
  elif _has ip6tables; then
    _warn "ip6tables connlimit 模块不可用；IPv6 连接数限制已保存但无法执行"
  fi

  if [ "$applied4" -eq 0 ] 2>/dev/null && [ "$applied6" -eq 0 ] 2>/dev/null && ! _iptables_has_connlimit && ! _ip6tables_has_connlimit; then
    _warn "连接数限制已保存，但当前防火墙 connlimit 能力不可用"
  fi
  [ "$warn" -eq 0 ] || _warn "UDP 连接数限制不能通过 TCP connlimit 执行"
  _ok "连接数限制规则已应用: IPv4 ${applied4} 条，IPv6 ${applied6} 条 TCP 规则"
}

_connlimit_clear_rules() {
  _need_root
  local cleared=0
  if _has iptables; then _connlimit_drop_empty_chain_cmd iptables; cleared=1; fi
  if _has ip6tables; then _connlimit_drop_empty_chain_cmd ip6tables; cleared=1; fi
  [ "$cleared" -eq 1 ] || { _ok "iptables/ip6tables 不存在，无需清理"; return 0; }
  _ok "已清除连接数限制防火墙规则"
}

_connlimit_list() {
  mkdir -p "$SINGBOX_DIR"
  [ -f "$CONNLIMIT_FILE" ] || _connlimit_refresh_state >/dev/null 2>&1 || touch "$CONNLIMIT_FILE"
  echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"
  printf "${GREEN}%-8s %-8s %-14s %-24s %-12s %-10s${NC}\n" "端口" "限制" "用户名" "标签" "协议" "状态"
  echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"
  local port conn name tag proto msg any=0
  while IFS='|' read -r port conn name tag proto msg; do
    [ -n "$port" ] || continue
    any=1
    if [ "$port" = "#WARN" ]; then
      printf "%-8s %-8s %-14s %-24s %-12s %-10s\n" "$tag" "$msg" "$conn" "$name" "$proto" "仅记录"
    else
      printf "%-8s %-8s %-14s %-24s %-12s %-10s\n" "$port" "$conn" "$name" "$tag" "$proto" "TCP"
    fi
  done < "$CONNLIMIT_FILE"
  [ "$any" -eq 1 ] || echo "暂无连接数限制规则"
  if _has iptables && iptables -L "$CONNLIMIT_CHAIN" -n >/dev/null 2>&1; then
    echo
    echo "IPv4 当前规则:"
    iptables -L "$CONNLIMIT_CHAIN" -n -v --line-numbers
  fi
  if _has ip6tables && ip6tables -L "$CONNLIMIT_CHAIN" -n >/dev/null 2>&1; then
    echo
    echo "IPv6 当前规则:"
    ip6tables -L "$CONNLIMIT_CHAIN" -n -v --line-numbers
  fi
}

_connlimit_persist() {
  _need_root
  _ensure_cmd iptables iptables iptables-nft || return 1
  cat >/etc/systemd/system/sing-box-sheldon-connlimit.service <<EOF
[Unit]
Description=sing-box Sheldon connection limit rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH connlimit-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  if _has systemctl; then systemctl daemon-reload; systemctl enable sing-box-sheldon-connlimit >/dev/null 2>&1 || true; fi
  _ok "已设置 systemd 开机自动应用连接数限制"
}

_connlimit_menu() {
  while true; do
    clear
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "${BOLD}${WHITE}                    连接数限制防火墙规则${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    _connlimit_list
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "    ${BLUE}1.${NC} ${GREEN}从 users.json 应用规则${NC}"
    echo -e "    ${BLUE}2.${NC} ${GREEN}清除防火墙规则${NC}"
    echo -e "    ${BLUE}3.${NC} ${GREEN}设置开机自动应用${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}返回主菜单${NC}"
    read -r -p "请选择操作: " c
    case "$c" in
      1) _connlimit_apply; _pause ;;
      2) _connlimit_clear_rules; _pause ;;
      3) _connlimit_persist; _pause ;;
      0) break ;;
    esac
  done
}

_warp_menu() {
  echo -e "${CYAN}WARP 分流说明${NC}"
  echo "当前轻量版提供 WireGuard/WARP 配置占位和手动接入入口。"
  echo "建议先用 wgcf/warp-go 生成 wireguard outbound，再通过中转/分流菜单写入 route rules。"
  echo
  echo "后续可扩展为：自动安装 wgcf、注册 WARP、生成 outbound、按 OpenAI/Netflix/Google 分流。"
}

_relay_menu() {
  echo -e "${CYAN}中转管理说明${NC}"
  echo "当前版本保留轻量直连节点管理；中转功能建议使用 sing-box 的 inbound -> outbound -> route.rules 模式。"
  echo "下一版可继续加入链接解析导入：vless/vmess/trojan/hy2/tuic/ss/anytls/socks5。"
}

_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l) echo armv7 ;;
    *) _err "不支持架构: $(uname -m)"; exit 1 ;;
  esac
}

_init_dirs() {
  mkdir -p "$SINGBOX_DIR"
  [ -f "$USER_FILE" ] || printf '{"users":[]}\n' > "$USER_FILE"
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<'JSON'
{
  "log": {"disabled": false, "level": "error", "timestamp": false},
  "ntp": {"enabled": true, "server": "time.apple.com", "server_port": 123, "interval": "30m", "detour": "direct"},
  "dns": {
    "servers": [
      {"tag": "cf", "type": "udp", "server": "1.1.1.1"},
      {"tag": "local", "type": "udp", "server": "223.5.5.5"}
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "auto_detect_interface": false,
    "find_process": false,
    "default_domain_resolver": "cf",
    "final": "direct",
    "rules": []
  },
  "experimental": {
    "cache_file": {"enabled": false}
  }
}
JSON
  fi
}

_download_singbox() {
  local arch tar url tmp
  arch="$(_arch)"
  tmp="/tmp/sing-box-${SINGBOX_VERSION}-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz"
  _ensure_core_deps || return 1
  _warn "下载 sing-box v${SINGBOX_VERSION} (${arch})..."
  _fetch "$url" "$tmp" || return 1
  tar -xzf "$tmp" -C /tmp || return 1
  install -m 755 "/tmp/sing-box-${SINGBOX_VERSION}-linux-${arch}/sing-box" "$BIN_PATH"
  _install_script_shortcut
  rm -rf "$tmp" "/tmp/sing-box-${SINGBOX_VERSION}-linux-${arch}"
}

_install_service() {
  _init_dirs
  if _has systemctl; then
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$SINGBOX_DIR
ExecStart=$BIN_PATH run -c $CONFIG_FILE
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
MemoryMax=192M
MemoryHigh=160M
CPUQuota=85%
TasksMax=256
# 省内存/安全加固
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
PrivateDevices=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
  elif _has rc-service; then
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="$BIN_PATH"
command_args="run -c $CONFIG_FILE"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
depend() { need net; }
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1 || true
  else
    _warn "未检测到 systemd/OpenRC，已安装二进制但未创建服务"
  fi
}

_service() {
  local act="$1"
  if _has systemctl; then systemctl "$act" sing-box; return; fi
  if _has rc-service; then rc-service sing-box "$act"; return; fi
  case "$act" in
    restart|start) pkill -f 'sing-box run' 2>/dev/null || true; nohup "$BIN_PATH" run -c "$CONFIG_FILE" >/var/log/sing-box.log 2>&1 & ;;
    stop) pkill -f 'sing-box run' 2>/dev/null || true ;;
    status) pgrep -af 'sing-box run' || true ;;
  esac
}

_check_config() {
  "$BIN_PATH" check -c "$CONFIG_FILE"
}

_status_text() {
  if _has systemctl && systemctl is-active --quiet sing-box; then echo "运行中"; return; fi
  if _has rc-service && rc-service sing-box status 2>/dev/null | grep -qi started; then echo "运行中"; return; fi
  if pgrep -f 'sing-box run' >/dev/null; then echo "运行中"; return; fi
  echo "未运行"
}

_core_version() { "$BIN_PATH" version 2>/dev/null | awk 'NR==1{print $3}'; }

_jq() { _has jq || _pkg_install jq; }

_normalize_mbps_limit() {
  _jq
  local v="$1"
  v="${v:-0}"
  [ -n "$v" ] || v=0
  case "$v" in
    *[!0-9]*) _err "限速必须是整数 Mbps，留空或 0 表示不限"; return 1 ;;
  esac
  jq -en --arg v "$v" '
    ($v | tonumber) as $n |
    if $n < 0 then halt_error(1)
    elif $n == 0 then 0
    else $n
    end
  ' 2>/dev/null || { _err "限速必须是整数 Mbps，留空或 0 表示不限"; return 1; }
}

_read_speed_limits() {
  local up_in down_in
  read -r -p "上传限速 Mbps [不限]: " up_in
  LIMIT_UPLOAD_MBPS="$(_normalize_mbps_limit "$up_in")" || return 1
  read -r -p "下载限速 Mbps [不限]: " down_in
  LIMIT_DOWNLOAD_MBPS="$(_normalize_mbps_limit "$down_in")" || return 1
}

_normalize_conn_limit() {
  _jq
  local v="$1"
  v="${v:-0}"
  [ -n "$v" ] || v=0
  case "$v" in
    *[!0-9]*) _err "连接数限制必须是整数，留空或 0 表示不限"; return 1 ;;
  esac
  jq -en --arg v "$v" '
    ($v | tonumber) as $n |
    if $n < 0 then halt_error(1)
    elif $n == 0 then 0
    else $n
    end
  ' 2>/dev/null || { _err "连接数限制必须是整数，留空或 0 表示不限"; return 1; }
}

_read_conn_limit() {
  local conn_in
  read -r -p "客户端连接数限制 [不限]: " conn_in
  LIMIT_CONN_COUNT="$(_normalize_conn_limit "$conn_in")" || return 1
}

_limit_display() {
  local up="$1" down="$2"
  up="${up:-0}"; down="${down:-0}"
  if [ "$up" = "0" ] && [ "$down" = "0" ]; then
    echo "不限"
  else
    echo "${up}/${down}"
  fi
}

_conn_limit_display() {
  local conn="${1:-0}"
  if [ "$conn" = "0" ]; then echo "不限"; else echo "$conn"; fi
}

_add_user_record() {
  _jq
  local name="$1" status="$2" plan="$3" reset="$4" expire="$5" port="$6" proto="$7" uuid="$8" pass="$9" tag="${10}"
  local reality_public="${11:-}" reality_short_id="${12:-}" reality_sni="${13:-}" reality_alpn="${14:-}"
  local upload_limit="${15:-0}" download_limit="${16:-0}" conn_limit="${17:-0}"
  local tmp="$USER_FILE.tmp"
  jq --arg name "$name" --arg status "$status" --arg plan "$plan" --arg reset "$reset" --arg expire "$expire" --arg port "$port" --arg proto "$proto" --arg uuid "$uuid" --arg pass "$pass" --arg tag "$tag" --arg pbk "$reality_public" --arg sid "$reality_short_id" --arg sni "$reality_sni" --arg alpn "$reality_alpn" --argjson up "$upload_limit" --argjson down "$download_limit" --argjson conn "$conn_limit" \
    '.users += [{name:$name,status:$status,upload:0,download:0,correct:0,plan:$plan,reset:$reset,expire:$expire,port:($port|tonumber),protocol:$proto,uuid:$uuid,password:$pass,tag:$tag,upload_limit_mbps:$up,download_limit_mbps:$down,connection_limit_count:$conn,reality_public_key:$pbk,reality_short_id:$sid,reality_server_name:$sni,reality_alpn:$alpn,created:now|todate}]' \
    "$USER_FILE" > "$tmp" && mv "$tmp" "$USER_FILE"
}

_del_user_record() {
  _jq
  local name="$1" tmp="$USER_FILE.tmp"
  jq --arg name "$name" '.users |= map(select(.name != $name))' "$USER_FILE" > "$tmp" && mv "$tmp" "$USER_FILE"
}

_set_user_limit_record() {
  _jq
  local name="$1" up="$2" down="$3" tmp="$USER_FILE.tmp"
  jq --arg name "$name" --argjson up "$up" --argjson down "$down" \
    '.users |= map(if .name == $name then .upload_limit_mbps = $up | .download_limit_mbps = $down else . end)' \
    "$USER_FILE" > "$tmp" && mv "$tmp" "$USER_FILE"
}

_set_user_conn_limit_record() {
  _jq
  local name="$1" conn="$2" tmp="$USER_FILE.tmp"
  jq --arg name "$name" --argjson conn "$conn" \
    '.users |= map(if .name == $name then .connection_limit_count = $conn else . end)' \
    "$USER_FILE" > "$tmp" && mv "$tmp" "$USER_FILE"
}


_ensure_tls_cert() {
  local name="$1" cert="$SINGBOX_DIR/${name}.pem" key="$SINGBOX_DIR/${name}.key"
  if [ -s "$cert" ] && [ -s "$key" ]; then
    echo "$cert|$key"
    return 0
  fi
  if _has openssl; then
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
      -subj "/CN=sing-box-sheldon" \
      -keyout "$key" -out "$cert" >/dev/null 2>&1 || return 1
    chmod 600 "$key" 2>/dev/null || true
    echo "$cert|$key"
    return 0
  fi
  return 1
}

_add_inbound_json() {
  _jq
  local proto="$1" tag="$2" port="$3" uuid="$4" pass="$5" upload_limit="${6:-0}" download_limit="${7:-0}" tmp="$CONFIG_FILE.tmp" inbound
  LAST_REALITY_PUBLIC=""; LAST_REALITY_SHORT_ID=""; LAST_REALITY_SNI=""; LAST_REALITY_ALPN=""
  case "$proto" in
    vless)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:false}}') ;;
    vless-reality|reality|sheldon|sheldon-reality|sheldon-vless)
      _generate_reality_material || return 1
      LAST_REALITY_PUBLIC="$REALITY_PUBLIC"; LAST_REALITY_SHORT_ID="$REALITY_SHORT_ID"; LAST_REALITY_SNI="$REALITY_SERVER_NAME"; LAST_REALITY_ALPN="$REALITY_ALPN"
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg pk "$REALITY_PRIVATE" --arg sid "$REALITY_SHORT_ID" --arg sni "$REALITY_SERVER_NAME" --arg hs "$REALITY_HANDSHAKE_SERVER" '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,alpn:["h2","http/1.1"],reality:{enabled:true,handshake:{server:$hs,server_port:443},private_key:$pk,short_id:[$sid]}}}') ;;
    vmess)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" '{type:"vmess",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid}],transport:{type:"tcp"}}') ;;
    trojan)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" '{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pass}]}' ) ;;
    hysteria2|hy2)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" --argjson up "$upload_limit" --argjson down "$download_limit" '{type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pass}],up_mbps:(if $up > 0 then $up else 100 end),down_mbps:(if $down > 0 then $down else 500 end)}' ) ;;
    tuic)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg pass "$pass" '{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$pass}],congestion_control:"bbr"}' ) ;;
    shadowsocks|ss)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:"2022-blake3-aes-128-gcm",password:$pass}' ) ;;
    anytls)
      local ck cert key; ck="$(_ensure_tls_cert "${tag}-${port}")" || { _err "AnyTLS 需要 TLS 证书，且 openssl 不可用"; return 1; }
      cert="${ck%%|*}"; key="${ck##*|}"
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" --arg cert "$cert" --arg key "$key" '{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pass}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}' ) ;;
    anytls-reality|any-reality|sheldon-anytls)
      _generate_reality_material || return 1
      LAST_REALITY_PUBLIC="$REALITY_PUBLIC"; LAST_REALITY_SHORT_ID="$REALITY_SHORT_ID"; LAST_REALITY_SNI="$REALITY_SERVER_NAME"; LAST_REALITY_ALPN="$REALITY_ALPN"
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" --arg pk "$REALITY_PRIVATE" --arg sid "$REALITY_SHORT_ID" --arg sni "$REALITY_SERVER_NAME" --arg hs "$REALITY_HANDSHAKE_SERVER" '{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pass}],tls:{enabled:true,server_name:$sni,alpn:["h2","http/1.1"],reality:{enabled:true,handshake:{server:$hs,server_port:443},private_key:$pk,short_id:[$sid]}}}' ) ;;
    socks)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" '{type:"socks",tag:$tag,listen:"::",listen_port:$port,users:[{username:"user",password:$pass}]}' ) ;;
    *) _err "不支持协议: $proto"; return 1 ;;
  esac
  jq --argjson in "$inbound" '.inbounds += [$in]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

_apply_user_speed_limit_config() {
  _jq
  local proto="$1" tag="$2" upload_limit="${3:-0}" download_limit="${4:-0}" tmp="$CONFIG_FILE.tmp"
  case "$proto" in
    hysteria2|hy2)
      jq --arg tag "$tag" --argjson up "$upload_limit" --argjson down "$download_limit" '
        def inbound_matches($tag):
          if (.inbound? | type) == "array" then ((.inbound | index($tag)) != null)
          elif (.inbound? | type) == "string" then (.inbound == $tag)
          elif (.inbound_tag? | type) == "array" then ((.inbound_tag | index($tag)) != null)
          elif (.inbound_tag? | type) == "string" then (.inbound_tag == $tag)
          else false end;
        def sheldon_limit_action: ((.action // "") == "limit") or ((if (.action? | type) == "object" then (.action.type // "") else "" end) == "limit");
        .inbounds |= map(if .tag == $tag then .up_mbps = (if $up > 0 then $up else 100 end) | .down_mbps = (if $down > 0 then $down else 500 end) else . end) |
        .route.rules = ((.route.rules // []) | map(select((sheldon_limit_action | not) or (inbound_matches($tag) | not))))
      ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      ;;
    *)
      # sing-box 1.13.x has no generic per-inbound bandwidth-limit route action.
      # Keep user limits in users.json for display/future migration, and remove any stale
      # experimental limit rules generated by older script revisions so config checks pass.
      jq --arg tag "$tag" '
        def inbound_matches($tag):
          if (.inbound? | type) == "array" then ((.inbound | index($tag)) != null)
          elif (.inbound? | type) == "string" then (.inbound == $tag)
          elif (.inbound_tag? | type) == "array" then ((.inbound_tag | index($tag)) != null)
          elif (.inbound_tag? | type) == "string" then (.inbound_tag == $tag)
          else false end;
        def sheldon_limit_action: ((.action // "") == "limit") or ((if (.action? | type) == "object" then (.action.type // "") else "" end) == "limit");
        .route.rules = ((.route.rules // []) | map(select((sheldon_limit_action | not) or (inbound_matches($tag) | not))))
      ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      if [ "$upload_limit" != "0" ] || [ "$download_limit" != "0" ]; then
        _warn "当前 sing-box 核心仅 Hysteria2 支持入站限速；已保存限速记录，但此协议暂不强制执行"
      fi
      ;;
  esac
}

_apply_user_conn_limit_config() {
  _jq
  local proto="$1" tag="$2" conn_limit="${3:-0}" tmp="$CONFIG_FILE.tmp"
  # sing-box 1.13.x 当前常用入站没有已验证的通用客户端连接数限制字段。
  # max_conn_client 属于旧 hysteria 入站，不适用于本脚本使用的 hysteria2。
  # 因此只清理可能残留的实验字段/规则，连接数限制保存在 users.json 用于展示和后续迁移。
  jq --arg tag "$tag" '
    def inbound_matches($tag):
      if (.inbound? | type) == "array" then ((.inbound | index($tag)) != null)
      elif (.inbound? | type) == "string" then (.inbound == $tag)
      elif (.inbound_tag? | type) == "array" then ((.inbound_tag | index($tag)) != null)
      elif (.inbound_tag? | type) == "string" then (.inbound_tag == $tag)
      else false end;
    def sheldon_connlimit_action:
      ((.action // "") == "connlimit") or
      ((.action // "") == "connection_limit") or
      ((if (.action? | type) == "object" then (.action.type // "") else "" end) == "connlimit") or
      ((if (.action? | type) == "object" then (.action.type // "") else "" end) == "connection_limit");
    .inbounds |= map(if .tag == $tag then del(.max_conn_client, .max_connections, .connection_limit, .connection_limit_count) else . end) |
    .route.rules = ((.route.rules // []) | map(select((sheldon_connlimit_action | not) or (inbound_matches($tag) | not))))
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  if [ "$conn_limit" != "0" ]; then
    if _connlimit_proto_enforceable "$proto"; then
      _warn "sing-box 配置不会写入未知连接数字段；TCP 连接数限制将通过 iptables connlimit 执行"
    else
      _warn "该协议主要使用 UDP；TCP connlimit 无法强制执行 UDP 连接数限制，仅保存和展示记录"
    fi
  fi
}

_remove_inbound_tag() {
  _jq
  local tag="$1" tmp="$CONFIG_FILE.tmp"
  jq --arg tag "$tag" '
    def inbound_matches($tag):
      if (.inbound? | type) == "array" then ((.inbound | index($tag)) != null)
      elif (.inbound? | type) == "string" then (.inbound == $tag)
      elif (.inbound_tag? | type) == "array" then ((.inbound_tag | index($tag)) != null)
      elif (.inbound_tag? | type) == "string" then (.inbound_tag == $tag)
      else false end;
    .inbounds |= map(select(.tag != $tag)) |
    .route.rules = ((.route.rules // []) | map(select(inbound_matches($tag) | not)))
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

_table_users() {
  _jq
  printf "${BLUE}------------------------------------------------------------------------------------------------------------------------------${NC}\n"
  printf "${GREEN}%-14s %-8s %-10s %-10s %-10s %-10s %-10s %-8s %-10s %-8s %-12s${NC}\n" "用户名" "状态" "上传流量" "下载流量" "补正流量" "已用总量" "限速" "连接数" "套餐" "重置日" "到期时间"
  printf "${BLUE}------------------------------------------------------------------------------------------------------------------------------${NC}\n"
  jq -r '.users[]? | (.upload_limit_mbps // 0) as $up | (.download_limit_mbps // 0) as $down | (.connection_limit_count // 0) as $conn | [.name,.status,((.upload/1048576)|tostring+" MB"),((.download/1048576)|tostring+" MB"),((.correct/1048576)|tostring+" MB"),(((.upload+.download+.correct)/1048576)|tostring+" MB"),(if $up == 0 and $down == 0 then "不限" else (($up|tostring)+"/"+($down|tostring)) end),(if $conn == 0 then "不限" else ($conn|tostring) end),.plan,.reset,.expire] | @tsv' "$USER_FILE" | \
  while IFS=$'\t' read -r a b c d e f g h i j k; do
    printf "%-14s %-8s %-10s %-10s %-10s %-10s %-10s %-8s %-10s %-8s %-12s\n" "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h" "$i" "$j" "$k"
  done
}

_add_user() {
  _init_dirs
  echo -e "${CYAN}支持协议: sheldon/sheldon-vless/vless-reality/sheldon-anytls/anytls-reality/vless/vmess/trojan/hysteria2/tuic/shadowsocks/anytls/socks${NC}"
  echo -e "${YELLOW}推荐: sheldon = VLESS + Reality + Vision + 公共站点伪装 + fp=chrome + NTP 校时${NC}"
  read -r -p "用户名: " name
  [ -n "$name" ] || { _err "用户名不能为空"; return; }
  proto="$(_protocol_menu_choice)" || return
  port="$(_read_listen_port "监听端口（留空随机）: ")" || return
  read -r -p "套餐 [不限]: " plan; plan="${plan:-不限}"
  read -r -p "重置日 [不重置]: " reset; reset="${reset:-不重置}"
  read -r -p "到期时间 [永久]: " expire; expire="${expire:-永久}"
  _read_speed_limits || return
  _read_conn_limit || return
  local uuid pass tag
  uuid="$(_generate_uuid)"; pass="$(_rand_pass)"; tag="user-$name"
  _add_inbound_json "$proto" "$tag" "$port" "$uuid" "$pass" "$LIMIT_UPLOAD_MBPS" "$LIMIT_DOWNLOAD_MBPS" || return
  case "$proto" in hysteria2|hy2) ;; *) _apply_user_speed_limit_config "$proto" "$tag" "$LIMIT_UPLOAD_MBPS" "$LIMIT_DOWNLOAD_MBPS" || return ;; esac
  _apply_user_conn_limit_config "$proto" "$tag" "$LIMIT_CONN_COUNT" || return
  _add_user_record "$name" "开启" "$plan" "$reset" "$expire" "$port" "$proto" "$uuid" "$pass" "$tag" "$LAST_REALITY_PUBLIC" "$LAST_REALITY_SHORT_ID" "$LAST_REALITY_SNI" "$LAST_REALITY_ALPN" "$LIMIT_UPLOAD_MBPS" "$LIMIT_DOWNLOAD_MBPS" "$LIMIT_CONN_COUNT"
  _open_firewall_port "$port" tcp
  case "$proto" in hysteria2|hy2|tuic) _open_firewall_port "$port" udp ;; esac
  if ! _check_config; then
    if [ "$LIMIT_UPLOAD_MBPS" != "0" ] || [ "$LIMIT_DOWNLOAD_MBPS" != "0" ]; then
      _warn "当前 sing-box 核心不接受该协议的 route limit 语法，已移除限速规则并保留用户为不限速"
      _apply_user_speed_limit_config "$proto" "$tag" 0 0 || true
      _set_user_limit_record "$name" 0 0 || true
      _check_config || { _err "配置检查失败，已写入但未重启，请手动修正"; return; }
    else
      _err "配置检查失败，已写入但未重启，请手动修正"; return
    fi
  fi
  _connlimit_apply || true
  _service restart >/dev/null 2>&1 || true
  _ok "用户已添加"
  echo "协议: $proto"
  echo "端口: $port"
  echo "UUID: $uuid"
  echo "密码: $pass"
}

_change_user_limit() {
  _init_dirs
  _table_users
  read -r -p "用户名: " name
  [ -n "$name" ] || return
  local row proto tag up down cfg_bak user_bak
  row=$(jq -c --arg name "$name" '.users[]? | select(.name==$name)' "$USER_FILE")
  [ -n "$row" ] || { _err "用户不存在"; return; }
  proto=$(echo "$row" | jq -r '.protocol')
  tag=$(echo "$row" | jq -r '.tag')
  _read_speed_limits || return
  up="$LIMIT_UPLOAD_MBPS"; down="$LIMIT_DOWNLOAD_MBPS"
  cfg_bak="$(mktemp /tmp/sing-box-config.XXXXXX)" || return
  user_bak="$(mktemp /tmp/sing-box-users.XXXXXX)" || { rm -f "$cfg_bak"; return; }
  cp "$CONFIG_FILE" "$cfg_bak"; cp "$USER_FILE" "$user_bak"
  _set_user_limit_record "$name" "$up" "$down" || { rm -f "$cfg_bak" "$user_bak"; return; }
  _apply_user_speed_limit_config "$proto" "$tag" "$up" "$down" || { cp "$cfg_bak" "$CONFIG_FILE"; cp "$user_bak" "$USER_FILE"; rm -f "$cfg_bak" "$user_bak"; return; }
  if _check_config; then
    _service restart >/dev/null 2>&1 || true
    rm -f "$cfg_bak" "$user_bak"
    _ok "已更新 $name 限速: $(_limit_display "$up" "$down")"
  else
    cp "$cfg_bak" "$CONFIG_FILE"; cp "$user_bak" "$USER_FILE"
    rm -f "$cfg_bak" "$user_bak"
    _err "配置检查失败，已回滚限速修改"
    return 1
  fi
}

_clear_user_limit() {
  _init_dirs
  _table_users
  read -r -p "用户名: " name
  [ -n "$name" ] || return
  local row proto tag cfg_bak user_bak
  row=$(jq -c --arg name "$name" '.users[]? | select(.name==$name)' "$USER_FILE")
  [ -n "$row" ] || { _err "用户不存在"; return; }
  proto=$(echo "$row" | jq -r '.protocol')
  tag=$(echo "$row" | jq -r '.tag')
  cfg_bak="$(mktemp /tmp/sing-box-config.XXXXXX)" || return
  user_bak="$(mktemp /tmp/sing-box-users.XXXXXX)" || { rm -f "$cfg_bak"; return; }
  cp "$CONFIG_FILE" "$cfg_bak"; cp "$USER_FILE" "$user_bak"
  _set_user_limit_record "$name" 0 0 || { rm -f "$cfg_bak" "$user_bak"; return; }
  _apply_user_speed_limit_config "$proto" "$tag" 0 0 || { cp "$cfg_bak" "$CONFIG_FILE"; cp "$user_bak" "$USER_FILE"; rm -f "$cfg_bak" "$user_bak"; return; }
  if _check_config; then
    _service restart >/dev/null 2>&1 || true
    rm -f "$cfg_bak" "$user_bak"
    _ok "已清除 $name 限速"
  else
    cp "$cfg_bak" "$CONFIG_FILE"; cp "$user_bak" "$USER_FILE"
    rm -f "$cfg_bak" "$user_bak"
    _err "配置检查失败，已回滚清除限速"
    return 1
  fi
}

_change_user_conn_limit() {
  _init_dirs
  _table_users
  read -r -p "用户名: " name
  [ -n "$name" ] || return
  local row proto tag conn cfg_bak user_bak
  row=$(jq -c --arg name "$name" '.users[]? | select(.name==$name)' "$USER_FILE")
  [ -n "$row" ] || { _err "用户不存在"; return; }
  proto=$(echo "$row" | jq -r '.protocol')
  tag=$(echo "$row" | jq -r '.tag')
  _read_conn_limit || return
  conn="$LIMIT_CONN_COUNT"
  cfg_bak="$(mktemp /tmp/sing-box-config.XXXXXX)" || return
  user_bak="$(mktemp /tmp/sing-box-users.XXXXXX)" || { rm -f "$cfg_bak"; return; }
  cp "$CONFIG_FILE" "$cfg_bak"; cp "$USER_FILE" "$user_bak"
  _set_user_conn_limit_record "$name" "$conn" || { rm -f "$cfg_bak" "$user_bak"; return; }
  _apply_user_conn_limit_config "$proto" "$tag" "$conn" || { cp "$cfg_bak" "$CONFIG_FILE"; cp "$user_bak" "$USER_FILE"; rm -f "$cfg_bak" "$user_bak"; return; }
  if _check_config; then
    _service restart >/dev/null 2>&1 || true
    rm -f "$cfg_bak" "$user_bak"
    _connlimit_apply || true
    _ok "已更新 $name 连接数限制: $(_conn_limit_display "$conn")"
  else
    cp "$cfg_bak" "$CONFIG_FILE"; cp "$user_bak" "$USER_FILE"
    rm -f "$cfg_bak" "$user_bak"
    _err "配置检查失败，已回滚连接数限制修改"
    return 1
  fi
}

_clear_user_conn_limit() {
  _init_dirs
  _table_users
  read -r -p "用户名: " name
  [ -n "$name" ] || return
  local row proto tag cfg_bak user_bak
  row=$(jq -c --arg name "$name" '.users[]? | select(.name==$name)' "$USER_FILE")
  [ -n "$row" ] || { _err "用户不存在"; return; }
  proto=$(echo "$row" | jq -r '.protocol')
  tag=$(echo "$row" | jq -r '.tag')
  cfg_bak="$(mktemp /tmp/sing-box-config.XXXXXX)" || return
  user_bak="$(mktemp /tmp/sing-box-users.XXXXXX)" || { rm -f "$cfg_bak"; return; }
  cp "$CONFIG_FILE" "$cfg_bak"; cp "$USER_FILE" "$user_bak"
  _set_user_conn_limit_record "$name" 0 || { rm -f "$cfg_bak" "$user_bak"; return; }
  _apply_user_conn_limit_config "$proto" "$tag" 0 || { cp "$cfg_bak" "$CONFIG_FILE"; cp "$user_bak" "$USER_FILE"; rm -f "$cfg_bak" "$user_bak"; return; }
  if _check_config; then
    _service restart >/dev/null 2>&1 || true
    rm -f "$cfg_bak" "$user_bak"
    _connlimit_apply || true
    _ok "已清除 $name 连接数限制"
  else
    cp "$cfg_bak" "$CONFIG_FILE"; cp "$user_bak" "$USER_FILE"
    rm -f "$cfg_bak" "$user_bak"
    _err "配置检查失败，已回滚清除连接数限制"
    return 1
  fi
}

_create_protocol_only() {
  _init_dirs
  echo -e "${CYAN}直接创建协议入站，不写入用户/套餐表。${NC}"
  echo -e "${YELLOW}推荐协议: sheldon；如需用户流量/套餐统计，请走 用户管理 -> 新增用户。${NC}"
  echo -e "${CYAN}支持协议: sheldon/sheldon-vless/vless-reality/sheldon-anytls/anytls-reality/vless/vmess/trojan/hysteria2/tuic/shadowsocks/anytls/socks${NC}"
  local name proto port uuid pass tag host
  read -r -p "协议备注 [sheldon]: " name; name="${name:-sheldon}"
  proto="$(_protocol_menu_choice)" || return
  port="$(_read_listen_port "监听端口（留空随机）: ")" || return
  uuid="$(_generate_uuid)"; pass="$(_rand_pass)"; tag="proto-${name}-${port}"
  tag=$(echo "$tag" | tr -cs 'A-Za-z0-9_.-' '-')
  _add_inbound_json "$proto" "$tag" "$port" "$uuid" "$pass" || return
  _open_firewall_port "$port" tcp
  case "$proto" in hysteria2|hy2|tuic) _open_firewall_port "$port" udp ;; esac
  _check_config || { _err "配置检查失败，已写入但未重启，请手动修正"; return; }
  _service restart >/dev/null 2>&1 || true
  host=$(_get_public_ip)
  _ok "协议入站已创建，不占用户表"
  echo "备注: $name"
  echo "协议: $proto"
  echo "端口: $port"
  echo "UUID: $uuid"
  echo "密码: $pass"
  echo "节点链接:"
  _build_share_link "$name" "$proto" "$host" "$port" "$uuid" "$pass" "$LAST_REALITY_PUBLIC" "$LAST_REALITY_SHORT_ID" "$LAST_REALITY_SNI" "$LAST_REALITY_ALPN"
}

_delete_user() {
  _table_users
  read -r -p "要删除的用户名: " name
  [ -n "$name" ] || return
  local tag
  tag=$(jq -r --arg name "$name" '.users[]? | select(.name==$name) | .tag' "$USER_FILE")
  [ -n "$tag" ] && [ "$tag" != "null" ] && _remove_inbound_tag "$tag"
  _del_user_record "$name"
  _connlimit_apply || true
  _check_config && _service restart >/dev/null 2>&1 || true
  _ok "已删除 $name"
}

_build_share_link() {
  local name="$1" proto="$2" host="$3" port="$4" uuid="$5" pass="$6" pbk="${7:-}" sid="${8:-}" sni="${9:-www.microsoft.com}" alpn="${10:-h2,http/1.1}"
  case "$proto" in
    vless) echo "vless://${uuid}@${host}:${port}?type=tcp&security=none#${name}" ;;
    vless-reality|reality|sheldon|sheldon-reality|sheldon-vless) echo "vless://${uuid}@${host}:${port}?type=tcp&security=reality&sni=${sni}&pbk=${pbk}&sid=${sid}&fp=chrome&alpn=${alpn}&flow=xtls-rprx-vision#${name}" ;;
    vmess) echo "vmess://$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none","host":"","path":"","tls":""}' "$name" "$host" "$port" "$uuid" | base64 -w0)" ;;
    trojan) echo "trojan://${pass}@${host}:${port}#${name}" ;;
    hysteria2|hy2) echo "hy2://${pass}@${host}:${port}?insecure=1#${name}" ;;
    tuic) echo "tuic://${uuid}:${pass}@${host}:${port}?congestion_control=bbr&udp_relay_mode=native#${name}" ;;
    shadowsocks|ss) echo "ss://$(printf '2022-blake3-aes-128-gcm:%s' "$pass" | base64 -w0)@${host}:${port}#${name}" ;;
    anytls) echo "anytls://${pass}@${host}:${port}?insecure=1#${name}" ;;
    anytls-reality|any-reality|sheldon-anytls) echo "anytls://${pass}@${host}:${port}?security=reality&sni=${sni}&pbk=${pbk}&sid=${sid}&fp=chrome&alpn=${alpn}#${name}" ;;
    socks) echo "socks5://user:${pass}@${host}:${port}#${name}" ;;
  esac
}

_export_user() {
  _jq
  read -r -p "用户名: " name
  local row proto port uuid pass host pbk sid sni alpn
  row=$(jq -c --arg name "$name" '.users[]? | select(.name==$name)' "$USER_FILE")
  [ -n "$row" ] || { _err "用户不存在"; return; }
  proto=$(echo "$row" | jq -r .protocol); port=$(echo "$row" | jq -r .port); uuid=$(echo "$row" | jq -r .uuid); pass=$(echo "$row" | jq -r .password)
  pbk=$(echo "$row" | jq -r '.reality_public_key // ""'); sid=$(echo "$row" | jq -r '.reality_short_id // ""'); sni=$(echo "$row" | jq -r '.reality_server_name // "www.microsoft.com"'); alpn=$(echo "$row" | jq -r '.reality_alpn // "h2,http/1.1"')
  host=$(_get_public_ip)
  _build_share_link "$name" "$proto" "$host" "$port" "$uuid" "$pass" "$pbk" "$sid" "$sni" "$alpn"
}


_optimize_config_light() {
  _jq
  _init_dirs
  local tmp="$CONFIG_FILE.tmp"
  jq '
    .log = ((.log // {}) + {disabled:false, level:"error", timestamp:false}) |
    .experimental.cache_file.enabled = false |
    .ntp = ((.ntp // {}) + {enabled:true, server:"time.apple.com", server_port:123, interval:"30m", detour:"direct"}) |
    .route.auto_detect_interface = false |
    .route.find_process = false |
    .route.default_domain_resolver = (.route.default_domain_resolver // ((.dns.servers[0].tag // "cf"))) |
    if (.dns.servers? | type) == "array" then
      .dns.servers |= map(if (.address? and (.type? | not)) then .type="udp" | .server=.address | del(.address) else . end)
    else . end |
    .route.default_domain_resolver = (.route.default_domain_resolver // ((.dns.servers[0].tag // "cf"))) |
    if (.dns.rules? | type) == "array" then
      .dns.rules |= map(del(.outbound, .domain_resolver))
    else . end
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  _ok "已应用轻量配置: log=error、关闭 cache、关闭接口/进程自动探测"
}

_optimize_system() {
  _optimize_config_light >/dev/null 2>&1 || true
  cat >/etc/sysctl.d/99-sing-box-sheldon.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.ip_local_port_range=1024 65535
EOF
  sysctl --system >/dev/null 2>&1 || true
  mkdir -p /etc/systemd/system/sing-box.service.d
  if _has systemctl; then
    cat >/etc/systemd/system/sing-box.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
OOMScoreAdjust=-300
MemoryAccounting=true
CPUAccounting=true
TasksMax=256
EOF
    systemctl daemon-reload
  fi
  _ok "已应用 BBR/内核/服务优化"
}

_update_script_self() {
  _need_root
  _ensure_core_deps || { _err "依赖安装失败"; return 1; }
  local current target tmp bak
  current="$(_realpath_self)"
  case "$current" in
    /usr/local/bin/sing-box-sheldon|/usr/local/bin/sp) target="$SCRIPT_PATH" ;;
    *) target="$current" ;;
  esac
  [ -n "$target" ] || target="$SCRIPT_PATH"
  tmp="$(mktemp /tmp/sing-box-sheldon.XXXXXX)" || return 1
  _ok "正在下载最新脚本..."
  if _fetch "$SCRIPT_UPDATE_URL" "$tmp"; then
    bash -n "$tmp" || { rm -f "$tmp"; _err "下载的新脚本语法检查失败，已取消更新"; return 1; }
    mkdir -p "$(dirname "$target")"
    [ -s "$target" ] && { bak="${target}.bak.$(date +%Y%m%d%H%M%S)"; cp -f "$target" "$bak" 2>/dev/null || true; }
    install -m 755 "$tmp" "$target"
    rm -f "$tmp"
    ln -sf "$target" "$SCRIPT_PATH" 2>/dev/null || true
    ln -sf "$SCRIPT_PATH" "$SP_PATH" 2>/dev/null || true
    _ok "脚本已更新: $target"
    [ -n "${bak:-}" ] && echo "备份: $bak"
    echo "重新输入 sp 可进入新版菜单"
  else
    rm -f "$tmp"
    _err "下载最新脚本失败"
    return 1
  fi
}

_install_update() {
  _need_root
  _ensure_core_deps || { _err "依赖安装失败"; return; }
  _sync_latest_version
  _download_singbox || { _err "下载失败"; return; }
  _install_service
  _migrate_config_latest >/dev/null 2>&1 || true
  _repair_missing_tls_certs >/dev/null 2>&1 || true
  _optimize_system
  _check_config && _service restart >/dev/null 2>&1 || true
  _ok "安装/更新完成"
}

_logs() {
  if _has journalctl; then journalctl -u sing-box -n 80 --no-pager; else tail -n 80 /var/log/sing-box.log /var/log/sing-box.err 2>/dev/null; fi
}



_argo_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7*) echo arm ;;
    *) echo amd64 ;;
  esac
}

_install_cloudflared() {
  _need_root
  _ensure_core_deps >/dev/null 2>&1 || true
  local force="${1:-}" arch url tmp oldv newv
  if [ -x "$ARGO_BIN" ] && [ "$force" != "force" ]; then
    _ok "cloudflared 已安装: $($ARGO_BIN --version 2>/dev/null | head -1)"
    echo "如需强制更新，可在 Argo 菜单选择安装/更新，或执行: sing-box-sheldon argo-update"
    return 0
  fi
  arch="$(_argo_arch)"
  tmp="/tmp/cloudflared-${arch}.$$"
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  oldv="$($ARGO_BIN --version 2>/dev/null | head -1 || true)"
  _warn "正在下载 cloudflared 最新版: $arch"
  _fetch "$url" "$tmp" || { _err "cloudflared 下载失败"; rm -f "$tmp"; return 1; }
  install -m 755 "$tmp" "$ARGO_BIN" 2>/dev/null || { cp "$tmp" "$ARGO_BIN" && chmod +x "$ARGO_BIN"; }
  rm -f "$tmp"
  newv="$($ARGO_BIN --version 2>/dev/null | head -1 || true)"
  [ -n "$oldv" ] && echo "旧版本: $oldv"
  _ok "cloudflared 安装/更新完成: ${newv:-unknown}"
}

_argo_pick_local_url() {
  local port
  if [ -s "$USER_FILE" ] && _has jq; then
    port=$(jq -r '.users[]? | select(.status=="开启") | .port' "$USER_FILE" 2>/dev/null | head -1)
  fi
  if [ -n "$port" ] && [ "$port" != "null" ]; then echo "http://127.0.0.1:${port}"; else echo "http://127.0.0.1:8080"; fi
}

_argo_validate_url() {
  local url="$1"
  case "$url" in
    http://127.0.0.1:*|http://localhost:*|http://[::1]:*) return 0 ;;
    https://127.0.0.1:*|https://localhost:*|https://[::1]:*) return 0 ;;
    *)
      _err "为避免误把内网/公网服务暴露出去，Argo 本地地址只允许 127.0.0.1 / localhost。"
      echo "示例: http://127.0.0.1:8080"
      return 1
      ;;
  esac
}

_argo_service_install_quick() {
  local url="$1"
  mkdir -p "$ARGO_DIR"
  cat >"$ARGO_CONFIG" <<EOF
# sing-box Sheldon Argo quick tunnel
# 仅监听本机 127.0.0.1，不额外暴露公网端口
url: ${url}
no-autoupdate: true
edge-ip-version: auto
protocol: quic
loglevel: warn
retries: 5
EOF
  if _has systemctl; then
    cat >"/etc/systemd/system/${ARGO_SERVICE}.service" <<EOF
[Unit]
Description=Cloudflare Tunnel for sing-box Sheldon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ARGO_BIN} tunnel --config ${ARGO_CONFIG}
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
MemoryAccounting=true
MemoryMax=96M
CPUAccounting=true
CPUQuota=60%

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$ARGO_SERVICE" >/dev/null 2>&1 || true
  else
    nohup "$ARGO_BIN" tunnel --config "$ARGO_CONFIG" >"$ARGO_DIR/quick.log" 2>&1 &
    echo $! >"$ARGO_DIR/quick.pid"
  fi
}

_argo_start_quick() {
  _need_root
  _install_cloudflared || return 1
  local url log public
  read -r -p "本地服务地址 [自动选择第一个用户端口]: " url
  url="${url:-$(_argo_pick_local_url)}"
  _argo_validate_url "$url" || return 1
  mkdir -p "$ARGO_DIR"
  _argo_service_install_quick "$url"
  sleep 4
  log="$ARGO_DIR/quick.log"
  if _has journalctl && _has systemctl; then
    journalctl -u "$ARGO_SERVICE" -n 80 --no-pager > "$log" 2>/dev/null || true
  fi
  public=$(grep -Eo 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$log" 2>/dev/null | tail -1 || true)
  [ -n "$public" ] && echo "quick_url=$public" > "$ARGO_INFO"
  _ok "Argo Quick Tunnel 已启动"
  echo "本地地址: $url"
  [ -n "$public" ] && echo "临时隧道: $public" || echo "临时域名生成中，可稍后在日志查看。"
  _warn "Quick Tunnel 是临时域名，重启可能变化；长期稳定请用 Cloudflare Named Tunnel Token。"
}

_argo_token_service() {
  local token="$1"
  mkdir -p "$ARGO_DIR"
  chmod 700 "$ARGO_DIR" 2>/dev/null || true
  printf '%s\n' "$token" > "$ARGO_DIR/token"
  chmod 600 "$ARGO_DIR/token" 2>/dev/null || true
  if _has systemctl; then
    cat >"/etc/systemd/system/${ARGO_SERVICE}.service" <<EOF
[Unit]
Description=Cloudflare Named Tunnel for sing-box Sheldon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ARGO_DIR}/token
ExecStart=${ARGO_BIN} tunnel --no-autoupdate run --token \${TUNNEL_TOKEN}
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
MemoryAccounting=true
MemoryMax=96M
CPUAccounting=true
CPUQuota=60%

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$ARGO_SERVICE" >/dev/null 2>&1 || true
  else
    nohup env "$(cat "$ARGO_DIR/token")" "$ARGO_BIN" tunnel --no-autoupdate run --token "${token#TUNNEL_TOKEN=}" >"$ARGO_DIR/named.log" 2>&1 &
    echo $! >"$ARGO_DIR/named.pid"
  fi
}

_argo_start_token() {
  _need_root
  _install_cloudflared || return 1
  local token
  echo "粘贴 Cloudflare Tunnel Token。脚本只保存到本机 $ARGO_DIR/token，不会输出。"
  read -r -s -p "Tunnel Token: " token; echo
  [ -n "$token" ] || { _err "Token 不能为空"; return 1; }
  case "$token" in TUNNEL_TOKEN=*) ;; *) token="TUNNEL_TOKEN=$token" ;; esac
  _argo_token_service "$token"
  _ok "Named Tunnel 已启动"
  _warn "如需域名伪装，请在 Cloudflare Zero Trust 里把 Public Hostname 指向本机服务端口。"
}

_argo_status() {
  if _has systemctl; then systemctl status "$ARGO_SERVICE" --no-pager || true; fi
  [ -f "$ARGO_INFO" ] && cat "$ARGO_INFO"
  [ -f "$ARGO_DIR/quick.log" ] && tail -n 30 "$ARGO_DIR/quick.log"
  [ -f "$ARGO_DIR/named.log" ] && tail -n 30 "$ARGO_DIR/named.log"
}

_argo_stop() {
  _need_root
  if _has systemctl; then systemctl disable --now "$ARGO_SERVICE" >/dev/null 2>&1 || true; rm -f "/etc/systemd/system/${ARGO_SERVICE}.service"; systemctl daemon-reload || true; fi
  [ -f "$ARGO_DIR/quick.pid" ] && kill "$(cat "$ARGO_DIR/quick.pid")" >/dev/null 2>&1 || true
  [ -f "$ARGO_DIR/named.pid" ] && kill "$(cat "$ARGO_DIR/named.pid")" >/dev/null 2>&1 || true
  rm -f "$ARGO_DIR/quick.pid" "$ARGO_DIR/named.pid"
  _ok "Argo 隧道已停止"
}

_argo_menu() {
  while true; do
    clear
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "${BOLD}${WHITE}                    Argo 隧道管理${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "${GREEN}用途: 使用 Cloudflare Tunnel 隐藏源站 IP，提高安全伪装。${NC}"
    echo -e "${YELLOW}建议: 长期稳定用 Named Tunnel；临时测试用 Quick Tunnel。${NC}"
    echo
    echo -e "    ${BLUE}1.${NC} ${GREEN}安装/更新 cloudflared 最新版${NC}"
    echo -e "    ${BLUE}2.${NC} ${GREEN}启动临时 Argo Quick Tunnel${NC}"
    echo -e "    ${BLUE}3.${NC} ${GREEN}启动 Named Tunnel Token${NC}"
    echo -e "    ${BLUE}4.${NC} ${GREEN}查看 Argo 状态/日志${NC}"
    echo -e "    ${BLUE}5.${NC} ${GREEN}停止 Argo 隧道${NC}"
    echo -e "    ${BLUE}6.${NC} ${GREEN}安全伪装说明${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}返回主菜单${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    read -r -p "请选择操作: " c
    case "$c" in
      1) _install_cloudflared force; _pause ;;
      2) _argo_start_quick; _pause ;;
      3) _argo_start_token; _pause ;;
      4) _argo_status; _pause ;;
      5) _argo_stop; _pause ;;
      6)
        echo "Argo/Cloudflare Tunnel 安全伪装："
        echo "- 入口走 Cloudflare 边缘网络，源站 IP 不直接暴露。"
        echo "- 本地服务建议只监听 127.0.0.1 或防火墙限制来源。"
        echo "- Named Tunnel 可绑定自己的域名并启用 Cloudflare TLS/WAF/Access。"
        echo "- Quick Tunnel 适合测试，域名临时，不建议长期使用。"
        echo "- Argo 只是隧道层；协议层仍推荐 sheldon / sheldon-vless。"
        _pause ;;
      0) break ;;
    esac
  done
}

_user_menu() {
  while true; do
    clear
    echo -e "${BLUE}-----------------------------------------------------------------------------------------------${NC}"
    echo -e "${BOLD}${WHITE}                                      用户管理${NC}"
    _table_users
    echo -e "${BLUE}-----------------------------------------------------------------------------------------------${NC}"
    echo -e "    ${BLUE}1.${NC} ${GREEN}新增用户${NC}"
    echo -e "    ${BLUE}2.${NC} ${GREEN}导出节点配置${NC}"
    echo -e "    ${BLUE}3.${NC} ${GREEN}删除用户${NC}"
    echo -e "    ${BLUE}4.${NC} ${GREEN}修改用户限速${NC}"
    echo -e "    ${BLUE}5.${NC} ${GREEN}清除用户限速${NC}"
    echo -e "    ${BLUE}6.${NC} ${GREEN}修改用户连接数限制${NC}"
    echo -e "    ${BLUE}7.${NC} ${GREEN}清除用户连接数限制${NC}"
    echo -e "    ${BLUE}8.${NC} ${GREEN}连接数限制防火墙规则${NC}"
    echo -e "    ${BLUE}9.${NC} ${GREEN}重启 sing-box${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}返回主菜单${NC}"
    echo
    read -r -p "请选择操作: " c
    case "$c" in
      1) _add_user; _pause ;;
      2) _export_user; _pause ;;
      3) _delete_user; _pause ;;
      4) _change_user_limit; _pause ;;
      5) _clear_user_limit; _pause ;;
      6) _change_user_conn_limit; _pause ;;
      7) _clear_user_conn_limit; _pause ;;
      8) _connlimit_menu ;;
      9) _service restart; _pause ;;
      0) break ;;
    esac
  done
}

_proto_support_text() {
  echo -e "${CYAN}当前脚本支持 sing-box v${SINGBOX_VERSION} 常用新协议:${NC}"
  echo "- Sheldon 协议：脚本自创安全预设，实际为 VLESS + Reality + Vision + 公共站点伪装 + fp=chrome + NTP"
  echo "- Sheldon AnyTLS：高级选项，AnyTLS + Reality；客户端支持不全时不要优先用"
  echo "- AnyTLS Reality / VLESS Reality"
  echo "- VLESS / VMess / Trojan"
  echo "- Hysteria2 / TUIC v5"
  echo "- Shadowsocks 2022-blake3-aes-128-gcm"
  echo "- AnyTLS / SOCKS5 入站"
  echo
  echo "推荐优先级: sheldon > sheldon-vless > vless-reality > sheldon-anytls/anytls-reality。"
  echo "默认安全策略: Reality 公共站点握手伪装、fp=chrome、ALPN=h2/http1.1、NTP 自动校时、log=error、关闭 cache_file。"
  echo "说明: Sheldon 是 sing-box Sheldon 的高安全配置预设，不魔改 sing-box 核心，客户端兼容性更好。"
  echo "新增: 可直接创建协议入站，不需要添加用户；但不进入用户/套餐/流量表。
兼容性修复: sheldon 默认改为 VLESS Reality Vision，AnyTLS Reality 保留为 sheldon-anytls 高级选项。"
}

_proto_menu() {
  while true; do
    clear
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "${BOLD}${WHITE}                    协议管理${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "    ${BLUE}1.${NC} ${GREEN}查看支持协议/防封说明${NC}"
    echo -e "    ${BLUE}2.${NC} ${GREEN}直接创建新协议入站${NC}"
    echo -e "    ${BLUE}3.${NC} ${GREEN}检查 sing-box 配置${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}返回主菜单${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    read -r -p "请选择操作: " c
    case "$c" in
      1) _proto_support_text; _pause ;;
      2) _create_protocol_only; _pause ;;
      3) _check_config; _pause ;;
      0) break ;;
    esac
  done
}


_command_menu() {
  while true; do
    clear
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "${BOLD}${WHITE}                    命令菜单${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "${GREEN}这里支持数字选择；已去掉和主菜单重复的中转/端口转发入口。${NC}"
    echo
    echo -e "    ${BLUE}1.${NC} ${GREEN}安装/更新 sing-box${NC}"
    echo -e "    ${BLUE}2.${NC} ${GREEN}自检服务器是否可用${NC}"
    echo -e "    ${BLUE}3.${NC} ${GREEN}应用省内存轻量配置${NC}"
    echo -e "    ${BLUE}4.${NC} ${GREEN}应用系统性能优化${NC}"
    echo -e "    ${BLUE}5.${NC} ${GREEN}检查 sing-box 配置${NC}"
    echo -e "    ${BLUE}6.${NC} ${GREEN}查看日志${NC}"
    echo -e "    ${BLUE}7.${NC} ${GREEN}重启 sing-box${NC}"
    echo -e "    ${BLUE}8.${NC} ${GREEN}查看服务状态${NC}"
    echo -e "    ${BLUE}9.${NC} ${GREEN}快捷命令说明${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}返回主菜单${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    read -r -p "请选择操作: " c
    case "$c" in
      1) _install_update; _pause ;;
      2) _self_check; _pause ;;
      3) _optimize_config_light; _pause ;;
      4) _optimize_system; _pause ;;
      5) _check_config; _pause ;;
      6) _logs; _pause ;;
      7) _service restart; _pause ;;
      8) _service status; _pause ;;
      9)
        echo
        echo "sp                                  打开主菜单"
        echo "sing-box-sheldon script-update      更新 Sheldon 脚本"
        echo "sing-box-sheldon install            安装/更新 sing-box"
        echo "sing-box-sheldon doctor             自检服务器是否可用"
        echo "sing-box-sheldon lowmem             应用省内存轻量配置"
        echo "sing-box-sheldon optimize           应用系统性能优化"
        echo "sing-box-sheldon check              检查 sing-box 配置"
        echo "sing-box-sheldon logs               查看日志"
        echo "sing-box-sheldon restart            重启 sing-box"
        echo "sing-box-sheldon status             查看服务状态"
        echo "sing-box-sheldon argo               Argo 隧道管理"
        echo "sing-box-sheldon argo-status        查看 Argo 状态"
        echo "sing-box-sheldon limit-user         修改用户限速"
        echo "sing-box-sheldon clear-user-limit   清除用户限速"
        echo "sing-box-sheldon limit-user-conn    修改用户连接数限制"
        echo "sing-box-sheldon clear-user-conn-limit 清除用户连接数限制"
        echo "sing-box-sheldon connlimit-apply    应用连接数限制防火墙规则"
        echo "sing-box-sheldon connlimit-list     查看连接数限制防火墙规则"
        _pause
        ;;
      0) break ;;
    esac
  done
}

_main_menu() {
  _init_dirs
  while true; do
    clear
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "${BOLD}${WHITE}        [sing-box Sheldon 管理系统 V${SCRIPT_VERSION}]${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e " sing-box : ${GREEN}$(_status_text)${NC}   版本 ${CYAN}$(_core_version || echo 未安装)${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    _check_script_update_hint
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    echo -e "    ${BLUE}1.${NC} ${GREEN}安装/更新 sing-box 最新稳定版${NC}"
    echo -e "    ${BLUE}2.${NC} ${GREEN}系统工具${NC}"
    echo -e "    ${BLUE}3.${NC} ${GREEN}协议管理/支持说明${NC}"
    echo -e "    ${BLUE}4.${NC} ${GREEN}中转管理${NC}"
    echo -e "    ${BLUE}5.${NC} ${GREEN}WARP 分流${NC}"
    echo -e "    ${BLUE}6.${NC} ${GREEN}用户管理${NC}"
    echo -e "    ${BLUE}7.${NC} ${GREEN}端口转发管理${NC}"
    echo -e "    ${BLUE}8.${NC} ${GREEN}Argo 隧道管理${NC}"
    echo -e "    ${BLUE}9.${NC} ${GREEN}命令菜单${NC}"
    echo -e "    ${BLUE}10.${NC} ${GREEN}更新脚本${NC}"
    echo -e "    ${BLUE}11.${NC} ${GREEN}卸载 sing-box${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}退出系统${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    read -r -p "请选择操作指令: " choice
    case "$choice" in
      1) _install_update; _pause ;;
      2) _system_tools_menu ;;
      3) _proto_menu ;;
      4) _relay_menu; _pause ;;
      5) _warp_menu; _pause ;;
      6) _user_menu ;;
      7) _port_forward_menu ;;
      8) _argo_menu ;;
      9) _command_menu ;;
      10) _update_script_self; _pause ;;
      11) _uninstall_all; _pause ;;
      0) exit 0 ;;
    esac
  done
}

_cli() {
  case "${1:-}" in
    script-update|self-update|update-script) _update_script_self ;;
    install|update) _install_update ;;
    latest) _sync_latest_version; echo "$SINGBOX_VERSION" ;;
    optimize) _optimize_system ;;
    light|lowmem) _optimize_config_light ;;
    deps|repair) _ensure_core_deps ;;
    relay) _relay_menu ;;
    port-forward|forward|pf) _port_forward_menu ;;
    port-forward-apply) _port_forward_apply ;;
    connlimit|conn-limit|connlimit-menu) _connlimit_menu ;;
    connlimit-apply|conn-limit-apply) _connlimit_apply ;;
    connlimit-list|conn-limit-list) _connlimit_list ;;
    connlimit-clear|conn-limit-clear) _connlimit_clear_rules ;;
    connlimit-persist|conn-limit-persist) _connlimit_persist ;;
    warp) _warp_menu ;;
    proto|protocol) _proto_menu ;;
    create-protocol|add-protocol) _create_protocol_only ;;
    argo|tunnel|cloudflared) _argo_menu ;;
    argo-update) _install_cloudflared force ;;
    argo-start) _argo_start_quick ;;
    argo-token) _argo_start_token ;;
    argo-status) _argo_status ;;
    argo-stop) _argo_stop ;;
    uninstall) _uninstall_all ;;
    restart) _service restart ;;
    start) _service start ;;
    stop) _service stop ;;
    status) _service status ;;
    check) _check_config ;;
    self-check|doctor|test) _self_check ;;
    logs) _logs ;;
    menu|sp) _main_menu ;;
    cmd|commands|help|-h|--help) _command_menu ;;
    add-user) shift; _add_user ;;
    export-user) shift; _export_user ;;
    limit-user|user-limit) shift; _change_user_limit ;;
    clear-user-limit|clear-limit) shift; _clear_user_limit ;;
    limit-user-conn|user-conn-limit|conn-limit-user) shift; _change_user_conn_limit ;;
    clear-user-conn-limit|clear-conn-limit) shift; _clear_user_conn_limit ;;
    *) _main_menu ;;
  esac
}

_need_root
_cli "$@"
