# OpenDisplay for iOS 12

把运行 **iOS 12** 的老 iPad（如 iPad Air 一代、iPad mini 2/3）变成 Mac 的扩展显示器。

这是 [OpenDisplay](https://github.com/peetzweg/opendisplay) 接收端的非官方移植版。官方 iPad 端要求 iPadOS 15 以上，并且用 SwiftUI 编写；本项目按官方公开的 [线路协议](https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md)（pv 3）用 Objective-C + UIKit 重新实现了接收端，Mac 端直接使用**官方 OpenDisplay 应用**，无需修改。

> 与 OpenDisplay 官方项目无关联，问题请不要反馈到官方仓库。

## 功能

- USB（经 usbmuxd）和 WiFi（Bonjour `_opensidecar._tcp`）两种连接
- H.264 硬件解码显示（`AVSampleBufferDisplayLayer`）
- 单指触摸 → 点击 / 拖动，双指 → 滚动
- 鼠标光标叠加显示；WiFi 下光标走 UDP 旁路通道（协议 §6.3）
- 握手、心跳、时钟同步、关键帧恢复、旋转时重发 `hello`
- 三指轻点打开设置菜单：
  - 画质：标准 1600×1200 / 原生 2048×1536（原生仅 USB）
  - WiFi 平滑播放（抖动缓冲）：关闭 / 60 ms / 100 ms
  - 性能信息叠加：帧率、端到端延迟、触摸延迟、解码积压
  - 仅 USB 连接：停止 Bonjour 广播并拒绝 WiFi 连接（官方 Mac 端拔线后会自动切到 WiFi，且没有开关可关）

## 实测（iPad Air 一代，A7，iOS 12.5.8）

| 连接 | 分辨率 | 端到端延迟（中位 / P95） |
|---|---|---|
| USB | 1536×2048 @ 60 fps | ~10 ms / ~14 ms |
| WiFi 5 GHz（Mac 端 Balanced） | 1152×1536 | ~12 ms / ~85 ms |

USB 体验最好。WiFi 下偶发 60–110 ms 的延迟尖峰，排查下来来自 Mac 一侧的无线网卡（疑似 AWDL），接收端无法消除。

## 要求

- **设备**：iOS 12.2 及以上的 arm64 iPad（A7 起）
- **越狱 + [AppSync Unified](https://github.com/akemin-dayo/AppSync)**：应用使用临时签名（ad-hoc），需要 AppSync 才能安装
- **Mac**：官方 [OpenDisplay](https://opendisplay.app/) 发送端（macOS 14+）
- **编译**：Xcode（已用 Xcode 27.1 / iOS 27.1 SDK 验证）、[libimobiledevice](https://libimobiledevice.org/)（提供 `ideviceinstaller`）

```sh
brew install libimobiledevice ideviceinstaller
```

## 编译与安装

```sh
./build.sh            # 编译，生成 build/OpenDisplay12.ipa
./build.sh install    # 编译并通过 USB 安装到已连接的设备
```

不需要 Xcode 工程，`build.sh` 直接调用 `clang` 编译、打包并做 ad-hoc 签名。

### 部署目标必须 ≥ iOS 12.2

新版 SDK 的 `CoreMedia.tbd` 里有一条 `$ld$previous$@rpath/libswiftCoreMedia.dylib$$2$7.0$12.2$$` 指令：部署目标低于 12.2 时，CoreMedia 会被链接到一个 iOS 12 上不存在的 `@rpath/libswiftCoreMedia.dylib`，应用启动即崩溃。所以 `-mios-version-min` 定为 12.2。

## 使用

1. 在 iPad 上打开 OpenDisplay，屏幕会提示等待连接
2. 用数据线连到 Mac，或让两者处于同一 WiFi
3. Mac 菜单栏的 OpenDisplay 里选择这台 iPad
4. 首次使用时，macOS 会要求授予「屏幕录制」和「辅助功能」权限

建议：USB 下 Mac 端画质选 **Best**、iPad 端选**原生画质**；WiFi 下 Mac 端选 **Balanced** 或 **Fast**。

## 代码结构

| 文件 | 说明 |
|---|---|
| `src/ODServer.m` | 协议实现：TCP 9000 监听、Bonjour、分帧与 JSON/视频分流、控制消息、UDP 光标通道、H.264 Annex B → AVCC、抖动缓冲、统计 |
| `src/ODVideoView.m` | 画面、光标、状态文字，触摸到协议坐标的转换 |
| `src/main.m` | 应用入口、设置菜单、前后台切换（发送 `sleeping` / 重新监听） |
| `build.sh` | 编译、打包、签名、安装 |

## 已知限制

- 不支持 Apple Pencil（`pencil` / `proximity` 消息）
- 只支持 H.264（A7 没有 HEVC 硬解）
- 未实现 `power` 关机动作（iOS 不允许）

## 许可

[GPL-3.0](LICENSE)。应用图标来自 OpenDisplay 官方项目（GPL-3.0）。
