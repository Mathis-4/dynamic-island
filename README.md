# Dynamic Island pour Windows 11

Une pilule façon iPhone en haut de l'écran : heure, batterie, musique en cours (couleurs de la pochette), minuteur Pomodoro, alertes volume/charge et statut de Nox.

## Installer (ou réparer)

Dans PowerShell :

```powershell
iex ((irm "https://raw.githubusercontent.com/Mathis-4/dynamic-island/main/install.ps1?t=$(Get-Random)").TrimStart([char]0xFEFF))
```

## Mises à jour

Automatiques : la pilule vérifie ce dépôt au démarrage puis toutes les 3 heures, s'installe et redémarre toute seule.

## Réglages perso

`%LOCALAPPDATA%\DynamicIsland\config.ps1` (adresse et jeton de Nox, etc.). Ce fichier reste sur le PC et n'est jamais remplacé.

## En cas de souci

Clic droit sur la pilule → **Ouvrir le journal**.
