param(
  [string]$Configuration = "Release",
  [string]$Platform = "x86",
  [string]$OutputDir = ""
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir = Join-Path $RepoRoot 'src'
if([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = Join-Path $RepoRoot 'runtime\libc' }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Find-VcVars {
  $candidates = @(
    'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat',
    'C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvarsall.bat'
  )
  foreach($c in $candidates){ if(Test-Path -LiteralPath $c){ return $c } }
  $found = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvarsall.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
  if($found){ return $found.FullName }
  return $null
}

$Steam = $env:STEAMAUDIO_SDK_DIR
$Miniaudio = $env:MINIAUDIO_DIR
$STBVorbis = $env:STB_VORBIS_DIR
if(-not $Steam) { $Steam = Join-Path $RepoRoot 'third_party\steamaudio' }
if(-not $Miniaudio) { $Miniaudio = Join-Path $RepoRoot 'third_party\miniaudio' }
if(-not $STBVorbis) { $STBVorbis = Join-Path $RepoRoot 'third_party\stb_vorbis' }

if(-not $Steam -or -not (Test-Path (Join-Path $Steam 'include\phonon.h')) -or -not (Test-Path (Join-Path $Steam 'lib\windows-x86\phonon.lib'))) {
  Write-Host 'SteamAudio SDK x86 not found. Set STEAMAUDIO_SDK_DIR to SDK root containing include\phonon.h and lib\windows-x86\phonon.lib.'
  exit 3
}
if(-not $Miniaudio -or -not (Test-Path (Join-Path $Miniaudio 'miniaudio.h'))) {
  Write-Host 'miniaudio not found. Set MINIAUDIO_DIR to the directory containing miniaudio.h.'
  exit 4
}
if($STBVorbis -and -not (Test-Path (Join-Path $STBVorbis 'stb_vorbis.c'))) {
  Write-Host 'STB_VORBIS_DIR was set, but stb_vorbis.c was not found in it.'
  exit 5
}

$vcvars = Find-VcVars
if(-not $vcvars){ Write-Host 'MSVC x86 toolchain not found'; exit 2 }

Copy-Item -LiteralPath (Join-Path $Steam 'lib\windows-x86\phonon.dll') -Destination (Join-Path $OutputDir 'phonon.dll') -Force
$stbInclude = if($STBVorbis) { " /I`"$STBVorbis`"" } else { "" }
$defines = '/DWIN32 /DSPATIAL_AUDIO_BUILD'
$cmd = "`"$vcvars`" x86 && cd /d `"$SrcDir`" && cl /nologo /std:c++17 /EHsc $defines /I`"$Steam\include`" /I`"$Miniaudio`"$stbInclude /LD SpatialAudio.cpp /Fe:`"$(Join-Path $OutputDir 'SpatialAudio.dll')`" /link /NOLOGO /MACHINE:X86 /LIBPATH:`"$Steam\lib\windows-x86`" phonon.lib ole32.lib winmm.lib"
Write-Host $cmd
cmd /c $cmd
if($LASTEXITCODE -ne 0){ exit $LASTEXITCODE }
Write-Host "Built SpatialAudio Lua module: $(Join-Path $OutputDir 'SpatialAudio.dll')"
Write-Host 'Expected public export: luaopen_SpatialAudio only.'

