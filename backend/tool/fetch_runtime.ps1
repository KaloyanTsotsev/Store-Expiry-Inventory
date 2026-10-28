param([ValidateSet('windows_amd64','linux_arm64')][string]$Platform = 'windows_amd64')
$ErrorActionPreference = 'Stop'
$version = '0.40.4'
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$destination = Join-Path $projectRoot "build/backend-v2/downloads/$Platform"
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$asset = "pocketbase_${version}_${Platform}.zip"
$base = "https://github.com/pocketbase/pocketbase/releases/download/v$version"
$archive = Join-Path $destination $asset
$checksums = Join-Path $destination 'checksums.txt'
Invoke-WebRequest "$base/$asset" -OutFile $archive
Invoke-WebRequest "$base/checksums.txt" -OutFile $checksums
$entry = @(Get-Content -LiteralPath $checksums | Where-Object { $_ -match ("\s+\*?" + [regex]::Escape($asset) + '$') })
if ($entry.Count -ne 1) { throw 'Missing or ambiguous official checksum' }
$expected = ($entry[0] -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expected -ne $actual) { throw 'SHA256 mismatch; do not execute this archive' }
# Extract only to the workspace build directory, never a server directory.
$binaryDirectory = Join-Path $destination 'bin'
Expand-Archive -LiteralPath $archive -DestinationPath $binaryDirectory -Force
Write-Output "Verified PocketBase $version $Platform SHA256=$actual"
Write-Output "Runtime directory: $binaryDirectory"
