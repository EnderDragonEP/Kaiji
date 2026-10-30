<#
Build Kaiji:
  .\build.ps1 [args]          dist\Kaiji\Kaiji.exe; args go to PyInstaller (needs: pip install pyinstaller)
  .\build.ps1 android [args]  dist\Kaiji-release.apk, the Android app; args go to flutter build apk,
                              e.g. --split-per-abi (needs Flutter and the Android SDK, see Kaiji.Mobile\README.md)
  .\build.ps1 all             both
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$argv = @($args)

function Build-Exe([string[]]$extra) {
    python Kaiji.Windows\tools\make_ico.py build\Kaiji.ico
    if ($LASTEXITCODE) { throw "Couldn't make the icon" }
    # kaiji_app lives in Kaiji.Windows; psycopg loads its libpq from psycopg_binary, which
    # PyInstaller only finds when told
    $env:PYTHONPATH = "$here\Kaiji.Windows;$env:PYTHONPATH"
    # The widget library's optional blur imports SciPy, Pillow and NumPy (Kaiji doesn't use it),
    # and SciPy in turn reaches an installed PyTorch: left in, they'd make the exe gigabytes.
    $unused = 'numpy', 'scipy', 'PIL', 'colorthief', 'torch', 'tkinter'
    pyinstaller --noconfirm --windowed --name Kaiji --icon "$here\build\Kaiji.ico" `
        --collect-submodules kaiji_app --collect-all psycopg_binary `
        --exclude-module PySide6.QtWebEngineCore --exclude-module PySide6.QtQuick `
        @($unused | ForEach-Object { '--exclude-module', $_ }) `
        @extra Kaiji.Windows\Kaiji.pyw
    if ($LASTEXITCODE) { throw "PyInstaller failed" }
}

function Build-Apk([string[]]$extra) {
    # Flutter from PATH, or from %USERPROFILE%\flutter (where it was installed for Kaiji)
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        $env:PATH = "$env:USERPROFILE\flutter\bin;$env:PATH"
    }
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        throw "Flutter isn't on PATH: see Kaiji.Mobile\README.md"
    }
    $out = "$here\Kaiji.Mobile\build\app\outputs\flutter-apk"
    # clear out earlier APKs, so only what this build makes goes to dist
    Remove-Item "$out\app-*.apk" -ErrorAction SilentlyContinue
    Push-Location "$here\Kaiji.Mobile"
    try {
        flutter build apk @extra
        if ($LASTEXITCODE) { throw "flutter build apk failed" }
    } finally {
        Pop-Location
    }
    New-Item -ItemType Directory -Force dist | Out-Null
    # app-release.apk -> dist\Kaiji-release.apk, app-arm64-v8a-release.apk -> dist\Kaiji-arm64-v8a-release.apk
    foreach ($apk in Get-ChildItem "$out\app-*.apk") {
        $name = "Kaiji-" + $apk.Name.Substring(4)
        Copy-Item $apk.FullName "dist\$name" -Force
        Write-Host "Copied to dist\$name"
    }
}

# the environment changes above stay in this build, not in your session
$saved = @{ PATH = $env:PATH; PYTHONPATH = $env:PYTHONPATH }
Push-Location $here
try {
    switch ($argv[0]) {
        'android' { Build-Apk @($argv | Select-Object -Skip 1) }
        'all' { Build-Exe @(); Build-Apk @() }
        default { Build-Exe $argv }
    }
} finally {
    Pop-Location
    $env:PATH = $saved.PATH
    $env:PYTHONPATH = $saved.PYTHONPATH
}
