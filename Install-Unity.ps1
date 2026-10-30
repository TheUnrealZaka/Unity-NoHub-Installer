# Copyright (c) 2026 Zakaria Hamdaoui
# Licensed under the MIT License. See the LICENSE file in the project root.
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
  Install any Unity Editor version (Windows) into your user profile - no Unity Hub, no admin rights.

.DESCRIPTION
  1. Resolves version -> changeset via Unity's GraphQL API (or from ProjectVersion.txt, or -Changeset).
  2. Downloads the editor (+ optional modules) from download.unity3d.com.
  3. Installs WITHOUT elevation:
       Installer : runs the NSIS installer silently with __COMPAT_LAYER=RunAsInvoker (suppresses UAC)
       Extract   : unpacks the NSIS installer with 7-Zip (never needs admin, never touches HKLM)
       Auto      : Installer first, falls back to Extract if it fails or Unity.exe is missing
  4. Verifies MD5 when Unity's per-version manifest (unity-<ver>-win.ini) is available.

.EXAMPLES
  .\Install-Unity.ps1                                       # interactive menu (also: -Menu)
  .\Install-Unity.ps1 -List                                  # versions of the 6000 line
  .\Install-Unity.ps1 -List -Filter 2022 -IncludePrerelease
  .\Install-Unity.ps1 -Latest 6000                           # newest final 6000.x
  .\Install-Unity.ps1 6000.6.7f1                             # exact version
  .\Install-Unity.ps1 6000.6.7f1 -Modules android,webgl,windows-il2cpp
  .\Install-Unity.ps1 6000.6.7f1 -Changeset b22767f04f04     # skip the API call entirely
  .\Install-Unity.ps1 -Project C:\Dev\MyGame -Modules android -Launch   # install what the project needs, open it
  .\Install-Unity.ps1 -Installed                             # what is already installed under -Root
  .\Install-Unity.ps1 6000.6.7f1 -Remove                     # delete that install
  .\Install-Unity.ps1 6000.6.7f1 -Method Extract             # force the 7-Zip route
  .\Install-Unity.ps1 6000.6.7f1 -Modules android -ShowManifest   # dump the ini sections (debug)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Version,
    [string]$Changeset,
    [string]$Latest,
    [string]$Project,
    [switch]$List,
    [string]$Filter = '6000',
    [switch]$IncludePrerelease,
    [switch]$Installed,
    [switch]$Remove,
    [string[]]$Modules = @(),
    [switch]$NoAndroidDeps,
    [ValidateSet('Auto', 'Installer', 'Extract')] [string]$Method = 'Auto',
    [switch]$Arm64,
    [switch]$Force,
    [switch]$Launch,
    [switch]$KeepInstallers,
    [switch]$ShowManifest,
    [switch]$Menu,
    [string]$Root  = (Join-Path $env:USERPROFILE 'Unity'),
    [string]$Cache = (Join-Path $env:LOCALAPPDATA 'UnityInstallers')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol } catch {}

$ScriptVersion = '0.2.0'
$Author        = 'TheUnrealZaka'
$Website       = 'https://www.theunrealzaka.me'
$DownloadBase = 'https://download.unity3d.com/download_unity'
$GraphQlUrl   = 'https://services.unity.com/api/live-platform/v1/graphql'

# alias -> file part in UnitySetup-<part>-<ver>.exe   (all under /TargetSupportInstaller/)
# Names verified against the 6000.6.7f1 release page (Windows x64 module list).
$ModuleMap = @{
    'android'        = 'Android-Support-for-Editor'
    'ios'            = 'iOS-Support-for-Editor'
    'appletv'        = 'AppleTV-Support-for-Editor'
    'visionos'       = 'VisionOS-Support-for-Editor'
    'webgl'          = 'WebGL-Support-for-Editor'
    'windows-il2cpp' = 'Windows-IL2CPP-Support-for-Editor'
    'windows-server' = 'Windows-Server-Support-for-Editor'
    'linux-il2cpp'   = 'Linux-IL2CPP-Support-for-Editor'
    'linux-mono'     = 'Linux-Mono-Support-for-Editor'
    'linux-server'   = 'Linux-Server-Support-for-Editor'
    'mac-mono'       = 'Mac-Mono-Support-for-Editor'
    'mac-server'     = 'Mac-Server-Support-for-Editor'
    'uwp'            = 'Universal-Windows-Platform-Support-for-Editor'
}

