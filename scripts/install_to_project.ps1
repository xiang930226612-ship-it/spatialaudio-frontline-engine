param(
  [Parameter(Mandatory=$true)][string]$TargetRoot,
  [switch]$WithReferenceClientMain
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
function Copy-One($relFrom, $relTo=$relFrom) {
  $src = Join-Path $RepoRoot $relFrom
  $dst = Join-Path $TargetRoot $relTo
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
  Copy-Item -LiteralPath $src -Destination $dst -Force
  Write-Host "copied $relTo"
}
Copy-One 'runtime\libc\SpatialAudio.dll' 'libc\SpatialAudio.dll'
Copy-One 'runtime\libc\phonon.dll' 'libc\phonon.dll'
Copy-One 'lua\resources\script\module\frontline\SpatialAudioAdapter.lua' 'resources\script\module\frontline\SpatialAudioAdapter.lua'
Copy-One 'lua\resources\script\module\frontline\SpatialAudioTuning.lua' 'resources\script\module\frontline\SpatialAudioTuning.lua'
Copy-One 'lua\server\frontline\client\SpatialAudioAdapter.lua' 'server\frontline\client\SpatialAudioAdapter.lua'
Copy-One 'lua\server\frontline\client\SpatialAudioTuning.lua' 'server\frontline\client\SpatialAudioTuning.lua'
Copy-One 'assets\audio\frontline\navigation\beep.wav' 'audio\frontline\navigation\beep.wav'
Copy-One 'assets\csv\frontline.csv' 'csv\frontline.csv.reference'
if($WithReferenceClientMain) {
  Copy-One 'lua\resources\script\module\frontline\ClientMain.reference.lua' 'resources\script\module\frontline\ClientMain.lua'
  Copy-One 'lua\server\frontline\client\ClientMain.reference.lua' 'server\frontline\client\ClientMain.lua'
} else {
  Write-Host 'ClientMain reference files were not overwritten. Merge them manually, then rebuild ClientMain.lc for standalone client.'
}
