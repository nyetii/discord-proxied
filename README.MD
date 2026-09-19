Implemented:

- Install.ps1
- Uninstall.ps1
- Update.ps1 — Copies the updated **Start-DiscordProxied.ps1** into DiscordProxied's %LOCALAPPDATA% folder.
- Start-DiscordProxied.ps1 — launcher helper installed automatically.

Key behavior:

- Uses the official winget package, with a verified GitHub-release fallback. sing-box installation documentation
- Creates and validates %USERPROFILE%\discord_proxy.config.json.
- Deletes the config if sing-box check fails.
- Creates Discord Proxied.lnk on the Desktop.
- Uses the real %LOCALAPPDATA%\Discord\Update.exe path.
- Runs sing-box elevated, launches Discord, waits for Discord to remain stable for 30 seconds, then stops sing-box.
- Uninstaller removes the shortcut, configuration, launcher files, portable fallback, and invokes winget to uninstall
sing-box.

Run with:

powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1

Both scripts and the launcher passed Windows PowerShell 5.1 syntax validation.