# ------------------------------------------------------------------ API
$Query = @'
query GetRelease($limit: Int, $skip: Int, $version: String!, $stream: [UnityReleaseStream!]) {
  getUnityReleases(limit: $limit, skip: $skip, stream: $stream, version: $version, entitlements: [XLTS]) {
    totalCount
    edges { node { version releaseDate unityHubDeepLink stream } }
  }
}
'@

function Get-UnityReleases([string]$VersionFilter) {
    $headers = @{
        'accept'           = 'application/graphql-response+json, application/json'
        'origin'           = 'https://unity.com'
        'referer'          = 'https://unity.com/'
        'x-client-name'    = 'web-platform-hexagon'
        'x-client-version' = '1.0.0'
        'user-agent'       = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36'
    }
    $all = New-Object System.Collections.Generic.List[object]
    $skip = 0; $limit = 300
    do {
        $json  = @{ operationName = 'GetRelease'; query = $Query
                    variables = @{ version = $VersionFilter; limit = $limit; skip = $skip } } | ConvertTo-Json -Depth 6
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $r = Invoke-RestMethod -Method Post -Uri $GraphQlUrl -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes
        if ($r.errors) { throw ('Unity API error: ' + ($r.errors | ConvertTo-Json -Depth 5 -Compress)) }
        $page = $r.data.getUnityReleases
        foreach ($e in $page.edges) {
            $n = $e.node
            if ($n.unityHubDeepLink -match 'unityhub://([^/]+)/([0-9a-f]+)') {
                $all.Add([pscustomobject]@{
                    Version   = $n.version
                    Changeset = $Matches[2]
                    Released  = [datetime]$n.releaseDate
                    Stream    = $n.stream
                })
            }
        }
        $skip += $limit
    } while ($skip -lt $page.totalCount)
    $all | Sort-Object Released -Descending
}

function Test-Prerelease([string]$v) { $v -match '[ab]\d+$' }

function Read-ProjectVersion([string]$ProjectPath) {
    $f = Join-Path $ProjectPath 'ProjectSettings\ProjectVersion.txt'
    if (-not (Test-Path $f)) { throw "Not a Unity project (missing $f)" }
    $txt = Get-Content $f -Raw
    if ($txt -notmatch 'm_EditorVersion:\s*(\S+)') { throw "Cannot parse $f" }
    $ver = $Matches[1]; $cs = $null
    if ($txt -match 'm_EditorVersionWithRevision:\s*\S+\s*\(([0-9a-f]+)\)') { $cs = $Matches[1] }
    [pscustomobject]@{ Version = $ver; Changeset = $cs }
}

# ------------------------------------------------------------------ manifest (unity-<ver>-win.ini)
function ConvertFrom-UnityIni([string]$Text) {
    $sections = [ordered]@{}; $cur = $null
    foreach ($line in ($Text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith(';') -or $l.StartsWith('#')) { continue }
        if ($l -match '^\[(.+)\]$') { $cur = [ordered]@{}; $sections[$Matches[1]] = $cur; continue }
        if ($cur -ne $null -and $l -match '^([^=]+?)\s*=\s*(.*)$') { $cur[$Matches[1].ToLower()] = $Matches[2] }
    }
    $sections
}

function Get-Manifest([string]$Ver, [string]$Cs) {
    $url = "$DownloadBase/$Cs/unity-$Ver-win.ini"
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing
        $t = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
        $m = ConvertFrom-UnityIni $t
        if ($m.Count -gt 0) { return $m }
    } catch { Write-Verbose "No manifest at $url ($($_.Exception.Message))" }
    $null
}

function Get-ExpectedMd5($Manifest, [string]$FileName) {
    if (-not $Manifest) { return $null }
    foreach ($s in $Manifest.Values) {
        if ($s['url'] -and $s['md5'] -and ($s['url'] -split '[/\\]')[-1] -eq $FileName) { return $s['md5'] }
    }
    $null
}

