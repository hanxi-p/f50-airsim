# F50 公网 TLS 直连与自建 Relay

以已经完成局域网来电、呼出、双向人声和挂断回归的 F50 为起点。本文用 `direct.example.com`、`relay.example.com` 和文档 IPv4 `203.0.113.10` 作示例，部署时全部替换。两项服务可共用同一台 VPS。

| 功能 | iPhone 配置页 | 公网入口 | 用途 |
|---|---|---|---|
| TLS 直连 | 公网域名配对，或给已配对设备添加自建域名 | DNS-only 域名 + 9443/8443/17593 | 首次外网配对、控制与实时音频 |
| 自建 Relay | 设置 → 云端 Relay | HTTPS/WSS 443 | 云端注册、信令、媒体与可选 APNs |

## 1. F50 到 VPS 的私有隧道

1. 在 VPS 建立专用非交互账号 `airsim-direct`，锁定密码，登录 shell 设为 nologin。在 F50 的私有部署根下创建 0700 的 `direct` 目录，用 `dropbearkey -t ed25519 -f direct/id_dropbear` 生成专用密钥。只将公钥添加到 VPS 账号的 `authorized_keys`，加上 `restrict,port-forwarding` 选项。
2. 将 [SSH Match 配置](examples/sshd-airsim-direct.conf) 放到 VPS 的 sshd drop-in 目录。先运行 `sshd -t`，并用 `sshd -T -C user=airsim-direct,host=localhost,addr=127.0.0.1` 确认仅允许反向转发至三个回环端口。确认管理账号有效配置未变后平滑重载 SSH。
3. 通过已有可信的 VPS 管理连接取得 SSH 主机公钥并在 F50 固定主机密钥。写入 `direct/vps-ip` 和 `direct/lan-ip`，分别是一行 VPS 公网 IPv4 和 F50 的 br-lan IPv4。将 [隧道 init 示例](examples/airsim-direct-tunnel.init) 安装为 `/etc/init.d/airsim-direct-tunnel`，权限 0755。启动后确认 VPS 只在 `127.0.0.1:18580/18581/18582` 监听，再启用自启。

| 公网 TLS 端口 | VPS 回环后端 | F50 LAN 后端 |
|---|---|---|
| 9443，限时配对 | 18580 | 8580 |
| 8443，控制 | 18581 | 8581 |
| 17593，PCM | 18582 | 8582 |

保持 SSH `GatewayPorts no`。F50 的管理 7581、内部 PCM 7580 和 Agent 8575 均不进入隧道。

## 2. VPS 直连入口

1. 为直连域名建立 DNS-only A 记录。普通 Cloudflare 网页代理无法转发原始 PCM TCP。用 Certbot 的 webroot 或 DNS 验证签发匹配域名、系统信任的证书。使用示例路径时将证书名指定为 `airsim-direct`。已有网站可继续使用独立虚拟主机和证书。
2. 安装 stunnel。将 [控制和音频配置](examples/stunnel-direct.conf) 安装为 `/etc/airsim-direct/tls.conf`，配合 [常驻 systemd 单元](examples/airsim-direct-tls.service)。确认运行用户可按配置降权，启动时能读取证书私钥。设置证书续期 hook 重启此服务，并安排在空闲窗口验证续期。安全组和系统防火墙仅按需允许 TCP 8443、17593 和临时的 9443。
3. 将 [配对配置](examples/stunnel-pair.conf) 安装为 `/etc/airsim-direct/pair.conf`，配合 [限时 systemd 单元](examples/airsim-direct-pair.service)。该示例使用 UFW，启动前添加 9443，停止后删除该规则。确认没有其它用途的 9443 规则；若不用 UFW，请改用当前防火墙的等效配置。限时单元不启用开机启动。保留 F50 原有一次性六位码、两分钟有效期、失败次数限制、控制与 PCM 身份验证。
4. 从外网验证控制入口 TLS 证书及未认证时的拒绝响应，另验证音频端口的 TLS 握手。若 VPS 本机成功而外网超时，核对云安全组与主机防火墙。TLS 握手通过后仍需 iPhone 验证设备身份和真实音频。

## 3. 适配 F50 并完成配对

已在局域网配对过的 iPhone，可在「自建域名直连」中填直连域名、控制 8443 和音频 17593，点击验证并保存。首次公网配对需要使用本仓库的补丁：

```sh
git checkout --detach v0.1.0-r21
git apply --check /path/to/f50-direct-pairing.patch
git apply /path/to/f50-direct-pairing.patch
go test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath \
  -o airsim-mu300d ./cmd/airsim-mu300d
sha256sum airsim-mu300d
```

