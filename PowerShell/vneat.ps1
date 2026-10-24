<#
.SYNOPSIS
    vneat (Windows) - smart batch video to H.264/AAC MP4 converter.

.DESCRIPTION
    Encoder priority: NVENC (NVIDIA) -> QSV (Intel) -> AMF (AMD) -> CPU (libx264).
    Detects installed GPUs, tests each hardware encoder with a real 1-frame encode and installs
    ffmpeg automatically (winget -> Chocolatey -> Scoop) when it is missing. GPU drivers are never
    installed silently; a download link is shown when one is missing.
    Run  .\vneat.ps1 -Help  for the full, illustrated help.

.PARAMETER Files
    Specific video files to convert. If omitted, every supported video in the input folder is converted.

.PARAMETER InputDir
    Folder that contains the videos (default: current folder). Aliases: -i, -Input

.PARAMETER OutputDir
    Output folder (default: <InputDir>\compressed). Aliases: -o, -Output

.PARAMETER Quality
    Quality in percent, 1-100, higher = better (default: 50). Alias: -q

.PARAMETER MaxSize
    Cap the resolution: sd (854x480), hd (1280x720), fullhd (1920x1080) or 4k (3840x2160).
    Small videos are never upscaled; portrait videos are handled. Alias: -s

.PARAMETER Encoder
    auto (default), nvenc, qsv, amf or cpu. The CPU is always kept as a fallback. Alias: -e

.PARAMETER Menu
    Interactive menu: pick encoder, quality and size. Aliases: -m, -Interactive

.PARAMETER ListEncoders
    Show which encoders work on this machine and exit. Aliases: -l, -List

.PARAMETER CpuOnly
    Shortcut for -Encoder cpu. Aliases: -c, -Cpu

.PARAMETER NoPreserveTimes
    Do not copy the original file timestamps. Aliases: -t, -NoTimestamps

.PARAMETER NoInstall
    Never install anything (wins over -InstallDeps). Alias: -n

.PARAMETER InstallDeps
    Install ffmpeg and report GPU support, then exit. Alias: -y

.PARAMETER Help
    Show the illustrated help. Alias: -h

.PARAMETER Version
    Show the version. Alias: -V

.NOTES
    Environment: NO_COLOR=1 disables colors; VNEAT_NETWORK=online|offline skips the internet check.

.EXAMPLE
    .\vneat.ps1 -Quality 70
.EXAMPLE
    .\vneat.ps1 -i "$HOME\Videos" -s hd -m
.EXAMPLE
    .\vneat.ps1 clip1.mov clip2.mkv
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('i', 'Input')][string]$InputDir,
    [Alias('o', 'Output')][string]$OutputDir,
    [Alias('q')][ValidateRange(1, 100)][int]$Quality = 50,
    [Alias('s')][ValidateSet('sd', 'hd', 'fullhd', '4k')][string]$MaxSize,
    [Alias('e')][ValidateSet('auto', 'nvenc', 'qsv', 'amf', 'cpu')][string]$Encoder = 'auto',
    [Alias('m', 'Interactive')][switch]$Menu,
    [Alias('l', 'List')][switch]$ListEncoders,
    [Alias('c', 'Cpu')][switch]$CpuOnly,
    [Alias('t', 'NoTimestamps')][switch]$NoPreserveTimes,
    [Alias('n')][switch]$NoInstall,
    [Alias('y')][switch]$InstallDeps,
    [Alias('h')][switch]$Help,
    [Alias('V')][switch]$Version,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Files
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$AppVersion = '2.0.0'
$SupportedExts = 'mov', 'mp4', 'mkv', 'avi', 'webm'
$CompressedSubdir = 'compressed'
$EvenScale = 'scale=trunc(iw/2)*2:trunc(ih/2)*2'
$Resolutions = @{ sd = @(854, 480); hd = @(1280, 720); fullhd = @(1920, 1080); '4k' = @(3840, 2160) }

$FfmpegInstallers = @(
    @{ Tool = 'winget'; Args = @('install', '--id', 'Gyan.FFmpeg', '-e', '--silent', '--accept-source-agreements', '--accept-package-agreements') },
    @{ Tool = 'choco';  Args = @('install', 'ffmpeg', '-y') },
    @{ Tool = 'scoop';  Args = @('install', 'ffmpeg') }
)

$GpuEncoders = @(
    @{ Pattern = 'NVIDIA';                            Encoder = 'nvenc'; DriverUrl = 'https://www.nvidia.com/drivers' },
    @{ Pattern = 'Intel';                             Encoder = 'qsv';   DriverUrl = 'https://www.intel.com/content/www/us/en/download-center/home.html' },
    @{ Pattern = 'AMD|Radeon|Advanced Micro Devices'; Encoder = 'amf';   DriverUrl = 'https://www.amd.com/en/support' }
)

if ($CpuOnly) { $Encoder = 'cpu' }

$script:CurrentTmp = $null
$script:Online = $null
$script:Videos = @()
$script:Encoders = @()
$script:Gpus = @()
$script:NameCol = 24
$script:Ok = 0
$script:Failed = 0
$script:Skipped = 0
$script:TotalIn = [long]0
$script:TotalOut = [long]0
$script:TotalSrc = [long]0
$script:MediaSeconds = [double]0
$script:WallSeconds = [double]0
$script:EncoderUse = @{}
$script:StartedAt = Get-Date

