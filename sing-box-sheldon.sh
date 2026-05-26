#!/usr/bin/env bash
# Sing-box Sheldon 管理系统
# 轻量、省内存、最新 sing-box 协议管理脚本
# Version: 1.4.0

set -o pipefail

SCRIPT_VERSION="1.4.0"
SINGBOX_VERSION="1.13.12"
SINGBOX_DIR="/usr/local/etc/sing-box"
CONFIG_FILE="$SINGBOX_DIR/config.json"
USER_FILE="$SINGBOX_DIR/users.json"
SERVICE_NAME="sing-box"
BIN_PATH="/usr/local/bin/sing-box"
SCRIPT_PATH="/usr/local/bin/sing-box-sheldon"
SP_PATH="/usr/local/bin/sp"
PF_FILE="$SINGBOX_DIR/port_forward.rules"

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

_generate_uuid() {
  if _has sing-box; then sing-box generate uuid 2>/dev/null && return; fi
  _rand_uuid
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
    echo -e "    ${RED}0.${NC} ${GREEN}返回主菜单${NC}"
    read -r -p "请选择操作: " c
    case "$c" in
      1) _ensure_core_deps; _pause ;;
      2) _optimize_system; _pause ;;
      3) (_has ss && ss -tulnp) || (_has netstat && netstat -tulnp) || echo "缺少 ss/netstat"; _pause ;;
      4) uname -a; echo; free -h 2>/dev/null || true; df -h 2>/dev/null || true; _pause ;;
      5) _generate_uuid; _pause ;;
      6) _generate_reality_keypair; _pause ;;
      0) break ;;
    esac
  done
}


_port_forward_apply() {
  _need_root
  mkdir -p "$SINGBOX_DIR"
  [ -f "$PF_FILE" ] || touch "$PF_FILE"
  _ensure_cmd iptables iptables iptables-nft || { _err "缺少 iptables"; return 1; }
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
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
  "log": {"level": "warn", "timestamp": false},
  "dns": {
    "servers": [
      {"tag": "cf", "address": "1.1.1.1"},
      {"tag": "local", "address": "223.5.5.5"}
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "auto_detect_interface": true,
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
MemoryMax=256M
CPUQuota=90%
# 省内存/安全加固
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

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

_add_user_record() {
  _jq
  local name="$1" status="$2" plan="$3" reset="$4" expire="$5" port="$6" proto="$7" uuid="$8" pass="$9" tag="${10}"
  local tmp="$USER_FILE.tmp"
  jq --arg name "$name" --arg status "$status" --arg plan "$plan" --arg reset "$reset" --arg expire "$expire" --arg port "$port" --arg proto "$proto" --arg uuid "$uuid" --arg pass "$pass" --arg tag "$tag" \
    '.users += [{name:$name,status:$status,upload:0,download:0,correct:0,plan:$plan,reset:$reset,expire:$expire,port:($port|tonumber),protocol:$proto,uuid:$uuid,password:$pass,tag:$tag,created:now|todate}]' \
    "$USER_FILE" > "$tmp" && mv "$tmp" "$USER_FILE"
}

_del_user_record() {
  _jq
  local name="$1" tmp="$USER_FILE.tmp"
  jq --arg name "$name" '.users |= map(select(.name != $name))' "$USER_FILE" > "$tmp" && mv "$tmp" "$USER_FILE"
}

_add_inbound_json() {
  _jq
  local proto="$1" tag="$2" port="$3" uuid="$4" pass="$5" tmp="$CONFIG_FILE.tmp" inbound
  case "$proto" in
    vless)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:false}}') ;;
    vmess)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" '{type:"vmess",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid}],transport:{type:"tcp"}}') ;;
    trojan)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" '{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pass}]}' ) ;;
    hysteria2|hy2)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" '{type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pass}],up_mbps:100,down_mbps:500}' ) ;;
    tuic)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg pass "$pass" '{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$pass}],congestion_control:"bbr"}' ) ;;
    shadowsocks|ss)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:"2022-blake3-aes-128-gcm",password:$pass}' ) ;;
    anytls)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" '{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pass}]}' ) ;;
    socks)
      inbound=$(jq -nc --arg tag "$tag" --argjson port "$port" --arg pass "$pass" '{type:"socks",tag:$tag,listen:"::",listen_port:$port,users:[{username:"user",password:$pass}]}' ) ;;
    *) _err "不支持协议: $proto"; return 1 ;;
  esac
  jq --argjson in "$inbound" '.inbounds += [$in]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