# ------------------------------------------------------------------ download
function Save-File([string]$Url, [string]$Dest, [string]$Md5) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
    if ((Test-Path $Dest) -and (-not $Md5 -or (Get-FileHash $Dest -Algorithm MD5).Hash -eq $Md5)) {
        Write-Host "  Cached: $(Split-Path $Dest -Leaf)"; return
    }
    $part = "$Dest.part"
    Write-Host "  Downloading $Url"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue      # ships with Windows 10 1803+
    if ($curl) {
        & $curl.Source -L --fail --retry 3 --retry-delay 2 -C - -o $part $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed (curl $LASTEXITCODE): $Url" }
    } else {
        $ProgressPreference = 'Continue'
        Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing
        $ProgressPreference = 'SilentlyContinue'
    }
    Move-Item $part $Dest -Force
    if ($Md5) {
        $h = (Get-FileHash $Dest -Algorithm MD5).Hash
        if ($h -ne $Md5) { Remove-Item $Dest -Force; throw "MD5 mismatch for $(Split-Path $Dest -Leaf): expected $Md5, got $h" }
        Write-Host "  MD5 OK"
    }
}

# ------------------------------------------------------------------ 7-Zip (for -Method Extract)
function Find-7Zip {
    $cands = @(
        (Get-Command 7z.exe -ErrorAction SilentlyContinue | ForEach-Object Source),
        "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe", (Join-Path $Cache 'tools\7z\7z.exe')
    )
    $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

function Install-Portable7Zip {
    # An MSI "administrative install" (msiexec /a) only unpacks files - no elevation needed.
    $page = (Invoke-WebRequest -Uri 'https://www.7-zip.org/download.html' -UseBasicParsing).Content
    if ($page -notmatch 'a/(7z\d+-x64\.msi)') { throw 'Could not find the 7-Zip MSI on 7-zip.org' }
    $msi = Join-Path $Cache $Matches[1]
    Save-File "https://www.7-zip.org/a/$($Matches[1])" $msi $null
    $dest = Join-Path $Cache 'tools\7z'
    New-Item -ItemType Directory -Force $dest | Out-Null
    $p = Start-Process msiexec.exe -ArgumentList "/a `"$msi`" /qn TARGETDIR=`"$dest`"" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec /a failed ($($p.ExitCode))" }
    $exe = Get-ChildItem $dest -Recurse -Filter 7z.exe | Select-Object -First 1
    if (-not $exe) { throw '7z.exe not found after MSI unpack' }
    if ($exe.DirectoryName -ne $dest) { Copy-Item "$($exe.DirectoryName)\*" $dest -Recurse -Force }
    Join-Path $dest '7z.exe'
}

# ------------------------------------------------------------------ installers
function Invoke-NsisRun([string]$Exe, [string]$TargetDir) {
    # NSIS rules: /D must be the LAST argument, unquoted, absolute. Spaces in the path are fine.
    $old = $env:__COMPAT_LAYER
    $env:__COMPAT_LAYER = 'RunAsInvoker'          # run as the current (non-admin) user, no UAC prompt
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList "/S /D=$($TargetDir.TrimEnd('\'))" -Wait -PassThru
        return $p.ExitCode
    } finally {
        if ($null -eq $old) { Remove-Item Env:\__COMPAT_LAYER -ErrorAction SilentlyContinue } else { $env:__COMPAT_LAYER = $old }
    }
}