# === UI layer ================================================================
# Glyphs are built from char codes so this file stays pure ASCII (safe for Windows PowerShell 5.1).
$UseColor = -not $env:NO_COLOR
$UseUnicode = [bool]($env:WT_SESSION -or $env:TERM_PROGRAM -or $env:ConEmuANSI)
if ($UseUnicode) {
    $G = @{
        Ok = [string][char]0x2714; Fail = [string][char]0x2716; Skip = [string][char]0x2298; Warn = [string][char]0x25B2
        Step = [string][char]0x25C6; Arrow = [string][char]0x2192; Dot = [string][char]0x00B7; Chain = [string][char]0x25B8
        Times = [string][char]0x00D7; Ellipsis = [string][char]0x2026; H = [string][char]0x2500; V = [string][char]0x2502
        TL = [string][char]0x256D + [string][char]0x2500; BL = [string][char]0x2570
        Up = [string][char]0x25B2; Down = [string][char]0x25BC
        BarFull = [string][char]0x2501; BarEmpty = [string][char]0x2500
    }
}
else {
    $G = @{
        Ok = '+'; Fail = 'x'; Skip = '-'; Warn = '!'; Step = '*'; Arrow = '->'; Dot = '-'; Chain = '>'
        Times = 'x'; Ellipsis = '~'; H = '-'; V = '|'; TL = '+-'; BL = '+'; Up = '^'; Down = 'v'
        BarFull = '#'; BarEmpty = '-'
    }
}
$Cols = try { $Host.UI.RawUI.WindowSize.Width } catch { 0 }
if ($Cols -lt 60) { $Cols = 100 }
$RuleWidth = if ($Cols -lt 66) { $Cols - 4 } else { 62 }
$BarWidth = if ($Cols -ge 100) { 30 } elseif ($Cols -ge 76) { 24 } else { 14 }

function Write-Seg([string]$Text, [string]$Color = '') {
    if ($Color -and $UseColor) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else { Write-Host $Text -NoNewline }
}

# Segments alternate: text, color, text, color, ...
function Write-Segments([object[]]$Segments) {
    for ($i = 0; $i -lt $Segments.Count; $i += 2) { Write-Seg $Segments[$i] $Segments[$i + 1] }
}
function Write-Row([object[]]$Segments) {
    Write-Segments $Segments
    Write-Host ''
}

function Write-Info([string]$Message) { Write-Host $Message }
function Write-Note([string]$Message) { Write-Row '  ', '', $Message, 'DarkGray' }
function Write-Step([string]$Message) { Write-Row '  ', '', $G.Step, 'Cyan', " $Message", '' }
function Write-Warn([string]$Message) { Write-Row '  ', '', "$($G.Warn) $Message", 'Yellow' }
function Stop-Script([string]$Message, [string[]]$Hints = @()) {
    Write-Host ''
    Write-Row '  ', '', "$($G.Fail) $Message", 'Red'
    foreach ($hint in $Hints) { Write-Row '    ', '', $hint, 'DarkGray' }
    Write-Host ''
    exit 1
}

# --- Cards: a titled block with a left gutter ---
function Write-CardOpen([string]$Title) {
    Write-Host ''
    Write-Row '  ', '', "$($G.TL) ", 'DarkGray', $Title, 'Cyan', " $($G.H * [Math]::Max(1, $RuleWidth - $Title.Length - 4))", 'DarkGray'
}
function Write-CardLine([object[]]$Segments = @()) { Write-Row (@('  ', '', $G.V, 'DarkGray', ' ', '') + $Segments) }
function Write-CardRow([string]$Key, [string]$Value) { Write-CardLine @(('{0,-10} ' -f $Key), 'DarkGray', $Value, '') }
function Write-CardClose { Write-Row '  ', '', "$($G.BL)$($G.H * ($RuleWidth - 1))", 'DarkGray' }

# --- Bars, badges, formatting ---
function Get-BarParts([int]$Percent, [int]$Width) {
    $cells = [Math]::Min($Width, [Math]::Max(0, [int][Math]::Floor($Percent * $Width / 100)))
    @(($G.BarFull * $cells), 'Cyan', ($G.BarEmpty * ($Width - $cells)), 'DarkGray')
}

function Write-Badge([string]$Name) {
    $label = switch ($Name) { 'nvenc' { 'NVENC' } 'qsv' { 'QSV' } 'amf' { 'AMF' } default { 'CPU' } }
    $color = switch ($Name) { 'nvenc' { 'Green' } 'qsv' { 'Cyan' } 'amf' { 'Red' } default { 'Gray' } }
    if ($UseColor) { Write-Host " $label " -ForegroundColor Black -BackgroundColor $color -NoNewline } else { Write-Host "[$label]" -NoNewline }
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -gt $Max) { $Text.Substring(0, [Math]::Max(1, $Max - 1)) + $G.Ellipsis } else { $Text }
}

function Format-Time([long]$Seconds) {
    if ($Seconds -ge 3600) { '{0}:{1:00}:{2:00}' -f [Math]::Floor($Seconds / 3600), [Math]::Floor(($Seconds % 3600) / 60), ($Seconds % 60) }
    else { '{0}:{1:00}' -f [Math]::Floor($Seconds / 60), ($Seconds % 60) }
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    else { '{0:N0} KB' -f ($Bytes / 1KB) }
}

function Get-QualityLabel([int]$Percent) {
    if ($Percent -ge 90) { 'near-lossless' } elseif ($Percent -ge 65) { 'high quality' } elseif ($Percent -ge 40) { 'balanced' }
    elseif ($Percent -ge 20) { 'small files' } else { 'tiny files' }
}

# Converts the user-facing percentage (higher = better) to ffmpeg's 1-51 scale (lower = better). 50% -> 26.
function Get-ActualQuality([int]$Percent) { 51 - [int][Math]::Floor([Math]::Min(100, [Math]::Max(1, $Percent)) / 2) }

