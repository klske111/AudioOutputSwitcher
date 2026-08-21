$ErrorActionPreference = "Stop"
$installDir = Join-Path $env:LOCALAPPDATA "AudioOutputSwitcher"
$desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "声音输出切换器.lnk"
$startupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "声音输出切换器.lnk"

Get-Process AudioOutputSwitcher -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($shortcutPath in @($desktopShortcut, $startupShortcut)) {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
}

if (Test-Path -LiteralPath $installDir) {
    $escapedInstallDir = $installDir.Replace("'", "''")
    $cleanup = "Start-Sleep -Milliseconds 700; Remove-Item -LiteralPath '$escapedInstallDir' -Recurse -Force"
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile", "-Command", $cleanup
}
Write-Host "卸载完成。"

