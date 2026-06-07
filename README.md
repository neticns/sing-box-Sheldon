# sing-box Sheldon

`sing-box Sheldon` 是轻量版 `sing-box` 管理脚本，适合快速部署、管理节点用户、导出节点链接，并针对低内存 VPS 做了默认优化。

> 当前核心版本：`sing-box v1.13.13`
>
> 脚本版本：`v1.2.16`

## 功能特性

- 一键安装 / 更新 `sing-box`
- 用户管理
  - 新增用户
  - 删除用户
  - 查看用户套餐、重置日、到期时间
  - 导出节点链接
- 协议管理
  - 查看支持协议/防封说明
  - 直接创建新协议入站，不必添加用户
  - 协议入站不进入用户/套餐/流量表，适合快速开独立节点
- 支持常用与新型防封协议
  - Sheldon 协议：脚本自创高安全预设，基于 VLESS + Reality + Vision + 公共站点伪装 + NTP
  - Sheldon VLESS：基于 VLESS Reality + Vision 的兼容预设
  - VLESS
  - VLESS Reality
  - Reality 公共站点伪装
  - VMess
  - Trojan
  - Hysteria2
  - TUIC
  - Shadowsocks 2022
  - AnyTLS
  - AnyTLS Reality
  - 导出链接自动带 `fp=chrome` / ALPN 参数
  - SOCKS5
- 轻量化默认配置
  - 日志级别默认 `error`
  - 关闭 `cache_file`
  - 不启用无用统计服务
  - 少写磁盘
  - 内置 NTP 自动校时配置，降低 `Handshake failed` / `Time offset too large` 报错
- 性能优化
  - BBR
  - TCP Fast Open
  - TCP 队列优化
  - 文件句柄优化
  - IPv4 / IPv6 转发
- 服务管理
  - 启动
  - 停止
  - 重启
  - 状态查看
  - 配置检查
  - 日志查看
- 端口转发管理
  - TCP / UDP / both 转发
  - 新增 / 删除 / 清空 / 应用规则
  - systemd 开机自动应用
- Argo 隧道管理
  - 安装/更新 cloudflared 最新版
  - 支持 Cloudflare Quick Tunnel 临时隧道
  - 支持 Named Tunnel Token 稳定隧道
  - 本地服务仅允许 127.0.0.1 / localhost，减少误暴露
  - systemd 资源限制与自动重启，提高安全伪装和稳定性

## 自动补依赖

`v1.2.0+` 开始，安装时会自动检测并补齐常见依赖，尽量做到“缺什么补什么，直到安装成功”。

自动处理的依赖包括：

- `curl` / `wget`：下载 sing-box 核心
- `ca-certificates`：修复 HTTPS 证书问题
- `tar` / `gzip`：解压 release 包
- `jq`：读写 JSON 配置
- `iproute2` / `ss`：端口占用检测
- `uuidgen` / `util-linux`：UUID 生成兜底
- `coreutils` / `base64`：节点链接编码

支持的包管理器：

- `apk`：Alpine
- `apt-get`：Debian / Ubuntu
- `dnf`：Fedora / Rocky / AlmaLinux
- `yum`：CentOS
- `zypper`：openSUSE

如果 `curl` 不存在但 `wget` 可用，脚本会自动使用 `wget` 下载。

## 系统支持

已按以下环境编写：

- Debian / Ubuntu
- Alpine Linux
- CentOS / Rocky / AlmaLinux
- 架构：`amd64`、`arm64`、`armv7`

服务管理支持：

- systemd
- OpenRC
- 无服务管理器时使用后台进程兜底

## 快速安装

```bash
curl -fsSL https://raw.githubusercontent.com/neticns/sing-box-Sheldon/main/sing-box-sheldon.sh -o sing-box-sheldon.sh
chmod +x sing-box-sheldon.sh
sudo ./sing-box-sheldon.sh
```

进入菜单后选择：

```text
1. 安装/更新 sing-box 最新稳定版
```

## 菜单预览

```text
------------------------------------------------------------
        [sing-box Sheldon 管理系统 V1.2.16]
------------------------------------------------------------
 sing-box : 运行中   版本 1.13.13
------------------------------------------------------------
    1. 安装/更新 sing-box 最新稳定版
    2. 系统工具
    3. 协议管理
    4. 中转管理
    5. WARP 分流
    6. 用户管理
    7. 端口转发管理
    8. Argo 隧道管理
    9. 命令菜单
    10. 更新脚本
    11. 卸载 sing-box
    0. 退出系统
------------------------------------------------------------
请选择操作指令:
```

## 命令行用法

除了交互菜单，也可以直接执行命令：

