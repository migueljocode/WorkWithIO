#Requires -Version 7.0
<#
.SYNOPSIS
    pneat (PowerShell) - smart batch image -> JPEG converter. Windows, macOS and Linux (PowerShell 7+).
.DESCRIPTION
    Standard images go through ImageMagick; RAW files through LibRaw (dcraw_emu) -> dcraw -> embedded preview.
    Missing prerequisites are installed only when needed (winget / Homebrew / apt / dnf / pacman).
    Run  ./pneat.ps1 -Help  for every option.  Defaults match pneat 1.4.1 (bash / zsh).
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [string[]] $Files = @(),
    [Alias('i', 'Input')]   [string] $InputDir = '',
    [Alias('o', 'Output')]  [string] $OutputDir = '',
    [Alias('q')]  [ValidateRange(1, 100)] [int] $Quality = 80,
    [Alias('s', 'Size')] [ValidateSet('', 'sd', 'hd', 'fullhd', '4k')] [string] $MaxSize = '',
    [Alias('hl')] [ValidateRange(0, 9)] [int] $Highlight = 5,
    [Alias('b')]  [ValidateRange(0.05, 10)] [double] $Brightness = 1.9,
    [Alias('c')]  [ValidateRange(0, 20)] [int] $Contrast = 6,
    [Alias('sat')] [ValidateRange(0, 200)] [int] $Saturation = 112,
    [Alias('sharp')] [ValidateRange(0, 100)] [int] $Sharpen = 70,
    [Alias('d')]  [ValidateSet('auto', 'libraw', 'dcraw', 'preview')] [string] $Decoder = 'auto',
    [Alias('dm')] [ValidateSet('auto', 'linear', 'vng', 'ppg', 'ahd', 'dcb', 'dht', 'aahd')] [string] $Demosaic = 'auto',
    [Alias('dn')] [string] $Denoise = 'auto',
    [ValidateSet('auto', '0', '1', '2')] [string] $Fbdd = 'auto',
    [string] $MaxAdjust = 'auto',
    [string] $LibRawArgs = '',
    [Alias('j')]  [string] $Jobs = 'auto',
    [switch] $DcbEnhance, [switch] $Best,
    [Alias('t')] [switch] $NoTimestamps,
    [Alias('w')] [switch] $NoCameraWb,
    [Alias('a')] [switch] $NoAutoLevel,
    [Alias('n')] [switch] $NoInstall,
    [Alias('y')] [switch] $InstallDeps,
    [Alias('l')] [switch] $ListDecoders,
    [Alias('m')] [switch] $Interactive,
    [Alias('f')] [switch] $Force,
    [Alias('k')] [switch] $SkipExisting,
    [Alias('z')] [switch] $DryRun,
    [Alias('h', '?')] [switch] $Help,
    [Alias('v')] [switch] $Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PneatVersion = '1.4.1'
$script:RAW_EXTS = 'cr2 cr3 crw dng nef nrw arw srf sr2 raf orf rw2 pef srw mos 3fr mef mrw x3f rwl iiq dcr kdc erf'.Split(' ')
$script:STD_EXTS = ('jpg jpeg jfif png gif tiff tif webp bmp jp2 j2k j2c jpf jpx jpm mj2 heic heif avif avifs jxl psd psb xcf ' +
                    'xpm xbm pcx tga sgi pnm pgm pbm ppm pam hdr exr ico cur wbmp').Split(' ')
$script:RES = @{ sd = 854; hd = 1280; fullhd = 1920; '4k' = 3840 }
$script:SUBDIR = 'compressed'
$script:StartedAt = [Diagnostics.Stopwatch]::StartNew()
$script:Pids = [System.Collections.Concurrent.ConcurrentDictionary[int, bool]]::new()

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
        $script:C = @{ Reset = "$ESC[0m"; Bold = "$ESC[1m"; Acc = "$ESC[38;5;220m"; Ok = "$ESC[38;5;114m"
                       Warn = "$ESC[38;5;208m"; Err = "$ESC[38;5;203m"; Muted = "$ESC[38;5;244m" }
    }
    $script:RuleW = if ($script:Cols -lt 66) { $script:Cols - 4 } else { 62 }
    $script:BarW = if ($script:Cols -ge 100) { 30 } elseif ($script:Cols -ge 76) { 24 } else { 14 }
    if ($env:PNEAT_ASCII) {
        $script:G = @{ Ok = '+'; Fail = 'x'; Skip = '-'; Warn = '!'; Step = '*'; Arrow = '->'; Chain = '>'; Dot = '-'; Ell = '~'
                       Up = '^'; Down = 'v'; H = '-'; V = '|'; TL = '+-'; BL = '+'; Full = '#'; Head = ''; Empty = '-'
                       Spin = @('|', '/', '-', '\'); Unicode = $false }
    } else {
        $script:G = @{ Ok = '✔'; Fail = '✖'; Skip = '⊘'; Warn = '▲'; Step = '◆'; Arrow = '→'; Chain = '▸'; Dot = '·'; Ell = '…'
                       Up = '▲'; Down = '▼'; H = '─'; V = '│'; TL = '╭─'; BL = '╰'; Full = '━'; Head = '╸'; Empty = '─'
                       Spin = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'); Unicode = $true }
    }
}

function Out-Ui([string] $Text = '', [switch] $NoNewline) { Write-Host $Text -NoNewline:$NoNewline }
function Get-Rep([string] $S, [int] $N) { if ($N -le 0) { '' } else { $S * $N } }
function Get-Clip([string] $T, [int] $Max) { if ($T.Length -gt $Max) { $T.Substring(0, [Math]::Max(0, $Max - 1)) + $script:G.Ell } else { $T } }
function Get-Pad([string] $T, [int] $W) { $t = Get-Clip $T $W; $t + (Get-Rep ' ' ($W - $t.Length)) }

function Format-Ms([long] $Ms) {
    if ($Ms -lt 10000) { return ('{0}.{1}s' -f [Math]::Floor($Ms / 1000), [Math]::Floor(($Ms % 1000) / 100)) }
    if ($Ms -lt 60000) { return ('{0}s' -f [Math]::Floor($Ms / 1000)) }
    Format-Time ([Math]::Floor($Ms / 1000))
}
function Format-Time([long] $S) {
    if ($S -ge 3600) { '{0}:{1:00}:{2:00}' -f [Math]::Floor($S / 3600), [Math]::Floor(($S % 3600) / 60), ($S % 60) }
    else { '{0}:{1:00}' -f [Math]::Floor($S / 60), ($S % 60) }
}
function Format-Bytes([double] $B) {
    $units = 'B', 'KB', 'MB', 'GB', 'TB'; $u = 0
    while ($B -ge 1024 -and $u -lt 4) { $B /= 1024; $u++ }
    if ($u -eq 0) { '{0} B' -f [int]$B } else { '{0:0.0} {1}' -f $B, $units[$u] }
}
function Get-QualityLabel([int] $Q) {
    if ($Q -ge 90) { 'near-lossless' } elseif ($Q -ge 75) { 'high quality' } elseif ($Q -ge 50) { 'balanced' }
    elseif ($Q -ge 30) { 'small files' } else { 'tiny files' }
}
function Get-EngineLabel([string] $E) {
    switch ($E) { 'im' { 'ImageMagick' } 'libraw' { 'LibRaw (dcraw_emu)' } 'dcraw' { 'dcraw' } 'preview' { 'Embedded preview' } default { $E } }
}
function Get-Badge([string] $E) {
    $label = switch ($E) { 'im' { 'IM' } 'libraw' { 'LIBRAW' } 'dcraw' { 'DCRAW' } 'preview' { 'PREVIEW' } default { $E.ToUpper() } }
    if ($script:ColorLevel -lt 2) { return "[$label]" }
    $bg = switch ($E) { 'im' { 228 } 'dcraw' { 214 } 'libraw' { 220 } default { 250 } }
    "$ESC[48;5;${bg};38;5;16m $label $($script:C.Reset)"
}

function Write-Note([string] $T) { Out-Ui "  $($script:C.Muted)$T$($script:C.Reset)" }
function Write-Step([string] $T) { Out-Ui "  $($script:C.Acc)$($script:G.Step)$($script:C.Reset) $T" }
function Write-Warn([string] $T) { Out-Ui "  $($script:C.Warn)$($script:G.Warn) $T$($script:C.Reset)" }
function Stop-Pneat([string] $Message, [string[]] $Hints = @()) {
    Out-Ui ''
    Out-Ui "  $($script:C.Err)$($script:G.Fail) $Message$($script:C.Reset)"
    foreach ($h in $Hints) { Out-Ui "    $($script:C.Muted)$h$($script:C.Reset)" }
    Out-Ui ''
    exit 1
}

function Open-Card([string] $Title) {
    $c = $script:C
    Out-Ui ''
    Out-Ui "  $($c.Muted)$($script:G.TL) $($c.Bold)$($c.Acc)$Title$($c.Reset)$($c.Muted) $(Get-Rep $script:G.H ($script:RuleW - $Title.Length - 4))$($c.Reset)"
}
function Write-CardLine([string] $T = '') { Out-Ui "  $($script:C.Muted)$($script:G.V)$($script:C.Reset)$(if ($T) { " $T" })" }
function Write-CardRow([string] $Label, [string] $Value) { Write-CardLine ("{0}{1,-10}{2} {3}" -f $script:C.Muted, $Label, $script:C.Reset, $Value) }
function Close-Card { Out-Ui "  $($script:C.Muted)$($script:G.BL)$(Get-Rep $script:G.H ($script:RuleW - 1))$($script:C.Reset)" }

function Get-Bar([int] $Pct, [int] $Width) {
    $cells = [Math]::Floor($Pct * $Width / 100)
    $head = 0
    if ($script:G.Head -and $cells -lt $Width -and (($Pct * $Width) % 100) -ge 50) { $head = 1 }
    $ramp = 208, 214, 220, 226, 227, 228
    $sb = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $cells + $head; $i++) {
        $w = [Math]::Max(1, $Width - 1)
        $col = if ($script:ColorLevel -ge 3) { "$ESC[38;2;255;$([int](150 + 95 * $i / $w));$([int](20 + 80 * $i / $w))m" }
               elseif ($script:ColorLevel -eq 2) { "$ESC[38;5;$($ramp[[Math]::Min(5, [int](5 * $i / $w))])m" } else { '' }
        [void]$sb.Append($col).Append($(if ($i -lt $cells) { $script:G.Full } else { $script:G.Head }))
    }
    $empty = $Width - $cells - $head
    "$($sb.ToString())$($script:C.Reset)$($script:C.Muted)$(Get-Rep $script:G.Empty $empty)$($script:C.Reset)"
}

function Show-Logo {
    $rows = '██████╗ ███╗   ██╗███████╗ █████╗ ████████╗', '██╔══██╗████╗  ██║██╔════╝██╔══██╗╚══██╔══╝',
            '██████╔╝██╔██╗ ██║█████╗  ███████║   ██║   ', '██╔═══╝ ██║╚██╗██║██╔══╝  ██╔══██║   ██║   ',
            '██║     ██║ ╚████║███████╗██║  ██║   ██║   ', '╚═╝     ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝   ╚═╝   '
    $ramp = 214, 220, 221, 226, 227, 228
    Out-Ui ''
    if ($script:G.Unicode -and $script:Cols -ge 52) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($script:ColorLevel -ge 2) { Out-Ui "  $ESC[38;5;$($ramp[$i])m$($rows[$i])$($script:C.Reset)" } else { Out-Ui "  $($rows[$i])" }
        }
    } else { Out-Ui "  $($script:C.Bold)$($script:C.Acc)pneat$($script:C.Reset)" }
}