function Invoke-NsisExtract([string]$Exe, [string]$TargetDir) {
    $7z = Find-7Zip
    if (-not $7z) { Write-Host '  7-Zip not found, fetching a portable copy...'; $7z = Install-Portable7Zip }
    New-Item -ItemType Directory -Force $TargetDir | Out-Null
    & $7z x -y "-o$TargetDir" $Exe | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed ($LASTEXITCODE) extracting $Exe" }
    # NSIS bookkeeping that is not part of the product
    foreach ($junk in '$PLUGINSDIR', '[NSIS].nsi', '$_OUTDIR', '$_0_', '$TEMP') {
        $p = Join-Path $TargetDir $junk
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# $Probe = a file that must exist afterwards (Editor\Unity.exe) or $null when it cannot be known
function Install-Nsis([string]$Exe, [string]$TargetDir, [string]$Probe) {
    $ok = $false
    if ($Method -in 'Auto', 'Installer') {
        Write-Host "  Silent install (RunAsInvoker) -> $TargetDir"
        try {
            $code = Invoke-NsisRun $Exe $TargetDir
            if ($code -ne 0) { Write-Warning "Installer exit code $code" }
            $ok = ($code -eq 0) -and ((-not $Probe) -or (Test-Path (Join-Path $TargetDir $Probe)))
        } catch { Write-Warning "Installer route failed: $($_.Exception.Message)" }
        if (-not $ok -and $Method -eq 'Installer') { throw 'Installer route failed (try -Method Extract).' }
    }
    if (-not $ok) {
        Write-Host "  Extracting with 7-Zip -> $TargetDir"
        Invoke-NsisExtract $Exe $TargetDir
        if ($Probe -and -not (Test-Path (Join-Path $TargetDir $Probe))) { throw "Expected file missing after extraction: $Probe" }
    }
}

# ------------------------------------------------------------------ Android SDK/NDK/JDK (best effort, from the ini)
function Install-AndroidDeps($Manifest, [string]$Cs, [string]$Target) {
    if (-not $Manifest) { Write-Warning 'No manifest: Android SDK/NDK/OpenJDK not installed. Unity will ask for them or use External Tools paths.'; return }
    $deps = foreach ($name in $Manifest.Keys) {
        $s = $Manifest[$name]
        if (-not $s['url'] -or -not $s['destination']) { continue }
        if ($s['url'] -match 'Android-Support-for-Editor') { continue }
        if ($name -match 'android|jdk|ndk|sdk' -or $s['url'] -match 'android|jdk|ndk') { [pscustomobject]@{ Name = $name; S = $s } }
    }
    if (-not $deps) { Write-Warning 'Manifest lists no Android dependencies.'; return }
    foreach ($d in $deps) {
        $s = $d.S
        $url = if ($s['url'] -match '^https?://') { $s['url'] } else { "$DownloadBase/$Cs/$($s['url'])" }
        $dest = ($s['destination'] -replace '\{UNITY_PATH\}', $Target) -replace '/', '\'
        $file = Join-Path $Cache (($url -split '/')[-1])
        Write-Host "Android dependency: $($d.Name)"
        Save-File $url $file $s['md5']
        New-Item -ItemType Directory -Force $dest | Out-Null
        if ($file -match '\.zip$') {
            & tar.exe -xf $file -C $dest                       # bsdtar: far faster than Expand-Archive for the NDK
            if ($LASTEXITCODE -ne 0) { Expand-Archive $file $dest -Force }
        } elseif ($file -match '\.exe$') {
            Install-Nsis $file $dest $null
        } else { Write-Warning "Unhandled dependency type: $file"; continue }
        if ($s['rename'] -match '^\s*([^,;>]+?)\s*(?:,|;|=>|->)\s*(.+?)\s*$') {     # e.g. android-ndk-r23b -> NDK
            $from = Join-Path $dest $Matches[1]; $to = Join-Path $dest $Matches[2]
            if ((Test-Path $from) -and -not (Test-Path $to)) { Move-Item $from $to }
        }
        if (-not $KeepInstallers) { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
}


# ------------------------------------------------------------------ interactive menu
$ModuleLabels = [ordered]@{
    'android'        = 'Android Build Support (+ SDK/NDK/OpenJDK)'
    'ios'            = 'iOS Build Support'
    'webgl'          = 'Web Build Support'
    'windows-il2cpp' = 'Windows Build Support (IL2CPP)'
    'windows-server' = 'Windows Dedicated Server'
    'linux-il2cpp'   = 'Linux Build Support (IL2CPP)'
    'linux-mono'     = 'Linux Build Support (Mono)'
    'linux-server'   = 'Linux Dedicated Server'
    'mac-mono'       = 'Mac Build Support (Mono)'
    'mac-server'     = 'Mac Dedicated Server'
    'uwp'            = 'Universal Windows Platform'
    'appletv'        = 'tvOS Build Support'
    'visionos'       = 'visionOS Build Support'
}

function Read-Key { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }

# Single select -> [int] index, Multi -> [int[]] indices.  $null = cancelled (Esc / empty input).
function Select-Menu {
    param([string]$Title, [string[]]$Items, [switch]$Multi, [int[]]$Checked = @())
    if (-not $Items -or $Items.Count -eq 0) { return $null }

    $interactive = -not ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)
    if (-not $interactive) {                                   # plain numbered fallback
        Write-Host ''; Write-Host $Title -ForegroundColor Cyan
        for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ('  {0,3}) {1}' -f ($i + 1), $Items[$i]) }
        $prompt = if ($Multi) { 'Numbers separated by commas (blank = none, q = back)' } else { 'Number (blank/q = back)' }
        $a = (Read-Host $prompt).Trim()
        if ($a -eq 'q' -or (-not $a -and -not $Multi)) { return $null }
        $n = @($a -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 } | Where-Object { $_ -ge 0 -and $_ -lt $Items.Count })
        if ($Multi) { return , $n }
        if ($n.Count) { return $n[0] } else { return $null }
    }

    $page   = [Math]::Max(4, [Math]::Min($Items.Count, [Console]::WindowHeight - 7))
    $width  = [Math]::Max(20, [Console]::WindowWidth - 1)
    $idx = 0; $off = 0
    $sel = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($c in $Checked) { [void]$sel.Add($c) }

    Write-Host ''; Write-Host $Title -ForegroundColor Cyan
    $hint = if ($Multi) { 'Up/Down move  Space toggle  A all/none  Enter confirm  Esc back' } else { 'Up/Down move  Enter select  Esc back' }
    Write-Host $hint -ForegroundColor DarkGray
    1..($page + 1) | ForEach-Object { Write-Host '' }          # reserve room (scrolls the window if needed)
    $top = [Console]::CursorTop - ($page + 1)
    $oldVis = $true; try { $oldVis = [Console]::CursorVisible } catch {}
    try { [Console]::CursorVisible = $false } catch {}
    try {
        while ($true) {
            if ($idx -lt $off) { $off = $idx }
            if ($idx -ge $off + $page) { $off = $idx - $page + 1 }
            for ($r = 0; $r -lt $page; $r++) {
                $i = $off + $r
                [Console]::SetCursorPosition(0, $top + $r)
                if ($i -lt $Items.Count) {
                    $box  = if ($Multi) { if ($sel.Contains($i)) { '[x] ' } else { '[ ] ' } } else { '' }
                    $line = ('{0} {1}{2}' -f $(if ($i -eq $idx) { '>' } else { ' ' }), $box, $Items[$i])
                    if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
                    $line = $line.PadRight($width)
                    if ($i -eq $idx) { Write-Host $line -NoNewline -ForegroundColor Black -BackgroundColor Cyan }
                    else             { Write-Host $line -NoNewline }
                } else { Write-Host (' ' * $width) -NoNewline }
            }
            [Console]::SetCursorPosition(0, $top + $page)
            $foot = if ($Multi) { "  $($idx + 1)/$($Items.Count)   selected: $($sel.Count)" } else { "  $($idx + 1)/$($Items.Count)" }
            Write-Host $foot.PadRight($width) -NoNewline -ForegroundColor DarkGray

            $k = Read-Key
            switch ($k.VirtualKeyCode) {
                38 { if ($idx -gt 0) { $idx-- } }
                40 { if ($idx -lt $Items.Count - 1) { $idx++ } }
                33 { $idx = [Math]::Max(0, $idx - $page) }
                34 { $idx = [Math]::Min($Items.Count - 1, $idx + $page) }
                36 { $idx = 0 }
                35 { $idx = $Items.Count - 1 }
                32 { if ($Multi) { if (-not $sel.Remove($idx)) { [void]$sel.Add($idx) } } }
                65 { if ($Multi) { if ($sel.Count -eq $Items.Count) { $sel.Clear() } else { 0..($Items.Count - 1) | ForEach-Object { [void]$sel.Add($_) } } } }
                13 { if ($Multi) { return , @($sel | Sort-Object) } else { return $idx } }
                27 { return $null }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $oldVis } catch {}
        [Console]::SetCursorPosition(0, $top + $page + 1)
    }
}

function Confirm-Menu([string]$Question) { (Select-Menu -Title $Question -Items @('Yes', 'No')) -eq 0 }

function Select-ModulesMenu {
    $keys = @($ModuleLabels.Keys)
    $items = $keys | ForEach-Object { '{0,-15} {1}' -f $_, $ModuleLabels[$_] }
    $r = Select-Menu -Title 'Modules to install (none is fine)' -Items $items -Multi
    if ($null -eq $r) { return $null }
    , @($r | ForEach-Object { $keys[$_] })
}

function Select-Release([bool]$LatestOnly) {
    $lines = @('6000   (Unity 6)', '2022', '2021', '2020', '2019', 'Other (type a version prefix)...')
    $i = Select-Menu -Title 'Release line' -Items $lines
    if ($null -eq $i) { return $null }
    $filter = if ($i -eq 5) { (Read-Host 'Version prefix (e.g. 6000.3 or 2022.3.10f1)').Trim() } else { ($lines[$i] -split '\s+')[0] }
    if (-not $filter) { return $null }

    Write-Host "Fetching releases for '$filter'..." -ForegroundColor DarkGray
    $all = @(Get-UnityReleases $filter)
    if (-not $all.Count) { Write-Warning "No releases found for '$filter'."; return $null }
    $showPre = $false
    while ($true) {
        $rels = @($all | Where-Object { $showPre -or -not (Test-Prerelease $_.Version) })
        if ($LatestOnly -and $rels.Count) { return $rels[0] }
        $items = @($rels | ForEach-Object { '{0,-16} {1:yyyy-MM-dd}  {2,-6} {3}' -f $_.Version, $_.Released, $_.Stream, $_.Changeset })
        $hasPre = @($all | Where-Object { Test-Prerelease $_.Version }).Count -gt 0
        if ($hasPre) { $items += $(if ($showPre) { '>> hide alpha/beta builds' } else { '>> show alpha/beta builds' }) }
        $j = Select-Menu -Title "Unity $filter - $($rels.Count) releases (newest first)" -Items $items
        if ($null -eq $j) { return $null }
        if ($j -lt $rels.Count) { return $rels[$j] }
        $showPre = -not $showPre
    }
}

function Start-Run {                                           # run Invoke-Main with the chosen settings
    try { Invoke-Main } catch { Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red }
    [void](Read-Host "`nPress Enter to return to the menu")
}

function Reset-Selection {
    $script:Version = $null; $script:Changeset = $null; $script:Latest = $null; $script:Project = $null
    $script:Modules = @(); $script:Remove = $false; $script:Launch = $false; $script:List = $false; $script:Installed = $false
}

function Find-InstalledEditors {
    if (-not (Test-Path $Root)) { return @() }
    @(Get-ChildItem $Root -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'Editor\Unity.exe') } | Sort-Object Name -Descending)
}