function Get-EncoderLabel([string]$Name) {
    switch ($Name) {
        'nvenc' { 'NVIDIA NVENC' }
        'qsv'   { 'Intel QSV' }
        'amf'   { 'AMD AMF' }
        'cpu'   { 'CPU (libx264)' }
        'auto'  { 'Automatic (best available)' }
        default { $Name }
    }
}

# --- Logo, banner, system info, plan ---
function Write-Logo {
    $rows = @(
    '\u2588\u2588\u2557   \u2588\u2588\u2557\u2588\u2588\u2588\u2557   \u2588\u2588\u2557\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2557 \u2588\u2588\u2588\u2588\u2588\u2557 \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2557'
    '\u2588\u2588\u2551   \u2588\u2588\u2551\u2588\u2588\u2588\u2588\u2557  \u2588\u2588\u2551\u2588\u2588\u2554\u2550\u2550\u2550\u2550\u255D\u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557\u255A\u2550\u2550\u2588\u2588\u2554\u2550\u2550\u255D'
    '\u2588\u2588\u2551   \u2588\u2588\u2551\u2588\u2588\u2554\u2588\u2588\u2557 \u2588\u2588\u2551\u2588\u2588\u2588\u2588\u2588\u2557  \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2551   \u2588\u2588\u2551   '
    '\u255A\u2588\u2588\u2557 \u2588\u2588\u2554\u255D\u2588\u2588\u2551\u255A\u2588\u2588\u2557\u2588\u2588\u2551\u2588\u2588\u2554\u2550\u2550\u255D  \u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2551   \u2588\u2588\u2551   '
    ' \u255A\u2588\u2588\u2588\u2588\u2554\u255D \u2588\u2588\u2551 \u255A\u2588\u2588\u2588\u2588\u2551\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2557\u2588\u2588\u2551  \u2588\u2588\u2551   \u2588\u2588\u2551   '
    '  \u255A\u2550\u2550\u2550\u255D  \u255A\u2550\u255D  \u255A\u2550\u2550\u2550\u255D\u255A\u2550\u2550\u2550\u2550\u2550\u2550\u255D\u255A\u2550\u255D  \u255A\u2550\u255D   \u255A\u2550\u255D   '
    ) | ForEach-Object { [regex]::Unescape($_) }
    $ramp = 'DarkCyan', 'Cyan', 'Cyan', 'Green', 'Green', 'DarkGreen'
    Write-Host ''
    if ($UseUnicode -and $Cols -ge 52) {
        for ($i = 0; $i -lt $rows.Count; $i++) { Write-Row '  ', '', $rows[$i], $ramp[$i] }
    }
    else { Write-Row '  ', '', 'vneat', 'Cyan' }
}

function Write-Banner {
    Write-Host ''
    Write-Row '  ', '', "$($G.Step) vneat", 'Cyan', "  smart batch video $($G.Arrow) H.264/AAC converter $($G.Dot) v$AppVersion", 'DarkGray'
}

function Write-SystemInfo {
    $os = [Environment]::OSVersion.VersionString
    $cpu = $env:PROCESSOR_IDENTIFIER
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try {
            $os = (Get-CimInstance Win32_OperatingSystem).Caption
            $cpu = ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name -replace '\s+', ' ').Trim()
        } catch { }
    }
    Write-CardOpen 'System'
    Write-CardRow 'OS' $os
    if ($cpu) { Write-CardRow 'CPU' (Limit-Text $cpu ($Cols - 18)) }
    foreach ($gpu in $script:Gpus) { Write-CardRow 'GPU' (Limit-Text "$($gpu.Name) (driver $($gpu.DriverVersion))" ($Cols - 18)) }
    Write-CardClose
}

function Write-Plan {
    $parts = @(('{0,-10} ' -f 'Encoders'), 'DarkGray')
    for ($i = 0; $i -lt $script:Encoders.Count; $i++) {
        $label = Get-EncoderLabel $script:Encoders[$i]
        if ($i -eq 0) { $parts += $label, 'Green' } else { $parts += " $($G.Chain) ", 'DarkGray', $label, '' }
    }
    $size = if ($MaxSize) { "$MaxSize $($G.Dot) $($Resolutions[$MaxSize][0])x$($Resolutions[$MaxSize][1]) max $($G.Dot) never upscaled" } else { 'original size' }
    $times = if ($NoPreserveTimes) { 'not kept' } else { 'kept' }
    Write-CardOpen 'Plan'
    Write-CardLine $parts
    Write-CardRow 'Quality' "$Quality% $($G.Dot) $(Get-QualityLabel $Quality) (CRF $(Get-ActualQuality $Quality))"
    Write-CardRow 'Size' $size
    Write-CardRow 'Output' $OutputDir
    Write-CardRow 'Files' "$($script:Videos.Count) video(s) $($G.Dot) $(Format-Size $script:TotalSrc) $($G.Dot) timestamps $times"
    Write-CardClose
    Write-Host ''
}

# === Help ====================================================================
function Write-HelpOpt([string]$Flags, [string]$Text, [string]$Default = '') {
    $parts = @($Flags.PadRight(27), 'Green', ' ', '', $Text, '')
    if ($Default) { $parts += "  ($Default)", 'DarkGray' }
    Write-CardLine $parts
}
function Write-HelpCmd([string]$Command, [string]$Text) { Write-CardLine @('$ ', 'Cyan', $Command.PadRight(32), '', $Text, 'DarkGray') }
function Write-HelpExample([string]$Command, [string]$Text) { Write-CardLine @('$ ', 'Cyan', $Command.PadRight(39), '', "# $Text", 'DarkGray') }
function Write-HelpQuality([int]$Percent, [string]$Label, [string]$Marker = '') {
    $parts = @(('{0,4}%  ' -f $Percent), 'White') + (Get-BarParts $Percent 12) + @(('  ' + $Label.PadRight(14)), '', "CRF $(('{0,2}' -f (Get-ActualQuality $Percent)))", 'DarkGray')
    if ($Marker) { $parts += "   $($G.Chain) $Marker", 'Green' }
    Write-CardLine $parts
}