```bash
./sing-box-sheldon.sh script-update # 更新 Sheldon 脚本本身
./sing-box-sheldon.sh install      # 安装/更新 sing-box
./sing-box-sheldon.sh optimize     # 应用性能/省内存优化
./sing-box-sheldon.sh lowmem       # 只应用轻量配置优化
./sing-box-sheldon.sh cmd          # 打开命令菜单
./sing-box-sheldon.sh help         # 打开命令菜单
./sing-box-sheldon.sh start        # 启动服务
./sing-box-sheldon.sh stop         # 停止服务
./sing-box-sheldon.sh restart      # 重启服务
./sing-box-sheldon.sh status       # 查看状态
./sing-box-sheldon.sh check        # 检查配置
./sing-box-sheldon.sh logs         # 查看日志
./sing-box-sheldon.sh doctor       # 脚本自检/可用性检测
./sing-box-sheldon.sh relay        # 中转管理
./sing-box-sheldon.sh proto        # 协议管理
./sing-box-sheldon.sh create-protocol # 直接创建协议入站
./sing-box-sheldon.sh pf           # 端口转发管理
./sing-box-sheldon.sh forward      # 端口转发管理
./sing-box-sheldon.sh argo        # Argo 隧道管理
./sing-box-sheldon.sh argo-status # 查看 Argo 状态
sp                            # 直接召唤脚本菜单
./sing-box-sheldon.sh sp           # 同样打开脚本菜单
```

## 快捷菜单 sp

`sp` 是全局快捷命令。安装后，只需要在终端输入 `sp`，就能直接召唤 `sing-box Sheldon` 管理菜单。

```bash
sp
```

也可以使用：

```bash
./sing-box-sheldon.sh sp
./sing-box-sheldon.sh menu
```

安装/更新时脚本会自动创建：

```text
/usr/local/bin/sing-box-sheldon
/usr/local/bin/sp -> /usr/local/bin/sing-box-sheldon
```

## v1.2.15 脚本更新提醒

- 主菜单和自检会自动检查 GitHub 最新脚本版本。
- 发现新版本时提示：主菜单选 `10 更新脚本` 或运行 `sp script-update`。
- 检查结果会缓存 6 小时，避免每次进菜单都慢。

## v1.2.16 核心版本更新

- 默认安装/更新的 sing-box 核心跟进到 `v1.13.13`。
- 协议预设保持不变：默认仍推荐 `sheldon`（VLESS + Reality + Vision）。

## v1.2.14 协议数字选择 / 随机端口

- 新增用户、直接创建协议入站时，协议改为数字菜单选择，避免手输协议名出错。
- 监听端口支持留空自动随机选择未占用端口。
- 随机端口范围：`20000-59999`，会自动避开已监听端口。

## v1.2.13 用户添加修复

- 修复直接执行 `./sing-box-sheldon.sh add-user` 时，首次添加用户没有初始化配置目录，导致 `config.json.tmp: No such file or directory` 的问题。
- 已覆盖测试：`sheldon`、`vless`、`vmess`、`trojan`、`hysteria2`、`tuic`、`shadowsocks`、`anytls`、`socks` 用户添加路径。

## v1.2.12 更新脚本修复

修复 `更新脚本` 菜单报错：

```text
_download: command not found
```

根因：脚本已有下载函数 `_fetch`，但自更新函数误调用了旧函数名 `_download`。

处理：

- 自更新改为调用 `_fetch`。
- 同时保留 `_download -> _fetch` 兼容别名，避免旧代码路径再触发同类问题。
- `bash -n` 和关键函数检查已通过。

## v1.2.11 主菜单更新脚本

主菜单新增：

```text
10. 更新脚本
11. 卸载 sing-box
```

`更新脚本` 只更新 `sing-box Sheldon` 脚本本身，不等于更新 sing-box 核心。

功能：

- 从 GitHub raw 拉取最新 `sing-box-sheldon.sh`。
- 下载后先执行 `bash -n` 语法检查。
- 自动备份旧脚本为 `.bak.时间戳`。
- 自动恢复/创建：
  - `/usr/local/bin/sing-box-sheldon`
  - `/usr/local/bin/sp`

命令：

```bash
sing-box-sheldon script-update
sing-box-sheldon self-update
sing-box-sheldon update-script
```

## v1.2.10 Sheldon 连接修复

修复 `Sheldon` 协议部分客户端连接不上的问题：

- 根因：之前默认 `sheldon` 使用 `AnyTLS + Reality`，服务端配置能通过 `sing-box check`，但不少客户端对 AnyTLS Reality 链接兼容不完整。
- 处理：默认 `sheldon` 改为更通用的 `VLESS + Reality + Vision`。
- 保留：`AnyTLS + Reality` 不删除，改为高级协议别名 `sheldon-anytls` / `anytls-reality`。
- 推荐：新建节点直接输入 `sheldon`。

