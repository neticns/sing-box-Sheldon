# sing-box Sheldon

`sing-box Sheldon` 是轻量版 `sing-box` 管理脚本，适合快速部署、管理节点用户、导出节点链接，并针对低内存 VPS 做了默认优化。

> 当前核心版本：`sing-box v1.13.12`
>
> 脚本版本：`v1.2.1`

## 功能特性

- 一键安装 / 更新 `sing-box`
- 用户管理
  - 新增用户
  - 删除用户
  - 查看用户套餐、重置日、到期时间
  - 导出节点链接
- 支持常用协议
  - VLESS
  - VMess
  - Trojan
  - Hysteria2
  - TUIC
  - Shadowsocks 2022
  - AnyTLS
  - SOCKS5
- 轻量化默认配置
  - 日志级别默认 `warn`
  - 关闭 `cache_file`
  - 不启用无用统计服务
  - 少写磁盘
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
        [sing-box Sheldon 管理系统 V1.2.1]
------------------------------------------------------------
 sing-box : 运行中   版本 1.13.12
------------------------------------------------------------
    1. 安装/更新 sing-box 最新稳定版
    2. 系统工具
    3. 协议管理/支持说明
    4. 中转管理
    5. WARP 分流
    6. 导出节点配置
    7. 用户管理
    8. 检查配置
    9. 重启 sing-box
    10. 查看日志
    11. 端口转发管理
    12. 卸载 sing-box
    0. 退出系统
------------------------------------------------------------
请选择操作指令:
```

## 命令行用法

除了交互菜单，也可以直接执行命令：

```bash
./sing-box-sheldon.sh install      # 安装/更新 sing-box
./sing-box-sheldon.sh optimize     # 应用性能优化
./sing-box-sheldon.sh start        # 启动服务
./sing-box-sheldon.sh stop         # 停止服务
./sing-box-sheldon.sh restart      # 重启服务
./sing-box-sheldon.sh status       # 查看状态
./sing-box-sheldon.sh check        # 检查配置
./sing-box-sheldon.sh logs         # 查看日志
./sing-box-sheldon.sh pf           # 端口转发管理
./sing-box-sheldon.sh forward      # 端口转发管理
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
vmess
trojan
hysteria2
tuic
shadowsocks
anytls
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

- `log.level = warn`，避免大量日志写入
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
4. Shadowsocks 2022 对系统时间敏感，建议确保 NTP 正常。
5. 如果是 NAT VPS，请区分外部映射端口和服务器内部监听端口。
6. 生产环境建议自行配置 TLS/Reality 证书和安全参数。

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