function Show-Help {
    Write-Logo
    Write-Host ''
    Write-Row '  ', '', "Smart batch video $($G.Arrow) H.264/AAC MP4 converter", 'White'
    Write-Row '  ', '', "GPU-accelerated $($G.Dot) automatic setup $($G.Dot) live progress $($G.Dot) v$AppVersion", 'DarkGray'

    Write-CardOpen 'USAGE'
    Write-HelpCmd 'vneat [options] [file ...]' 'convert specific files'
    Write-HelpCmd 'vneat [options] -i <folder>' 'convert every video in a folder'
    Write-HelpCmd 'vneat' 'convert the current folder'
    Write-CardLine @('(run as .\vneat.ps1 - every option also has a -LongName)', 'DarkGray')
    Write-CardClose

    Write-CardOpen 'INPUT & OUTPUT'
    Write-HelpOpt '-i, -InputDir <dir>' 'Folder that contains the videos' 'default: .'
    Write-HelpOpt '-o, -OutputDir <dir>' 'Output folder' "default: <input>\$CompressedSubdir"
    Write-HelpOpt '-t, -NoPreserveTimes' "Don't copy the original file dates"
    Write-CardClose

    Write-CardOpen 'QUALITY & SIZE'
    Write-HelpOpt '-q, -Quality <1-100>' 'Quality in %, higher = better' 'default: 50'
    Write-HelpOpt '-s, -MaxSize <preset>' 'Cap the resolution (never upscales,'
    Write-CardLine @((' ' * 27), '', ' keeps aspect ratio, portrait-aware)', '')
    Write-CardLine @((' ' * 27), '', " sd 854x480 $($G.Dot) hd 1280x720", 'DarkGray')
    Write-CardLine @((' ' * 27), '', " fullhd 1920x1080 $($G.Dot) 4k 3840x2160", 'DarkGray')
    Write-CardClose

    Write-CardOpen 'ENCODER'
    Write-HelpOpt '-e, -Encoder <name>' 'auto  nvenc  qsv  amf  cpu' 'default: auto'
    Write-HelpOpt '-c, -CpuOnly' 'Shortcut for -Encoder cpu'
    Write-HelpOpt '-l, -ListEncoders' 'Show which encoders work here, then exit'
    Write-HelpOpt '-m, -Menu' 'Pick encoder, quality and size from a menu'
    Write-CardLine
    Write-CardLine @('auto tries, in order: ', 'DarkGray', "NVIDIA NVENC $($G.Chain) Intel QSV $($G.Chain) AMD AMF $($G.Chain) CPU", '')
    Write-CardClose

    Write-CardOpen 'SETUP'
    Write-HelpOpt '-y, -InstallDeps' 'Install ffmpeg, check GPU support, then exit'
    Write-HelpOpt '-n, -NoInstall' 'Never install anything (wins over -y)'
    Write-CardClose

    Write-CardOpen 'OTHER'
    Write-HelpOpt '-h, -Help' 'Show this help'
    Write-HelpOpt '-V, -Version' 'Show the version'
    Write-CardClose

    Write-CardOpen 'QUALITY GUIDE'
    Write-HelpQuality 100 'near-lossless'
    Write-HelpQuality 75 'high quality'
    Write-HelpQuality 50 'balanced' 'default'
    Write-HelpQuality 25 'small files'
    Write-HelpQuality 10 'tiny files'
    Write-CardClose

    Write-CardOpen 'EXAMPLES'
    Write-HelpExample 'vneat' 'convert this folder, best settings'
    Write-HelpExample 'vneat -i ~\Videos -q 70' 'higher quality'
    Write-HelpExample 'vneat -s hd -e qsv -o out *.mov' '720p cap, force Intel QSV'
    Write-HelpExample 'vneat -MaxSize fullhd -c' '1080p cap on the CPU'
    Write-HelpExample 'vneat -m' 'guided interactive setup'
    Write-HelpExample 'vneat -l' 'list encoders that work here'
    Write-HelpExample 'vneat -y' 'install ffmpeg + check GPU support'
    Write-CardClose

    Write-CardOpen 'GOOD TO KNOW'
    Write-CardLine @('Formats      ', 'DarkGray', ($SupportedExts -join " $($G.Dot) "), '')
    Write-CardLine @('Audio        ', 'DarkGray', 'first audio track is kept (AAC 96k)', '')
    Write-CardLine @('Env          ', 'DarkGray', 'NO_COLOR=1  disable colors', '')
    Write-CardLine @('             ', 'DarkGray', 'VNEAT_NETWORK=online|offline  skip the internet check', '')
    Write-CardLine @('Drivers      ', 'DarkGray', 'GPU drivers are never installed silently; a link is shown', '')
    Write-CardLine @('Exit codes   ', 'DarkGray', '0 ok   1 error or a file failed', '')
    Write-CardClose
    Write-Host ''
}

# === Prerequisites ===========================================================
function Assert-Windows {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        Stop-Script 'This is the Windows script. Use vneat (Linux) or vneat.zsh (macOS).'
    }
}

