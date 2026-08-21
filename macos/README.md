# macOS 版

原生 Swift/AppKit 菜单栏应用。

## 使用

- 按住 `Option`，每按一次 `V` 预览下一个输出设备
- 松开 `Option` 应用选择
- 点击菜单栏图标可直接切换设备或调节音量
- 通过 CoreAudio 的传输及终端类型自动识别显示器、耳机、AirPods、AirPlay、内置和虚拟设备图标
- 桌面设备切换面板采用轻微半透明外观

## 构建

要求 macOS 13 或更高版本、Apple Silicon Mac 和 Xcode Command Line Tools。

```bash
cd macos
./scripts/build.sh
```

构建结果位于 `macos/dist/AudioOutputSwitcher.app` 和 `macos/dist/AudioOutputSwitcher.zip`。

网易云自动续播需要“系统设置 → 隐私与安全性 → 辅助功能”权限。该权限只用于在音频路由变化后触发网易云音乐自身的播放菜单。
