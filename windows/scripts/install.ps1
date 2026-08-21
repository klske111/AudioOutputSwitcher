$ErrorActionPreference = "Stop"
$packageDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceExe = Join-Path $packageDir "AudioOutputSwitcher.exe"
$installDir = Join-Path $env:LOCALAPPDATA "AudioOutputSwitcher"
$targetExe = Join-Path $installDir "AudioOutputSwitcher.exe"
$desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "声音输出切换器.lnk"
$startupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "声音输出切换器.lnk"

if (-not (Test-Path -LiteralPath $sourceExe)) {
    throw "安装包中缺少 AudioOutputSwitcher.exe。"
}

Get-Process AudioOutputSwitcher -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -LiteralPath $sourceExe -Destination $targetExe -Force
Copy-Item -LiteralPath (Join-Path $packageDir "uninstall.ps1") -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $packageDir "卸载声音输出切换器.cmd") -Destination $installDir -Force

$shell = New-Object -ComObject WScript.Shell
foreach ($shortcutPath in @($desktopShortcut, $startupShortcut)) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $targetExe
    $shortcut.WorkingDirectory = $installDir
    $shortcut.IconLocation = "$targetExe,0"
    $shortcut.Description = "声音输出切换器 - Alt+V"
    $shortcut.Save()
}

Start-Process -FilePath $targetExe
Write-Host "安装完成：$installDir"

