param([string]$Flutter = '', [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Flutter) {
    $localFlutter = Join-Path $projectRoot '.tooling/flutter/bin/flutter.bat'
    if (Test-Path -LiteralPath $localFlutter) { $Flutter = $localFlutter }
    else { $Flutter = (Get-Command flutter -ErrorAction Stop).Source }
}
$flutterRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path $Flutter) '..'))
$buildAlias = Join-Path ([IO.Path]::GetTempPath()) ('ocs-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Junction -Path $buildAlias -Target $projectRoot | Out-Null
Push-Location -LiteralPath $buildAlias
try {
    if ($flutterRoot.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $flutterRoot = $buildAlias + $flutterRoot.Substring($projectRoot.Length)
        $Flutter = Join-Path $flutterRoot 'bin/flutter.bat'
    }
    $env:PUB_CACHE = Join-Path $buildAlias '.tooling/pub-cache'
    $env:CI = 'true'
    & $Flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'pub get failed' }
    if (-not $SkipTests) {
        & $Flutter test
        if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
    }
    & $Flutter build windows --release
    $bundle = Join-Path $buildAlias 'build/windows/x64/runner/Release'
    if ($LASTEXITCODE -ne 0) {
        $engine = Join-Path $flutterRoot 'bin/cache/artifacts/engine'
        $ephemeral = Join-Path $buildAlias 'windows/flutter/ephemeral'
        Copy-Item -Path (Join-Path $engine 'windows-x64-release/flutter*') -Destination $ephemeral -Force
        Copy-Item -LiteralPath (Join-Path $engine 'windows-x64/icudtl.dat') -Destination $ephemeral -Force
        Copy-Item -Path (Join-Path $engine 'windows-x64/cpp_client_wrapper/*') -Destination (Join-Path $ephemeral 'cpp_client_wrapper') -Recurse -Force
        $nativeBuild = Join-Path $buildAlias ('build/native-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        $vsVersion = & $vswhere -latest -products '*' -property installationVersion
        $generator = if ($vsVersion.StartsWith('18.')) { 'Visual Studio 18 2026' } else { 'Visual Studio 17 2022' }
        cmake -S windows -B $nativeBuild -G $generator -A x64
        if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed' }
        cmake --build $nativeBuild --config Release --target INSTALL --parallel 6
        if ($LASTEXITCODE -ne 0) { throw 'Native build failed' }
        $bundle = Join-Path $nativeBuild 'runner/Release'
    }
    $destination = Join-Path $projectRoot ('dist/OCS-Bridge-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Get-ChildItem -LiteralPath $bundle -File | Where-Object {
        $_.Extension -in '.exe', '.dll' -or $_.Name -eq 'native_assets.json'
    } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $destination -Force }
    Copy-Item -LiteralPath (Join-Path $bundle 'data') -Destination $destination -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot 'README.md') -Destination $destination
    Compress-Archive -Path (Join-Path $destination '*') -DestinationPath ($destination + '.zip')
    Write-Output ($destination + '.zip')
} finally {
    Pop-Location
    # Preserve the directory link referenced by generated CMake project files.
}
