#Requires -Version 7.0
<#
.SYNOPSIS
    dneat (PowerShell) - smart batch downloader: resumable, multi-connection transfers powered by aria2.
    Windows, macOS and Linux (PowerShell 7+).
.DESCRIPTION
    URLs come from the clipboard, the command line or list files; unfinished downloads are saved so they can be resumed.
    Missing prerequisites are installed only when needed (winget / choco / scoop / Homebrew / apt / dnf / pacman).
    Run  ./dneat.ps1 -Help  for every option.  Defaults match dneat 1.0.0 (bash / zsh).
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [string[]] $Sources = @(),
    [Alias('i', 'Input')]   [string[]] $InputFile = @(),
    [Alias('o', 'Output')]  [string] $OutputDir = '',
    [Alias('j')] [int] $Jobs = 1,
    [Alias('c')] [int] $Connections = 16,
    [Alias('l')] [string] $Limit = '',
    [Alias('s')] [string] $Session = 'resume.session',
    [Alias('f')] [switch] $Force,
    [Alias('k')] [switch] $KeepList,
    [Alias('n')] [switch] $NoInstall,
    [Alias('y')] [switch] $InstallDeps,
    [Alias('h', '?')] [switch] $Help,
    [Alias('v')] [switch] $Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DneatVersion = '1.0.0'
$script:DefaultSession = 'resume.session'
$script:UrlRe = '(?:https?|ftps?)://\S+'                    # what is picked out of clipboard text
$script:ItemRe = '^(?:(?:https?|ftps?|sftp)://|magnet:)'    # a URL line in an aria2 input file (options are indented)
$script:Self = './dneat.ps1'
$script:StartedAt = [Diagnostics.Stopwatch]::StartNew()
$script:Online = $null; $script:InstallOutput = ''; $script:InputPath = $null; $script:ListFiles = @(); $script:Remaining = 0