function Test-Command([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

# --- Connectivity ---
function Test-TcpReachable {
    foreach ($address in '1.1.1.1', '8.8.8.8') {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $pending = $client.BeginConnect($address, 443, $null, $null)
            if ($pending.AsyncWaitHandle.WaitOne(2000) -and $client.Connected) { return $true }
        }
        catch { }
        finally { $client.Close() }
    }
    try { [void][System.Net.Dns]::GetHostAddresses('github.com'); return $true } catch { return $false }
}

function Test-Online {
    if ($null -eq $script:Online) {
        $override = if ($env:VNEAT_NETWORK) { $env:VNEAT_NETWORK } else { $env:VIDEO2MP4_NETWORK }
        if ($env:HTTPS_PROXY -or $env:HTTP_PROXY) { $script:Online = $true }
        else { $script:Online = switch ($override) { 'online' { $true } 'offline' { $false } default { Test-TcpReachable } } }
    }
    $script:Online
}

function Test-NetworkError([string]$Text) {
    $Text -match '(?i)could not resolve|name resolution|no such host|network is unreachable|timed out|timeout|unable to connect|connection (refused|reset|was closed)|0x80072ee[27d]|0x80072efe|failed (to download|when searching source)|no internet'
}

# --- Installing ffmpeg ---
function Invoke-Installer([string]$Tool, [string[]]$ToolArgs) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # installers write progress to stderr
    try { (& $Tool @ToolArgs 2>&1 | Out-String) } finally { $ErrorActionPreference = $previous }
}

function Get-LastLine([string]$Text) {
    $line = ($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($line) { Limit-Text $line.Trim() 110 } else { '' }
}

function Install-Ffmpeg {
    foreach ($installer in $FfmpegInstallers) {
        if (-not (Test-Command $installer.Tool)) { continue }
        Write-Step "Installing ffmpeg via $($installer.Tool)..."
        $toolArgs = $installer.Args
        $output = Invoke-Installer $installer.Tool $toolArgs
        Update-SessionPath
        if (Test-Command 'ffmpeg') { return }
        if (Test-NetworkError $output) {
            $script:Online = $false
            Write-Warn "$($installer.Tool): network problem - check your internet connection."
            return
        }
        $reason = Get-LastLine $output
        $suffix = if ($reason) { ": $reason" } else { '' }
        Write-Warn "$($installer.Tool) could not install ffmpeg$suffix"
    }
}

function Initialize-Ffmpeg {
    if (Test-Command 'ffmpeg') { return }
    $hint = 'winget install Gyan.FFmpeg   (or download from https://www.gyan.dev/ffmpeg/builds/)'
    if ($NoInstall) { Stop-Script 'ffmpeg is not installed (auto-install disabled).' @("Install it manually: $hint") }
    if (-not (Test-Online)) {
        Stop-Script 'ffmpeg is not installed and there is no internet connection.' @('Connect to the network and run again, or install it manually:', $hint)
    }
    if (-not ((Test-Command 'winget') -or (Test-Command 'choco') -or (Test-Command 'scoop'))) {
        Stop-Script 'ffmpeg is not installed and no package manager (winget, Chocolatey, Scoop) was found.' @('Install it manually: https://www.gyan.dev/ffmpeg/builds/')
    }
    Install-Ffmpeg
    if (Test-Command 'ffmpeg') { return }
    if ($script:Online -eq $false) {
        Stop-Script 'ffmpeg could not be downloaded (network problem).' @('Check your internet connection and run again, or install it manually:', $hint)
    }
    Stop-Script 'ffmpeg installation failed.' @("Install it manually: $hint")
}

function Initialize-Gpus {
    $script:Gpus = @()
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try { $script:Gpus = @(Get-CimInstance Win32_VideoController) } catch { }
    }
}

function Get-DetectedGpuEncoders {
    if ($script:Gpus | Where-Object { $_.Name -match 'Basic Display' }) {
        Write-Warn 'A GPU is using the generic Microsoft driver - install the vendor driver for hardware encoding.'
    }
    foreach ($entry in $GpuEncoders) {
        if ($script:Gpus | Where-Object { "$($_.Name) $($_.AdapterCompatibility)" -match $entry.Pattern }) { $entry }
    }
}

# === Running native tools ====================================================
function ConvertTo-ArgumentString([string[]]$Items) {
    ($Items | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
}

# Runs a tool without a shell, streaming stdout lines to $OnLine; stderr is collected.
function Invoke-Native([string]$Tool, [string[]]$ToolArgs, [scriptblock]$OnLine) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command $Tool).Source
    $startInfo.Arguments = ConvertTo-ArgumentString $ToolArgs
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $lines = New-Object System.Collections.Generic.List[string]
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $errorTask = $process.StandardError.ReadToEndAsync()
        while ($null -ne ($line = $process.StandardOutput.ReadLine())) {
            $lines.Add($line)
            if ($OnLine) { & $OnLine $line }
        }
        $process.WaitForExit()
        $lastError = ($errorTask.Result.Trim() -split "`r?`n" | Select-Object -Last 1)
        [pscustomobject]@{ Success = ($process.ExitCode -eq 0); Lines = $lines; Error = $lastError }
    }
    finally {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
}

# === Encoders ================================================================
# Cap the output to max WxH (swapped for portrait videos), keep the aspect ratio and never upscale.
# min(iw,..)/min(ih,..) is what prevents upscaling; force_original_aspect_ratio=decrease alone would
# still stretch a small source up to the box.
function Get-VideoFilter {
    if (-not $MaxSize) { return $EvenScale }
    $w, $h = $Resolutions[$MaxSize]
    "scale=w='if(gt(a,1),min(iw,$w),min(iw,$h))':h='if(gt(a,1),min(ih,$h),min(ih,$w))':force_original_aspect_ratio=decrease,$EvenScale"
}

