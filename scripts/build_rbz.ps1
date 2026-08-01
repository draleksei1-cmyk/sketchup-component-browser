[CmdletBinding()]
param(
  [string]$OutputDirectory,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSScriptRoot
$packageName = 'component_library_browser'
$loaderName = 'component_library_browser.rb'
$loader = Join-Path $root $loaderName
$packageRoot = Join-Path $root $packageName
$versionFile = Join-Path $packageRoot 'VERSION'

if (-not (Test-Path -LiteralPath $loader -PathType Leaf)) { throw "Missing extension loader: $loader" }
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { throw "Missing package VERSION: $versionFile" }
foreach ($required in 'icons', 'ui', 'tools', 'services') {
  if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $required) -PathType Container)) {
    throw "Missing required package directory: $required"
  }
}

$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ($version -notmatch '^\d+\.\d+(\.\d+)?([+-][0-9A-Za-z.-]+)?$') { throw "Invalid VERSION: '$version'" }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$artifactName = "component-library-browser-$version.rbz"
$artifact = Join-Path $OutputDirectory $artifactName
$manifest = "$artifact.sha256"
$tempArtifact = Join-Path ([IO.Path]::GetTempPath()) ("clb-rbz-" + [guid]::NewGuid().ToString('N') + '.rbz')

$files = @($loader) + @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File | ForEach-Object { $_.FullName })
$entries = @(
  $files | ForEach-Object {
    $full = [IO.Path]::GetFullPath($_)
    $relative = $full.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)') { throw "Unsafe package path: $relative" }
    [pscustomobject]@{ FullName = $full; Relative = $relative }
  } | Sort-Object Relative
)

if (@($entries | Where-Object { $_.Relative -eq $loaderName }).Count -ne 1) { throw 'RBZ must contain exactly one extension loader.' }
if (-not ($entries.Relative -contains "$packageName/VERSION")) { throw 'RBZ must contain package VERSION.' }

try {
  $stream = [IO.File]::Open($tempArtifact, [IO.FileMode]::CreateNew)
  try {
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
      foreach ($item in $entries) {
        $entry = $zip.CreateEntry($item.Relative, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]([IO.File]::GetLastWriteTimeUtc($item.FullName))
        $entryStream = $entry.Open()
        try {
          $input = [IO.File]::OpenRead($item.FullName)
          try { $input.CopyTo($entryStream) } finally { $input.Dispose() }
        } finally { $entryStream.Dispose() }
      }
    } finally { $zip.Dispose() }
  } finally { $stream.Dispose() }

  if (Test-Path -LiteralPath $artifact) { Remove-Item -LiteralPath $artifact -Force }
  Move-Item -LiteralPath $tempArtifact -Destination $artifact
  $sha256 = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content -LiteralPath $manifest -Value "$sha256  $artifactName" -NoNewline -Encoding ascii

  if ($SelfTest) {
    $read = [IO.Compression.ZipFile]::OpenRead($artifact)
    try {
      $paths = @($read.Entries | ForEach-Object { $_.FullName })
      if (@($paths | Where-Object { $_ -eq $loaderName }).Count -ne 1) { throw 'Self-check: loader count is invalid.' }
      if ($paths -notcontains "$packageName/VERSION") { throw 'Self-check: VERSION is missing.' }
      if ($paths | Where-Object { $_ -match '(^|/)\.\.(/|$)|^/|^[A-Za-z]:' }) { throw 'Self-check: archive has unsafe path.' }
    } finally { $read.Dispose() }
  }

  Write-Host "RBZ: $artifact"
  Write-Host "SHA256: $sha256"
  Write-Host "Manifest: $manifest"
} finally {
  if (Test-Path -LiteralPath $tempArtifact) { Remove-Item -LiteralPath $tempArtifact -Force }
}