# ══ UI layer ═══════════════════════════════════════════════════════════════════
$ESC = [char]27
function Initialize-Ui {
    try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
    $script:Tty = -not [Console]::IsOutputRedirected
    $script:Cols = 80
    if ($script:Tty) { try { $script:Cols = [Math]::Max(40, [Console]::WindowWidth) } catch { } }
    $level = 0
    if ($script:Tty -and -not $env:NO_COLOR -and $env:TERM -ne 'dumb') {
        $level = 2
        if ($env:COLORTERM -match 'truecolor|24bit' -or $env:WT_SESSION) { $level = 3 }
    }
    $script:ColorLevel = $level
    $script:C = @{ Reset = ''; Bold = ''; Acc = ''; Ok = ''; Warn = ''; Err = ''; Muted = '' }
    if ($level -ge 2) {
        $script:C = @{ Reset = "$ESC[0m"; Bold = "$ESC[1m"; Acc = "$ESC[38;5;141m"; Ok = "$ESC[38;5;78m"
                       Warn = "$ESC[38;5;221m"; Err = "$ESC[38;5;203m"; Muted = "$ESC[38;5;244m" }
    }
    $script:RuleW = if ($script:Cols -lt 66) { $script:Cols - 4 } else { 62 }
    $script:BarW = if ($script:Cols -ge 100) { 30 } elseif ($script:Cols -ge 76) { 24 } else { 14 }
    if ($env:DNEAT_ASCII) {
        $script:G = @{ Ok = '+'; Fail = 'x'; Skip = '-'; Warn = '!'; Step = '*'; Arrow = '->'; Dot = '-'; Ell = '~'; Times = 'x'
                       H = '-'; V = '|'; TL = '+-'; BL = '+'; Full = '#'; Head = ''; Empty = '-'
                       Spin = @('|', '/', '-', '\'); Unicode = $false }
    } else {
        $script:G = @{ Ok = '✔'; Fail = '✖'; Skip = '⊘'; Warn = '▲'; Step = '◆'; Arrow = '→'; Dot = '·'; Ell = '…'; Times = '×'
                       H = '─'; V = '│'; TL = '╭─'; BL = '╰'; Full = '━'; Head = '╸'; Empty = '─'
                       Spin = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'); Unicode = $true }
    }
}

function Out-Ui([string] $Text = '', [switch] $NoNewline) { Write-Host $Text -NoNewline:$NoNewline }
function Get-Rep([string] $S, [int] $N) { if ($N -le 0) { '' } else { $S * $N } }
function Get-Clip([string] $T, [int] $Max) { if ($T.Length -gt $Max) { $T.Substring(0, [Math]::Max(0, $Max - 1)) + $script:G.Ell } else { $T } }
function Get-Pad([string] $T, [int] $W) { $t = Get-Clip $T $W; $t + (Get-Rep ' ' ($W - $t.Length)) }

function Format-Time([long] $S) {
    if ($S -ge 3600) { '{0}:{1:00}:{2:00}' -f [Math]::Floor($S / 3600), [Math]::Floor(($S % 3600) / 60), ($S % 60) }
    else { '{0}:{1:00}' -f [Math]::Floor($S / 60), ($S % 60) }
}
function Format-Bytes([double] $B) {
    $units = 'B', 'KB', 'MB', 'GB', 'TB'; $u = 0
    while ($B -ge 1024 -and $u -lt 4) { $B /= 1024; $u++ }
    if ($u -eq 0) { '{0} B' -f [int]$B } else { '{0:0.0} {1}' -f $B, $units[$u] }
}

# aria2 prints sizes as 1.4MiB / 512KiB / 0B; the UI uses the same KB/MB style as vneat and pneat.
function ConvertTo-SpeedLabel([string] $S) { if ($S -match '^([\d.]+)([KMGT]?)i?B$') { "$($Matches[1]) $($Matches[2])B/s" } else { "$S/s" } }
function ConvertTo-Seconds([string] $Eta) {       # 1h2m3s -> seconds
    $t = 0
    foreach ($m in [regex]::Matches($Eta, '(\d+)([dhms])')) {
        $n = [int]$m.Groups[1].Value
        $t += switch ($m.Groups[2].Value) { 'd' { $n * 86400 } 'h' { $n * 3600 } 'm' { $n * 60 } default { $n } }
    }
    $t
}

function Get-UrlName([string] $Url) {             # the file name aria2 will most likely use
    if ($Url -like 'magnet:*') { return 'magnet link' }
    $u = ($Url -split '[?#]', 2)[0].TrimEnd('/')
    $name = $u.Substring($u.LastIndexOf('/') + 1)
    if ($u -match '^[a-z]+://[^/]+/.' -and $name) { try { [Uri]::UnescapeDataString($name) } catch { $name } }
    else { $u -replace '^[a-z]+://', '' }
}
function Get-UrlScheme([string] $Url) { ($Url -split ':', 2)[0].ToUpperInvariant() }

# Colored pill with a short label (plain "[LABEL]" without colors).
function Get-Badge([string] $Label) {
    if ($script:ColorLevel -lt 2) { return "[$Label]" }
    $bg = switch ($Label) { 'HTTPS' { 141 } 'HTTP' { 221 } { $_ -in 'FTP', 'FTPS', 'SFTP' } { 215 } 'MAGNET' { 213 } default { 245 } }
    "$ESC[48;5;${bg};38;5;16m $Label $($script:C.Reset)"
}

function Write-Note([string] $T) { Out-Ui "  $($script:C.Muted)$T$($script:C.Reset)" }
function Write-Step([string] $T) { Out-Ui "  $($script:C.Acc)$($script:G.Step)$($script:C.Reset) $T" }
function Write-Warn([string] $T) { Out-Ui "  $($script:C.Warn)$($script:G.Warn) $T$($script:C.Reset)" }
function Stop-Dneat([string] $Message, [string[]] $Hints = @()) {
    Out-Ui ''
    Out-Ui "  $($script:C.Err)$($script:G.Fail) $Message$($script:C.Reset)"
    foreach ($h in $Hints) { Out-Ui "    $($script:C.Muted)$h$($script:C.Reset)" }
    Out-Ui ''
    exit 1
}

# ── Cards: a titled block with a left gutter ──
function Open-Card([string] $Title) {
    $c = $script:C
    Out-Ui ''
    Out-Ui "  $($c.Muted)$($script:G.TL) $($c.Bold)$($c.Acc)$Title$($c.Reset)$($c.Muted) $(Get-Rep $script:G.H ($script:RuleW - $Title.Length - 4))$($c.Reset)"
}
function Write-CardLine([string] $T = '') { Out-Ui "  $($script:C.Muted)$($script:G.V)$($script:C.Reset)$(if ($T) { " $T" })" }
function Write-CardRow([string] $Label, [string] $Value) { Write-CardLine ("{0}{1,-10}{2} {3}" -f $script:C.Muted, $Label, $script:C.Reset, $Value) }
function Close-Card { Out-Ui "  $($script:C.Muted)$($script:G.BL)$(Get-Rep $script:G.H ($script:RuleW - 1))$($script:C.Reset)" }

# Smooth violet -> pink gradient on truecolor terminals, a 256-color ramp elsewhere.
function Get-Bar([int] $Pct, [int] $Width) {
    $cells = [Math]::Floor($Pct * $Width / 100)
    $head = 0
    if ($script:G.Head -and $cells -lt $Width -and (($Pct * $Width) % 100) -ge 50) { $head = 1 }
    $ramp = 99, 105, 141, 177, 213, 219
    $sb = [Text.StringBuilder]::new()
    $w = [Math]::Max(1, $Width - 1)
    for ($i = 0; $i -lt $cells + $head; $i++) {
        $col = if ($script:ColorLevel -ge 3) { "$ESC[38;2;$([int](140 + 115 * $i / $w));$([int](100 + 10 * $i / $w));$([int](255 - 45 * $i / $w))m" }
               elseif ($script:ColorLevel -eq 2) { "$ESC[38;5;$($ramp[[Math]::Min(5, [int](5 * $i / $w))])m" } else { '' }
        [void]$sb.Append($col).Append($(if ($i -lt $cells) { $script:G.Full } else { $script:G.Head }))
    }
    $empty = $Width - $cells - $head
    "$($sb.ToString())$($script:C.Reset)$($script:C.Muted)$(Get-Rep $script:G.Empty $empty)$($script:C.Reset)"
}

function Show-Logo {
    $rows = '██████╗ ███╗   ██╗███████╗ █████╗ ████████╗', '██╔══██╗████╗  ██║██╔════╝██╔══██╗╚══██╔══╝',
            '██║  ██║██╔██╗ ██║█████╗  ███████║   ██║   ', '██║  ██║██║╚██╗██║██╔══╝  ██╔══██║   ██║   ',
            '██████╔╝██║ ╚████║███████╗██║  ██║   ██║   ', '╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝   ╚═╝   '
    $ramp = 99, 105, 141, 177, 213, 219
    Out-Ui ''
    if ($script:G.Unicode -and $script:Cols -ge 52) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($script:ColorLevel -ge 2) { Out-Ui "  $ESC[38;5;$($ramp[$i])m$($rows[$i])$($script:C.Reset)" } else { Out-Ui "  $($rows[$i])" }
        }
    } else { Out-Ui "  $($script:C.Bold)$($script:C.Acc)dneat$($script:C.Reset)" }
}

function Show-Banner {
    $c = $script:C; $g = $script:G
    Out-Ui ''
    Out-Ui "  $($c.Acc)$($c.Bold)$($g.Step) dneat$($c.Reset)  $($c.Muted)smart batch downloader $($g.Arrow) resumable multi-connection $($g.Dot) v$($script:DneatVersion)$($c.Reset)"
}

function Show-System {
    $os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    $cpu = $null
    try {
        if ($IsWindows) { $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name }
        elseif ($IsMacOS) { $cpu = (& sysctl -n machdep.cpu.brand_string 2>$null) }
        elseif ($IsLinux) { $cpu = ((Get-Content /proc/cpuinfo -ErrorAction Stop | Select-String 'model name' | Select-Object -First 1) -split ':', 2)[1].Trim() }
    } catch { }
    if (-not $cpu) { $cpu = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() }
    Open-Card 'System'
    Write-CardRow 'OS' (Get-Clip $os ($script:Cols - 18))
    Write-CardRow 'CPU' (Get-Clip $cpu ($script:Cols - 18))
    Close-Card
}

# ══ Prerequisites ═══════════════════════════════════════════════════════════════
function Find-Tool([string] $Name) { (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)?.Source }

function Update-PathFromSystem {
    if ($IsWindows) {      # pick up tools installed after this session started, without dropping anything already on PATH
        $have = $env:Path -split ';'
        $extra = ([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';' -split ';' | Where-Object { $_ -and $have -notcontains $_ }
        if ($extra) { $env:Path = (@($have) + @($extra)) -join ';' }
        $links = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'      # where winget puts the aria2c shim
        if ((Test-Path $links) -and ($env:Path -split ';') -notcontains $links) { $env:Path += ";$links" }
    }
    elseif ($IsMacOS) { $env:PATH = "/opt/homebrew/bin:/usr/local/bin:$env:PATH" }
}

function Get-ClipboardTool { foreach ($t in 'wl-paste', 'xclip', 'xsel') { if (Find-Tool $t) { return $t } }; '' }

function Test-Role([string] $Role) {
    switch ($Role) {
        'aria2'     { [bool](Find-Tool 'aria2c') }
        'clipboard' { [bool](Get-ClipboardTool) }
    }
}

function Get-PackageManager {
    if ($IsWindows) { foreach ($pm in 'winget', 'choco', 'scoop') { if (Find-Tool $pm) { return $pm } } }
    elseif ($IsMacOS) { foreach ($b in '/opt/homebrew/bin/brew', '/usr/local/bin/brew') { if (Test-Path $b) { return $b } }; if (Find-Tool 'brew') { return 'brew' } }
    else { foreach ($pm in 'apt-get', 'dnf', 'pacman', 'zypper') { if (Find-Tool $pm) { return $pm } } }
    ''
}

# Package per manager; an empty entry means "no package - install it manually".
function Get-Packages([string] $Pm, [string] $Role) {
    if ($Role -eq 'clipboard') { return $(if ($IsLinux -and $Pm -ne '') { if ($env:WAYLAND_DISPLAY) { 'wl-clipboard' } else { 'xclip' } } else { '' }) }
    $key = if ($Pm -like '*brew') { 'brew' } else { $Pm }
    $table = @{ 'winget' = 'aria2.aria2'; 'choco' = 'aria2'; 'scoop' = 'aria2'; 'brew' = 'aria2'
                'apt-get' = 'aria2'; 'dnf' = 'aria2'; 'pacman' = 'aria2'; 'zypper' = 'aria2' }
    if ($table.ContainsKey($key)) { $table[$key] } else { '' }
}

function Get-ManualHint([string] $Role) {
    if ($Role -eq 'aria2') {
        if ($IsWindows) { return 'winget install aria2.aria2   (or: choco install aria2 / scoop install aria2)' }
        if ($IsMacOS) { return 'brew install aria2' }
    }
    $pm = Get-PackageManager; $pkg = if ($pm) { Get-Packages $pm $Role } else { '' }
    if ($pkg) { "install $pkg with $pm" } else { "install $Role with your package manager" }
}

# ── Connectivity ──
function Test-TcpReachable {
    foreach ($h in '1.1.1.1', '8.8.8.8') {
        try {
            $client = [Net.Sockets.TcpClient]::new()
            try { if ($client.ConnectAsync($h, 443).Wait(2000) -and $client.Connected) { return $true } } finally { $client.Dispose() }
        } catch { }
    }
    try { [void][Net.Dns]::GetHostAddresses('github.com'); $true } catch { $false }
}
function Test-Online {
    if ($null -eq $script:Online) {
        if ($env:HTTPS_PROXY -or $env:HTTP_PROXY -or $env:https_proxy -or $env:http_proxy) { $script:Online = $true }
        else { $script:Online = switch ($env:DNEAT_NETWORK) { 'online' { $true } 'offline' { $false } default { Test-TcpReachable } } }
    }
    $script:Online
}
function Test-NetworkError([string] $Text) {
    $Text -match '(?i)could not resolve|name resolution|no such host|network is unreachable|timed out|timeout|unable to connect|connection (refused|reset|was closed)|0x80072ee[27d]|0x80072efe|failed (to download|when searching source|to fetch)|temporary failure'
}

# Runs an installer with its output captured (so a failure can be explained); returns $true on exit code 0.
function Invoke-Installer([string[]] $Cmd) {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'      # installers write progress to stderr
    try {
        $script:InstallOutput = (& $Cmd[0] $Cmd[1..($Cmd.Count - 1)] 2>&1 | Out-String)
        $LASTEXITCODE -eq 0
    } finally { $ErrorActionPreference = $previous }
}

function Write-InstallFailure([string] $What) {
    if (Test-NetworkError $script:InstallOutput) { $script:Online = $false; Write-Warn "${What}: network problem - check your internet connection."; return }
    $last = ($script:InstallOutput -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    Write-Warn "$What$(if ($last) { ": $(Get-Clip $last.Trim() 110)" })."
}

# "sudo" in front of Linux package-manager commands, except when already root or sudo is missing.
function Get-SudoPrefix { if ($IsWindows -or $IsMacOS -or -not (Find-Tool 'sudo') -or (& id -u) -eq '0') { @() } else { @('sudo') } }

function Install-Role([string] $Pm, [string] $Role) {
    $pkg = Get-Packages $Pm $Role
    if (-not $pkg) { Write-Warn "No package for '$Role' - $(Get-ManualHint $Role)"; return }
    if ($Pm -in 'apt-get', 'zypper') {
        $refresh = @(Get-SudoPrefix) + $(if ($Pm -eq 'apt-get') { @('apt-get', 'update', '-qq') } else { @('zypper', '--non-interactive', '-q', 'refresh') })
        if (-not (Invoke-Installer $refresh)) { Write-InstallFailure 'Could not refresh package lists' }
    }
    Write-Step "Installing $pkg"
    $cmd = switch -Wildcard ($Pm) {
        'winget'  { @('winget', 'install', '-e', '--id', $pkg, '--accept-source-agreements', '--accept-package-agreements', '--silent') }
        'choco'   { @('choco', 'install', $pkg, '-y', '--no-progress') }
        'scoop'   { @('scoop', 'install', $pkg) }
        '*brew'   { @($Pm, 'install', $pkg) }
        'apt-get' { @(Get-SudoPrefix) + @('apt-get', 'install', '-y', '-qq', $pkg) }
        'dnf'     { @(Get-SudoPrefix) + @('dnf', 'install', '-y', '-q', $pkg) }
        'pacman'  { @(Get-SudoPrefix) + @('pacman', '-S', '--needed', '--noconfirm', $pkg) }
        'zypper'  { @(Get-SudoPrefix) + @('zypper', '--non-interactive', '-q', 'install', $pkg) }
    }
    if (-not (Invoke-Installer $cmd)) { Write-InstallFailure "Could not install $pkg" }
}

# Installs the absent roles; returns $false when something is still missing afterwards.
function Install-Missing([string[]] $Roles) {
    $missing = @($Roles | Where-Object { -not (Test-Role $_) })
    if ($missing.Count -eq 0) { return $true }
    if ($NoInstall) { Write-Warn "Auto-install is disabled - missing: $($missing -join ', ')."; return $false }
    $pm = Get-PackageManager
    if (-not $pm) { Write-Warn "No supported package manager found - cannot install: $($missing -join ', ')."; return $false }
    if (-not (Test-Online)) { Write-Warn "No internet connection - cannot install: $($missing -join ', ')."; return $false }
    foreach ($r in $missing) { Install-Role $pm $r }
    Update-PathFromSystem
    -not ($missing | Where-Object { -not (Test-Role $_) })
}

# ══ Input ═══════════════════════════════════════════════════════════════════════
function Get-ClipboardText {
    try {
        if ($IsWindows) { return (Get-Clipboard -Raw) }
        if ($IsMacOS) { return ((& pbpaste 2>$null) -join "`n") }
        switch (Get-ClipboardTool) {
            'wl-paste' { return ((& wl-paste --no-newline 2>$null) -join "`n") }
            'xclip'    { return ((& xclip -selection clipboard -o 2>$null) -join "`n") }
            'xsel'     { return ((& xsel --clipboard --output 2>$null) -join "`n") }
        }
    } catch { }
    ''
}

function Get-ItemCount([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    @(Get-Content -LiteralPath $Path | Where-Object { $_ -match $script:ItemRe }).Count
}

function Test-SameFile([string] $A, [string] $B) {
    if (-not ((Test-Path -LiteralPath $A) -and (Test-Path -LiteralPath $B))) { return $false }
    $x = [IO.Path]::GetFullPath($A, $PWD.ProviderPath); $y = [IO.Path]::GetFullPath($B, $PWD.ProviderPath)
    if ($IsWindows) { $x -ieq $y } else { $x -ceq $y }
}

function Get-ResumeCommand {
    $q = { param($t) if ($t -match '\s') { "'$t'" } else { $t } }
    $cmd = $script:Self      # aria2 stores each download's folder in the session file, so -OutputDir is not needed
    if ($Session -ne $script:DefaultSession) { $cmd += " -Session $(& $q $Session)" }
    "$cmd $(& $q $Session)"
}

# Builds one aria2 input file from the clipboard, URLs and list files (list files are copied as they are).
function Build-Input {
    $lines = [Collections.Generic.List[string]]::new()
    $script:ListFiles = @(); $nUrls = 0; $nFiles = 0
    $all = @(@($InputFile) + @($Sources) | Where-Object { $_ })
    if ($all.Count -eq 0) {
        Write-Step 'Reading URLs from the clipboard…'
        $text = Get-ClipboardText
        foreach ($m in [regex]::Matches("$text", $script:UrlRe)) { $lines.Add(($m.Value -replace '[\].,;:!?)>"'']+$', '')) }
        if ($lines.Count -eq 0) { Stop-Dneat 'No URLs found on the clipboard.' @('Copy one or more http(s)/ftp links, or pass URLs / a list file as arguments.') }
        $script:SourceLabel = 'clipboard'
    } else {
        foreach ($item in $all) {
            if ($item -match $script:ItemRe) { $lines.Add($item); $nUrls++ }
            elseif (Test-Path -LiteralPath $item -PathType Leaf) {
                foreach ($l in (Get-Content -LiteralPath $item)) { $lines.Add($l) }
                $nFiles++
                if (-not (Test-SameFile $item $Session)) { $script:ListFiles += $item }
            } else { Stop-Dneat "'$item' is neither a URL nor an existing file." @("Run '$($script:Self) -Help' for usage.") }
        }
        $script:SourceLabel = if ($nFiles -gt 0 -and $nUrls -gt 0) { "$nFiles list file(s) + command line" } elseif ($nFiles -gt 0) { "$nFiles list file(s)" } else { 'command line' }
    }
    $script:InputPath = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllLines($script:InputPath, $lines, [Text.UTF8Encoding]::new($false))
    $script:Urls = @($lines | Where-Object { $_ -match $script:ItemRe } | ForEach-Object { ($_ -split '[\t ]')[0] })
    $script:Total = $script:Urls.Count
    if ($script:Total -eq 0) { Stop-Dneat 'No URLs found.' @('A list file needs one URL per line.') }
}

# A leftover session from an earlier run is replaced by this run's - tell the user before that happens.
function Test-StaleSession {
    foreach ($item in (@($InputFile) + @($Sources) | Where-Object { $_ })) { if (Test-SameFile $item $Session) { return } }
    $left = Get-ItemCount $script:SessionPath
    if ($left -gt 0) {
        Write-Warn "$Session still holds $left unfinished URL(s) from an earlier run - it will be replaced."
        Write-Note "To continue them instead, stop now and run: $(Get-ResumeCommand)"
    }
}

# ══ Progress & reporting ════════════════════════════════════════════════════════
function Clear-Live { if ($script:Tty) { [Console]::Write("`r$ESC[2K`n$ESC[2K$ESC[1A`r") } }

# Two live lines: the current file (spinner, bar, speed, ETA, protocol) and the whole batch.
function Write-Live([int] $Pct, [string] $Speed, [string] $Eta, [int] $Active, [int] $OPct) {
    $c = $script:C; $idx = $script:Finished + 1
    if ($Jobs -eq 1) {
        $idx = [Math]::Min($idx, $script:Total)
        $tag = "[$idx/$($script:Total)]"
        $url = $script:Urls[$idx - 1]; $name = Get-UrlName $url; $label = Get-UrlScheme $url
    } else {
        $tag = "[$($script:Finished)/$($script:Total)]"; $name = "$Active active"; $label = "$($script:G.Times)$Active"
    }
    $badgeW = $label.Length + 2
    if ($Pct -ge 0) {
        $plain = '{0,3}%  {1,9}  ETA {2,-5}' -f $Pct, $Speed, $Eta
        $colored = "$($c.Bold){0,3}%$($c.Reset)  $($c.Muted){1,9}  ETA {2,-5}$($c.Reset)" -f $Pct, $Speed, $Eta
    } else {
        $plain = '{0,7}  {1,9}' -f (Format-Time ([long]$script:StartedAt.Elapsed.TotalSeconds)), $Speed
        $colored = "$($c.Muted)$plain$($c.Reset)"
    }
    $avail = $script:Cols - (2 + 1 + 1 + $tag.Length + 1 + 1 + $plain.Length + 2 + $badgeW) - 1          # room for the name and the bar
    $bw = 0
    if ($Pct -ge 0) { $bw = [Math]::Min($script:BarW, $avail - 15); if ($bw -lt 8) { $bw = 0 } }
    $bar = ''; $nameMax = $avail
    if ($bw -gt 0) { $bar = "$(Get-Bar $Pct $bw) "; $nameMax = $avail - $bw - 1 }
    $nameMax = [Math]::Max(10, $nameMax)
    $prefixW = 2 + 1 + 1 + $tag.Length + 1 + $nameMax + 1
    $obw = if ($bw -gt 0) { $bw } else { [Math]::Max(6, [Math]::Min($script:BarW, $script:Cols - $prefixW - 24)) }
    $spin = $script:G.Spin[$script:Frame % $script:G.Spin.Count]
    $l1 = "  $($c.Acc)$spin$($c.Reset) $($c.Muted)$tag$($c.Reset) $($c.Bold)$(Get-Pad $name $nameMax)$($c.Reset) $bar$colored  $(Get-Badge $label)"
    $l2 = ("{0}{1}{2} {3}  {4}{5,3}%  {6} elapsed{2}" -f $c.Muted, 'overall'.PadLeft($prefixW - 1), $c.Reset, (Get-Bar $OPct $obw), $c.Muted, $OPct, (Format-Time ([long]$script:StartedAt.Elapsed.TotalSeconds)))
    [Console]::Write("`r$ESC[2K$l1`n$ESC[2K$l2$ESC[1A`r")
}

# One aria2 readout line:  [#gid 4.5MiB/5.7MiB(80%) CN:1 DL:1.5MiB ETA:3s]   or   [DL:1.4MiB][#gid ...(16%)][#gid ...(35%)]
function Update-Readout([string] $Line) {
    if (-not $script:Tty) { return }
    $speed = '--'; $eta = '--:--'; $pct = -1; $sum = 0
    if ($Line -match 'DL:([\d.]+[KMGT]?i?B)') { $speed = ConvertTo-SpeedLabel $Matches[1] }
    $pcts = @([regex]::Matches($Line, '\((\d+)%\)') | ForEach-Object { [int]$_.Groups[1].Value })
    foreach ($p in $pcts) { $sum += $p }
    $active = [Math]::Max(1, @($Line.ToCharArray() | Where-Object { $_ -eq '#' }).Count)
    if ($pcts.Count -gt 0) { $pct = [int][Math]::Floor($sum / $pcts.Count) }
    $opct = [Math]::Min(100, [int][Math]::Floor(($script:Finished * 100 + $sum) / $script:Total))
    $elapsed = [long]$script:StartedAt.Elapsed.TotalSeconds
    if (($Jobs -eq 1 -or $active -eq 1) -and $Line -match 'ETA:([0-9dhms]+)') { $eta = Format-Time (ConvertTo-Seconds $Matches[1]) }
    elseif ($opct -gt 0 -and $opct -lt 100 -and $elapsed -gt 0) { $eta = Format-Time ([long]($elapsed * (100 - $opct) / $opct)) }
    $script:Frame++
    Write-Live $pct $speed $eta $active $opct
}

function Write-ReportOk([string] $Tag, [string] $Name, [long] $Bytes, [long] $Secs) {
    $c = $script:C; $speed = ''; $time = ''
    if ($Secs -ge 0) { $time = Format-Time $Secs; $speed = if ($Secs -gt 0) { "$(Format-Bytes ($Bytes / $Secs))/s" } else { '--' } }
    $cols = '{0,9}  {1}{2,10}  {3,5}{4}' -f (Format-Bytes $Bytes), $c.Muted, $speed, $time, $c.Reset
    Out-Ui "  $($c.Ok)$($script:G.Ok)$($c.Reset) $($c.Muted)$Tag$($c.Reset) $($c.Bold)$(Get-Pad $Name $script:NameCol)$($c.Reset)  $cols"
}

function Write-ReportNote([string] $Kind, [string] $Tag, [string] $Name, [string] $Detail) {
    $c = $script:C; $g = $script:G
    $glyph, $color = if ($Kind -eq 'fail') { $g.Fail, $c.Err } else { $g.Skip, $c.Muted }
    $room = [Math]::Max(10, $script:Cols - $Tag.Length - $script:NameCol - 8)
    Out-Ui "  $color$glyph$($c.Reset) $($c.Muted)$Tag$($c.Reset) $($c.Bold)$(Get-Pad $Name $script:NameCol)$($c.Reset)  $color$(Get-Clip $Detail $room)$($c.Reset)"
}

function Complete-Download([string] $Path) {
    $now = [long]$script:StartedAt.Elapsed.TotalSeconds
    $bytes = 0; if (Test-Path -LiteralPath $Path -PathType Leaf) { $bytes = (Get-Item -LiteralPath $Path).Length }
    $script:Finished++; $script:Ok++; $script:TotalBytes += $bytes
    $secs = if ($Jobs -eq 1) { $now - $script:LastEvent } else { -1 }
    $script:LastEvent = $now
    Clear-Live
    Write-ReportOk "[$($script:Finished)/$($script:Total)]" ([IO.Path]::GetFileName($Path)) $bytes $secs
}

function Get-FriendlyReason([string] $Msg) { if ($Msg -match 'status=(\d+)') { "HTTP $($Matches[1])" } else { $Msg.TrimEnd('.') } }

function Complete-Failure {
    $name = Get-UrlName $script:ExcUri
    $script:ExcPending = $false; $script:Finished++
    Clear-Live
    $tag = "[$($script:Finished)/$($script:Total)]"
    if ($script:ExcCode -eq 13) { $script:Skipped++; Write-ReportNote 'skip' $tag $name 'already exists – use -f to replace' }
    else { $script:Fail++; Write-ReportNote 'fail' $tag $name "failed: $(Get-FriendlyReason $script:ExcMsg)" }
}

# Reads one line of aria2's output and turns it into the neat UI.
function Read-Aria2Line([string] $Line) {
    if ($script:ExcPending -and $Line -notmatch '^(Exception:|  ->)') { Complete-Failure }
    if ($Line -match '^\[(#|DL:)') { Update-Readout $Line }
    elseif ($Line -match '\[NOTICE\] Download complete: (.+)$') { Complete-Download $Matches[1].Trim() }
    elseif ($Line -match '\[ERROR\].*Download aborted\. URI=(.*)$') { $script:ExcPending = $true; $script:ExcUri = $Matches[1].Trim(); $script:ExcCode = 0; $script:ExcMsg = '' }
    elseif ($Line -match '^(Exception:|  ->)') {
        # the last errorCode/message pair on the last line wins
        if ($Line -match '^.*errorCode=(\d+) ?(.*)$') { $script:ExcCode = [int]$Matches[1]; $script:ExcMsg = $Matches[2] }
    }
}

function Invoke-Aria2 {
    $a = @("--input-file=$($script:InputPath)", "--dir=$OutputDir", "--max-concurrent-downloads=$Jobs",
           "--split=$Connections", "--max-connection-per-server=$Connections", '--summary-interval=0',
           '--console-log-level=notice', '--enable-color=false', '--download-result=hide', '--auto-file-renaming=false',
           "--save-session=$($script:SessionPath)", '--save-session-interval=60')
    if ($Force) { $a += '--allow-overwrite=true' }
    if ($Limit) { $a += "--max-overall-download-limit=$Limit" }
    $psi = [Diagnostics.ProcessStartInfo]::new($script:Aria2)
    foreach ($x in $a) { $psi.ArgumentList.Add($x) }
    $psi.WorkingDirectory = $PWD.ProviderPath
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $script:LastEvent = [long]$script:StartedAt.Elapsed.TotalSeconds
    $proc = [Diagnostics.Process]::Start($psi)
    $script:Aria2Proc = $proc
    [void]$proc.StandardError.ReadToEndAsync()           # drained so aria2 can never block on a full pipe
    if ($script:Tty) { [Console]::Write("$ESC[?25l") }
    $finishedNormally = $false
    try {
        while ($null -ne ($line = $proc.StandardOutput.ReadLine())) { Read-Aria2Line $line }
        if ($script:ExcPending) { Complete-Failure }
        $proc.WaitForExit()
        $script:AriaRc = $proc.ExitCode
        $finishedNormally = $true
    } finally {
        # Ctrl-C reaches aria2 too; give it a moment to shut down and write its session file before reporting.
        if (-not $finishedNormally) {
            [void]$proc.WaitForExit(8000)
            $left = (Get-ItemCount $script:SessionPath) - $script:Skipped
            [Console]::Write("`r$ESC[2K`n$ESC[2K$ESC[1A`r$ESC[?25h`n  $($script:C.Warn)$($script:G.Warn) Interrupted$($script:C.Reset)`n")
            if ($left -gt 0) { [Console]::Write("  $($script:C.Muted)$left unfinished URL(s) saved $($script:G.Arrow) continue with: $(Get-ResumeCommand)$($script:C.Reset)`n") }
            [Console]::Write("`n")
            if ($script:InputPath) { Remove-Item -LiteralPath $script:InputPath -Force -ErrorAction SilentlyContinue }
        } elseif ($script:Tty) { Clear-Live; [Console]::Write("$ESC[?25h") }
    }
}

# Unfinished URLs live in the session file; items skipped because they already exist are not "unfinished".
function Complete-Session {
    $script:Remaining = [Math]::Max(0, (Get-ItemCount $script:SessionPath) - $script:Skipped)
    if ($script:Remaining -eq 0) { Remove-Item -LiteralPath $script:SessionPath -Force -ErrorAction SilentlyContinue }
}

function Show-Plan {
    $g = $script:G
    $jobsLine = if ($Jobs -eq 1) { '1 file at a time' } else { "$Jobs files at a time" }
    $limitLine = if (-not $Limit) { 'no speed limit' } elseif ($Limit -match '[KM]$') { "max $($Limit.Substring(0, $Limit.Length - 1)) $($Limit[-1])B/s" } else { "max $Limit B/s" }
    $ver = ((& $script:Aria2 --version | Select-Object -First 1) -split ' ')[2]
    Open-Card 'Plan'
    Write-CardRow 'Source' "$($script:SourceLabel) $($g.Dot) $($script:Total) URL(s)"
    Write-CardRow 'Output' $OutputDir
    Write-CardRow 'Engine' "aria2 $ver"
    Write-CardRow 'Transfer' "$jobsLine $($g.Dot) $Connections connection(s) per file $($g.Dot) $limitLine"
    Write-CardRow 'Existing' $(if ($Force) { 'replaced (-Force)' } else { 'skipped (use -f to replace)' })
    Write-CardRow 'Resume' $Session
    Close-Card
    Out-Ui ''
}

function Show-Summary {
    $c = $script:C; $g = $script:G
    $wall = [long]$script:StartedAt.Elapsed.TotalSeconds
    Open-Card 'Summary'
    $line = "$($c.Ok)$($g.Ok) $($script:Ok) downloaded$($c.Reset)"
    if ($script:Fail) { $line += "   $($c.Err)$($g.Fail) $($script:Fail) failed$($c.Reset)" }
    if ($script:Skipped) { $line += "   $($c.Muted)$($g.Skip) $($script:Skipped) skipped$($c.Reset)" }
    Write-CardRow 'Result' $line
    if ($script:TotalBytes -gt 0) {
        Write-CardRow 'Size' (Format-Bytes $script:TotalBytes)
        if ($wall -gt 0) { Write-CardRow 'Speed' "$(Format-Bytes ($script:TotalBytes / $wall))/s average" }
    }
    Write-CardRow 'Time' (Format-Time $wall)
    Write-CardRow 'Output' $OutputDir
    if ($script:Remaining -gt 0) { Write-CardRow 'Resume' "$($c.Warn)$($script:Remaining) URL(s) left$($c.Reset) $($g.Arrow) $(Get-ResumeCommand)" }
    else { Write-CardRow 'Resume' "$($c.Muted)nothing left to resume$($c.Reset)" }
    Close-Card
    if ($script:Fail -eq 0) { Out-Ui "`n  $($c.Ok)$($c.Bold)$($g.Ok) All done.$($c.Reset)`n" } else { Out-Ui "`n  $($c.Err)$($c.Bold)$($g.Fail) Finished with $($script:Fail) failure(s).$($c.Reset)`n" }
}

# Offers to delete the URL lists that were used (never the resume file - dneat manages that one).
function Request-ListRemoval {
    if ($KeepList -or $script:ListFiles.Count -eq 0 -or -not $script:Tty -or [Console]::IsInputRedirected) { return }
    $c = $script:C; $g = $script:G
    foreach ($list in $script:ListFiles) {
        if (-not (Test-Path -LiteralPath $list -PathType Leaf)) { continue }
        Open-Card 'URL list'
        Write-CardLine "'$list' is no longer needed."
        Write-CardLine "$($c.Muted)$(if ($script:Remaining -gt 0) { "Finished downloads are on disk; the unfinished ones are saved in $Session." } else { 'Everything in it has been handled.' })$($c.Reset)"
        Out-Ui "  $($c.Muted)$($g.V)$($c.Reset) $($c.Bold)Remove it?$($c.Reset) $($c.Muted)[y/N]$($c.Reset): " -NoNewline
        $answer = [Console]::ReadLine()
        if ($answer -match '^[Yy]$') { Remove-Item -LiteralPath $list -Force; Write-CardLine "$($c.Ok)$($g.Ok)$($c.Reset) removed" } else { Write-CardLine "$($c.Muted)kept$($c.Reset)" }
        Close-Card
    }
}

# ══ Help ════════════════════════════════════════════════════════════════════════
function Show-Help {
    $c = $script:C
    Show-Logo
    Out-Ui "`n  $($c.Bold)Smart batch downloader $($script:G.Arrow) resumable multi-connection transfers$($c.Reset)"
    Out-Ui "  $($c.Muted)aria2 powered $($script:G.Dot) automatic setup $($script:G.Dot) live progress $($script:G.Dot) v$($script:DneatVersion) $($script:G.Dot) PowerShell 7+$($c.Reset)"
    $rows = @(
        @('USAGE', @('./dneat.ps1 [options] [url|list ...]::download links and/or list files', './dneat.ps1 -InputFile <list>::download every URL in a list file', './dneat.ps1::download the URLs on the clipboard')),
        @('INPUT & OUTPUT', @('-InputFile (-i) <file>::list file with the URLs (clipboard)', '-OutputDir (-o) <dir>::download folder (.)', '-Force (-f)::replace files that already exist', '-KeepList (-k)::never ask to remove the URL list')),
        @('TRANSFER', @('-Jobs (-j) 1-16::files at the same time (1)', '-Connections (-c) 1-16::connections per file (16)', '-Limit (-l) <rate>::max total speed, e.g. 500K or 2M', '-Session (-s) <file>::where unfinished URLs are saved', '::(resume.session)')),
        @('SETUP', @('-InstallDeps (-y)::install aria2 (+ clipboard tool on Linux)', '-NoInstall (-n)::never install anything', '-Help (-h)   -Version (-v)::'))
    )
    foreach ($sec in $rows) {
        Open-Card $sec[0]
        $w = [Math]::Max(29, 2 + ($sec[1] | ForEach-Object { ($_ -split '::', 2)[0].Length } | Measure-Object -Maximum).Maximum)
        foreach ($r in $sec[1]) { $a, $b = $r -split '::', 2; Write-CardLine ("{0}{1}{2} {3}" -f $c.Ok, $a.PadRight($w), $c.Reset, $b) }
        Close-Card
    }
    Open-Card 'EXAMPLES'
    foreach ($e in @(@('./dneat.ps1', 'download the clipboard links'), @('./dneat.ps1 urls.txt', 'download every URL in a file'),
                     @('./dneat.ps1 https://a.io/x.zip <url>', 'download two links'), @('./dneat.ps1 -o ~/Downloads -j 3 urls.txt', '3 files in parallel'),
                     @('./dneat.ps1 -Limit 2M urls.txt', 'cap the speed at 2 MB/s'), @('./dneat.ps1 resume.session', 'continue an interrupted batch'),
                     @('./dneat.ps1 -y', 'install aria2'))) {
        Write-CardLine ('{0}${1} {2,-42} {3}# {4}{1}' -f $c.Acc, $c.Reset, $e[0], $c.Muted, $e[1])
    }
    Close-Card
    Open-Card 'GOOD TO KNOW'
    Write-CardLine "Links: https $($script:G.Dot) http $($script:G.Dot) ftps $($script:G.Dot) ftp $($script:G.Dot) sftp $($script:G.Dot) magnet"
    Write-CardLine 'Unfinished URLs are saved in resume.session - run'
    Write-CardLine '  ./dneat.ps1 resume.session  to continue them.'
    Write-CardLine 'aria2 list files work too (out=, dir=, mirrors).'
    Write-CardLine 'NO_COLOR=1 disables colours, DNEAT_ASCII=1 plain ASCII.'
    Write-CardLine 'DNEAT_NETWORK=online|offline skips the internet check.'
    Write-CardLine 'Windows: winget (or choco / scoop) installs aria2.'
    Write-CardLine 'Exit codes: 0 ok  1 error or a download failed  130 interrupted.'
    Close-Card
    Out-Ui ''
}

# ══ Main ═════════════════════════════════════════════════════════════════════════
function Invoke-Dneat {
    Initialize-Ui
    if ($Version) { Out-Ui "dneat $($script:DneatVersion)"; return 0 }
    if ($Help) { Show-Help; return 0 }
    Update-PathFromSystem
    Show-Banner; Show-System

    if ($Jobs -lt 1 -or $Jobs -gt 16) { Stop-Dneat 'Jobs must be a number from 1 to 16.' }
    if ($Connections -lt 1 -or $Connections -gt 16) { Stop-Dneat 'Connections must be a number from 1 to 16.' }
    if ($Limit) {
        if ($Limit -notmatch '^\d+(\.\d+)?[KkMm]?$') { Stop-Dneat "Invalid speed limit '$Limit'." @('Use a number with an optional K or M, e.g. 500K or 2M.') }
        $script:Limit = $Limit.ToUpperInvariant()
    }

    if ($InstallDeps) {
        $roles = @('aria2'); if ($IsLinux) { $roles += 'clipboard' }
        if (Install-Missing $roles) { Out-Ui "`n  $($script:C.Ok)$($script:C.Bold)$($script:G.Ok) Dependency setup finished.$($script:C.Reset) $($script:C.Muted)Re-run without -y to download.$($script:C.Reset)`n"; return 0 }
        return 1
    }

    # ── tools ──
    [void](Install-Missing @('aria2'))
    if (-not (Test-Role 'aria2')) { Stop-Dneat 'aria2 is not installed.' @("Install it manually: $(Get-ManualHint 'aria2')") }
    $script:Aria2 = Find-Tool 'aria2c'
    if (@($InputFile).Count -eq 0 -and @($Sources).Count -eq 0 -and $IsLinux) {
        [void](Install-Missing @('clipboard'))
        if (-not (Test-Role 'clipboard')) { Stop-Dneat 'No clipboard tool is installed.' @("Install one manually: $(Get-ManualHint 'clipboard')", 'Or pass URLs / a list file as arguments.') }
    }

    # ── input & layout ──
    Build-Input
    if (-not $OutputDir) { $OutputDir = '.' }
    [void](New-Item -ItemType Directory -Force -Path $OutputDir)
    $OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
    $script:SessionPath = [IO.Path]::GetFullPath($Session, $PWD.ProviderPath)
    $longest = 0; foreach ($u in $script:Urls) { $longest = [Math]::Max($longest, (Get-UrlName $u).Length) }
    $script:NameCol = [Math]::Max(8, [Math]::Min($longest, [Math]::Min(40, [Math]::Max(14, $script:Cols - 60))))
    Test-StaleSession
    Show-Plan

    # ── run ──
    $script:Finished = 0; $script:Ok = 0; $script:Fail = 0; $script:Skipped = 0; $script:TotalBytes = 0; $script:Frame = 0
    $script:ExcPending = $false; $script:ExcUri = ''; $script:ExcCode = 0; $script:ExcMsg = ''; $script:AriaRc = 0; $script:Remaining = 0
    try { Invoke-Aria2 } finally { if ($script:InputPath) { Remove-Item -LiteralPath $script:InputPath -Force -ErrorAction SilentlyContinue } }
    if ($script:AriaRc -ne 0 -and $script:AriaRc -ne 13 -and $script:Fail -eq 0 -and $script:Skipped -eq 0 -and $script:Ok -lt $script:Total) {
        $script:Fail = 1; Write-Warn "aria2 stopped with exit code $($script:AriaRc)."
    }
    Complete-Session
    Show-Summary
    Request-ListRemoval
    if ($script:Fail -eq 0) { 0 } else { 1 }
}

exit (Invoke-Dneat)
