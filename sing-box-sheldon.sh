#!/usr/bin/env bash
# Sing-box Sheldon 管理系统
# 轻量、省内存、最新 sing-box 协议管理脚本
# Version: 1.0.0

set -o pipefail

SCRIPT_VERSION="1.1.0"
SINGBOX_VERSION="1.13.12"
SINGBOX_DIR="/usr/local/etc/sing-box"
CONFIG_FILE="$SINGBOX_DIR/config.json"
USER_FILE="$SINGBOX_DIR/users.json"
SERVICE_NAME="sing-box"
BIN_PATH="/usr/local/bin/sing-box"
TG_CONFIG_FILE="$SINGBOX_DIR/telegram.conf"

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
  if _has apk; then apk add --no-cache "$@"; return; fi
  if _has apt-get; then apt-get update -qq >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; return; fi
  if _has dnf; then dnf install -y "$@"; return; fi
  if _has yum; then yum install -y "$@"; return; fi
  _err "未知包管理器，请手动安装: $*"; return 1
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
  _has curl || _pkg_install curl
  _has tar || _pkg_install tar
  _warn "下载 sing-box v${SINGBOX_VERSION} (${arch})..."
  curl -fL --connect-timeout 15 --max-time 180 "$url" -o "$tmp" || return 1
  tar -xzf "$tmp" -C /tmp || return 1
  install -m 755 "/tmp/sing-box-${SINGBOX_VERSION}-linux-${arch}/sing-box" "$BIN_PATH"
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
  if ss -lntup 2>/dev/null | grep -q ":$port "; then _err "端口已占用"; return; fi
  read -r -p "套餐 [不限]: " plan; plan="${plan:-不限}"
  read -r -p "重置日 [不重置]: " reset; reset="${reset:-不重置}"
  read -r -p "到期时间 [永久]: " expire; expire="${expire:-永久}"
  local uuid pass tag
  uuid="$(_rand_uuid)"; pass="$(_rand_pass)"; tag="user-$name"
  _add_inbound_json "$proto" "$tag" "$port" "$uuid" "$pass" || return
  _add_user_record "$name" "开启" "$plan" "$reset" "$expire" "$port" "$proto" "$uuid" "$pass" "$tag"
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
  _has jq || _pkg_install jq
  _download_singbox || { _err "下载失败"; return; }
  _install_service
  _optimize_system
  _check_config && _service restart >/dev/null 2>&1 || true
  _ok "安装/更新完成"
}

_logs() {
  if _has journalctl; then journalctl -u sing-box -n 80 --no-pager; else tail -n 80 /var/log/sing-box.log /var/log/sing-box.err 2>/dev/null; fi
}

_tg_load_config() {
  [ -f "$TG_CONFIG_FILE" ] && . "$TG_CONFIG_FILE"
  TG_BOT_TOKEN="${TG_BOT_TOKEN:-${BOT_TOKEN:-}}"
  TG_CHAT_ID="${TG_CHAT_ID:-${CHAT_ID:-}}"
}

_tg_save_config() {
  mkdir -p "$SINGBOX_DIR"
  cat > "$TG_CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF
  chmod 600 "$TG_CONFIG_FILE"
}

_tg_send() {
  _tg_load_config
  local text="$*"
  [ -n "$text" ] || { _err "公告内容不能为空"; return 1; }
  if [ -z "$TG_BOT_TOKEN" ]; then
    read -r -p "Bot Token: " TG_BOT_TOKEN
  fi
  if [ -z "$TG_CHAT_ID" ]; then
    read -r -p "频道/群组 ID 或 @username [@kucunn]: " TG_CHAT_ID
    TG_CHAT_ID="${TG_CHAT_ID:-@kucunn}"
  fi
  _tg_save_config
  _has curl || _pkg_install curl
  local resp
  resp=$(curl -sS --connect-timeout 10 --max-time 30 \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "disable_web_page_preview=true")
  echo "$resp" | grep -q '"ok":true' && _ok "公告已发送到 ${TG_CHAT_ID}" || { _err "发送失败: $resp"; return 1; }
}

_sp_announcement() {
  if [ "$#" -gt 0 ]; then
    _tg_send "$*"
    return
  fi
  echo -e "${CYAN}快捷公告 sp：输入内容后发送到 Telegram 频道/群组${NC}"
  echo -e "${YELLOW}提示：第一次会要求填写 Bot Token 和频道 ID，之后保存在 ${TG_CONFIG_FILE}${NC}"
  read -r -p "公告内容: " text
  _tg_send "$text"
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
    echo -e "    ${BLUE}2.${NC} ${GREEN}系统性能优化/省内存${NC}"
    echo -e "    ${BLUE}3.${NC} ${GREEN}协议支持说明${NC}"
    echo -e "    ${BLUE}4.${NC} ${GREEN}用户管理${NC}"
    echo -e "    ${BLUE}5.${NC} ${GREEN}检查配置${NC}"
    echo -e "    ${BLUE}6.${NC} ${GREEN}重启 sing-box${NC}"
    echo -e "    ${BLUE}7.${NC} ${GREEN}查看日志${NC}"
    echo -e "    ${BLUE}sp.${NC} ${GREEN}快捷发频道公告${NC}"
    echo -e "    ${RED}0.${NC} ${GREEN}退出系统${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    read -r -p "请选择操作指令: " choice
    case "$choice" in
      1) _install_update; _pause ;;
      2) _optimize_system; _pause ;;
      3) _proto_menu; _pause ;;
      4) _user_menu ;;
      5) _check_config; _pause ;;
      6) _service restart; _pause ;;
      7) _logs; _pause ;;
      sp|SP) _sp_announcement; _pause ;;
      0) exit 0 ;;
    esac
  done
}

_cli() {
  case "${1:-}" in
    install|update) _install_update ;;
    optimize) _optimize_system ;;
    restart) _service restart ;;
    start) _service start ;;
    stop) _service stop ;;
    status) _service status ;;
    check) _check_config ;;
    logs) _logs ;;
    sp) shift; _sp_announcement "$@" ;;
    send-post) shift; _sp_announcement "$@" ;;
    add-user) shift; _add_user ;;
    export-user) shift; _export_user ;;
    *) _main_menu ;;
  esac
}

_need_root
_cli "$@"
