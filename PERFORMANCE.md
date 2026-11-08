# 通话音频等待精度修复

2026-11-08 在 F50 上确认默认 sleep 拒绝小数秒，usleep 也不可用。音频脚本的 nap 因而把 0.1 秒或 0.5 秒等待向上取整到 1 秒，影响场景启动确认、重试和退出等待。设备已有的 /opt/mu300/bin/busybox 支持小数秒。

scripts/f50-sleep.sh 把等待交给该静态 BusyBox。把它保存为 /mnt/mu300-disk/extra/airsim-f50/bin/sleep 并设为 0700，AirSIM 的既有 PATH 会优先使用它。先执行 /opt/mu300/bin/busybox sleep 0.01 确认设备支持。音频模块和内核保持原有构建。

## 安装和回滚

在设备空闲时，将脚本放到私有临时路径，运行 sh -n 检查，然后原子移动到上述 bin/sleep 路径。目录和文件应由 root 拥有。

```sh
root=/mnt/mu300-disk/extra/airsim-f50
sh -n "$root/bin/sleep.next"
/opt/mu300/bin/busybox sleep 0.01
chmod 700 "$root/bin/sleep.next"
mv "$root/bin/sleep.next" "$root/bin/sleep"
```

回滚时在空闲状态删除本次添加的 bin/sleep。修改供 AirSIM 使用的私有目录即可，无需替换系统 sleep。

## 已测结果

| 项目 | 修复前 | 修复后 |
|---|---|---|
| 0.1 秒请求 | 默认 sleep 拒绝，音频脚本走整秒 fallback | 0.10 秒 |
| 1 秒空闲双向 PCM 自检总耗时 | 3.25 秒 | 2.44 秒 |
| 自检后四个 PCM 端点 | closed | closed |
| 内核异常标记 | 0 | 0 |

自检总耗时缩短约 25%，包含启动、固定 1 秒的媒体自检和退出。该结果来自单次前后比较，真实呼出、接听和两端挂断的延迟仍需分别测量。更新后基带状态、音频设备和云端命令通道检查正常。

同时评估过将 Agent 轮询从 1 秒改为 500 毫秒。候选代码通过 Go race 测试和 vet，但实际云端命令连接未通过上线检查，因此设备恢复使用原 Agent。当前生效的修复只有等待精度修复。候选 Agent 未纳入本次发布。

上游音频修复在 mu300-voice 的 nap 选择流程中增加静态 BusyBox fallback。配套测试模拟默认 sleep 仅支持整秒、没有 usleep 的环境，确认 0.1 和 0.5 秒请求完整传给静态 BusyBox。