# ------------------------------------------------------------------ banner
# Unity logo (cube + wordmark) as ASCII density art. Kept pure ASCII on purpose:
# Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
$LogoCube = @(
    '        .-- .-:.        ',
    '    .:====- .====-.     ',
    ' :-======-.  :======-:. ',
    '**++===.        -===+#%-',
    '###**++=-:   .-=+*#@@@@-',
    '####-+***++==+#%@%+%@@@-',
    '####   :=**#@@#=.  #@@@-',
    '####     -#%@#     #@@@-',
    '*=:      -#%@#    . -*%-',
    ' .-+**+-.-#%@#.=#@@%+:  ',
    '  :=*######%@@@@@@@#=:  ',
    '     .-+*##%@@@@*-      ',
    '         :=##=.         '
)
$LogoWord = @(
    '',
    '',
    '.++:    .+++            :@@#  :++',
    '#@@@    +@@@            :##+  @@@.',
    '#@@@    +@@@ +@@##@@@#. :@@#.@@@@@@ @@@:  :@@#',
    '#@@@    +@@@ #@@@++@@@@ +@@@ +@@@#+ :@@@  @@@.',
    '#@@@    +@@@ #@@#  :@@@ +@@@  @@@.   #@@+#@@+',
    ':@@@+..:@@@@ #@@#  .@@@ +@@@  @@@:    @@@@@@',
    ' :@@@@@@@@#  #@@#  .@@@ +@@@  #@@@@    @@@@.',
    '    .::..    ...    ...  ...    .:.  ++@@@+',
    '                                    .@@@@:',
    '',
    ''
)

