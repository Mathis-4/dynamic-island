# Dynamic Island pour Windows 11

Une pilule façon iPhone en haut de l'écran : heure, batterie, musique en cours (couleurs de la pochette), minuteur Pomodoro, agenda, lumières, notifications, alertes volume/charge et statut de Nox.

Un panneau latéral s'ouvre aussi en approchant la souris du bord droit de l'écran : dépôt d'un fichier pour Nox, actions sur ce que tu viens de copier, « Que faire ici ? ».

## Installer (ou réparer)

Dans PowerShell :

```powershell
$sha = (irm https://api.github.com/repos/Mathis-4/dynamic-island/commits/main).sha; iex ((irm "https://raw.githubusercontent.com/Mathis-4/dynamic-island/$sha/install.ps1").TrimStart([char]0xFEFF))
```

L'installation crée le dossier `%LOCALAPPDATA%\DynamicIsland`, deux raccourcis « Dynamic Island » (Bureau et démarrage de Windows) et, au premier lancement, une tâche planifiée Windows `DynamicIsland` qui relance la pilule à l'ouverture de session, au déverrouillage et à la sortie de veille.

## Mises à jour

Automatiques : la pilule vérifie ce dépôt au démarrage puis toutes les 3 heures, s'installe et redémarre toute seule. Si une nouvelle version ne démarre pas, la pilule revient seule à la version précédente.

## Réglages perso

`%LOCALAPPDATA%\DynamicIsland\config.ps1` (plein écran, notifications, position sur Chrome, etc.). Ce fichier reste sur le PC et n'est jamais remplacé.

La pilule trouve Nox toute seule par Tailscale : il n'y a ni adresse ni jeton à saisir. Si ton `config.ps1` contient encore une ligne `$NoxToken` ou `$NoxStatusUrl`, tu peux la supprimer : elle ne sert plus.

## Désinstaller

Dans PowerShell :

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*DynamicIsland*island.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Unregister-ScheduledTask -TaskName 'DynamicIsland' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Dynamic Island.lnk'), (Join-Path ([Environment]::GetFolderPath('Startup')) 'Dynamic Island.lnk') -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:LOCALAPPDATA 'DynamicIsland') -Recurse -Force
```

Pour vérifier (la première ligne ne doit rien afficher, la seconde doit répondre `False`) :

```powershell
Get-ScheduledTask -TaskName 'DynamicIsland' -ErrorAction SilentlyContinue
Test-Path (Join-Path $env:LOCALAPPDATA 'DynamicIsland')
```

Le dossier supprimé contient aussi tes réglages (`config.ps1`) et les journaux.

## En cas de souci

Clic droit sur la pilule → **Ouvrir le journal**.
