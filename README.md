<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/unity-logo-dark.png">
    <img src="assets/unity-logo.png" alt="Unity" width="340">
  </picture>
</p>

<h1 align="center">Unity-NoHub-Installer</h1>

<p align="center">
  Install any Unity Editor version into your user profile.<br>
  No Unity Hub. No admin rights.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="PowerShell 5.1+" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg">
  <img alt="Windows" src="https://img.shields.io/badge/platform-Windows-0078D4.svg">
  <a href="https://www.theunrealzaka.me"><img alt="Website" src="https://img.shields.io/badge/by-TheUnrealZaka-black.svg"></a>
</p>

---

A single PowerShell script that installs **any Unity Editor version** into your **user profile**, with **no Unity Hub** and **no admin rights**.

Made for school/lab PCs, locked-down machines and CI-style setups where you can't (or don't want to) install Unity Hub.

> **Status:** early version. See [Known limitations](#known-limitations) before relying on it.

```text
          .-- .-:.
      .:====- .====-.
   :-======-.  :======-:.   .++:    .+++            :@@#  :++
  **++===.        -===+#%-  #@@@    +@@@            :##+  @@@.
  ###**++=-:   .-=+*#@@@@-  #@@@    +@@@ +@@##@@@#. :@@#.@@@@@@ @@@:  :@@#
  ####-+***++==+#%@%+%@@@-  #@@@    +@@@ #@@@++@@@@ +@@@ +@@@#+ :@@@  @@@.
  ####   :=**#@@#=.  #@@@-  #@@@    +@@@ #@@#  :@@@ +@@@  @@@.   #@@+#@@+
  ####     -#%@#     #@@@-  :@@@+..:@@@@ #@@#  .@@@ +@@@  @@@:    @@@@@@
  *=:      -#%@#    . -*%-   :@@@@@@@@#  #@@#  .@@@ +@@@  #@@@@    @@@@.
   .-+**+-.-#%@#.=#@@%+:        .::..    ...    ...  ...    .:.  ++@@@+
    :=*######%@@@@@@@#=:                                        .@@@@:
       .-+*##%@@@@*-
           :=##=.

  Editor installer  v0.2.0
  by TheUnrealZaka  -  https://www.theunrealzaka.me
  ------------------------------------------------------------

Main menu   [Root: C:\Users\you\Unity]
> Install a Unity version (pick from the live list)
  Install the newest release of a line
  Install the version a project needs
  Manage installed editors
  Quit
```

## What does it do?

- Fetches the live list of Unity releases (version, changeset, stream) from Unity's release API.
- Downloads the editor and the modules you pick straight from `download.unity3d.com`.
- Installs **without elevation**, using one of two methods:
  - **Installer**: runs the official silent installer with `__COMPAT_LAYER=RunAsInvoker`, which tells Windows not to ask for UAC.
  - **Extract**: unpacks the installer with 7-Zip, which never needs admin and never writes to `HKLM`. If 7-Zip isn't installed, a portable copy is unpacked from its MSI (`msiexec /a`, also no admin).
  - **Auto** (default): tries *Installer* first and falls back to *Extract* if it fails or `Editor\Unity.exe` is missing.
- Reads `ProjectSettings\ProjectVersion.txt` and installs exactly the version a project needs (`-Project`).
- Resumes interrupted downloads and checks MD5 when Unity's per-version manifest is available.
- Has an interactive terminal menu, so you can also just run it with no arguments.

Default locations (both inside your user profile):

| What | Where |
| --- | --- |
| Editors | `%USERPROFILE%\Unity\<version>` |
| Download cache | `%LOCALAPPDATA%\UnityInstallers` |

## How to use it?

Requirements: Windows 10 1803+ (for `curl.exe` and `tar.exe`) and Windows PowerShell 5.1 or PowerShell 7+. No admin needed.

```powershell
git clone https://github.com/TheUnrealZaka/Unity-NoHub-Installer.git
cd Unity-NoHub-Installer
PowerShell -ExecutionPolicy Bypass -File .\Install-Unity.ps1
```

Run it with no arguments to get the menu. Or use it from the command line:

```powershell
.\Install-Unity.ps1 -List                                   # versions of the 6000 line
.\Install-Unity.ps1 -List -Filter 2022 -IncludePrerelease
.\Install-Unity.ps1 -Latest 6000                            # newest final 6000.x
.\Install-Unity.ps1 6000.6.7f1                              # exact version
.\Install-Unity.ps1 6000.6.7f1 -Modules android,webgl
.\Install-Unity.ps1 6000.6.7f1 -Changeset b22767f04f04      # skip the API call entirely
.\Install-Unity.ps1 -Project C:\Dev\MyGame -Modules android -Launch
.\Install-Unity.ps1 -Installed                              # what's under -Root
.\Install-Unity.ps1 6000.6.7f1 -Remove                      # delete that install
.\Install-Unity.ps1 6000.6.7f1 -Method Extract              # force the 7-Zip route
```

### Parameters

| Parameter | Description |
| --- | --- |
| `-Version` (position 0) | Exact editor version, e.g. `6000.6.7f1` |
| `-Changeset` | Skip the API lookup by giving the changeset yourself |
| `-Latest <line>` | Newest release of a line (`6000`, `2022`, ...) |
| `-Project <path>` | Install the version the project's `ProjectVersion.txt` asks for |
| `-Modules a,b,c` | Modules to add (see below) |
| `-List`, `-Filter`, `-IncludePrerelease` | List releases; alpha/beta are hidden unless you add the switch |
| `-Installed` / `-Remove` | List or delete installs under `-Root` |
| `-Method Auto\|Installer\|Extract` | How to install without admin (default `Auto`) |
| `-Arm64` | Use the Windows ARM64 editor installer |
| `-NoAndroidDeps` | With the `android` module, skip the SDK/NDK/OpenJDK step |
| `-Force` | Reinstall even if the editor is already there |
| `-Launch` | Open the editor (and the project, with `-Project`) when done |
| `-KeepInstallers` | Don't delete downloaded installers from the cache |
| `-ShowManifest` | Dump the manifest sections (debugging) |
| `-Menu` | Force the interactive menu |
| `-Root`, `-Cache` | Override the install and cache folders |

### Modules

`android`, `ios`, `appletv`, `visionos`, `webgl`, `windows-il2cpp`, `windows-server`, `linux-il2cpp`, `linux-mono`, `linux-server`, `mac-mono`, `mac-server`, `uwp`

## Known limitations

Be aware that this was written and checked against the Unity 6000.6.7f1 release page, not tested end to end on a real locked-down Windows machine yet:

- **`RunAsInvoker` is not guaranteed.** Whether Unity's installer cooperates without elevation isn't confirmed. If the *Installer* route fails, `-Method Extract` is the dependable one.
- **Android SDK / NDK / OpenJDK** are installed on a best-effort basis from Unity's per-version manifest (`unity-<ver>-win.ini`). The manifest's section and key names were written from memory. If the Android step does nothing, run with `-ShowManifest` and open an issue with the output.
- **The release API is not an official public API.** It's the GraphQL endpoint unity.com uses, so it can change. `-Changeset` lets you bypass it.
- **The interactive arrow-key menu** has been seen working in VS Code's integrated terminal on Windows. Windows Terminal and the classic console host haven't been checked yet. On terminals narrower than 76 columns the logo collapses to a one-line title.
- **Installing is not licensing.** You still need to sign in or activate a license the first time you open the editor.

## Disclaimer

This is an unofficial community tool and is not affiliated with or endorsed by Unity Technologies. The Unity logo (in this README and as ASCII art in the menu) is only there to identify the software it installs. It only downloads from Unity's own servers; it doesn't redistribute any Unity software. Unity and the Unity logo are trademarks of Unity Technologies. Your use of the Unity Editor is subject to Unity's own terms.

## License

This project's source code is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

You are allowed to use, modify, and distribute this project as long as you include the original copyright and keep the attribution to the original author.

The Unity name and logo are trademarks of Unity Technologies and are **not** covered by this license.

## Credits

- **TheUnrealZaka** (Zakaria Hamdaoui) - Author - [theunrealzaka.me](https://www.theunrealzaka.me)
