[CmdletBinding()]
param(
  [string]$ChromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$icons = Join-Path $root 'component_library_browser\icons'
$main = Get-Content -Raw (Join-Path $root 'component_library_browser\main.rb')
$names = [regex]::Matches($main, "icon_prefix:\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

if (-not (Test-Path -LiteralPath $ChromePath)) {
  throw "SVG renderer was not found at '$ChromePath'. Install Chrome or rerun with -ChromePath <path>."
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("clb-icons-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
  foreach ($name in $names) {
    $svg = Join-Path $icons "$name.svg"
    if (-not (Test-Path -LiteralPath $svg)) { throw "Missing SVG source: $svg" }
    foreach ($size in 16, 24) {
      $page = Join-Path $work "$name-$size.html"
      $svgUrl = ([Uri]$svg).AbsoluteUri
      @"
<!doctype html><meta charset="utf-8"><style>html,body{margin:0;width:${size}px;height:${size}px;overflow:hidden;background:transparent;color:#20242b}img{display:block;width:${size}px;height:${size}px}</style><img src="$svgUrl">
"@ | Set-Content -LiteralPath $page -Encoding utf8
      $out = Join-Path $icons "$name`_$size.png"
      $previousPreference = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      & $ChromePath --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --default-background-color=00000000 --window-size=$size,$size "--screenshot=$out" ([Uri]$page).AbsoluteUri 2>&1 | Out-Null
      $chromeExit = $LASTEXITCODE
      $ErrorActionPreference = $previousPreference
      if ($chromeExit -and $chromeExit -ne 0) { throw "Chrome SVG export failed for $name at ${size}px (exit $chromeExit)." }
      if (-not (Test-Path -LiteralPath $out)) { throw "Chrome did not create $out" }
      $bytes = [System.IO.File]::ReadAllBytes($out)
      if ($bytes.Length -lt 24 -or [Text.Encoding]::ASCII.GetString($bytes, 1, 3) -ne 'PNG') { throw "Invalid PNG output: $out" }
      $width = [System.BitConverter]::ToInt32(@($bytes[19], $bytes[18], $bytes[17], $bytes[16]), 0)
      $height = [System.BitConverter]::ToInt32(@($bytes[23], $bytes[22], $bytes[21], $bytes[20]), 0)
      if ($width -ne $size -or $height -ne $size) { throw "Wrong dimensions for ${out}: $width x $height" }
    }
  }
} finally {
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Write-Host "Exported toolbar PNG icons: $($names -join ', ')"