协议优先级：

```text
sheldon > sheldon-vless > vless-reality > sheldon-anytls / anytls-reality
```

## v1.2.9 协议管理优化

主菜单 `3. 协议管理` 现在支持数字操作：

```text
1. 查看支持协议/防封说明
2. 直接创建新协议入站
3. 检查 sing-box 配置
0. 返回主菜单
```

说明：

- `直接创建新协议入站` 不需要新增用户。
- 会直接写入 sing-box `inbounds`，并输出节点链接。
- 不进入用户表、套餐表、流量统计表。
- 如果需要用户套餐/重置日/到期时间/流量管理，请继续使用 `用户管理 -> 新增用户`。
- 推荐协议仍是 `sheldon`。

命令：

```bash
./sing-box-sheldon.sh proto
./sing-box-sheldon.sh create-protocol
```

## v1.2.7 Sheldon 协议预设

新增 `Sheldon` 自创协议预设。它不是魔改 sing-box 核心的新私有协议，而是为了兼容性和稳定性，把当前更适合自建节点的安全伪装参数组合成一套默认模板。

协议别名：

```text
sheldon           # 推荐，VLESS + Reality + Vision + 公共站点伪装
sheldon-reality   # sheldon 的同义别名
sheldon-vless     # sheldon 的兼容别名
sheldon-anytls    # 高级选项，AnyTLS + Reality，客户端支持不全时不要优先用
```

Sheldon 默认策略：

- AnyTLS + Reality，无需购买域名，无需自签名证书
- 自动随机公共站点握手伪装
- 默认 `fp=chrome`
- 默认 `h2,http/1.1` ALPN
- 16 位随机 short_id
- 自动写入 NTP 校时配置，减少 `Handshake failed` / `Time offset too large`
- 保持 sing-box 原生配置，不魔改核心，方便客户端兼容

新增用户时协议直接输入：

```text
sheldon
```

推荐优先级：`sheldon` > `sheldon-vless` > `anytls-reality` > `vless-reality`。

## v1.2.6 防封协议、伪装与 NTP 校时

新增/优化：

- `anytls-reality`：AnyTLS + Reality，无需购买域名，无需自签名证书。
- `vless-reality`：VLESS + Reality，适合无域名场景。
- Reality 自动随机公共站点 SNI/握手目标，默认 `h2,http/1.1` ALPN，导出链接带 `fp=chrome`。
- 新增配置文件 `ntp`：自动向高精度时间服务器校时。
- 减少因时间偏移导致的常见报错：`Handshake failed`、`Time offset too large`。

新增用户时协议可直接输入：

```text
sheldon
sheldon-vless
anytls-reality
vless-reality
```

## v1.2.8 Argo 隧道安全伪装

主菜单新增 `8. Argo 隧道管理`。

功能：

- 自动安装/更新 `cloudflared` 最新版。
- 支持 Quick Tunnel：适合临时测试，会生成 `trycloudflare.com` 临时域名。
- 支持 Named Tunnel Token：适合长期稳定使用，可绑定 Cloudflare 域名。
- 本地服务地址只允许 `127.0.0.1` / `localhost`，避免误把内网或公网服务暴露。
- systemd 服务默认启用自动重启、资源限制、`NoNewPrivileges`、`ProtectSystem`、`ProtectHome` 等安全参数。
- 建议协议层继续使用 `sheldon` / `sheldon-vless`，隧道层用 Argo 隐藏源站 IP。

命令：

```bash
./sing-box-sheldon.sh argo          # 打开 Argo 隧道菜单
./sing-box-sheldon.sh argo-update   # 安装/更新 cloudflared
./sing-box-sheldon.sh argo-start    # 启动临时 Quick Tunnel
./sing-box-sheldon.sh argo-token    # 启动 Named Tunnel Token
./sing-box-sheldon.sh argo-status   # 查看状态/日志
./sing-box-sheldon.sh argo-stop     # 停止隧道
```

## 命令菜单

命令菜单支持数字选择，用来快速执行常用维护动作；中转管理、端口转发管理这类大功能仍保留在主菜单，避免重复。

进入方式：

```bash
sp
# 选择 8. 命令菜单
```

也可以直接执行：

```bash
./sing-box-sheldon.sh cmd
./sing-box-sheldon.sh commands
./sing-box-sheldon.sh help
```

当前命令菜单：

