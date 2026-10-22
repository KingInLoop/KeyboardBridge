$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$distDir = Join-Path $scriptDir "dist\win-x64"

dotnet run --project (Join-Path $scriptDir "CoreSelfTest\CoreSelfTest.csproj") `
  --configuration Release
if ($LASTEXITCODE -ne 0) { throw "Core self-test failed with exit code $LASTEXITCODE" }

dotnet publish (Join-Path $scriptDir "KeyboardBridge.csproj") `
  --configuration Release `
  --runtime win-x64 `
  --self-contained true `
  -p:PublishSingleFile=true `
  --output $distDir

$exe = Join-Path $distDir "KeyboardBridge.exe"
& $exe --self-test
if ($LASTEXITCODE -ne 0) { throw "Self-test failed with exit code $LASTEXITCODE" }

& $exe --input-self-test
if ($LASTEXITCODE -ne 0) { throw "Input self-test failed with exit code $LASTEXITCODE" }

Write-Host "Built: $exe"

