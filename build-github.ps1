# Reproducible Windows build for pull requests and CI.
#
#   .\build-github.ps1
#   .\build-github.ps1 -V C:\path\to\v.exe
#
# V is resolved from -V, then $env:V, then `v` on PATH. If none is present, or
# the one found is not the pinned build, the pinned V source is fetched into
# %TEMP% and bootstrapped with gcc using V's own vc/v_win.c snapshot.
param(
    [string]$V
)

$ErrorActionPreference = 'Stop'

$VRelease = '0.5.2'
$VCommit = 'f9ebca402799a19b449d38d2b55b97a95cc33b04'
$VShort = 'f9ebca4'
$VCCommit = '3eda45e0e6d9ac3c0757dcde9ff19f3c33bd0ee6'
$VSourceUrl = "https://github.com/vlang/v/archive/$VCommit.zip"
$VCSourceUrl = "https://github.com/vlang/vc/archive/$VCCommit.zip"

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
Push-Location $root

try {
    # A build that silently drops the icon still runs, so the failure would surface
    # as a blank file icon and an empty tray days later. V embeds the resource
    # itself on Windows (vlib/v/driver/windows_icon.v, RT_GROUP_ICON id 1); windres
    # is only used for cross builds, so assert the artefact rather than a tool.
    function Assert-EmbeddedIcon([string]$exe) {
        $bytes = [IO.File]::ReadAllBytes($exe)
        $pe = [BitConverter]::ToInt32($bytes, 0x3c)
        $sections = [BitConverter]::ToUInt16($bytes, $pe + 6)
        $optSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
        $table = $pe + 24 + $optSize
        for ($i = 0; $i -lt $sections; $i++) {
            $name = [Text.Encoding]::ASCII.GetString($bytes, $table + $i * 40, 8).TrimEnd([char]0)
            if ($name -eq '.rsrc') { return }
        }
        throw "no .rsrc section in $exe - the icon was not embedded"
    }

    function Resolve-V([string]$path) {
        if ([string]::IsNullOrWhiteSpace($path)) { return $null }
        if (Test-Path $path -PathType Leaf) { return (Resolve-Path $path).Path }
        $inside = Join-Path $path 'v.exe'
        if (Test-Path $inside -PathType Leaf) { return (Resolve-Path $inside).Path }
        return $null
    }

    function Version-Matches([string]$exe) {
        try {
            $version = (& $exe version 2>&1 | Out-String).Trim()
        } catch {
            return $false
        }
        return ($version -match [regex]::Escape($VRelease)) -and
            ($version -match $VShort)
    }

    function Get-Pinned-V {
        $cache = Join-Path $env:TEMP "hexv-v-$VShort"
        $cached = Get-ChildItem -Path $cache -Filter v_pinned.exe -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cached -and (Version-Matches $cached.FullName)) {
            return $cached.FullName
        }

        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        $sourceZip = Join-Path $env:TEMP "v-$VShort-source.zip"
        if (-not (Test-Path $sourceZip)) {
            Write-Host "downloading V source $VShort"
            Invoke-WebRequest -Uri $VSourceUrl -OutFile $sourceZip
        }
        $sourceDir = Join-Path $cache 'source'
        if (-not (Test-Path $sourceDir)) {
            Expand-Archive -Path $sourceZip -DestinationPath $sourceDir -Force
        }
        $sourceRoot = Get-ChildItem -Path $sourceDir -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName 'cmd\v') } |
            Select-Object -First 1
        if (-not $sourceRoot) { throw "V source tree not found in $VSourceUrl" }

        # `vc/` is a submodule and is not present in the V source archive. The
        # vc snapshot is pinned to the same V commit and supplies v_win.c.
        $vcZip = Join-Path $env:TEMP "vc-$VShort-source.zip"
        if (-not (Test-Path $vcZip)) {
            Write-Host "downloading V vc snapshot $VShort"
            Invoke-WebRequest -Uri $VCSourceUrl -OutFile $vcZip
        }
        $vcDir = Join-Path $cache 'vc'
        if (-not (Test-Path $vcDir)) {
            Expand-Archive -Path $vcZip -DestinationPath $vcDir -Force
        }
        $vcRoot = Get-ChildItem -Path $vcDir -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName 'v_win.c') } |
            Select-Object -First 1
        if (-not $vcRoot) { throw "v_win.c not found in $VCSourceUrl" }
        $vcTarget = Join-Path $sourceRoot.FullName 'vc'
        New-Item -ItemType Directory -Force -Path $vcTarget | Out-Null
        $vcFile = Join-Path $vcTarget 'v_win.c'
        Copy-Item -Force (Join-Path $vcRoot.FullName 'v_win.c') $vcFile
        # The generated snapshot embeds the CI checkout prefix in its #include
        # lines. Make those relative to the source root before compiling.
        $vcText = [System.IO.File]::ReadAllText($vcFile)
        $vcText = $vcText.Replace('/home/runner/work/v/v/', '')
        [System.IO.File]::WriteAllText($vcFile, $vcText, (New-Object System.Text.UTF8Encoding($false)))

        # Build V's own bootstrap snapshot with gcc, then use it to compile the
        # pinned compiler. This follows makev.bat and avoids depending on an
        # older released V binary that cannot parse newer V source.
        $bootstrap = Join-Path $sourceRoot.FullName 'v_bootstrap.exe'
        Push-Location $sourceRoot.FullName
        try {
            & gcc '-DCUSTOM_DEFINE_v1_fallback' '-std=c99' '-municode' '-g' '-w' '-I.' `
                -o $bootstrap `
                'vc\v_win.c' `
                'vlib\time\ticks_windows.c' `
                'vlib\v\winthread_helper_windows.c' `
                'cmd\v\toolcache_windows_helpers.c' `
                '-ladvapi32' '-lws2_32' '-lbcrypt' '-Wl,--stack,33554432'
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

            $pinned = Join-Path $sourceRoot.FullName 'v_pinned.exe'
            & $bootstrap -cc gcc -o $pinned cmd/v
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } finally {
            Pop-Location
        }
        if (-not (Version-Matches $pinned)) {
            throw "bootstrapped compiler is not V $VRelease $VShort"
        }
        return $pinned
    }

    if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
        throw 'gcc is required: install MinGW-w64 and put gcc.exe on PATH'
    }

    $vExe = $null
    if ($V) {
        $vExe = Resolve-V $V
        if (-not $vExe) { throw "-V '$V' is neither v.exe nor a directory containing it" }
    } elseif ($env:V) {
        $vExe = Resolve-V $env:V
    }
    if (-not $vExe) {
        $onPath = Get-Command v -ErrorAction SilentlyContinue
        if ($onPath) { $vExe = $onPath.Source }
    }

    if ($vExe -and -not (Version-Matches $vExe)) {
        Write-Warning "V at $vExe is not $VRelease $VShort; using the pinned compiler"
        $vExe = $null
    }
    if (-not $vExe) { $vExe = Get-Pinned-V }

    $version = (& $vExe version 2>&1 | Out-String).Trim()
    Write-Host "V: $version ($vExe)"

    $src = Join-Path $root 'v'
    $outDir = Join-Path $src 'bin'
    $out = Join-Path $outDir 'hexv.exe'
    $icon = Join-Path $src 'hex.ico'
    if (-not (Test-Path $icon -PathType Leaf)) { throw "app icon missing: $icon" }
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    Remove-Item -Force $out -ErrorAction SilentlyContinue

    # GNU ld stamps the PE header with the current time by default. V/gcc do not
    # provide a linker flag for this, but ld honours SOURCE_DATE_EPOCH, so two
    # clean builds produce the same bytes.
    $env:SOURCE_DATE_EPOCH = '0'

    & $vExe -prod -enable-globals -cc gcc -cflags "-ffp-contract=off" -icon $icon -o $out $src
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Assert-EmbeddedIcon $out
    Write-Host "built $out"
} finally {
    Pop-Location
}
