$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$expectedRevision = '2ba94f8266e5062b0813d75949fc9d5c772e14ca'
$expectedBeforeBlob = 'f7991106dbdc8ccbd39e6cb14a8183ec2fd5a9ab'
$expectedAfterBlob = '5f319398a292bcb5f0eefdaba73c9ff6a5c237ba'

$configPath = Join-Path (Get-Location) '.dart_tool/package_config.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$packages = @($config.packages | Where-Object { $_.name -eq 'file_picker' })
if ($packages.Count -ne 1) {
  throw "Expected one file_picker package, found $($packages.Count)"
}

$rootUri = [Uri]$packages[0].rootUri
if ($rootUri.IsAbsoluteUri) {
  if (-not $rootUri.IsFile) {
    throw "Unsupported file_picker root URI: $rootUri"
  }
  $packageRoot = $rootUri.LocalPath
} else {
  $configDirectory = Split-Path -Parent $configPath
  $packageRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $configDirectory $packages[0].rootUri)
  )
}

$revision = git -C $packageRoot rev-parse HEAD
if ($revision -ne $expectedRevision) {
  throw "Unexpected file_picker revision: $revision"
}

$targetPath = Join-Path `
  $packageRoot `
  'darwin/file_picker/Sources/file_picker/IOSFilePickerHandler.swift'
$beforeBlob = git -C $packageRoot hash-object -- $targetPath
if ($beforeBlob -ne $expectedBeforeBlob) {
  throw "Unexpected file_picker iOS source before patch: $beforeBlob"
}

$patchPath = Join-Path $PSScriptRoot 'file_picker_ios.patch'
git -C $packageRoot apply --check --whitespace=nowarn $patchPath
git -C $packageRoot apply --whitespace=nowarn $patchPath

$afterBlob = git -C $packageRoot hash-object -- $targetPath
if ($afterBlob -ne $expectedAfterBlob) {
  throw "Unexpected file_picker iOS source after patch: $afterBlob"
}

Write-Host "Patched file_picker iOS source at $revision"