空闲时备份已部署的网关二进制、启动脚本和配对目录。校验哈希后替换部署根中 `apk-files/usr/lib/airsim/airsim-mu300d`，使用本仓库的 supervisor，并创建 `direct-pairing.enabled`。重启 AirSIM，确认 LAN 和通话状态仍正常。补丁仅允许通过 F50 本机转发地址进入直连配对，复用原配对加密，并返回 iPhone 验证所需的 HMAC 路由证明。

打开 VPS 的限时配对服务，再从 F50 回环管理接口执行：

```sh
wget -q -T 4 --post-data='{}' -O - http://127.0.0.1:7581/pair/start
```

在 iPhone 的「公网域名配对」填 `direct.example.com`、9443、8443、17593 和新六位码。配对成功或过期后停止临时入口。使用另一网络验证控制身份、前台呼出与来电、双方人声、挂断，再回到 LAN 验证同一配对。公网直连不提供锁屏唤醒。

## 4. 可选 Relay 与短信边界

按 [AirSIM 自建 Relay 上游说明](https://github.com/kai-wu-cortex/AirSIM/tree/main/push-relay-worker/self-hosted) 固定源码、Node 和 workerd，并核对发布哈希。Relay 8787、维护 8789、APNs 桥 8790 绑定 VPS 回环。TLS 反代只开放 `/healthz` 与客户端 API，保留 WebSocket Upgrade，管理 Dashboard 留在回环。关闭会记录带令牌 URL 的访问日志。为公网注册端点加单独限流，避免影响心跳和媒体。管理令牌由 VPS 独立生成，配置设为 0600，备份 SQLite 及 WAL。APNs 私钥、Team ID 和 Key ID 需匹配实际 iOS 签名。

Cloudflare 部署可参考 [Nginx 模板](examples/nginx-relay-cloudflare.conf)。从 [官方地址清单](https://www.cloudflare.com/ips/) 生成模板所需的源站白名单，只对这些代理启用真实客户端 IP 解析。验证 HTTPS 回源、代理端证书及 WebSocket 后再切换客户端。ECS 安全组需单独允许 TCP 443；本机健康而公网返回 522 时，用仅匹配目标端口及本机地址的 SYN 检查区分云安全组与主机防火墙。

F50 停服务并备份 `lan-data/management.json`，设置 `mode` 为 `cloud`、`relay_url` 为 `https://relay.example.com`，保留 LAN 接口和端口。部署根写入同一个 HTTPS 地址作为单行 `relay-approved`，权限 0600。启动后确认 Agent 和 LAN 正常。iPhone 在同一 Wi-Fi 下保存同一 Relay 地址，运行云端自检，核对新 Relay 收到注册和心跳。实际前台云端通话与锁屏 APNs 分别验收。

- 设备注册返回 HTTP 400 时，先比对 Relay 的 `ALLOWED_BUNDLE_ID` 与实际安装的 iPhone App 标识。上游示例值只是占位符，保留精确白名单。
- iPhone 已注册但没有 Agent 记录时，检查 F50 本地 `/api/push/status` 的 `configured` 和 `relay_url`。旧配对若只启用本地模式，可在 iPhone 关闭纯本地模式、保存新地址后，用 Bonjour 做一次允许云端同步的配对。
- 如果普通 HTTPS 可达，而指定 modem 接口的同一请求和 Agent 心跳超时，用 [Agent 路由补丁](patches/f50-agent-relay-route.patch) 让 MU300 OpenWrt 沿用系统路由。解包已验证的 R21 源码发布物，在 `AirSIM/module/module-agent` 目录用 `git apply --check` 验证后应用补丁，运行 `go test ./...`，再用 `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o airsim-agent .` 构建。空闲时备份并替换 F50 的 Agent，仅重启 AirSIM 服务。以 VPS 实际收到的新鲜心跳和命令路由自检为验收。

Bark 使用宿主原有短信路径。AirSIM 云端模式的私有挂载隐藏本地收件目录并屏蔽 native SMS 工具，避免将本机短信引入云端。纯局域网模式可用 `local-sms.enabled` 选择保留 AirSIM 本地短信。

## 5. 回滚

关闭 VPS 临时配对入口并检查 9443 的主机防火墙规则。撤销公网直连时，先停用对应 TLS 服务及 F50 隧道自启，再移除专用账号的公钥、专用入站规则和直连 DNS 记录。F50 空闲时恢复备份网关和 supervisor，撤销 `direct-pairing.enabled`，保留既有配对。撤销 Relay 时同时把 F50 与 iPhone 改回原模式或原地址，复测 LAN 和 Bark。公开仓库仅保存示例和代码，不提交实际域名、设备备份、配对数据、密钥或 DSP 固件。
