<#
.SYNOPSIS
    TallyHawk Lite - free, agentless Windows inventory snapshot in one file.

.DESCRIPTION
    Collects the basics every IT inventory needs - computer name, manufacturer, model,
    serial number, CPU, RAM, Windows version/build and disk usage - and writes them to the
    console, a CSV row (append-friendly, one row per PC) and a plain-text summary.

    Read-only. No install, no agent, no internet connection, no admin rights required.
    Run it on many PCs with the same -OutputPath (e.g. a network share) and the CSV
    becomes a simple fleet inventory you can open in Excel.

    TallyHawk Lite is the free edition of TallyHawk - IT Inventory & Health Kit.

.PARAMETER OutputPath
    Folder for TallyHawk-Lite-Inventory.csv and the <COMPUTER>.txt summary.
    Default: your Desktop. A UNC path such as \\server\share\inventory works too.

.PARAMETER Quiet
    No console output (for logon scripts, RMM jobs, scheduled tasks). Exit code 0 = OK.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\TallyHawk-Lite.ps1

.EXAMPLE
    .\TallyHawk-Lite.ps1 -OutputPath \\fileserver\it\inventory -Quiet

.NOTES
    Version 1.0.0 - MIT License - Windows PowerShell 5.1 and PowerShell 7+.
    Full version: https://dilgec.gumroad.com/l/tallyhawk/LAUNCH72
#>
[CmdletBinding()]
param(
    [string]$OutputPath = [Environment]::GetFolderPath('Desktop'),
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$ProUrl = 'https://dilgec.gumroad.com/l/tallyhawk/LAUNCH72'
$Inv = [Globalization.CultureInfo]::InvariantCulture   # dot decimals on every Windows language

function Fmt { param([string]$F, [object[]]$V) [string]::Format($Inv, $F, $V) }
function Say { param([string]$Text, [string]$Color = 'Gray') if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color } }
function Get-Cim { param([string]$Class, [string]$Filter)
    try {
        if ($Filter) { Get-CimInstance -ClassName $Class -Filter $Filter -ErrorAction Stop }
        else { Get-CimInstance -ClassName $Class -ErrorAction Stop }
    }
    catch { $null }
}

