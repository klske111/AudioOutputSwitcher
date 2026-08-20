# 声音输出切换器

一款原生 macOS 菜单栏应用，用类似 Windows `Win + P` 的方式快速切换声音输出设备。

![应用图标](Resources/AppIcon-1024.png)

## 功能

- 按住 `Option`，连续按 `V` 预览输出设备，松开 `Option` 应用选择
- 菜单栏直接查看并切换所有声音输出设备
- 菜单栏滑块调节当前设备音量，并实时同步键盘和耳机端的音量变化
- 根据 AirPods、头戴式耳机、MacBook 扬声器和显示器显示不同菜单栏图标
- 登录时自动启动
- 防止 AirPods 在切换后重新抢占默认输出
- 针对网易云音乐从 AirPods 切出后暂停的问题，检测并调用网易云自身的播放菜单恢复播放

## 安装

从仓库的 Releases 页面下载 `AudioOutputSwitcher-1.5.0.zip`，解压后把应用拖入“应用程序”文件夹。

首次运行时，如果 macOS 阻止打开，请按住 `Control` 点按应用并选择“打开”。

网易云自动续播需要“系统设置 → 隐私与安全性 → 辅助功能”权限。该权限只用于在网易云因 AirPods 路由变化而暂停时触发其自身的“控制 → 播放”菜单。

## 从源码构建

要求：

- macOS 13 或更高版本
- Apple Silicon Mac
- Xcode Command Line Tools

运行：

```bash
./scripts/build.sh
```

构建结果位于 `dist/AudioOutputSwitcher.app` 和 `dist/AudioOutputSwitcher.zip`。

## 项目结构

- `Sources/AudioOutputSwitcher.swift`：应用源码
- `Resources/AppIcon.icns`：应用图标
- `App/Info.plist`：应用信息
- `scripts/build.sh`：本地构建及打包脚本

## 说明

应用通过 CoreAudio 切换系统默认输出设备。网易云恢复逻辑使用 macOS 辅助功能接口，并以 MediaRemote 作为无权限时的兼容回退；未来系统或网易云版本变化时可能需要调整。