function Show-Banner {
    $c = $script:C; $g = $script:G
    Out-Ui ''
    Out-Ui "  $($c.Acc)$($c.Bold)$($g.Step) pneat$($c.Reset)  $($c.Muted)smart batch image $($g.Arrow) JPEG converter $($g.Dot) v$($script:PneatVersion)$($c.Reset)"
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

# ══ Files & options ═════════════════════════════════════════════════════════════
function Test-InList([string] $Path, [string[]] $List) { $List -contains ([IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()) }
function Test-Raw([string] $Path) { Test-InList $Path $script:RAW_EXTS }
function Test-Image([string] $Path) { (Test-Raw $Path) -or (Test-InList $Path $script:STD_EXTS) }

function Get-Bound([string] $Name) { $PSBoundParameters.ContainsKey($Name) }

function Get-DemosaicNumber([string] $Name) {
    switch ($Name) { 'linear' { 0 } 'vng' { 1 } 'ppg' { 2 } 'ahd' { 3 } 'dcb' { 4 } 'dht' { 11 } 'aahd' { 12 } default { $null } }
}
function Get-DemosaicName($N) {
    switch ("$N") { '0' { 'linear' } '1' { 'VNG' } '2' { 'PPG' } '3' { 'AHD' } '4' { 'DCB' } '11' { 'DHT' } '12' { 'AAHD' } default { '' } }
}
function Get-HighlightName([int] $H) { switch ($H) { 0 { 'clip' } 1 { 'unclip' } 2 { 'blend' } default { "rebuild $H" } } }

# ══ Prerequisites ═══════════════════════════════════════════════════════════════
function Find-Tool([string] $Name) { (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)?.Source }

function Update-PathFromSystem {
    if ($IsWindows) {      # pick up tools installed after this session started, without dropping anything already on PATH
        $have = $env:Path -split ';'
        $extra = ([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';' -split ';' | Where-Object { $_ -and $have -notcontains $_ }
        if ($extra) { $env:Path = (@($have) + @($extra)) -join ';' }
    }
    elseif ($IsMacOS) { $env:PATH = "/opt/homebrew/bin:/usr/local/bin:$env:PATH" }
}

function Test-Role([string] $Role) {
    switch ($Role) {
        'imagemagick' { [bool](Find-Tool 'magick') -or (-not $IsWindows -and [bool](Find-Tool 'convert')) }
        'exiftool'    { [bool](Find-Tool 'exiftool') }
        'dcraw'       { [bool](Find-Tool 'dcraw') }
        'libraw'      { [bool](Find-Tool 'dcraw_emu') }
    }
}

function Get-PackageManager {
    if ($IsWindows) { if (Find-Tool 'winget') { return 'winget' } }
    elseif ($IsMacOS) { foreach ($b in '/opt/homebrew/bin/brew', '/usr/local/bin/brew') { if (Test-Path $b) { return $b } }; if (Find-Tool 'brew') { return 'brew' } }
    else { foreach ($pm in 'apt-get', 'dnf', 'pacman', 'zypper') { if (Find-Tool $pm) { return $pm } } }
    ''
}

# Packages per manager; an empty entry means "no package - install it manually".
function Get-Packages([string] $Pm, [string] $Role) {
    $table = @{
        'winget'  = @{ imagemagick = 'ImageMagick.ImageMagick'; exiftool = 'OliverBetz.ExifTool'; dcraw = ''; libraw = '' }
        'apt-get' = @{ imagemagick = 'imagemagick'; exiftool = 'libimage-exiftool-perl'; dcraw = 'dcraw'; libraw = 'libraw-bin' }
        'dnf'     = @{ imagemagick = 'ImageMagick'; exiftool = 'perl-Image-ExifTool'; dcraw = 'dcraw'; libraw = 'LibRaw-samples' }
        'pacman'  = @{ imagemagick = 'imagemagick'; exiftool = 'perl-image-exiftool'; dcraw = 'dcraw'; libraw = 'libraw' }
        'zypper'  = @{ imagemagick = 'ImageMagick'; exiftool = 'exiftool'; dcraw = 'dcraw'; libraw = 'libraw-tools' }
        'brew'    = @{ imagemagick = 'imagemagick'; exiftool = 'exiftool'; dcraw = 'dcraw'; libraw = 'libraw' }
    }
    $key = if ($Pm -like '*brew') { 'brew' } else { $Pm }
    if ($table.ContainsKey($key)) { $table[$key][$Role] } else { '' }
}

function Get-ManualHint([string] $Role) {
    if ($IsWindows) {
        switch ($Role) {
            'imagemagick' { 'winget install ImageMagick.ImageMagick' }
            'exiftool'    { 'winget install OliverBetz.ExifTool' }
            'dcraw'       { 'download dcraw.exe and put it on PATH' }
            'libraw'      { 'download the LibRaw binaries (dcraw_emu.exe) from https://www.libraw.org/download and put them on PATH' }
        }
    } else {
        $pm = Get-PackageManager; $pkg = if ($pm) { Get-Packages $pm $Role } else { '' }
        if ($pkg) { "install $pkg with $pm" } else { "install $Role with your package manager" }
    }
}

function Install-Role([string] $Pm, [string] $Role) {
    $pkg = Get-Packages $Pm $Role
    if (-not $pkg) { Write-Warn "No package for '$Role' - $(Get-ManualHint $Role)"; return }
    Write-Step "Installing $pkg"
    $cmd = switch -Wildcard ($Pm) {
        'winget'  { @('winget', 'install', '-e', '--id', $pkg, '--accept-source-agreements', '--accept-package-agreements', '--silent') }
        '*brew'   { @($Pm, 'install', $pkg) }
        'apt-get' { @('sudo', 'apt-get', 'install', '-y', '-qq', $pkg) }
        'dnf'     { @('sudo', 'dnf', 'install', '-y', '-q', $pkg) }
        'pacman'  { @('sudo', 'pacman', '-S', '--needed', '--noconfirm', $pkg) }
        'zypper'  { @('sudo', 'zypper', '--non-interactive', '-q', 'install', $pkg) }
    }
    & $cmd[0] $cmd[1..($cmd.Count - 1)] *> $null
    if ($LASTEXITCODE -ne 0) { Write-Warn "Could not install $pkg." }
}

# Installs the absent roles; returns $false when something is still missing afterwards.
function Install-Missing([string[]] $Roles) {
    $missing = @($Roles | Where-Object { -not (Test-Role $_) })
    if ($missing.Count -eq 0) { return $true }
    if ($NoInstall) { Write-Warn "Auto-install is disabled - missing: $($missing -join ', ')."; return $false }
    $pm = Get-PackageManager
    if (-not $pm) { Write-Warn "No supported package manager found - cannot install: $($missing -join ', ')."; return $false }
    Write-Step "Installing missing tools: $($missing -join ', ')"
    foreach ($r in $missing) { Install-Role $pm $r }
    Update-PathFromSystem
    -not ($missing | Where-Object { -not (Test-Role $_) })
}

# ══ Decoder profile ═════════════════════════════════════════════════════════════
function Get-DecoderTier { foreach ($e in 'libraw', 'dcraw', 'preview') { if ($script:Decoders -contains $e) { return $e } }; 'none' }

# Fills the RAW tuning: explicit values win, the rest comes from the best profile the decoder supports.
function Resolve-RawProfile {
    $tier = Get-DecoderTier
    $script:ProfileNotes = [Collections.Generic.List[string]]::new()
    $recDem = switch ($tier) { 'libraw' { 12 } 'dcraw' { 3 } default { $null } }
    $dem = Get-DemosaicNumber $Demosaic            # $null = auto
    $demAuto = $null -eq $dem
    if ($demAuto) { $dem = $recDem }
    $enhance = [bool]($DcbEnhance -or $Best)
    if ($Best -and $demAuto -and $tier -eq 'libraw') { $dem = 4; $demAuto = $false }
    if ($enhance) {
        if ($tier -ne 'libraw') { $enhance = $false; $script:ProfileNotes.Add('DCB enhance ignored - LibRaw is not installed'); if ($demAuto) { $dem = $recDem } }
        elseif ($demAuto) { $dem = 4 }
        elseif ($dem -ne 4) { $enhance = $false; $script:ProfileNotes.Add('DCB enhance ignored - it needs the dcb demosaic') }
    }
    if ($tier -ne 'libraw' -and $null -ne $dem -and $dem -gt 3) {
        if ($demAuto) { $dem = $recDem } else { $script:ProfileNotes.Add("demosaic $(Get-DemosaicName $dem) is not supported by dcraw - using AHD"); $dem = 3 }
    }
    $fb = $null; $ma = $null
    if ($tier -eq 'libraw') {
        $fb = if ($Fbdd -eq 'auto') { '0' } else { $Fbdd }
        $ma = if ($MaxAdjust -eq 'auto') { if ($Best) { '0' } else { '0.75' } } else { $MaxAdjust }
    } else {
        if (Get-Bound 'Fbdd') { Write-Warn 'FBDD needs LibRaw - ignored.' }
        if (Get-Bound 'MaxAdjust') { Write-Warn 'Max-adjust needs LibRaw - ignored.' }
    }
    $dn = if ($Denoise -eq 'auto') { $null } else { $Denoise }
    if ($tier -eq 'preview') { $dem = $null; $fb = $null; $ma = $null; $enhance = $false; $script:ProfileNotes.Add('embedded preview - no RAW tuning available') }
    $script:Prof = @{ Demosaic = $dem; Enhance = $enhance; Fbdd = $fb; MaxAdjust = $ma; Denoise = $dn; Tier = $tier }
}

# One spec per engine: the decoder command (with {SRC}/{OUT} placeholders) and the ImageMagick stages.
function New-EngineSpecs {
    $resize = if ($script:MaxPx -gt 0) { @('-resize', "$($script:MaxPx)x$($script:MaxPx)>") } else { @() }
    $finish = @('-background', 'white', '-alpha', 'remove', '-alpha', 'off', '-colorspace', 'sRGB', '-strip',
                '-interlace', 'Plane', '-depth', '8', '-quality', "$Quality")
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $tone = @()
    if (-not $NoAutoLevel) { $tone += '-auto-level' }
    if ([Math]::Abs($Brightness - 1.0) -gt 1e-9) { $tone += '-gamma', $Brightness.ToString($inv) }
    if ($Contrast -gt 0) { $tone += '-sigmoidal-contrast', "${Contrast}x50%" }
    if ($Saturation -ne 100) { $tone += '-modulate', "100,$Saturation" }
    if ($Sharpen -gt 0) { $tone += '-unsharp', ('0x1+{0}+0.02' -f ($Sharpen / 100.0).ToString('0.00', $inv)) }
    $common = @('-W', '-H', "$Highlight", '-6', '-g', '2.4', '12.92', $(if ($NoCameraWb) { '-a' } else { '-w' }))
    $p = $script:Prof
    if ($p.Denoise) { $common += '-n', $p.Denoise }
    $lr = @('-Z', '{OUT}') + $common
    if ($null -ne $p.Demosaic) { $lr += '-q', "$($p.Demosaic)" }
    if ($p.Enhance) { $lr += '-dcbe' }
    if ($p.Fbdd) { $lr += '-fbdd', $p.Fbdd }
    if ($p.MaxAdjust) { $lr += '-c', $p.MaxAdjust }
    if ($LibRawArgs) { $lr += $LibRawArgs.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) }
    $dc = @('-c') + $common
    if ($null -ne $p.Demosaic) { $dc += '-q', "$([Math]::Min(3, [int]$p.Demosaic))" }
    $script:Specs = @{
        libraw  = @{ Exe = (Find-Tool 'dcraw_emu'); Args = $lr + '{SRC}'; ToStdout = $false; Magick = @('{IN}') + $resize + $tone + $finish }
        dcraw   = @{ Exe = (Find-Tool 'dcraw');     Args = $dc + '{SRC}'; ToStdout = $true;  Magick = @('{IN}') + $resize + $tone + $finish }
        preview = @{ Exe = (Find-Tool 'exiftool');  Args = @();           ToStdout = $true;  Magick = @('{IN}') + $resize + $finish }
        im      = @{ Exe = '';                      Args = @();           ToStdout = $false; Magick = @('{SRC}[0]', '-auto-orient') + $resize + $finish }
    }
}

# ══ Worker (runs in a runspace; everything it needs is passed in $Ctx) ═══════════
function Invoke-Native {
    param([string] $File, [string[]] $Arguments, [string] $StdoutFile, $Pids)
    $psi = [Diagnostics.ProcessStartInfo]::new($File)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    [void]$Pids.TryAdd($proc.Id, $true)
    $fs = $null
    if ($StdoutFile) { $fs = [IO.File]::Create($StdoutFile); $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($fs) }
    else { $outTask = $proc.StandardOutput.ReadToEndAsync() }
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $outTask.Wait(); $errTask.Wait()
    if ($fs) { $fs.Dispose() }
    $dummy = $false; [void]$Pids.TryRemove($proc.Id, [ref]$dummy)
    $firstErr = (($errTask.Result -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    @{ Code = $proc.ExitCode; Out = $(if ($StdoutFile) { '' } else { $outTask.Result }); Err = $(if ($firstErr) { $firstErr.Substring(0, [Math]::Min(100, $firstErr.Length)) } else { '' }) }
}

function Expand-Args([string[]] $Template, [hashtable] $Map) {
    foreach ($t in $Template) { $v = $t; foreach ($k in $Map.Keys) { $v = $v.Replace($k, $Map[$k]) }; $v }
}

function Convert-One {
    param([hashtable] $Ctx)
    $idx = $Ctx.Idx; $src = $Ctx.Src; $out = $Ctx.Out
    $res = @{ Idx = $idx; Kind = 'fail'; Why = ''; Warns = [Collections.Generic.List[string]]::new() }
    $tmpJpg = Join-Path $Ctx.TmpDir ("$idx.out.jpg")
    $tmpIn = Join-Path $Ctx.TmpDir ("$idx.in.tmp")
    try {
        if ($Ctx.Dup) { $res.Kind = 'skip'; $res.Why = "same output name as $($Ctx.Dup)"; return $res }
        if ([IO.Path]::GetFullPath($src).StartsWith([IO.Path]::GetFullPath($Ctx.OutDir) + [IO.Path]::DirectorySeparatorChar)) {
            $res.Kind = 'skip'; $res.Why = 'already in the output folder'; return $res
        }
        if ((Test-Path -LiteralPath $out) -and -not $Ctx.Replace) { $res.Kind = 'skip'; $res.Why = 'output already exists'; return $res }
        $started = [Diagnostics.Stopwatch]::StartNew()
        $engines = if ($Ctx.IsRaw) { $Ctx.Decoders } else { @('im') }
        $reason = ''
        foreach ($engine in $engines) {
            [IO.File]::WriteAllText((Join-Path $Ctx.TmpDir "$idx.run"), "$engine $([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())")
            $spec = $Ctx.Specs[$engine]
            Remove-Item -LiteralPath $tmpIn, $tmpJpg -Force -ErrorAction SilentlyContinue
            $ok = $true
            if ($engine -eq 'im') { $inArg = $src }
            else {
                $map = @{ '{SRC}' = $src; '{OUT}' = $tmpIn }
                if ($engine -eq 'preview') {
                    $ok = $false
                    foreach ($tag in 'JpgFromRaw', 'PreviewImage', 'OtherImage') {
                        $probe = Invoke-Native $spec.Exe @('-s3', "-$tag", $src) $null $Ctx.Pids
                        if ($probe.Out -like '*Binary*') {
                            $n = Invoke-Native $spec.Exe @('-b', "-$tag", $src) $tmpIn $Ctx.Pids
                            if ($n.Code -eq 0 -and (Test-Path -LiteralPath $tmpIn) -and (Get-Item -LiteralPath $tmpIn).Length -gt 0) { $ok = $true; break }
                        }
                    }
                    if (-not $ok) { $reason = 'no embedded preview found' }
                } else {
                    $n = Invoke-Native $spec.Exe @(Expand-Args $spec.Args $map) $(if ($spec.ToStdout) { $tmpIn } else { $null }) $Ctx.Pids
                    if ($n.Code -ne 0 -or -not (Test-Path -LiteralPath $tmpIn) -or (Get-Item -LiteralPath $tmpIn).Length -eq 0) { $ok = $false; $reason = $n.Err }
                }
                $inArg = $tmpIn
            }
            if ($ok) {
                $margs = @(Expand-Args $spec.Magick @{ '{SRC}' = $src; '{IN}' = $inArg }) + "jpg:$tmpJpg"
                $m = Invoke-Native $Ctx.Magick $margs $null $Ctx.Pids
                if ($m.Code -ne 0 -or -not (Test-Path -LiteralPath $tmpJpg) -or (Get-Item -LiteralPath $tmpJpg).Length -eq 0) { $ok = $false; $reason = $m.Err }
            }
            Remove-Item -LiteralPath $tmpIn -Force -ErrorAction SilentlyContinue
            if ($ok) {
                $tags = if ($Ctx.IsRaw) { @('-all:all') } else { @('-EXIF:all', '-IPTC:all', '-XMP:all') }
                $orient = if ($engine -eq 'preview') { @() } else { @('-Orientation=1') }
                $null = Invoke-Native $Ctx.Exiftool (@('-q', '-overwrite_original', '-P', '-tagsFromFile', $src) + $tags + $orient + @('-n', $tmpJpg)) $null $Ctx.Pids
                Move-Item -LiteralPath $tmpJpg -Destination $out -Force
                if ($Ctx.KeepTimes) { (Get-Item -LiteralPath $out).LastWriteTime = (Get-Item -LiteralPath $src).LastWriteTime }
                $res.Kind = 'ok'; $res.In = (Get-Item -LiteralPath $src).Length; $res.OutSize = (Get-Item -LiteralPath $out).Length
                $res.Engine = $engine; $res.Ms = $started.ElapsedMilliseconds
                return $res
            }
            Remove-Item -LiteralPath $tmpJpg -Force -ErrorAction SilentlyContinue
            if ($engine -ne $engines[-1]) { $res.Warns.Add("$($Ctx.Labels[$engine]) failed on $([IO.Path]::GetFileName($src))$(if ($reason) { ": $reason" }) - trying next decoder") }
        }
        $res.Why = $reason
    } catch { $res.Kind = 'fail'; $res.Why = $_.Exception.Message }
    finally { Remove-Item -LiteralPath $tmpIn, $tmpJpg -Force -ErrorAction SilentlyContinue }
    $res
}

# ══ Batch ═══════════════════════════════════════════════════════════════════════
function Get-AvailableMb {
    try {
        if ($IsWindows) { return [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024) }
        if ($IsLinux) { return [int](((Get-Content /proc/meminfo | Where-Object { $_ -like 'MemAvailable:*' }) -split '\s+')[1] / 1024) }
        if ($IsMacOS) {
            $vm = & vm_stat; $size = [int]([regex]::Match(($vm | Select-Object -First 1), 'page size of (\d+)').Groups[1].Value)
            $pages = 0; foreach ($l in $vm) { if ($l -match '^Pages (free|inactive|speculative|purgeable):\s+(\d+)') { $pages += [long]$Matches[2] } }
            return [int]($pages * $size / 1MB)
        }
    } catch { }
    4096
}

function Resolve-Jobs {
    $script:Cores = [Environment]::ProcessorCount
    $perJob = [Math]::Max(512, [int]($script:LargestBytes * 25 / 1MB))
    $script:JobsNote = ''
    if ($Jobs -eq 'auto') {
        $n = [Math]::Max(1, [Math]::Min($script:Cores, [int]([Math]::Floor((Get-AvailableMb) / $perJob))))
        if ($n -lt $script:Cores -and $n -lt $script:Images.Count) { $script:JobsNote = " $($script:G.Dot) memory-limited" }
    } else {
        if ($Jobs -notmatch '^\d+$' -or [int]$Jobs -lt 1 -or [int]$Jobs -gt 64) { Stop-Pneat "Jobs must be a number from 1 to 64, or 'auto'." }
        $n = [int]$Jobs
    }
    $script:JobCount = [Math]::Min($n, $script:Images.Count)
    $script:Threads = [Math]::Max(1, [int][Math]::Floor($script:Cores / $script:JobCount))
    [Environment]::SetEnvironmentVariable('OMP_NUM_THREADS', "$($script:Threads)")
    [Environment]::SetEnvironmentVariable('MAGICK_THREAD_LIMIT', "$($script:Threads)")
}

function Write-Live([string] $Spin, [int] $Idx, [string] $Engine, [long] $ElapsedMs, [int] $Active) {
    $c = $script:C; $tag = "[$Idx/$($script:Images.Count)]"
    $name = [IO.Path]::GetFileName($script:Images[$Idx - 1]); $short = (Get-Badge $Engine)
    $more = if ($Active -gt 1) { "+$($Active - 1)" } else { '' }
    $nameMax = [Math]::Min(48, [Math]::Max(10, $script:Cols - (2 + 1 + 1 + $tag.Length + 1 + 2 + 9 + 2 + 6 + 5) - 1))
    $pct = [int][Math]::Floor($script:Finished * 100 / $script:Images.Count)
    $eta = Get-Eta
    $l1 = "  $($c.Acc)$Spin$($c.Reset) $($c.Muted)$tag$($c.Reset) $($c.Bold)$(Get-Pad $name $nameMax)$($c.Reset)  $short  $($c.Muted){0,6} {1,-4}$($c.Reset)" -f (Format-Ms $ElapsedMs), $more
    $l2 = "  $($c.Muted)overall$($c.Reset)  $(Get-Bar $pct $script:BarW)  $($c.Muted){0,3}%  {1} elapsed  ETA {2}$($c.Reset)" -f $pct, (Format-Time ([long]$script:StartedAt.Elapsed.TotalSeconds)), $eta
    [Console]::Write("`r$ESC[2K$l1`n$ESC[2K$l2$ESC[1A`r")
}
function Clear-Live { [Console]::Write("`r$ESC[2K`n$ESC[2K$ESC[1A`r") }

# ETA from the average time of the last 5 finished files of each kind (RAW and ordinary are timed separately).
function Get-Eta {
    $avg = @{}
    foreach ($k in 'raw', 'std') { $r = $script:Ring[$k]; $avg[$k] = if ($r.Count) { ($r | Measure-Object -Average).Average } else { 0 } }
    if (-not $script:Ring.raw.Count -and -not $script:Ring.std.Count) { return '--:--' }
    $fallback = ($avg.Values | Where-Object { $_ -gt 0 } | Measure-Object -Average).Average
    $rem = 0.0
    foreach ($i in 0..($script:Images.Count - 1)) {
        if ($script:Done.ContainsKey($i + 1)) { continue }
        $k = if (Test-Raw $script:Images[$i]) { 'raw' } else { 'std' }
        $a = if ($avg[$k] -gt 0) { $avg[$k] } else { $fallback }
        $spent = 0
        if ($script:Running.ContainsKey($i + 1)) { $spent = [Math]::Min($script:Running[$i + 1].Watch.ElapsedMilliseconds, 1.5 * $a) }
        $rem += [Math]::Max(0, ($(if ($spent) { 1.5 * $a } else { $a })) - $spent)
    }
    Format-Time ([long][Math]::Ceiling($rem / 1000 / [Math]::Max(1, $script:JobCount)))
}

function Write-Result($R) {
    $c = $script:C; $g = $script:G; $idx = $R.Idx; $tag = "[$idx/$($script:Images.Count)]"
    $base = [IO.Path]::GetFileName($script:Images[$idx - 1])
    foreach ($w in $R.Warns) { Write-Warn $w }
    switch ($R.Kind) {
        'ok' {
            $delta = [int][Math]::Truncate(($R.OutSize - $R.In) * 100 / [Math]::Max(1, $R.In))
            $col = if ($delta -le 0) { $c.Ok } else { $c.Warn }; $arrow = if ($delta -le 0) { $g.Down } else { $g.Up }
            Out-Ui ("  $($c.Ok)$($g.Ok)$($c.Reset) $($c.Muted)$tag$($c.Reset) $($c.Bold)$(Get-Pad $base $script:NameCol)$($c.Reset)  {0,9} $($c.Muted)$($g.Arrow)$($c.Reset) {1,-9}  $col$arrow {2,3}%$($c.Reset)  $(Get-Badge $R.Engine)  $($c.Muted){3,6}$($c.Reset)" -f
                (Format-Bytes $R.In), (Format-Bytes $R.OutSize), [Math]::Abs($delta), (Format-Ms $R.Ms))
            $script:Ok++; $script:TotalIn += $R.In; $script:TotalOut += $R.OutSize
            $script:EngineUsed[$R.Engine] = 1 + $(if ($script:EngineUsed.ContainsKey($R.Engine)) { $script:EngineUsed[$R.Engine] } else { 0 })
            $k = if (Test-Raw $script:Images[$idx - 1]) { 'raw' } else { 'std' }
            $script:Ring[$k].Add([double]$R.Ms); if ($script:Ring[$k].Count -gt 5) { $script:Ring[$k].RemoveAt(0) }
        }
        'skip' { Out-Ui "  $($c.Muted)$($g.Skip) $tag $(Get-Pad $base $script:NameCol)  $($R.Why)$($c.Reset)"; $script:Skipped++ }
        default { Out-Ui "  $($c.Err)$($g.Fail)$($c.Reset) $($c.Muted)$tag$($c.Reset) $($c.Bold)$(Get-Pad $base $script:NameCol)$($c.Reset)  $($c.Err)$(Get-Clip "failed$(if ($R.Why) { ": $($R.Why)" })" ($script:Cols - $script:NameCol - 14))$($c.Reset)"; $script:Fail++ }
    }
}

function Stop-Workers {
    foreach ($w in @($script:Running.Values)) { try { $w.Ps.Stop() } catch { } }
    foreach ($procId in @($script:Pids.Keys)) { try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch { } }
}

function Invoke-Batch {
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fn in 'Invoke-Native', 'Expand-Args', 'Convert-One') {
        $iss.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($fn, (Get-Command $fn -CommandType Function).Definition))
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, $script:JobCount, $iss, $Host)
    $pool.Open()
    $script:Running = @{}; $script:Done = @{}; $script:Finished = 0
    $results = @{}; $next = 1; $printed = 0; $frame = 0; $total = $script:Images.Count
    $labels = @{ im = 'ImageMagick'; libraw = 'LibRaw (dcraw_emu)'; dcraw = 'dcraw'; preview = 'Embedded preview' }
    if ($script:Tty) { [Console]::Write("$ESC[?25l") }
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($printed -lt $total) {
            while ($script:Running.Count -lt $script:JobCount -and $next -le $total) {
                $src = $script:Images[$next - 1]
                $ctx = @{
                    Idx = $next; Src = $src; Out = (Join-Path $OutputDir ([IO.Path]::GetFileNameWithoutExtension($src) + '.jpg')); OutDir = $OutputDir
                    TmpDir = $script:ResDir; IsRaw = (Test-Raw $src); Decoders = @($script:Decoders); Specs = $script:Specs
                    Magick = $script:Magick; Exiftool = (Find-Tool 'exiftool'); KeepTimes = (-not $NoTimestamps); Pids = $script:Pids
                    Dup = $(if ($script:DupOf.ContainsKey($next)) { $script:DupOf[$next] } else { '' })
                    Replace = [bool]$script:Replace[$next]; Labels = $labels
                }
                $ps = [powershell]::Create(); $ps.RunspacePool = $pool
                [void]$ps.AddCommand('Convert-One').AddParameter('Ctx', $ctx)
                $script:Running[$next] = @{ Ps = $ps; Handle = $ps.BeginInvoke(); Watch = [Diagnostics.Stopwatch]::StartNew() }
                $next++
            }
            foreach ($idx in @($script:Running.Keys)) {
                $w = $script:Running[$idx]
                if ($w.Handle.IsCompleted) {
                    try { $r = $w.Ps.EndInvoke($w.Handle) | Select-Object -Last 1 } catch { $r = @{ Idx = $idx; Kind = 'fail'; Why = $_.Exception.Message; Warns = @() } }
                    if (-not $r) { $r = @{ Idx = $idx; Kind = 'fail'; Why = 'worker stopped unexpectedly'; Warns = @() } }
                    $w.Ps.Dispose(); $script:Running.Remove($idx); $script:Done[$idx] = $true; $script:Finished++; $results[$idx] = $r
                }
            }
            $flushed = $false
            while ($printed -lt $total -and $results.ContainsKey($printed + 1)) {
                if ($script:Tty -and -not $flushed) { Clear-Live; $flushed = $true }
                $printed++; Write-Result $results[$printed]
            }
            if ($printed -lt $total) {
                $frame++
                if ($script:Tty -and $script:Running.Count -gt 0) {
                    $oldest = ($script:Running.Keys | Measure-Object -Minimum).Minimum
                    $runFile = Join-Path $script:ResDir "$oldest.run"; $engine = 'im'; $start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    if (Test-Path -LiteralPath $runFile) { $parts = (Get-Content -LiteralPath $runFile -Raw) -split ' '; if ($parts.Count -eq 2) { $engine = $parts[0]; $start = [long]$parts[1] } }
                    Write-Live $script:G.Spin[$frame % $script:G.Spin.Count] $oldest $engine ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $start) $script:Running.Count
                }
                Start-Sleep -Milliseconds 100
            }
        }
    } finally {
        Stop-Workers; $pool.Close(); $pool.Dispose()
        if ($script:Tty) { [Console]::Write("$ESC[?25h") }
    }
    $script:BatchMs = $t0.ElapsedMilliseconds
}

# ══ Existing outputs, plan and summary ═══════════════════════════════════════════
function Get-OutputPath([string] $Src) { Join-Path $OutputDir ([IO.Path]::GetFileNameWithoutExtension($Src) + '.jpg') }

# Decides per file: replace all / replace this one / ignore this one / ignore all and exit.
function Resolve-ExistingOutputs {
    $script:Replace = @{}; $script:OverwriteNote = ''
    $existing = @(1..$script:Images.Count | Where-Object { -not $script:DupOf.ContainsKey($_) -and (Test-Path -LiteralPath (Get-OutputPath $script:Images[$_ - 1])) })
    if ($existing.Count -eq 0) { return }
    if ($Force) { foreach ($i in $existing) { $script:Replace[$i] = $true }; $script:OverwriteNote = 'existing files replaced'; return }
    if ($SkipExisting -or [Console]::IsInputRedirected -or -not $script:Tty) {
        $script:OverwriteNote = 'existing files kept'
        if (-not $SkipExisting) { Write-Warn "$($existing.Count) file(s) already exist in the output folder - skipped."; Write-Note 'Use -Force to replace them, -SkipExisting to skip without this note.' }
        return
    }
    Open-Card 'Existing files'
    Write-CardRow 'Found' "$($existing.Count) file(s) already exist in $OutputDir"
    foreach ($i in ($existing | Select-Object -First 6)) { Write-CardLine "  $([IO.Path]::GetFileName((Get-OutputPath $script:Images[$i - 1])))" }
    if ($existing.Count -gt 6) { Write-CardLine "  ...and $($existing.Count - 6) more" }
    Close-Card
    $pos = 0; $replaced = 0; $kept = 0
    foreach ($i in $existing) {
        $pos++
        Out-Ui "  $([IO.Path]::GetFileName((Get-OutputPath $script:Images[$i - 1]))) already exists ($pos of $($existing.Count))"
        Out-Ui '    1 replace all   2 replace this one   3 ignore this one   4 ignore all and exit'
        $choice = Read-Host '  Choice [3]'
        switch ($choice) {
            '1' { foreach ($j in $existing | Where-Object { $_ -ge $i }) { $script:Replace[$j] = $true }; $replaced += ($existing.Count - $pos + 1); break }
            '2' { $script:Replace[$i] = $true; $replaced++ }
            '4' { Out-Ui "  $($script:C.Muted)Nothing was written.$($script:C.Reset)"; exit 0 }
            default { $kept++ }
        }
        if ($choice -eq '1') { break }
    }
    $script:OverwriteNote = if ($replaced -and $kept) { 'some existing files replaced' } elseif ($replaced) { 'existing files replaced' } else { 'existing files kept' }
}

function Show-Plan {
    $p = $script:Prof; $g = $script:G
    Open-Card 'Plan'
    Write-CardRow 'Engine' "ImageMagick ($([IO.Path]::GetFileName($script:Magick)))"
    if ($script:RawTotal -gt 0) {
        $chain = ($script:Decoders | ForEach-Object { Get-EngineLabel $_ }) -join " $($g.Chain) "
        Write-CardRow 'RAW' $chain
        $dem = if ($null -ne $p.Demosaic) { Get-DemosaicName $p.Demosaic } else { 'n/a' }
        $extra = @(); if ($p.Enhance) { $extra += 'enhance' }; if ($p.Fbdd) { $extra += "fbdd $($p.Fbdd)" }; if ($p.MaxAdjust) { $extra += "max-adjust $($p.MaxAdjust)" }
        Write-CardRow 'Demosaic' ((@($dem) + $extra) -join " $($g.Dot) ")
        Write-CardRow 'RAW look' "contrast $Contrast $($g.Dot) saturation $Saturation% $($g.Dot) sharpen $Sharpen"
        Write-CardRow 'RAW opts' "highlights $(Get-HighlightName $Highlight) $($g.Dot) wb $(if ($NoCameraWb) { 'auto' } else { 'camera' }) $($g.Dot) brightness $Brightness $($g.Dot) auto-level $(if ($NoAutoLevel) { 'off' } else { 'on' })"
        foreach ($n in $script:ProfileNotes) { Write-CardRow 'Note' "$($script:C.Warn)$n$($script:C.Reset)" }
    }
    Write-CardRow 'Quality' "$Quality% $($g.Dot) $(Get-QualityLabel $Quality)"
    Write-CardRow 'Size' $(if ($script:MaxPx -gt 0) { "$MaxSize $($g.Dot) $($script:MaxPx)px longest side $($g.Dot) never upscaled" } else { 'original size' })
    Write-CardRow 'Output' "$OutputDir$(if ($script:OverwriteNote) { " $($g.Dot) $($script:OverwriteNote)" })"
    Write-CardRow 'Files' "$($script:Images.Count) image(s) ($($script:RawTotal) RAW) $($g.Dot) $(Format-Bytes $script:TotalSrc) $($g.Dot) timestamps $(if ($NoTimestamps) { 'not kept' } else { 'kept' })"
    Write-CardRow 'Jobs' "$($script:JobCount) in parallel $($g.Dot) $($script:Threads) thread(s) each $($g.Dot) $($script:Cores) cores$($script:JobsNote)"
    Close-Card
    Out-Ui ''
}

function Show-Summary {
    $c = $script:C; $g = $script:G
    Open-Card 'Summary'
    $line = "$($c.Ok)$($g.Ok) $($script:Ok) converted$($c.Reset)"
    if ($script:Fail) { $line += "   $($c.Err)$($g.Fail) $($script:Fail) failed$($c.Reset)" }
    if ($script:Skipped) { $line += "   $($c.Muted)$($g.Skip) $($script:Skipped) skipped$($c.Reset)" }
    Write-CardRow 'Result' $line
    if ($script:TotalIn -gt 0) {
        $saved = $script:TotalIn - $script:TotalOut; $pct = [int][Math]::Floor([Math]::Abs($saved) * 100 / $script:TotalIn)
        $txt = if ($saved -ge 0) { "$($c.Ok)$($g.Down) $pct% smaller$($c.Reset)" } else { "$($c.Warn)$($g.Up) $pct% larger$($c.Reset)" }
        Write-CardRow 'Size' "$(Format-Bytes $script:TotalIn) $($g.Arrow) $(Format-Bytes $script:TotalOut)  $txt"
        $kept = [int][Math]::Floor($script:TotalOut * 100 / $script:TotalIn)
        Write-CardRow '' "$(Get-Bar ([Math]::Min(100, $kept)) 24)  $($c.Muted)$kept% of original$($c.Reset)"
        if ($saved -gt 0) { Write-CardRow 'Saved' "$($c.Ok)$(Format-Bytes $saved)$($c.Reset)" } elseif ($saved -lt 0) { Write-CardRow 'Grew' "$($c.Warn)$(Format-Bytes (-$saved))$($c.Reset)" }
    }
    if ($script:Ok -gt 0) {
        Write-CardRow 'Average' "$(Format-Ms ([long]($script:BatchMs / $script:Ok))) per image ($($script:JobCount) parallel)"
        $secs = [Math]::Max(0.001, $script:BatchMs / 1000.0)
        Write-CardRow 'Throughput' ('{0:0.0} MB/s {1} {2:0} image(s)/min' -f ($script:TotalIn / 1MB / $secs), $g.Dot, ($script:Ok * 60 / $secs))
    }
    $used = ''
    foreach ($e in 'im', 'libraw', 'dcraw', 'preview') { if ($script:EngineUsed.ContainsKey($e)) { $used += "$(Get-Badge $e) $($script:EngineUsed[$e])  " } }
    if ($used) { Write-CardRow 'Engines' $used }
    if ($script:EngineUsed.ContainsKey('preview')) {
        Write-CardRow 'Note' "$($c.Warn)$($script:EngineUsed['preview']) RAW file(s) used the embedded preview (lower resolution)$($c.Reset)"
        Write-CardRow '' "$($c.Muted)Run  ./pneat.ps1 -InstallDeps  to install LibRaw for full decoding$($c.Reset)"
    }
    Write-CardRow 'Time' (Format-Time ([long]$script:StartedAt.Elapsed.TotalSeconds))
    Write-CardRow 'Output' $OutputDir
    Close-Card
    if ($script:Fail -eq 0) { Out-Ui "`n  $($c.Ok)$($c.Bold)$($g.Ok) All done.$($c.Reset)`n" } else { Out-Ui "`n  $($c.Err)$($c.Bold)$($g.Fail) Finished with $($script:Fail) failure(s).$($c.Reset)`n" }
}

# ══ Interactive setup (simplified) ═══════════════════════════════════════════════
function Read-Choice([string] $Prompt, [string] $Default) { $a = Read-Host "  $Prompt [$Default]"; if ($a) { $a } else { $Default } }

function Invoke-InteractiveSetup {
    if ([Console]::IsInputRedirected -or -not $script:Tty) { Stop-Pneat 'Interactive mode needs a terminal.' }
    Open-Card 'Interactive setup'
    Write-CardLine "Batch $($script:Images.Count) image(s) $($script:G.Dot) $($script:RawTotal) RAW, $($script:Images.Count - $script:RawTotal) ordinary"
    Write-CardLine '  1  Quality   best detail, larger files'
    Write-CardLine '  2  Speed     smaller files, faster'
    Write-CardLine '  3  Auto      recommended defaults'
    Close-Card
    switch (Read-Choice 'Priority' '3') {
        '1' { if (-not (Get-Bound 'Quality')) { $script:Quality = 95 } }
        '2' { if (-not (Get-Bound 'Quality')) { $script:Quality = 75 }; if (-not (Get-Bound 'MaxSize')) { $script:MaxSize = 'fullhd' } }
    }
    $q = Read-Choice 'JPEG quality 1-100' "$($script:Quality)"
    if ($q -match '^\d+$' -and [int]$q -ge 1 -and [int]$q -le 100) { $script:Quality = [int]$q } else { Stop-Pneat 'Quality must be a number from 1 to 100.' }
    $s = (Read-Choice 'Max size sd|hd|fullhd|4k|none' $(if ($script:MaxSize) { $script:MaxSize } else { 'none' })).ToLower()
    if ($s -eq 'none') { $script:MaxSize = '' } elseif ($script:RES.ContainsKey($s)) { $script:MaxSize = $s } else { Stop-Pneat "Invalid max size '$s'." }
    if ($script:RawTotal -gt 0 -and $script:Decoders.Count -gt 1) {
        $d = (Read-Choice "RAW decoder auto|$($script:Decoders -join '|')" 'auto').ToLower()
        if ($d -ne 'auto') { if ($script:Decoders -contains $d) { $script:Decoder = $d } else { Stop-Pneat "Decoder '$d' is not available." } }
    }
}

# ══ Help ═════════════════════════════════════════════════════════════════════════
function Show-Help {
    $c = $script:C
    Show-Logo
    Out-Ui "`n  $($c.Bold)Smart batch image $($script:G.Arrow) JPEG converter$($c.Reset)"
    Out-Ui "  $($c.Muted)RAW + 40 formats $($script:G.Dot) automatic setup $($script:G.Dot) live progress $($script:G.Dot) v$($script:PneatVersion) $($script:G.Dot) PowerShell 7+$($c.Reset)"
    $rows = @(
        @('USAGE', @('./pneat.ps1 [options] [file ...]::convert specific files', './pneat.ps1 -InputDir <folder>::convert a whole folder', './pneat.ps1::convert the current folder')),
        @('INPUT & OUTPUT', @('-InputDir (-i) <dir>::folder with the images (.)', '-OutputDir (-o) <dir>::output (<input>/compressed)', '-NoTimestamps (-t)::do not copy the file dates')),
        @('QUALITY & SIZE', @('-Quality (-q) 1-100::JPEG quality (80)', '-MaxSize (-s) <preset>::cap longest side: sd hd fullhd 4k', '::854 / 1280 / 1920 / 3840 px, no upscaling')),
        @('RAW LOOK', @('-Highlight (-hl) 0-9::0 clip, 1 unclip (pink!), 2 blend,', '::3-9 rebuild (5)', '-Brightness (-b) <num>::midtone lift, 1 = off (1.9)', '-Contrast (-c) 0-20::S-curve strength (6)', '-Saturation (-sat) 0-200::100 = unchanged (112)', '-Sharpen (-sharp) 0-100::unsharp amount (70)', '-NoCameraWb (-w)::auto white balance', '-NoAutoLevel (-a)::do not stretch the histogram')),
        @('RAW DECODER', @('-Decoder (-d) <name>::auto libraw dcraw preview (auto)', '-Demosaic (-dm) <name>::auto linear vng ppg ahd dcb dht aahd', '-DcbEnhance::DCB colour enhance (needs dcb)', '-Denoise (-dn) <n>::wavelet threshold, e.g. 100-500', '-Fbdd 0|1|2::FBDD noise reduction (LibRaw)', '-MaxAdjust <0-1>::LibRaw auto-maximum, 0 = off', '-LibRawArgs "<flags>"::extra dcraw_emu flags, appended last', '-Best::preset: dcb + enhance + max-adjust 0', '-ListDecoders (-l)::show which decoders work')),
        @('RUN', @('-Jobs (-j) <n|auto>::parallel images (all cores)', '-Interactive (-m)::guided setup menu', '-Force (-f)::replace existing outputs', '-SkipExisting (-k)::keep existing outputs, no question', '-DryRun (-z)::show decoder commands only', '-InstallDeps (-y)::install ImageMagick, exiftool, dcraw...', '-NoInstall (-n)::never install anything', '-Help (-h)   -Version (-v)::'))
    )
    foreach ($sec in $rows) {
        Open-Card $sec[0]
        foreach ($r in $sec[1]) { $a, $b = $r -split '::', 2; Write-CardLine ("{0}{1,-29}{2} {3}" -f $c.Ok, $a, $c.Reset, $b) }
        Close-Card
    }
    Open-Card 'GOOD TO KNOW'
    Write-CardLine 'Defaults match pneat 1.4.1. RAW look options apply to RAW only.'
    Write-CardLine 'NO_COLOR=1 disables colours, PNEAT_ASCII=1 plain ASCII.'
    Write-CardLine 'Windows: winget installs ImageMagick + exiftool; put dcraw_emu.exe'
    Write-CardLine '(LibRaw) or dcraw.exe on PATH yourself for RAW files.'
    Close-Card
    Out-Ui ''
}

# ══ Main ═════════════════════════════════════════════════════════════════════════
function Invoke-Pneat {
    Initialize-Ui
    if ($Version) { Out-Ui "pneat $($script:PneatVersion)"; return 0 }
    if ($Help) { Show-Help; return 0 }
    Update-PathFromSystem
    if ($ListDecoders) {
        $d = @(); if (Test-Role 'libraw') { $d += 'libraw' }; if (Test-Role 'dcraw') { $d += 'dcraw' }; if (Test-Role 'exiftool') { $d += 'preview' }
        Out-Ui "Available decoders: $(if ($d) { $d -join ' ' } else { 'none' })"; return 0
    }
    Show-Banner; Show-System

    foreach ($pair in @(@('Denoise', '^(auto|\d+)$', 'Denoise threshold must be a whole number (e.g. 100).'), @('MaxAdjust', '^(auto|0(\.\d+)?|1(\.0+)?)$', 'Max-adjust must be between 0 and 1 (0 = off).'))) {
        if ((Get-Variable $pair[0]).Value -notmatch $pair[1]) { Stop-Pneat $pair[2] }
    }
    $script:MaxPx = if ($MaxSize) { $script:RES[$MaxSize] } else { 0 }
    if ($Highlight -eq 1) { Write-Warn 'Highlight mode 1 (unclip) leaves pink highlights - mode 2 (blend) is safer.' }

    if ($InstallDeps) {
        if (Install-Missing @('imagemagick', 'exiftool', 'dcraw', 'libraw')) { Out-Ui "`n  $($script:C.Ok)$($script:C.Bold)$($script:G.Ok) Dependency setup finished.$($script:C.Reset)`n"; return 0 }
        return 1
    }

    # ── collect files ──
    $mode = if ($Files.Count -gt 0) { 'files' } else { 'dir' }
    if (-not $InputDir) { $InputDir = '.' }
    if (-not $OutputDir) { $OutputDir = if ($mode -eq 'files') { Join-Path '.' $script:SUBDIR } else { Join-Path $InputDir $script:SUBDIR } }
    $script:Images = @(); $skipped = 0
    if ($mode -eq 'files') {
        foreach ($f in $Files) {
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Write-Warn "File not found: $f" }
            elseif (-not (Test-Image $f)) { Write-Note "$($script:G.Skip) $([IO.Path]::GetFileName($f)) (unsupported)"; $skipped++ }
            else { $script:Images += (Resolve-Path -LiteralPath $f).Path }
        }
    } else {
        if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) { Stop-Pneat "Folder '$InputDir' not found." }
        $script:Images = @(Get-ChildItem -LiteralPath $InputDir -File | Where-Object { Test-Image $_.Name } | Sort-Object Name | ForEach-Object FullName)
    }
    if ($script:Images.Count -eq 0) { Stop-Pneat 'No supported image files found.' }
    $script:RawTotal = @($script:Images | Where-Object { Test-Raw $_ }).Count
    $script:Skipped = $skipped

    # ── tools ──
    $roles = @('imagemagick', 'exiftool'); if ($script:RawTotal -gt 0) { $roles += 'dcraw', 'libraw' }
    [void](Install-Missing $roles)
    foreach ($r in 'imagemagick', 'exiftool') { if (-not (Test-Role $r)) { Stop-Pneat "$r is not installed." @("Install it manually: $(Get-ManualHint $r)") } }
    $script:Magick = (Find-Tool 'magick'); if (-not $script:Magick) { $script:Magick = Find-Tool 'convert' }
    $script:Decoders = @(); if (Test-Role 'libraw') { $script:Decoders += 'libraw' }; if (Test-Role 'dcraw') { $script:Decoders += 'dcraw' }; $script:Decoders += 'preview'

    if ($Interactive) { Invoke-InteractiveSetup; $script:MaxPx = if ($script:MaxSize) { $script:RES[$script:MaxSize] } else { 0 } }
    if ($script:RawTotal -gt 0 -and $Decoder -ne 'auto') {
        if ($script:Decoders -notcontains $Decoder) { Stop-Pneat "Decoder '$Decoder' is not available. Available: $($script:Decoders -join ', ')" @('Install the missing tools with: ./pneat.ps1 -InstallDeps') }
        $script:Decoders = @($Decoder)
    }
    Resolve-RawProfile
    New-EngineSpecs

    # ── layout, duplicates, jobs ──
    $script:TotalSrc = 0; $script:LargestBytes = 0; $longest = 0
    foreach ($f in $script:Images) { $len = (Get-Item -LiteralPath $f).Length; $script:TotalSrc += $len; $script:LargestBytes = [Math]::Max($script:LargestBytes, $len); $longest = [Math]::Max($longest, [IO.Path]::GetFileName($f).Length) }
    $script:NameCol = [Math]::Max(8, [Math]::Min($longest, [Math]::Min(40, [Math]::Max(14, $script:Cols - 60))))
    $script:DupOf = @{}; $first = @{}
    for ($i = 0; $i -lt $script:Images.Count; $i++) {
        $base = [IO.Path]::GetFileName($script:Images[$i]); $stem = [IO.Path]::GetFileNameWithoutExtension($base)
        if ($first.ContainsKey($stem)) { $script:DupOf[$i + 1] = $first[$stem] } else { $first[$stem] = $base }
    }
    Resolve-Jobs
    [void](New-Item -ItemType Directory -Force -Path $OutputDir)
    $OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
    Resolve-ExistingOutputs
    Show-Plan

    if ($DryRun) {
        foreach ($f in $script:Images) {
            if (-not (Test-Raw $f)) { Out-Ui "  $([IO.Path]::GetFileName($f))  ->  $($script:Magick) $((@($script:Specs.im.Magick) -join ' '))"; continue }
            $e = $script:Decoders[0]; $s = $script:Specs[$e]
            Out-Ui "  $([IO.Path]::GetFileName($f))  [$e]  $($s.Exe) $((@($s.Args) -join ' '))  ->  magick $((@($s.Magick) -join ' '))"
        }
        return 0
    }

    # ── run ──
    $script:ResDir = Join-Path ([IO.Path]::GetTempPath()) ("pneat." + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:ResDir)
    $script:Ok = 0; $script:Fail = 0; $script:TotalIn = 0; $script:TotalOut = 0; $script:BatchMs = 0
    $script:EngineUsed = @{}; $script:Ring = @{ raw = [Collections.Generic.List[double]]::new(); std = [Collections.Generic.List[double]]::new() }
    try { Invoke-Batch } finally { Remove-Item -LiteralPath $script:ResDir -Recurse -Force -ErrorAction SilentlyContinue }
    Show-Summary
    if ($script:Fail -eq 0) { 0 } else { 1 }
}

exit (Invoke-Pneat)
