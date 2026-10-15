# Install this repo into the Weasel user dir, keeping personal data.
# Usage (PowerShell, from anywhere):
#   .\windows\install.ps1 -RimeDir "D:\AppData\Rime" -DryRun    # preview
#   .\windows\install.ps1 -RimeDir "D:\AppData\Rime"            # backup, then install
# Untested on a real machine when written (authored on macOS): run with -DryRun first.
param(
  [string]$RimeDir = (Join-Path $env:APPDATA "Rime"),
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$Src = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $RimeDir)) { throw "RimeDir not found: $RimeDir" }

# 1. backup (skip the big .gram model and the build dir)
if (-not $DryRun) {
  $Backup = "$RimeDir.backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
  robocopy $RimeDir $Backup /E /XD build /XF *.gram /NFL /NDL /NJH /NJS | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "backup failed (robocopy exit $LASTEXITCODE)" }
  Write-Host "Backup: $Backup"
}

# 2. files that must never be overwritten
$xf = @("README.md","README.en.md","README.upstream.md","LICENSE","AGENTS.md",".gitignore","install.sh","recipe.yaml",
        "squirrel.yaml","squirrel.custom.yaml","rime_ice.custom.yaml","installation.yaml","user.yaml",
        "recent_words.tsv","custom_phrase.txt","user_freq.tsv",
        "ai_rerank_filter.lua","ai_rerank_processor.lua","drop_words.lua","hide_words.lua","reduce_freq_words.lua","turn_down_words.lua")
# default.custom.yaml usually holds your own schema_list: never overwrite an existing one
$existingDefault = Join-Path $RimeDir "default.custom.yaml"
if (Test-Path $existingDefault) {
  $xf += "default.custom.yaml"
  Write-Host "NOTE: kept your default.custom.yaml. Merge by hand: menu/page_size: 5 and switcher/save_options (see repo default.custom.yaml); schema_list must contain rime_ice."
}
$xd = @(".git",".github","others","build","sync","windows","tools","*.userdb")

$flags = @("/E","/NFL","/NDL","/NJH","/NJS")
if ($DryRun) { $flags += "/L" }
robocopy $Src $RimeDir @flags /XD @xd /XF @xf
if ($LASTEXITCODE -ge 8) { throw "copy failed (robocopy exit $LASTEXITCODE)" }

# 3. Windows-specific overlay + files copied only when missing
if (-not $DryRun) {
  Copy-Item (Join-Path $Src "windows\rime_ice.custom.yaml") (Join-Path $RimeDir "rime_ice.custom.yaml") -Force
  $wc = Join-Path $Src "windows\weasel.custom.yaml"
  if ((Test-Path $wc) -and -not (Test-Path (Join-Path $RimeDir "weasel.custom.yaml"))) { Copy-Item $wc $RimeDir }
  $cp = Join-Path $RimeDir "custom_phrase.txt"
  if (-not (Test-Path $cp)) { Copy-Item (Join-Path $Src "custom_phrase.txt") $cp }
}

Write-Host "Done. Next: redeploy (tray Weasel -> Redeploy). If the LLM Lua modules were changed, restart WeaselServer too."
Write-Host "Then run: .\windows\check_deployed.ps1 -RimeDir `"$RimeDir`""
