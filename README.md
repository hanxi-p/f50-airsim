# F50 AirSIM

F50 热点内的 iPhone 通过 AirSIM 接听和发起 SIM 语音通话。使用 Bonjour 配对、局域网控制和 PCM 通道，以及 F50 的 mu300-atd。iPhone 使用原 AirSIM 客户端。

本仓库统一维护 [构建和部署脚本](scripts/)、[F50 公网配对补丁](patches/f50-direct-pairing.patch)及 [VPS 公网配置](PUBLIC.md)。下面的 Fork 分支保留先前的局域网实现供追溯。

| 功能分支 | 内容 |
|---|---|
| [f50-airsim-gateway](https://github.com/hanxi-p/f50-airsim-gateway/tree/feature/f50-lan/packaging/f50-lan) | LAN 服务、AT 兼容和私有挂载命名空间 |
| [f50-airsim-audio](https://github.com/hanxi-p/f50-airsim-audio/tree/feature/f50-lan/tools/f50-lan) | ARM64 本地构建与 CRC 核对 |
| [f50-airsim-linux](https://github.com/hanxi-p/f50-airsim-linux/tree/feature/f50-lan/tools/f50-lan) | 只读诊断和发布内核配置提取 |

按 [稳定性检查清单](VALIDATION.md) 验收备份、内核 ABI、开机启动、局域网、公网直连和云端 Relay。上游命令和运行时字段继续使用其原始名称，便于复用现有 AirSIM 客户端和 OpenWrt 工具。

## 1. 核对设备与恢复入口

本方案的实测设备使用 OpenWrt 25.12.5，系统横幅 v2026.10.11，实际运行的 AArch64 内核为 `5.4.254-gb50db5b6224c`。规范化配置 SHA-256 为 `1057cb97e0d2d7f26816e8bf7841faac1153833a01d4893cdc196b75ae6356b3`，与 v2026.10.30.1 参考内核相符。使用 mu300-linux 分支的 `collect-f50-readonly.sh` 核对。装载前还须核对符号 CRC、实际设备树和 DSP 保留区。

将设备的 /etc、/root、Bark 服务和已装包清单备份到设备外的私有目录，校验归档和 SHA-256。确认独立于热点的 USB 或 Android 恢复入口。文件备份用于恢复配置，系统启动需要另外准备恢复介质。所有变更在无活动通话时进行。

## 2. 本机重建驱动

在一次性的 Ubuntu 20.04 VM 中安装 clang-12、lld-12、llvm-12、build-essential、bc、bison、flex、libssl-dev、libelf-dev、python-is-python3、cpio、kmod、gcc-aarch64-linux-gnu 和 binutils-aarch64-linux-gnu。Windows 可使用 QEMU 和仅绑定回环的 SSH 转发。

| 构建输入 | 来源 |
|---|---|
| zte-git-verified.tar.gz | [ZTE 内核固定提交](https://github.com/Enceka/android_kernel_zte_ums9620_mifi_u30air/tree/b50db5b6224c11db42a246e8fcdaad1e1d59f478)，用 `git archive --format=tar.gz --prefix=zte-b50db5b/` 导出 |
| linux-reference.tar | mu300-linux v2026.10.30.1 的 `kernel/` Git 归档 |
| audio-reference.tar | mu300-audio 提交 `53cbe6a7344b7fa175ff87a73630f05e5862f483` 的完整 Git 归档 |
| r21-recipe.tar | airsim-mu300 v0.1.0-r21 的 `packaging/openwrt-audio/` Git 归档 |
| reference-kernel.tar.gz | [v2026.10.30.1 的 mu300-kernel.tar.gz](https://github.com/dikeckaan/mu300-linux/releases/tag/v2026.10.30.1)，SHA-256 `01a29c853be8bf202a2f1d3c47cb434c5cabb53ce23137646fd4380242d8e1b2` |
| openwrt-audio-abi.py | R21 的 `scripts/openwrt-audio-abi.py` |

Git 归档应保持原始 LF 换行，可用 `git -c core.autocrlf=false archive`。对上述输入和音频分支中的 build-f50-local.sh 生成 SHA256SUMS，在空白 VM 运行 `sudo env JOBS=6 bash build-f50-local.sh "$PWD"`。只有 /evidence/abi-report.json 显示 ABI 通过才进入实机阶段。一次本地重建的 24 个模块与 R21 发布模块逐字节一致，978 条导入记录通过审计。

## 3. 暂存与启动

1. 从 [R21 发布页](https://github.com/kai-wu-cortex/airsim-mu300/releases/tag/v0.1.0-r21) 获取 APK、公钥和签名清单。固定公钥 SHA-256 为 `0ce703e76ea4b702194c54b90534d7127874bb38ecda17f7ed6b1add2d2cf1de`。用 `openssl dgst -sha256 -verify airsim-dev.pem -signature SHA256SUMS.sig SHA256SUMS` 验证清单，再核对 APK 哈希。
2. 使用设备上 APK v3 的 `apk --no-network --no-logfile --keys-dir KEYDIR verify PACKAGE` 和 `apk --no-network --no-logfile --keys-dir KEYDIR extract --destination apk-files PACKAGE` 解包到私有暂存目录。KEYDIR 只需放该发布公钥。把 apk-files/usr/lib/airsim/deps/airsim-audio-0.1.0-r16.tar.gz 解到暂存根，保留其中的 bin、modules 和 KERNEL 元数据。核对模块清单。签名 APK 内的 agdsp.bin 哈希应为 `378ceea78dbf013e10625e71efd6fab487d727e371884ae8daf078da2828b937`。固件的再分发许可未确认，本仓库无固件副本。
3. 确认地址适用于设备后，在设备空闲时运行 `bin/mu300-audio-dsp reserve`。读取 /sys/module/audio_reserve/parameters/ranges 和 missing，范围须为 `0xaf700000,0x300000;0xafa00000,0x600000`，且 missing 为 0。保留失败应立即停止。内存保留需要重启才能释放。
4. 将暂存根移到 /mnt/mu300-disk/extra/airsim-f50 并设 0700。复制网关分支的 f50-airsim-at.sh，另将 f50-airsim-boot.sh 复制为 boot-lan.sh、f50-airsim-lan.sh 复制为 lan-supervisor.sh，权限 0700。
5. 在构建机执行 `aarch64-linux-gnu-gcc -static -O2 -Wall -Wextra -Werror -o f50-private-mount f50-private-mount.c`，将生成的启动器放到设备暂存根。解引用复制设备原 /usr/bin/mu300-at 为 mu300-at-original，并从 [mu300-linux 固定提交](https://github.com/dikeckaan/mu300-linux/blob/833616a6c03a7c0245300c5946d98ec98b09bb94/rootfs/overlay/opt/mu300/lib/run-dir.sh)复制 run-dir.sh。
6. 创建私有 empty-sms 目录和可执行的 deny-sms.sh，后者两行内容为 `#!/bin/sh` 和 `exit 1`。创建 0700 的 lan-data 目录，已有配对时先停止旧网关再迁移完整目录。将 management.json 设为 0600，内容为 `{"mode":"local","interface":"br-lan","pair_port":8580,"control_port":8581,"pcm_port":8582}`。SMS 屏蔽只作用于 AirSIM 的挂载命名空间。
7. 安装 f50-airsim.init 和 f50-airsim-reserve.init 为 /etc/init.d/airsim-f50 和 /etc/init.d/airsim-f50-reserve，权限 0755。先在空闲时执行 `/etc/init.d/airsim-f50 start` 验证启动，检查 /tmp/airsim-f50-runtime/boot.log。确认 23 个音频驱动和 sprdphone 声卡、DSP 应答及本地网关状态后，对两个服务执行 enable，再受控重启验收。内存保留失败时网关应停止启动。

## 4. 配对和通话验收

```sh
wget -q -T 4 --post-data='{}' -O - http://127.0.0.1:7581/pair/start
```

iPhone 连上 F50 Wi-Fi，允许 AirSIM 本地网络权限，在 Bonjour 自动发现列表中选择设备，输入限时配对码。R21 会拒绝手动 IP 配对。内部 7580、7581、8575 应绑定回环，LAN 8580、8581、8582 应只绑定可信网段接口。分别验证来电、呼出、两端人声、挂断释放及 Bark 短信回归。空闲音频自检不替代真实通话，锁屏可靠性单独验收。

### 保留局域网短信

Bark 使用系统原有 SMS 路径，各模式均保留。若还希望 AirSIM 在纯局域网模式读取本机短信，可在部署根创建空文件 `local-sms.enabled`，设备空闲时重启 AirSIM 服务。该选项会在 AirSIM 私有命名空间中保留原生短信读取和发送工具。先核对当前 mu300-linux 的工具版本，再用测试短信验收。删除标记并重启服务可恢复隔离。云端模式始终隔离 AirSIM 的短信入口。

## 5. 公网访问

按 [公网 TLS 直连与自建 Relay](PUBLIC.md) 选择部署方式。TLS 直连使用配对、控制、音频三个入口；Relay 通过 HTTPS/WSS 工作，首次局域网配对仍使用 Bonjour。

## 回滚

```sh
/etc/init.d/airsim-f50 stop
/etc/init.d/airsim-f50 disable
/etc/init.d/airsim-f50-reserve disable
```

在空闲时受控重启以释放内存保留模块。热点失联时用事先确认的 USB 恢复入口执行同一流程。恢复后检查热点、移动数据和 Bark。配对凭据仅保留在私有备份中。
