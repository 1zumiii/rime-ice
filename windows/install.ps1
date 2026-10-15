# Install this repo into the Weasel user dir, keeping personal data.
# Usage (PowerShell, from anywhere):
#   .\windows\install.ps1 -RimeDir "D:\AppData\Rime" -DryRun    # preview
#   .\windows\install.ps1 -RimeDir "D:\AppData\Rime"            # backup, then install
# Written on macOS, then fixed after running it on Windows (robocopy hang on locked userdb files,
# invisible -DryRun listing, overwritten weasel.yaml). Still run with -DryRun first.
param(
  [string]$RimeDir = (Join-Path $env:APPDATA "Rime"),
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$Src = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $RimeDir)) { throw "RimeDir not found: $RimeDir" }

# 1. backup (skip the big .gram model and the build dir)
# /R:1 /W:1: retry a locked file once after 1 s. The robocopy default is 1,000,000 retries x 30 s, which
# hangs forever on files WeaselServer holds open (e.g. *.userdb\*.log, MANIFEST-*).
if (-not $DryRun) {
  $Backup = "$RimeDir.backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
  robocopy $RimeDir $Backup /E /R:1 /W:1 /XD build /XF *.gram /NFL /NDL /NJH /NJS | Out-Null
  $rc = $LASTEXITCODE
  if ($rc -ge 16) { throw "backup failed (robocopy exit $rc)" }
  if ($rc -ge 8) {
    Write-Warning "Some files were locked and skipped in the backup (usually *.userdb while WeaselServer is running). Quit WeaselServer first if you need a complete userdb backup."
  }
  Write-Host "Backup: $Backup"
}

# 2. files that must never be overwritten
$xf = @("README.md","README.upstream.md","LICENSE","AGENTS.md",".gitignore","install.sh","recipe.yaml",
        "squirrel.yaml","squirrel.custom.yaml","rime_ice.custom.yaml","installation.yaml","user.yaml",
        "weasel.yaml",
        "recent_words.tsv","custom_phrase.txt","user_freq.tsv",
        "ai_rerank_filter.lua","ai_rerank_processor.lua","drop_words.lua","hide_words.lua","reduce_freq_words.lua","turn_down_words.lua")
# weasel.yaml is NOT copied: the repo's copy would overwrite Weasel's own style (horizontal layout,
# inline preedit, font sizes ...). Put style overrides in weasel.custom.yaml instead.
Write-Host "NOTE: weasel.yaml is not copied, so your Weasel style is kept."
# default.custom.yaml usually holds your own schema_list: never overwrite an existing one
$existingDefault = Join-Path $RimeDir "default.custom.yaml"
if (Test-Path $existingDefault) {
  $xf += "default.custom.yaml"
  Write-Host "NOTE: kept your default.custom.yaml. Merge by hand: menu/page_size: 5 and switcher/save_options (see repo default.custom.yaml); schema_list must contain rime_ice."
}
$xd = @(".git",".github","others","build","sync","windows","tools","*.userdb")

# Keep the file list visible (no /NFL /NDL): with -DryRun it is the whole point of the preview.
$flags = @("/E","/R:1","/W:1","/NJH","/NJS")
if ($DryRun) { $flags += "/L" }
robocopy $Src $RimeDir @flags /XD @xd /XF @xf
if ($LASTEXITCODE -ge 8) { throw "copy failed (robocopy exit $LASTEXITCODE). A destination file may be locked: quit WeaselServer and retry." }

# 3. Windows-specific overlay + files copied only when missing
if (-not $DryRun) {
  Copy-Item (Join-Path $Src "windows\rime_ice.custom.yaml") (Join-Path $RimeDir "rime_ice.custom.yaml") -Force
  $wc = Join-Path $Src "windows\weasel.custom.yaml"
  if ((Test-Path $wc) -and -not (Test-Path (Join-Path $RimeDir "weasel.custom.yaml"))) { Copy-Item $wc $RimeDir }
  $cp = Join-Path $RimeDir "custom_phrase.txt"
  if (-not (Test-Path $cp)) { Copy-Item (Join-Path $Src "custom_phrase.txt") $cp }
}

if ($DryRun) {
  Write-Host "Dry run only: nothing was copied. Run again without -DryRun to install."
} else {
  Write-Host "Done. Next: click the Weasel tray icon -> Redeploy. (WeaselDeployer.exe /deploy from a command line does NOT compile the schemas.)"
  Write-Host "If any Lua module changed, restart WeaselServer too."
}
Write-Host "Then run: .\windows\check_deployed.ps1 -RimeDir `"$RimeDir`""
