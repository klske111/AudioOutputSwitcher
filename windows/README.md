# Windows 版

原生 C# / WinForms 托盘应用，无第三方运行库。

## 使用

- 按住 `Alt`，每按一次 `V` 预览下一个输出设备
- 松开 `Alt` 应用选择
- 点击托盘图标可直接切换设备或调节音量
- 点击浮层外任意位置自动隐藏

安装包会把程序放到 `%LOCALAPPDATA%\AudioOutputSwitcher`，创建桌面及开机启动快捷方式。

## 构建

要求 Windows 10/11 和系统自带的 .NET Framework C# 编译器。

```powershell
.\windows\scripts\build.ps1 -Version 2.0.0
```

构建结果位于 `windows/dist/`。

## 源码

- `src/AudioOutputSwitcher.cs`：托盘、快捷键、Core Audio 和界面实现
- `assets/AudioOutputSwitcher.ico`：应用图标
- `scripts/build.ps1`：编译并生成 ZIP 发布包
- `scripts/install.ps1`：本机安装和快捷方式创建
- `scripts/uninstall.ps1`：卸载程序与快捷方式

