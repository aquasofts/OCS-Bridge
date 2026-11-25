param([string]$Flutter = '', [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Flutter) {
    $localFlutter = Join-Path $projectRoot '.tooling/flutter/bin/flutter.bat'
    if (Test-Path -LiteralPath $localFlutter) { $Flutter = $localFlutter }
    else { $Flutter = (Get-Command flutter -ErrorAction Stop).Source }
}
$flutterRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path $Flutter) '..'))
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
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
        $nativeBuild = Join-Path $buildAlias ('build/native-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $vsVersion = & $vswhere -latest -products '*' -property installationVersion
        $generator = if ($vsVersion.StartsWith('18.')) { 'Visual Studio 18 2026' } else { 'Visual Studio 17 2022' }
        cmake -S windows -B $nativeBuild -G $generator -A x64
        if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed' }
        cmake --build $nativeBuild --config Release --target flutter_assemble
        if ($LASTEXITCODE -ne 0) { throw 'Flutter asset assembly failed' }
        $wrapper = Join-Path $ephemeral 'cpp_client_wrapper'
        New-Item -ItemType Directory -Path $wrapper -Force | Out-Null
        Copy-Item -Path (Join-Path $engine 'windows-x64/cpp_client_wrapper/*') -Destination $wrapper -Recurse -Force
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
    $vsInstall = & $vswhere -latest -products '*' -property installationPath
    $redistVersion = Get-ChildItem -LiteralPath (Join-Path $vsInstall 'VC/Redist/MSVC') -Directory |
        Where-Object Name -Match '^\d+\.\d+\.\d+$' | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $crt = Get-ChildItem -LiteralPath (Join-Path $redistVersion.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' | Select-Object -First 1
    foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
        Copy-Item -LiteralPath (Join-Path $crt.FullName $dll) -Destination $destination
    }
    $pythonVersion = '3.13.17'
    $pythonFile = "python-$pythonVersion-embed-amd64.zip"
    $pythonArchive = Join-Path $projectRoot "build/$pythonFile"
    if (-not (Test-Path -LiteralPath $pythonArchive)) {
        Invoke-WebRequest "https://www.python.org/ftp/python/$pythonVersion/$pythonFile" -OutFile $pythonArchive
    }
    if ((Get-FileHash -LiteralPath $pythonArchive -Algorithm SHA256).Hash -ne '9e35319bffedab8b36ad44d8f377cb4f1733bcec257a0b6d04d94f01486ddb38') {
        throw 'Embedded Python SHA-256 mismatch'
    }
    $pythonDirectory = Join-Path $destination 'python'
    Expand-Archive -LiteralPath $pythonArchive -DestinationPath $pythonDirectory
    $mathWheels = @(
        @{
            Name = 'sympy-1.14.0-py3-none-any.whl'
            Url = 'https://files.pythonhosted.org/packages/a2/09/77d55d46fd61b4a135c444fc97158ef34a095e5681d0a6c10b75bf356191/sympy-1.14.0-py3-none-any.whl'
            Hash = 'E091CC3E99D2141A0BA2847328F5479B05D94A6635CB96148CCB3F34671BD8F5'
        }
        @{
            Name = 'mpmath-1.3.0-py3-none-any.whl'
            Url = 'https://files.pythonhosted.org/packages/43/e3/7d92a15f894aa0c9c4b49b8ee9ac9850d6e63b03c9c32c0367a13ae62209/mpmath-1.3.0-py3-none-any.whl'
            Hash = 'A0B2B9FE80BBCD81A6647FF13108738CFB482D481D826CC0E02F5B35E5C88D2C'
        }
    )
    foreach ($wheel in $mathWheels) {
        $wheelPath = Join-Path $projectRoot ('build/' + $wheel.Name)
        if (-not (Test-Path -LiteralPath $wheelPath)) {
            Invoke-WebRequest $wheel.Url -OutFile $wheelPath
        }
        if ((Get-FileHash -LiteralPath $wheelPath -Algorithm SHA256).Hash -ne $wheel.Hash) {
            throw "Python wheel SHA-256 mismatch: $($wheel.Name)"
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($wheelPath, $pythonDirectory)
    }
    Compress-Archive -Path (Join-Path $destination '*') -DestinationPath ($destination + '.zip')
    Write-Output ($destination + '.zip')
} finally {
    Pop-Location
    # Preserve the directory link referenced by generated CMake project files.
}