function Get-EncoderArgs([string]$Name) {
    $q = "$(Get-ActualQuality $Quality)"
    switch ($Name) {
        'nvenc' { @('-c:v', 'h264_nvenc', '-rc', 'vbr', '-cq', $q, '-b:v', '0', '-pix_fmt', 'yuv420p') }
        'qsv'   { @('-c:v', 'h264_qsv', '-global_quality', $q, '-pix_fmt', 'nv12') }
        'amf'   { @('-c:v', 'h264_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', $q, '-qp_p', $q, '-pix_fmt', 'yuv420p') }
        'cpu'   { @('-c:v', 'libx264', '-crf', $q, '-preset', 'medium', '-pix_fmt', 'yuv420p') }
    }
}

# Real 1-frame test encode using the exact arguments used for conversion.
function Test-Encoder([string]$Name) {
    $probe = @('-nostdin', '-hide_banner', '-loglevel', 'quiet',
               '-f', 'lavfi', '-i', 'color=c=black:s=256x256:d=0.1', '-vf', (Get-VideoFilter)) +
             (Get-EncoderArgs $Name) + @('-frames:v', '1', '-f', 'null', '-')
    (Invoke-Native 'ffmpeg' $probe $null).Success
}

function Get-AvailableEncoders {
    $available = @()
    if ($Encoder -ne 'cpu') {
        foreach ($entry in Get-DetectedGpuEncoders) {
            if (Test-Encoder $entry.Encoder) { $available += $entry.Encoder; continue }
            Write-Warn "$(Get-EncoderLabel $entry.Encoder) unavailable (driver or ffmpeg build). Update the GPU driver: $($entry.DriverUrl)"
        }
    }
    $available + 'cpu'
}

# Keeps only the requested encoder (plus the CPU as a safety net).
function Select-RequestedEncoder([string[]]$Available) {
    if ($Encoder -eq 'auto') { return $Available }
    if ($Encoder -eq 'cpu') { return @('cpu') }
    if ($Available -notcontains $Encoder) { Stop-Script "Encoder '$Encoder' is not available." @("Available: $($Available -join ', ')") }
    @($Encoder, 'cpu')
}

function Select-EncoderInteractively([string[]]$Available) {
    $options = @('auto') + $Available
    Write-CardOpen 'Interactive setup'
    Write-CardLine @('Encoder', 'White')
    for ($i = 0; $i -lt $options.Count; $i++) { Write-CardLine @("  $($i + 1)  ", 'Cyan', (Get-EncoderLabel $options[$i]), '') }
    $choice = Read-Host '  Choice [1]'
    if (-not $choice) { $choice = '1' }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $options.Count) { Stop-Script 'Invalid choice.' }
    $script:Encoder = $options[$number - 1]
    $answer = Read-Host "  Quality 1-100, higher = better [$Quality]"
    if ($answer) {
        $value = 0
        if (-not [int]::TryParse($answer, [ref]$value) -or $value -lt 1 -or $value -gt 100) { Stop-Script 'Quality must be a number from 1 to 100.' }
        $script:Quality = $value
    }
    $shown = if ($MaxSize) { $MaxSize } else { 'none' }
    $answer = (Read-Host "  Max size sd | hd | fullhd | 4k | none [$shown]").Trim().ToLower()
    if ($answer) {
        if ($answer -eq 'none') { $script:MaxSize = '' }
        elseif ($Resolutions.ContainsKey($answer)) { $script:MaxSize = $answer }
        else { Stop-Script "Invalid max size '$answer'." @('Choose one of: sd, hd, fullhd, 4k, none.') }
    }
    Write-CardClose
}

function Get-ConvertArgs([string]$Source, [string]$Target, [string]$EncoderName) {
    @('-nostdin', '-hide_banner', '-loglevel', 'error', '-nostats', '-progress', 'pipe:1', '-i', $Source,
      '-map', '0:v:0', '-map', '0:a:0?', '-sn', '-dn', '-vf', (Get-VideoFilter)) +
    (Get-EncoderArgs $EncoderName) +
    @('-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', '-f', 'mp4', '-y', $Target)
}

# === Files ===================================================================
function Get-InputVideos {
    if ($Files) {
        foreach ($path in $Files) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Warn "File not found: $path"; continue }
            $item = Get-Item -LiteralPath $path
            if ($SupportedExts -contains $item.Extension.TrimStart('.')) { $item; continue }
            Write-Note "$($G.Skip) $($item.Name) (unsupported)"
            $script:Skipped++
        }
        return
    }
    Get-ChildItem -LiteralPath $InputDir -File |
        Where-Object { $SupportedExts -contains $_.Extension.TrimStart('.') } |
        Sort-Object Name
}