_remove_inbound_tag() {
  _jq
  local tag="$1" tmp="$CONFIG_FILE.tmp"
  jq --arg tag "$tag" '.inbounds |= map(select(.tag != $tag)) | .route.rules |= map(select((.inbound // "") != $tag and ((.inbound_tag // []) | index($tag) | not)))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

_table_users() {
  _jq
  printf "${BLUE}-----------------------------------------------------------------------------------------------${NC}\n"
  printf "${GREEN}%-14s %-8s %-10s %-10s %-10s %-10s %-10s %-8s %-12s${NC}\n" "用户名" "状态" "上传流量" "下载流量" "补正流量" "已用总量" "套餐" "重置日" "到期时间"
  printf "${BLUE}-----------------------------------------------------------------------------------------------${NC}\n"
  jq -r '.users[]? | [.name,.status,((.upload/1048576)|tostring+" MB"),((.download/1048576)|tostring+" MB"),((.correct/1048576)|tostring+" MB"),(((.upload+.download+.correct)/1048576)|tostring+" MB"),.plan,.reset,.expire] | @tsv' "$USER_FILE" | \
  while IFS=$'\t' read -r a b c d e f g h i; do
    printf "%-14s %-8s %-10s %-10s %-10s %-10s %-10s %-8s %-12s\n" "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h" "$i"
  done
}

_add_user() {
  echo -e "${CYAN}支持协议: vless/vmess/trojan/hysteria2/tuic/shadowsocks/anytls/socks${NC}"
  read -r -p "用户名: " name
  [ -n "$name" ] || { _err "用户名不能为空"; return; }
  read -r -p "协议 [vless]: " proto; proto="${proto:-vless}"
  read -r -p "监听端口: " port
  [[ "$port" =~ ^[0-9]+$ ]] || { _err "端口错误"; return; }
  if _has ss && ss -lntup 2>/dev/null | grep -q ":$port "; then _err "端口已占用"; return; fi
  read -r -p "套餐 [不限]: " plan; plan="${plan:-不限}"
  read -r -p "重置日 [不重置]: " reset; reset="${reset:-不重置}"
  read -r -p "到期时间 [永久]: " expire; expire="${expire:-永久}"
  local uuid pass tag
  uuid="$(_generate_uuid)"; pass="$(_rand_pass)"; tag="user-$name"
  _add_inbound_json "$proto" "$tag" "$port" "$uuid" "$pass" || return
  _add_user_record "$name" "开启" "$plan" "$reset" "$expire" "$port" "$proto" "$uuid" "$pass" "$tag"
  _open_firewall_port "$port" tcp
  case "$proto" in hysteria2|hy2|tuic) _open_firewall_port "$port" udp ;; esac
  _check_config || { _err "配置检查失败，已写入但未重启，请手动修正"; return; }
  _service restart >/dev/null 2>&1 || true
  _ok "用户已添加"
  echo "协议: $proto"
  echo "端口: $port"
  echo "UUID: $uuid"
  echo "密码: $pass"
}

_delete_user() {
  _table_users
  read -r -p "要删除的用户名: " name
  [ -n "$name" ] || return
  local tag
  tag=$(jq -r --arg name "$name" '.users[]? | select(.name==$name) | .tag' "$USER_FILE")
  [ -n "$tag" ] && [ "$tag" != "null" ] && _remove_inbound_tag "$tag"
  _del_user_record "$name"
  _check_config && _service restart >/dev/null 2>&1 || true
  _ok "已删除 $name"
}

_export_user() {
  _jq
  read -r -p "用户名: " name
  local row proto port uuid pass host
  row=$(jq -c --arg name "$name" '.users[]? | select(.name==$name)' "$USER_FILE")
  [ -n "$row" ] || { _err "用户不存在"; return; }
  proto=$(echo "$row" | jq -r .protocol); port=$(echo "$row" | jq -r .port); uuid=$(echo "$row" | jq -r .uuid); pass=$(echo "$row" | jq -r .password)
  host=$(curl -4 -s --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')
  case "$proto" in
    vless) echo "vless://${uuid}@${host}:${port}?type=tcp&security=none#${name}" ;;
    vmess) echo "vmess://$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none","host":"","path":"","tls":""}' "$name" "$host" "$port" "$uuid" | base64 -w0)" ;;
    trojan) echo "trojan://${pass}@${host}:${port}#${name}" ;;
    hysteria2|hy2) echo "hy2://${pass}@${host}:${port}?insecure=1#${name}" ;;
    tuic) echo "tuic://${uuid}:${pass}@${host}:${port}?congestion_control=bbr&udp_relay_mode=native#${name}" ;;
    shadowsocks|ss) echo "ss://$(printf '2022-blake3-aes-128-gcm:%s' "$pass" | base64 -w0)@${host}:${port}#${name}" ;;
    anytls) echo "anytls://${pass}@${host}:${port}?insecure=1#${name}" ;;
    socks) echo "socks5://user:${pass}@${host}:${port}#${name}" ;;
  esac
}