```text
1. 安装/更新 sing-box
2. 自检服务器是否可用
3. 应用省内存轻量配置
4. 应用系统性能优化
5. 检查 sing-box 配置
6. 查看日志
7. 重启 sing-box
8. 查看服务状态
9. 快捷命令说明
0. 返回主菜单
```

说明：中转管理在主菜单 4，端口转发管理在主菜单 7，不在命令菜单重复显示。

## v1.2.3 省内存/性能优化

进一步压低默认资源占用：

- 日志从 `warn` 调整为 `error`，减少磁盘写入和日志处理
- 关闭 `cache_file`
- 关闭 `route.auto_detect_interface`
- 关闭 `route.find_process`
- systemd 限制：`MemoryMax=192M`、`MemoryHigh=160M`、`CPUQuota=85%`、`TasksMax=256`
- 增加 TCP keepalive / Fast Open / BBR / 队列优化
- 提供轻量配置命令：

```bash
./sing-box-sheldon.sh lowmem
./sing-box-sheldon.sh light
```

## 自检/可用性检测

`v1.2.2` 新增自检命令，用于快速判断当前服务器能不能正常安装/运行。

```bash
./sing-box-sheldon.sh doctor
# 或
./sing-box-sheldon.sh self-check
./sing-box-sheldon.sh test
```

检测内容：

- root 权限
- 包管理器
- curl / wget
- tar / jq / ss / iptables
- systemd / OpenRC
- sing-box 核心
- 配置目录可写
- 已安装时自动执行 sing-box config check

## 端口转发管理

`v1.2.1` 新增端口转发管理，适合中转机/NAT 机器做本地端口到远端目标的转发。

支持：

- 本地端口 → 目标 IP/域名:目标端口
- 协议：`tcp` / `udp` / `both`
- 新增、删除、清空、应用规则
- 自动开启 IPv4 转发：`net.ipv4.ip_forward=1`
- 自动尝试放行防火墙端口
- systemd 开机自动应用规则

规则文件：

```text
/usr/local/etc/sing-box/port_forward.rules
```

进入方式：

```bash
sp
# 选择 11. 端口转发管理
```

也可以直接：

```bash
./sing-box-sheldon.sh pf
./sing-box-sheldon.sh forward
./sing-box-sheldon.sh port-forward
```

## 配置文件路径

脚本使用以下路径：

```text
/usr/local/bin/sing-box                 # sing-box 核心
/usr/local/etc/sing-box/config.json     # 主配置文件
/usr/local/etc/sing-box/users.json      # 用户记录
/etc/systemd/system/sing-box.service    # systemd 服务文件
/etc/init.d/sing-box                    # OpenRC 服务文件
```

## 新增用户

进入菜单：

```text
4. 用户管理
1. 新增用户
```

按提示输入：

- 用户名
- 协议
- 监听端口
- 套餐
- 重置日
- 到期时间

支持协议输入：

```text
vless
vless-reality
vmess
trojan
hysteria2
tuic
shadowsocks
anytls
anytls-reality
socks
```

## 导出节点

进入菜单：

```text
4. 用户管理
2. 导出节点配置
```

输入用户名后，脚本会自动生成对应协议链接。

## 省内存设计

默认配置尽量减少长期资源占用：

- `log.level = error`，进一步减少日志写入
- `experimental.cache_file.enabled = false`
- 不开启面板、不驻留额外 Web 服务
- systemd 下限制 `MemoryMax=256M`
- 使用单配置文件管理，减少脚本复杂度

## 性能优化项

执行：

```bash
./sing-box-sheldon.sh optimize
```

会写入：

```text
/etc/sysctl.d/99-sing-box-sheldon.conf
```

包含：

```text
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
```

## 注意事项

1. 脚本需要 `root` 权限。
2. 新增用户前请确认端口没有被占用。
3. Hysteria2 / TUIC 属于 UDP/QUIC 协议，服务器防火墙和服务商安全组需要放行 UDP。
4. Shadowsocks 2022、Reality、AnyTLS Reality 都对系统时间敏感，脚本已默认写入 NTP 配置。
5. 如果是 NAT VPS，请区分外部映射端口和服务器内部监听端口。
6. Reality 默认随机使用公共站点作为握手伪装，并导出 `fp=chrome`/ALPN 参数；可按需自行调整 SNI/握手目标。

## 卸载

当前脚本没有自动卸载菜单，可以手动执行：

```bash
systemctl stop sing-box 2>/dev/null || rc-service sing-box stop 2>/dev/null || true
systemctl disable sing-box 2>/dev/null || rc-update del sing-box default 2>/dev/null || true
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/init.d/sing-box
rm -f /usr/local/bin/sing-box
rm -rf /usr/local/etc/sing-box
systemctl daemon-reload 2>/dev/null || true
```

## License

MIT