try {
    # ---------------- Collect (read-only) ----------------
    $cs   = Get-Cim Win32_ComputerSystem
    $bios = Get-Cim Win32_BIOS
    $os   = Get-Cim Win32_OperatingSystem
    $cpu  = Get-Cim Win32_Processor | Select-Object -First 1
    $vols = @(Get-Cim Win32_LogicalDisk 'DriveType=3')
    $cv   = $(try { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } catch { $null })

    # Self-built PCs report placeholders such as "System Product Name": use the motherboard instead.
    $ph = '^(To be filled.*|Default string|System Serial Number|System Product Name|System manufacturer|Not Applicable|0+|None|\s*)$'
    $mfr = ([string]$cs.Manufacturer).Trim()
    $model = ([string]$cs.Model).Trim()
    $serial = ([string]$bios.SerialNumber).Trim()
    if ($serial -match $ph -or $model -match $ph -or $mfr -match $ph) {
        $bb = Get-Cim Win32_BaseBoard | Select-Object -First 1
        if ($bb) {
            if ($serial -match $ph -and ([string]$bb.SerialNumber).Trim() -notmatch $ph) { $serial = ([string]$bb.SerialNumber).Trim() }
            if ($model -match $ph -and $bb.Product) { $model = '{0} (motherboard)' -f ([string]$bb.Product).Trim() }
            if ($mfr -match $ph -and $bb.Manufacturer) { $mfr = ([string]$bb.Manufacturer).Trim() }
        }
    }
    if ($serial -match $ph) { $serial = '' }

    $build = if ($os) { [int]$os.BuildNumber } else { 0 }
    $osName = if ($os) { [string]$os.Caption } else { 'Unknown' }
    if ($build -ge 22000) { $osName = $osName -replace 'Windows 10', 'Windows 11' }   # Win11 still reports "10" in some places
    $osName = $osName -replace '^Microsoft ', ''

    $ramGb = if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { $null }

    $disks = foreach ($v in $vols) {
        if (-not $v -or -not $v.Size) { continue }
        $usedPct = [math]::Round((1 - ($v.FreeSpace / $v.Size)) * 100, 1)
        [pscustomobject]@{
            Drive   = $v.DeviceID
            SizeGB  = [math]::Round($v.Size / 1GB, 1)
            FreeGB  = [math]::Round($v.FreeSpace / 1GB, 1)
            UsedPct = $usedPct
            Status  = if ($usedPct -ge 92) { 'CRITICAL' } elseif ($usedPct -ge 85) { 'LOW SPACE' } else { 'OK' }
        }
    }
    $disks = @($disks)
    $sys = $disks | Where-Object { $_.Drive -eq $env:SystemDrive } | Select-Object -First 1

    $row = [pscustomobject]@{
        ScanDate      = (Get-Date).ToString('yyyy-MM-dd HH:mm', $Inv)
        Computer      = $env:COMPUTERNAME
        User          = [string]$cs.UserName
        Manufacturer  = $mfr
        Model         = $model
        Serial        = $serial
        CPU           = if ($cpu) { ([string]$cpu.Name -replace '\s+', ' ').Trim() } else { '' }
        Cores         = if ($cpu) { $cpu.NumberOfCores } else { '' }
        RamGB         = if ($null -ne $ramGb) { $ramGb.ToString($Inv) } else { '' }
        OS            = $osName
        OSVersion     = if ($cv -and $cv.DisplayVersion) { [string]$cv.DisplayVersion } else { '' }
        Build         = if ($cv -and $null -ne $cv.UBR) { '{0}.{1}' -f $build, $cv.UBR } else { [string]$build }
        SystemDrive   = if ($sys) { $sys.Drive } else { '' }
        SystemSizeGB  = if ($sys) { $sys.SizeGB.ToString($Inv) } else { '' }
        SystemUsedPct = if ($sys) { $sys.UsedPct.ToString($Inv) } else { '' }
        AllDrives     = ($disks | ForEach-Object { Fmt '{0} {1}% used of {2} GB' @($_.Drive, $_.UsedPct, $_.SizeGB) }) -join '; '
        Tool          = "TallyHawk Lite $Version"
    }

    # ---------------- Write outputs ----------------
    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $csv = Join-Path $OutputPath 'TallyHawk-Lite-Inventory.csv'
    $txt = Join-Path $OutputPath ('TallyHawk-Lite_{0}.txt' -f $env:COMPUTERNAME)

    # One row per computer: re-running on the same PC replaces its old row.
    $rows = @()
    if (Test-Path -LiteralPath $csv) {
        $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8 | Where-Object { $_.Computer -ne $env:COMPUTERNAME })
    }
    $rows += $row
    $rows | Sort-Object Computer | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

    $line = '-' * 62
    $diskLines = $disks | ForEach-Object { Fmt '  {0,-4} {1,6:0.0}% used  {2,8:0.0} GB free of {3,7:0.0} GB   {4}' @($_.Drive, $_.UsedPct, $_.FreeGB, $_.SizeGB, $_.Status) }
    $summary = @(
        "TallyHawk Lite $Version - inventory snapshot"
        $line
        ('Computer      : {0}' -f $row.Computer)
        ('Scanned       : {0}' -f $row.ScanDate)
        ('Logged-on user: {0}' -f $row.User)
        ('Manufacturer  : {0}' -f $row.Manufacturer)
        ('Model         : {0}' -f $row.Model)
        ('Serial number : {0}' -f $(if ($row.Serial) { $row.Serial } else { 'not reported by firmware' }))
        ('CPU           : {0} ({1} cores)' -f $row.CPU, $row.Cores)
        ('Memory        : {0} GB' -f $row.RamGB)
        ('Windows       : {0} {1} (build {2})' -f $row.OS, $row.OSVersion, $row.Build)
        ''
        'Disks'
    ) + @($diskLines) + @(
        ''
        $line
        'WANT THE FULL PICTURE? -> TallyHawk (full version)'
        $line
        '  Lite answers "what do we have?". TallyHawk also answers "is it safe?"'
        '  and "what do I fix first?":'
        ''
        '  * 25 security & health checks: BitLocker (incl. suspended), TPM 2.0,'
        '    Secure Boot, SMBv1, UAC, firewall, antivirus, local admin sprawl'
        '  * Warranty & lifecycle tracking: Windows 10/11 end of support,'
        '    end-of-life software (Office 2016/2019, SQL 2014/2016, Java 7...)'
        '  * 9 one-click fixes with snapshot + rollback - undo any change later'
        '  * One interactive offline HTML dashboard that merges every PC:'
        '    search, filter, CSV export, print to PDF. No cloud, no agent.'
        ''
        "  72-hour launch price (`$39 instead of `$49): $ProUrl"
        $line
    )
    [IO.File]::WriteAllLines($txt, [string[]]$summary, (New-Object Text.UTF8Encoding($true)))

    # ---------------- Console ----------------
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  ||||/ ' -ForegroundColor Yellow -NoNewline
        Write-Host 'Tally' -ForegroundColor White -NoNewline
        Write-Host 'Hawk' -ForegroundColor Yellow -NoNewline
        Write-Host (' Lite {0}  -  free agentless inventory' -f $Version) -ForegroundColor Gray
        Write-Host ('  ' + $line) -ForegroundColor DarkGray
        foreach ($l in $summary[2..10]) { Write-Host ('  ' + $l) }
        Write-Host ''
        Write-Host '  Disks' -ForegroundColor Cyan
        foreach ($d in $disks) {
            $c = switch ($d.Status) { 'CRITICAL' { 'Red' } 'LOW SPACE' { 'Yellow' } default { 'Green' } }
            Write-Host (Fmt '    {0,-4} {1,6:0.0}% used  {2,8:0.0} GB free of {3,7:0.0} GB   ' @($d.Drive, $d.UsedPct, $d.FreeGB, $d.SizeGB)) -NoNewline
            Write-Host $d.Status -ForegroundColor $c
        }
        Write-Host ''
        Say ('  CSV (one row per PC): {0}' -f $csv) 'Green'
        Say ('  Text summary        : {0}' -f $txt) 'Green'
        Write-Host ''
        Write-Host ('  ' + $line) -ForegroundColor DarkYellow
        Write-Host '  TallyHawk full version adds:' -ForegroundColor Yellow
        Write-Host '   + 25 security checks  (BitLocker, TPM, SMBv1, UAC, local admins...)'
        Write-Host '   + warranty & lifecycle tracking, end-of-life software'
        Write-Host '   + 9 one-click fixes you can roll back'
        Write-Host '   + one offline HTML dashboard for every PC in the company'
        Write-Host ('  Launch price $39 (72h): {0}' -f $ProUrl) -ForegroundColor Yellow
        Write-Host ('  ' + $line) -ForegroundColor DarkYellow
        Write-Host ''
    }
    exit 0
}
catch {
    if (-not $Quiet) {
        Write-Host ''
        Write-Host ('  TallyHawk Lite failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Host '  Check that the output folder exists and is writable, then run again.' -ForegroundColor Gray
    }
    exit 1
}

# -----------------------------------------------------------------------------
#  TallyHawk Lite shows WHAT you have. TallyHawk shows whether it is SAFE and
#  WHAT TO FIX FIRST:
#    - 25 security & health checks (BitLocker, TPM 2.0, SMBv1, UAC, firewall,
#      antivirus, local admin analysis) with a 0-100 score per PC
#    - warranty & lifecycle tracking, Windows / end-of-life software dates
#    - 9 one-click remediation commands, each with snapshot + rollback
#    - interactive offline HTML dashboard that merges every PC in the fleet
#  72-hour launch price ($39 instead of $49):
#  https://dilgec.gumroad.com/l/tallyhawk/LAUNCH72
# -----------------------------------------------------------------------------