_optimize_system() {
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
net.ipv4.ip_local_port_range=1024 65535
EOF
  sysctl --system >/dev/null 2>&1 || true
  mkdir -p /etc/systemd/system/sing-box.service.d
  if _has systemctl; then
    cat >/etc/systemd/system/sing-box.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
OOMScoreAdjust=-500
MemoryAccounting=true
CPUAccounting=true
EOF
    systemctl daemon-reload
  fi
  _ok "已应用 BBR/内核/服务优化"
}

_install_update() {
  _need_root
  _ensure_core_deps || { _err "依赖安装失败"; return; }
  _sync_latest_version
  _download_singbox || { _err "下载失败"; return; }
  _install_service
  _optimize_system
  _check_config && _service restart >/dev/null 2>&1 || true
  _ok "安装/更新完成"
}

_logs() {
  if _has journalctl; then journalctl -u sing-box -n 80 --no-pager; else tail -n 80 /var/log/sing-box.log /var/log/sing-box.err 2>/dev/null; fi
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
    echo -e "    ${BLUE}4.${NC} ${GREEN}重启 sing-box${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}返回主菜单${NC}"
    echo
    read -r -p "请选择操作: " c
    case "$c" in
      1) _add_user; _pause ;;
      2) _export_user; _pause ;;
      3) _delete_user; _pause ;;
      4) _service restart; _pause ;;
      0) break ;;
    esac
  done
}

_proto_menu() {
  echo -e "${CYAN}当前脚本支持 sing-box v${SINGBOX_VERSION} 常用新协议:${NC}"
  echo "- VLESS / VMess / Trojan"
  echo "- Hysteria2 / TUIC v5"
  echo "- Shadowsocks 2022-blake3-aes-128-gcm"
  echo "- AnyTLS"
  echo "- SOCKS5 入站"
  echo
  echo "默认轻量策略: log=warn、关闭 cache_file、少写磁盘、不启用无用 sniff/统计服务。"
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
    echo -e "    ${BLUE}1.${NC} ${GREEN}安装/更新 sing-box 最新稳定版${NC}"
    echo -e "    ${BLUE}2.${NC} ${GREEN}系统工具${NC}"
    echo -e "    ${BLUE}3.${NC} ${GREEN}协议管理/支持说明${NC}"
    echo -e "    ${BLUE}4.${NC} ${GREEN}中转管理${NC}"
    echo -e "    ${BLUE}5.${NC} ${GREEN}WARP 分流${NC}"
    echo -e "    ${BLUE}6.${NC} ${GREEN}导出节点配置${NC}"
    echo -e "    ${BLUE}7.${NC} ${GREEN}用户管理${NC}"
    echo -e "    ${BLUE}8.${NC} ${GREEN}检查配置${NC}"
    echo -e "    ${BLUE}9.${NC} ${GREEN}重启 sing-box${NC}"
    echo -e "    ${BLUE}10.${NC} ${GREEN}查看日志${NC}"
    echo -e "    ${BLUE}11.${NC} ${GREEN}端口转发管理${NC}"
    echo -e "    ${BLUE}12.${NC} ${GREEN}卸载 sing-box${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}退出系统${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    read -r -p "请选择操作指令: " choice
    case "$choice" in
      1) _install_update; _pause ;;
      2) _system_tools_menu ;;
      3) _proto_menu; _pause ;;
      4) _relay_menu; _pause ;;
      5) _warp_menu; _pause ;;
      6) _export_user; _pause ;;
      7) _user_menu ;;
      8) _check_config; _pause ;;
      9) _service restart; _pause ;;
      10) _logs; _pause ;;
      11) _port_forward_menu ;;
      12) _uninstall_all; _pause ;;
      0) exit 0 ;;
    esac
  done
}

_cli() {
  case "${1:-}" in
    install|update) _install_update ;;
    latest) _sync_latest_version; echo "$SINGBOX_VERSION" ;;
    optimize) _optimize_system ;;
    deps|repair) _ensure_core_deps ;;
    relay) _relay_menu ;;
    port-forward|forward|pf) _port_forward_menu ;;
    port-forward-apply) _port_forward_apply ;;
    warp) _warp_menu ;;
    uninstall) _uninstall_all ;;
    restart) _service restart ;;
    start) _service start ;;
    stop) _service stop ;;
    status) _service status ;;
    check) _check_config ;;
    logs) _logs ;;
    menu|sp) _main_menu ;;
    add-user) shift; _add_user ;;
    export-user) shift; _export_user ;;
    *) _main_menu ;;
  esac
}

_need_root
_cli "$@"
