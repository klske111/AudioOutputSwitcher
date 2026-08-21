param(
    [string]$Version = "2.0.0"
)

$ErrorActionPreference = "Stop"
$windowsRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $windowsRoot "src\AudioOutputSwitcher.cs"
$icon = Join-Path $windowsRoot "assets\AudioOutputSwitcher.ico"
$dist = Join-Path $windowsRoot "dist"
$packageName = "AudioOutputSwitcher-Windows-x64-$Version"
$packageDir = Join-Path $dist $packageName
$archive = Join-Path $dist "$packageName.zip"

if (Test-Path -LiteralPath $dist) {
    Remove-Item -LiteralPath $dist -Recurse -Force
}
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

$compiler = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64" -Filter csc.exe -Recurse |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $compiler) {
    throw "找不到 .NET Framework C# 编译器。"
}

$exe = Join-Path $packageDir "AudioOutputSwitcher.exe"
& $compiler /nologo /target:winexe /optimize+ /platform:x64 "/win32icon:$icon" "/out:$exe" `
    /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll `
    /reference:System.Windows.Forms.dll $source
if ($LASTEXITCODE -ne 0) {
    throw "编译失败，退出代码：$LASTEXITCODE"
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot "install.ps1") -Destination $packageDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "uninstall.ps1") -Destination $packageDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "安装声音输出切换器.cmd") -Destination $packageDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "卸载声音输出切换器.cmd") -Destination $packageDir
Copy-Item -LiteralPath (Join-Path $windowsRoot "使用说明.txt") -Destination $packageDir

Compress-Archive -LiteralPath $packageDir -DestinationPath $archive -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$archive.sha256" -Value "$hash  $(Split-Path -Leaf $archive)" -Encoding ASCII

Write-Host "Built: $exe"
Write-Host "Archive: $archive"
Write-Host "SHA-256: $hash"

