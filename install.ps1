# Installation / réparation de la Dynamic Island de Mathis
# Usage (PowerShell) : irm https://raw.githubusercontent.com/Mathis-4/dynamic-island/main/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$base = 'https://raw.githubusercontent.com/Mathis-4/dynamic-island/main'
$d = Join-Path $env:LOCALAPPDATA 'DynamicIsland'
New-Item -ItemType Directory -Force $d | Out-Null

# Arrête l'ancienne version si elle tourne
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*DynamicIsland*island.ps1*' } | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force; Wait-Process -Id $_.ProcessId -Timeout 5 -ErrorAction SilentlyContinue }

# Télécharge la dernière version
$bytes = (Invoke-WebRequest -UseBasicParsing ($base + '/island.ps1?t=' + [DateTime]::Now.Ticks)).Content
if ($bytes -is [string]) { $bytes = [System.Text.Encoding]::UTF8.GetBytes($bytes) }
$txt = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
[System.IO.File]::WriteAllText((Join-Path $d 'island.ps1'), $txt, (New-Object System.Text.UTF8Encoding $true))

# Fichier de réglages perso (créé une seule fois, jamais écrasé)
$cfg = Join-Path $d 'config.ps1'
if (-not (Test-Path $cfg)) {
  $c = @(
    '# Réglages perso de la Dynamic Island (ce fichier n''est jamais remplacé par les mises à jour)',
    '# $NoxStatusUrl = "https://..."',
    '# $NoxToken     = "..."',
    '# $HideInFullscreen = $true'
  ) -join "`r`n"
  [System.IO.File]::WriteAllText($cfg, $c, (New-Object System.Text.UTF8Encoding $true))
}

# Raccourcis : Bureau + démarrage de Windows
$target  = Join-Path $env:WINDIR 'System32\conhost.exe'
$cmdArgs = '--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $d 'island.ps1') + '"'
$sh = New-Object -ComObject WScript.Shell
foreach ($folder in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Startup')) {
  $lnk = $sh.CreateShortcut((Join-Path $folder 'Dynamic Island.lnk'))
  $lnk.TargetPath = $target; $lnk.Arguments = $cmdArgs
  $lnk.IconLocation = "$env:WINDIR\System32\imageres.dll,186"
  $lnk.Save()
}
Start-Process $target $cmdArgs
$v = ([regex]::Match($txt, "Version = '([^']+)'")).Groups[1].Value
Write-Host "Dynamic Island v$v installée et lancée. Les prochaines mises à jour se feront toutes seules." -ForegroundColor Green