function Show-Banner {
    $w = 120; try { $w = [Console]::WindowWidth } catch {}
    if ($w -lt 1) { $w = 120 }
    Write-Host ''
    if ($w -ge 76) {
        for ($i = 0; $i -lt $LogoCube.Count; $i++) {
            Write-Host ('  ' + $LogoCube[$i]) -NoNewline -ForegroundColor Gray
            Write-Host ('  ' + $LogoWord[$i]) -ForegroundColor White
        }
    } else {
        Write-Host '  UNITY' -ForegroundColor White
    }
    Write-Host ''
    Write-Host ('  Editor installer  v{0}' -f $ScriptVersion) -ForegroundColor Cyan
    Write-Host ('  by {0}  -  {1}' -f $Author, $Website) -ForegroundColor DarkGray
    Write-Host ('  ' + ('-' * [Math]::Min(60, [Math]::Max(10, $w - 4)))) -ForegroundColor DarkGray
}

function Invoke-Interactive {
    while ($true) {
        Reset-Selection
        if (-not ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) { Clear-Host }
        Show-Banner
        $c = Select-Menu -Title "Main menu   [Root: $Root]" -Items @(
            'Install a Unity version (pick from the live list)',
            'Install the newest release of a line',
            'Install the version a project needs',
            'Manage installed editors',
            'Quit')
        if ($null -eq $c -or $c -eq 4) { return }

        switch ($c) {
            { $_ -in 0, 1 } {
                $rel = Select-Release ($c -eq 1)
                if (-not $rel) { continue }
                $mods = Select-ModulesMenu
                if ($null -eq $mods) { continue }
                $already = Test-Path (Join-Path (Join-Path $Root $rel.Version) 'Editor\Unity.exe')
                $q = "Install Unity $($rel.Version) -> $(Join-Path $Root $rel.Version)`n  modules: $(if ($mods.Count) { $mods -join ', ' } else { '(none)' })$(if ($already) { "`n  (editor already present - only modules will be added)" })"
                if (-not (Confirm-Menu $q)) { continue }
                $script:Version = $rel.Version; $script:Changeset = $rel.Changeset; $script:Modules = $mods
                Start-Run
            }
            2 {
                $path = (Read-Host 'Path to the Unity project folder').Trim('" ')
                if (-not $path) { continue }
                try { $pv = Read-ProjectVersion $path } catch { Write-Host $_.Exception.Message -ForegroundColor Red; [void](Read-Host 'Enter'); continue }
                Write-Host "Project uses Unity $($pv.Version)"
                $mods = Select-ModulesMenu
                if ($null -eq $mods) { continue }
                $launch = Confirm-Menu 'Open the project in the editor when done?'
                $script:Project = $path; $script:Modules = $mods; $script:Launch = $launch
                Start-Run
            }
            3 {
                $eds = Find-InstalledEditors
                if (-not $eds.Count) { Write-Host "No editors found under $Root" -ForegroundColor Yellow; [void](Read-Host 'Enter'); continue }
                $e = Select-Menu -Title 'Installed editors' -Items @($eds | ForEach-Object { $_.Name })
                if ($null -eq $e) { continue }
                $ed = $eds[$e]
                $a = Select-Menu -Title "Unity $($ed.Name)" -Items @('Launch editor', 'Open folder', 'Remove (delete folder)')
                switch ($a) {
                    0 { Start-Process (Join-Path $ed.FullName 'Editor\Unity.exe') }
                    1 { Start-Process explorer.exe $ed.FullName }
                    2 { if (Confirm-Menu "Delete $($ed.FullName) ?") { Remove-Item $ed.FullName -Recurse -Force; Write-Host 'Removed.' -ForegroundColor Green; [void](Read-Host 'Enter') } }
                }
            }
        }
    }
}

# ------------------------------------------------------------------ main
function Invoke-Main {
    if ($Installed) {
        if (-not (Test-Path $Root)) { Write-Host "Nothing under $Root"; return }
        Get-ChildItem $Root -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'Editor\Unity.exe') } |
            ForEach-Object { [pscustomobject]@{ Version = $_.Name; Path = $_.FullName } } | Format-Table -AutoSize
        return
    }

    if ($List) {
        Get-UnityReleases $Filter | Where-Object { $IncludePrerelease -or -not (Test-Prerelease $_.Version) } |
            Format-Table Version, Changeset, @{ n = 'Released'; e = { $_.Released.ToString('yyyy-MM-dd') } }, Stream -AutoSize
        return
    }

    # ---- resolve version + changeset
    $projectDir = $null
    if ($Project) {
        $projectDir = (Resolve-Path $Project).Path
        $pv = Read-ProjectVersion $projectDir
        $Version = $pv.Version
        if ($pv.Changeset -and -not $Changeset) { $Changeset = $pv.Changeset }
        Write-Host "Project needs Unity $Version"
    }
    elseif ($Latest) {
        $rel = Get-UnityReleases $Latest | Where-Object { $IncludePrerelease -or -not (Test-Prerelease $_.Version) } | Select-Object -First 1
        if (-not $rel) { throw "No releases found for '$Latest'" }
        $Version = $rel.Version; $Changeset = $rel.Changeset
    }

    if (-not $Version) { throw 'Specify a version, -Latest <line>, -Project <path>, -List or -Installed. See Get-Help .\Install-Unity.ps1 -Examples' }

    if (-not $Changeset) {
        $rel = Get-UnityReleases $Version | Where-Object Version -eq $Version | Select-Object -First 1
        if (-not $rel) { throw "Version '$Version' not found. Use -List -Filter <line> (add -IncludePrerelease), or pass -Changeset." }
        $Changeset = $rel.Changeset
    }

    $target = Join-Path $Root $Version
    $editorExe = Join-Path $target 'Editor\Unity.exe'

    if ($Remove) {
        if (Test-Path $target) { Remove-Item $target -Recurse -Force; Write-Host "Removed $target" } else { Write-Host "Not installed: $target" }
        return
    }

    Write-Host "Unity $Version (changeset $Changeset) -> $target"
    $base = "$DownloadBase/$Changeset"
    $manifest = Get-Manifest $Version $Changeset
    if ($ShowManifest) {
        if ($manifest) { $manifest.GetEnumerator() | ForEach-Object { "[$($_.Key)]"; $_.Value.GetEnumerator() | ForEach-Object { "  $($_.Key)=$($_.Value)" } } }
        else { Write-Host '(no manifest available)' }
    }

    # ---- editor
    if ((Test-Path $editorExe) -and -not $Force) {
        Write-Host '  Editor already installed, skipping (use -Force to reinstall).'
    } else {
        $kind = if ($Arm64) { 'WindowsArm64EditorInstaller/UnitySetupArm64' } else { 'Windows64EditorInstaller/UnitySetup64' }
        $url  = "$base/$kind-$Version.exe"
        $exe  = Join-Path $Cache (($url -split '/')[-1])
        Save-File $url $exe (Get-ExpectedMd5 $manifest (Split-Path $exe -Leaf))
        Install-Nsis $exe $target 'Editor\Unity.exe'
        if (-not $KeepInstallers) { Remove-Item $exe -Force -ErrorAction SilentlyContinue }
    }

    # ---- modules
    foreach ($m in $Modules) {
        $key = $m.ToLower()
        if (-not $ModuleMap.ContainsKey($key)) { Write-Warning "Unknown module '$m'. Known: $(($ModuleMap.Keys | Sort-Object) -join ', ')"; continue }
        $file = "UnitySetup-$($ModuleMap[$key])-$Version.exe"
        $mexe = Join-Path $Cache $file
        Write-Host "Module: $key"
        Save-File "$base/TargetSupportInstaller/$file" $mexe (Get-ExpectedMd5 $manifest $file)
        Install-Nsis $mexe $target $null          # modules unpack into <target>\Editor\Data\PlaybackEngines\...
        if (-not $KeepInstallers) { Remove-Item $mexe -Force -ErrorAction SilentlyContinue }
        if ($key -eq 'android' -and -not $NoAndroidDeps) { Install-AndroidDeps $manifest $Changeset $target }
    }

    if (-not (Test-Path $editorExe)) { throw "Finished, but $editorExe does not exist." }
    Write-Host "`nDone: $editorExe"

    if ($Launch) {
        $args = @(); if ($projectDir) { $args = @('-projectPath', $projectDir) }
        Start-Process $editorExe -ArgumentList $args
    }
}

# Allows dot-sourcing for tests: . .\Install-Unity.ps1  (no side effects)
if ($MyInvocation.InvocationName -ne '.') {
    $hasAction = $Version -or $Latest -or $Project -or $List -or $Installed -or $Remove
    if ($Menu -or -not $hasAction) { Invoke-Interactive } else { Invoke-Main }
}