function Get-DurationUs([string]$Path) {
    if (-not (Test-Command 'ffprobe')) { return [long]0 }
    $result = Invoke-Native 'ffprobe' @('-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', $Path) $null
    $seconds = 0.0
    if ($result.Success -and $result.Lines.Count -gt 0 -and
        [double]::TryParse($result.Lines[0], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
        return [long]($seconds * 1000000)
    }
    [long]0
}

function Copy-Timestamps([System.IO.FileInfo]$From, [string]$To) {
    $target = Get-Item -LiteralPath $To
    $target.CreationTime = $From.CreationTime
    $target.LastWriteTime = $From.LastWriteTime
    $target.LastAccessTime = $From.LastAccessTime
}

# === Progress & reporting ====================================================
function Update-FileProgress($State, [long]$DurationUs, [string]$Label, [string]$EncoderName, [int]$Index, [int]$Total) {
    $elapsed = ([DateTime]::UtcNow - $State.Started).TotalSeconds
    $percent = -1
    $eta = '--:--'
    if ($DurationUs -gt 0) {
        $percent = [Math]::Min(100, [int][Math]::Floor($State.OutUs * 100 / $DurationUs))
        if ($State.OutUs -gt 0 -and $elapsed -ge 1 -and $State.OutUs -lt $DurationUs) {
            $eta = Format-Time ([long]($elapsed * ($DurationUs - $State.OutUs) / $State.OutUs))
        }
    }
    $status = if ($percent -ge 0) { '{0,3}%  {1}  ETA {2}  [{3}]' -f $percent, $State.Speed, $eta, $EncoderName }
              else { '{0}  {1}  [{2}]' -f (Format-Time ([long]$elapsed)), $State.Speed, $EncoderName }
    $overall = [int][Math]::Floor((($Index - 1) * 100 + [Math]::Max(0, $percent)) / $Total)
    Write-Progress -Id 0 -Activity "vneat - batch" -Status "File $Index of $Total  ($overall% overall)" -PercentComplete $overall
    $progress = @{ Id = 1; ParentId = 0; Activity = "[$Index/$Total] $Label"; Status = $status }
    if ($percent -ge 0) { $progress.PercentComplete = $percent }
    Write-Progress @progress
}

function Write-ReportOk([string]$Tag, [string]$Name, [long]$InBytes, [long]$OutBytes, [string]$EncoderName, [long]$Seconds) {
    $delta = [int][Math]::Round(($OutBytes - $InBytes) * 100 / [Math]::Max(1, $InBytes))
    $arrow, $color = if ($delta -le 0) { $G.Down, 'Green' } else { $G.Up, 'Yellow' }
    $shown = Limit-Text $Name $script:NameCol
    Write-Segments @('  ', '', $G.Ok, 'Green', " $Tag ", 'DarkGray', $shown.PadRight($script:NameCol), 'White',
        ('  {0,9} {1} {2,-9}  ' -f (Format-Size $InBytes), $G.Arrow, (Format-Size $OutBytes)), '',
        ('{0} {1,3}%  ' -f $arrow, [Math]::Abs($delta)), $color)
    Write-Badge $EncoderName
    Write-Row '  ', '', (Format-Time $Seconds), 'DarkGray'
}

function Write-ReportNote([string]$Kind, [string]$Tag, [string]$Name, [string]$Detail) {
    $glyph, $color = if ($Kind -eq 'fail') { $G.Fail, 'Red' } else { $G.Skip, 'DarkGray' }
    $room = [Math]::Max(10, $Cols - $Tag.Length - $script:NameCol - 8)
    $shown = Limit-Text $Name $script:NameCol
    Write-Row '  ', '', $glyph, $color, " $Tag ", 'DarkGray', $shown.PadRight($script:NameCol), 'White', "  $(Limit-Text $Detail $room)", $color
}

function Convert-Video([System.IO.FileInfo]$Source, [int]$Index) {
    $total = $script:Videos.Count
    $tag = "[$Index/$total]"
    $out = Join-Path $OutputDir "$($Source.BaseName).mp4"
    $script:CurrentTmp = Join-Path $OutputDir ".$($Source.BaseName).partial.mp4"

    if ($Source.DirectoryName -eq $OutputDir) {
        Write-ReportNote 'skip' $tag $Source.Name 'already in the output folder'; $script:Skipped++; return
    }
    if (Test-Path -LiteralPath $out) {
        Write-ReportNote 'skip' $tag $Source.Name 'output already exists'; $script:Skipped++; return
    }

    $durationUs = Get-DurationUs $Source.FullName
    $startedFile = Get-Date
    $lastEncoder = $script:Encoders[-1]
    $reason = ''

    foreach ($candidate in $script:Encoders) {
        $state = @{ OutUs = [long]0; Speed = '--'; Started = [DateTime]::UtcNow }
        $onLine = {
            param($Line)
            if ($Line -match '^out_time_(us|ms)=(\d+)$') { $state.OutUs = [long]$Matches[2] }
            elseif ($Line -match '^speed=\s*(\S+)') { $state.Speed = $(if ($Matches[1] -eq 'N/A') { '--' } else { $Matches[1] }) }
            elseif ($Line -like 'progress=*') { Update-FileProgress $state $durationUs $Source.Name $candidate $Index $total }
        }
        Update-FileProgress $state $durationUs $Source.Name $candidate $Index $total
        $result = Invoke-Native 'ffmpeg' (Get-ConvertArgs $Source.FullName $script:CurrentTmp $candidate) $onLine
        Write-Progress -Id 1 -ParentId 0 -Activity $Source.Name -Completed

        if ($result.Success) {
            Move-Item -LiteralPath $script:CurrentTmp -Destination $out -Force
            if (-not $NoPreserveTimes) { Copy-Timestamps $Source $out }
            $outBytes = (Get-Item -LiteralPath $out).Length
            $seconds = [long]((Get-Date) - $startedFile).TotalSeconds
            $script:TotalIn += $Source.Length
            $script:TotalOut += $outBytes
            $script:MediaSeconds += $durationUs / 1000000.0
            $script:WallSeconds += ((Get-Date) - $startedFile).TotalSeconds
            $script:EncoderUse[$candidate] = 1 + $(if ($script:EncoderUse.ContainsKey($candidate)) { $script:EncoderUse[$candidate] } else { 0 })
            Write-ReportOk $tag $Source.Name $Source.Length $outBytes $candidate $seconds
            $script:Ok++
            return
        }
        Remove-Item -LiteralPath $script:CurrentTmp -Force -ErrorAction SilentlyContinue
        $reason = $result.Error
        if ($candidate -ne $lastEncoder) {
            $suffix = if ($reason) { ": $reason" } else { '' }
            Write-Warn "$(Get-EncoderLabel $candidate) failed$suffix - trying next encoder"
        }
    }
    $detail = if ($reason) { "failed: $reason" } else { 'failed' }
    Write-ReportNote 'fail' $tag $Source.Name $detail
    $script:Failed++
}

function Write-Summary {
    Write-CardOpen 'Summary'
    $parts = @(('{0,-10} ' -f 'Result'), 'DarkGray', "$($G.Ok) $($script:Ok) converted", 'Green')
    if ($script:Failed -gt 0) { $parts += '   ', '', "$($G.Fail) $($script:Failed) failed", 'Red' }
    if ($script:Skipped -gt 0) { $parts += '   ', '', "$($G.Skip) $($script:Skipped) skipped", 'DarkGray' }
    Write-CardLine $parts
    if ($script:TotalIn -gt 0) {
        $saved = $script:TotalIn - $script:TotalOut
        $percent = [int][Math]::Floor([Math]::Abs($saved) * 100 / $script:TotalIn)
        $verdict, $color = if ($saved -ge 0) { "$($G.Down) $percent% smaller", 'Green' } else { "$($G.Up) $percent% larger", 'Yellow' }
        Write-CardLine @(('{0,-10} ' -f 'Size'), 'DarkGray', "$(Format-Size $script:TotalIn) $($G.Arrow) $(Format-Size $script:TotalOut)  ", '', $verdict, $color)
        $kept = [Math]::Min(100, [int][Math]::Floor($script:TotalOut * 100 / $script:TotalIn))
        Write-CardLine (@(('{0,-10} ' -f ''), '') + (Get-BarParts $kept 24) + @("  $kept% of original", 'DarkGray'))
        if ($saved -gt 0) { Write-CardLine @(('{0,-10} ' -f 'Saved'), 'DarkGray', (Format-Size $saved), 'Green') }
    }
    if ($script:WallSeconds -gt 0 -and $script:MediaSeconds -gt 0) {
        Write-CardRow 'Speed' ('{0:N1}{1} realtime' -f ($script:MediaSeconds / $script:WallSeconds), $G.Times)
    }
    if ($script:EncoderUse.Count -gt 0) {
        $used = ($script:EncoderUse.Keys | ForEach-Object { "$(Get-EncoderLabel $_) $($G.Times)$($script:EncoderUse[$_])" }) -join '  '
        Write-CardRow 'Encoders' $used
    }
    Write-CardRow 'Time' (Format-Time ([long]((Get-Date) - $script:StartedAt).TotalSeconds))
    Write-CardRow 'Output' $OutputDir
    Write-CardClose
    Write-Host ''
    if ($script:Failed -eq 0) { Write-Row '  ', '', "$($G.Ok) All done.", 'Green' }
    else { Write-Row '  ', '', "$($G.Fail) Finished with $($script:Failed) failure(s).", 'Red' }
    Write-Host ''
}

# === Dependencies (-y) ========================================================
function Install-Dependencies {
    if ($NoInstall) { Write-Warn '-n (no install) takes precedence over -y - nothing was installed.'; exit 1 }
    if (-not (Test-Online)) { Write-Warn 'No internet connection - dependencies were not installed.'; exit 1 }
    Initialize-Ffmpeg
    Write-Note 'ffmpeg is ready.'
    $available = @(Get-AvailableEncoders)
    Write-Note "Encoders that work here: $($available -join ', ')"
    Write-Host ''
    Write-Row '  ', '', "$($G.Ok) Dependency setup finished.", 'Green', ' Re-run without -y to convert videos.', 'DarkGray'
    Write-Host ''
}

# === Main ====================================================================
function Main {
    Assert-Windows
    if ($Help) { Show-Help; return }
    if ($Version) { Write-Info "vneat $AppVersion"; return }
    Initialize-Gpus
    if (-not $ListEncoders) { Write-Banner; Write-SystemInfo }

    if ($Files) {
        if (-not $OutputDir) { $script:OutputDir = ".\$CompressedSubdir" }
    }
    else {
        if (-not $InputDir) { $script:InputDir = '.' }
        if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) { Stop-Script "Folder '$InputDir' not found." }
        if (-not $OutputDir) { $script:OutputDir = Join-Path $InputDir $CompressedSubdir }
    }
    if ($InstallDeps) { Install-Dependencies; return }
    if (-not $ListEncoders) {
        $script:Videos = @(Get-InputVideos)
        if ($script:Videos.Count -eq 0) { Stop-Script 'No supported video files found.' }
    }

    Initialize-Ffmpeg
    $available = @(Get-AvailableEncoders)
    if ($ListEncoders) { Write-Info "Available encoders: $($available -join ', ')"; return }
    if ($Menu) { Select-EncoderInteractively $available }
    $script:Encoders = @(Select-RequestedEncoder $available)
    $script:OutputDir = (New-Item -ItemType Directory -Force -Path $OutputDir).FullName

    $longest = ($script:Videos | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    $script:TotalSrc = [long](($script:Videos | Measure-Object -Property Length -Sum).Sum)
    $script:NameCol = [Math]::Max(8, [Math]::Min($longest, [Math]::Min(40, [Math]::Max(14, $Cols - 60))))
    Write-Plan

    for ($i = 0; $i -lt $script:Videos.Count; $i++) { Convert-Video $script:Videos[$i] ($i + 1) }

    Write-Progress -Id 1 -Activity 'vneat' -Completed
    Write-Progress -Id 0 -Activity 'vneat' -Completed
    Write-Summary
    if ($script:Failed -gt 0) { exit 1 }
}

try { Main }
finally {
    if ($script:CurrentTmp) { Remove-Item -LiteralPath $script:CurrentTmp -Force -ErrorAction SilentlyContinue }
}
