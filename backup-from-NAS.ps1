<# 
.SYNOPSIS
    Backup from NAS
.DESCRIPTION
    Copies files from network/NAS to a USB drive or a local folder on this PC. Configurable via config.json.
    Immich is just one of possible use cases.
.EXAMPLE
    .\backup-from-NAS.ps1
    .\backup-from-NAS.ps1 -Drive H
    .\backup-from-NAS.ps1 -Verify
    .\backup-from-NAS.ps1 -Drive H -Verify
    .\backup-from-NAS.ps1 -LocalPath "D:\MyBackups"
#>

param(
    [string]$Drive,    # USB drive letter (e.g. H). If not specified - interactive selection
    [string]$LocalPath, # Local destination folder on this PC (overrides USB). If set - save locally, not to USB
    [switch]$Verify    # Enable SHA256 integrity check after copying
)

# ===== READ CONFIG =====
$CONFIG_PATH = Join-Path $PSScriptRoot "config.json"

if (!(Test-Path $CONFIG_PATH)) {
    Write-Err "Config file not found: $CONFIG_PATH"
    exit 1
}

try {
    $CONFIG = Get-Content -Path $CONFIG_PATH -Raw | ConvertFrom-Json
} catch {
    Write-Err "Failed to parse config file: $_"
    exit 1
}

# ===== SETTINGS =====
$SOURCE = $CONFIG.source_path
$BACKUP_FOLDER = $CONFIG.usb_target_folder
$DATE = Get-Date -Format "yyyy-MM-dd"
$TIMESTAMP_START = Get-Date

$SYNC_FOLDERS = @($CONFIG.sync_folders | ForEach-Object {
    @{ SourceRoot = $SOURCE; Src = $_.source; Dst = $_.destination }
})

$SYNC_FOLDERS += @($CONFIG.additional_sources | ForEach-Object {
    @{ SourceRoot = $_.source; Src = "."; Dst = $_.destination }
})

# File extensions for CRC verification
$VERIFY_EXTENSIONS = $CONFIG.verify_extensions

# How many days to keep old DB dumps
$DUMP_RETENTION_DAYS = $CONFIG.dump_retention_days

# Use verify from config if not specified via parameter
if (-not $Verify) {
    $Verify = $CONFIG.verify
}

# Count files on check (default: false)
$COUNT_FILES_ON_CHECK = if ($null -ne $CONFIG.count_files_on_check) { $CONFIG.count_files_on_check } else { $false }

# Show robocopy progress (default: true)
$SHOW_ROBOCOPY_PROGRESS = if ($null -ne $CONFIG.show_robocopy_progress) { $CONFIG.show_robocopy_progress } else { $true }

# Log settings
$LOGS_FOLDER = if ($null -ne $CONFIG.logs_folder) { $CONFIG.logs_folder } else { "logs" }
$LOG_MAX_SIZE_BYTES = if ($null -ne $CONFIG.log_max_size_mb) { [long]($CONFIG.log_max_size_mb * 1MB) } else { [long](10 * 1MB) }
$LOG_RETENTION_DAYS = if ($null -ne $CONFIG.log_retention_days) { $CONFIG.log_retention_days } else { 90 }

# Backup subfolder (optional)
$BACKUP_SUBFOLDER = if ($null -ne $CONFIG.backup_subfolder) { $CONFIG.backup_subfolder } else { $null }

# ============================================================
# FUNCTIONS
# ============================================================

function Write-Step {
    param([string]$Step, [string]$Message)
    Write-Host "`n$Step $Message" -ForegroundColor Cyan
    Write-Host ("-" * 50) -ForegroundColor DarkGray
}

function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [!!] $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "  [ERR] $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "  [i] $Msg" -ForegroundColor Gray }

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    return "{0:N2} KB" -f ($Bytes / 1KB)
}

function Format-Duration {
    param([timespan]$Duration)
    if ($Duration.TotalHours -ge 1) { return "{0:hh\:mm\:ss}" -f $Duration }
    return "{0:mm\:ss}" -f $Duration
}

function Get-DirectoryMeasure {
    param([string]$Path)
    
    if (!(Test-Path $Path)) {
        return @{ Count = 0; Bytes = 0L }
    }
    
    $measure = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    return @{
        Count = $measure.Count
        Bytes = if ($null -ne $measure.Sum) { [long]$measure.Sum } else { 0L }
    }
}

function Format-TextBar {
    param(
        [int]$Percent,
        [int]$Width = 20
    )
    
    $safePercent = [math]::Max(0, [math]::Min(100, $Percent))
    $filled = [int][math]::Round(($safePercent / 100) * $Width)
    if ($filled -gt $Width) { $filled = $Width }
    $empty = $Width - $filled
    return "[" + ("#" * $filled) + ("-" * $empty) + "]"
}

function Format-AnimatedBar {
    param(
        [int]$Step,
        [int]$Width = 20
    )
    
    $safeWidth = [math]::Max(5, $Width)
    $chars = New-Object char[] $safeWidth
    for ($i = 0; $i -lt $safeWidth; $i++) {
        $chars[$i] = '-'
    }
    $position = $Step % $safeWidth
    $chars[$position] = '#'
    return "[" + (-join $chars) + "]"
}

function Filter-RobocopyLog {
    <#
    .SYNOPSIS
    Reduce robocopy log by removing percentage noise and other redundant lines
    #>
    param([string]$LogPath)
    
    if (!(Test-Path $LogPath)) { return }
    
    $file = Get-Item $LogPath
    if ($file.Length -lt 1024) { return }
    
    $tempPath = "$LogPath.tmp"
    $lines = Get-Content $LogPath
    
    $filtered = $lines | Where-Object {
        $line = $_
        # Skip lines that are just a percentage
        if ($line -match '^\s*\d+%\s*$') { return $false }
        # Skip lines with embedded progress percent like " 12.3%"
        if ($line -match '^\s*\d+(?:\.\d+)?%') { return $false }
        # Skip "Bytes : ...x.x% ..." noise
        if ($line -match '^\s*Bytes\s*:.*%') { return $false }
        $true
    }
    
    $filtered | Set-Content -Path $tempPath -Encoding UTF8
    Move-Item -Path $tempPath -Destination $LogPath -Force
}

function Get-RobocopyStats {
    <#
    .SYNOPSIS
    Parse robocopy log and return statistics
    #>
    param([string]$LogPath)
    
    $stats = @{ Copied = 0; Skipped = 0; Failed = 0; TotalSize = ""; CopiedBytes = 0 }
    
    if (!(Test-Path $LogPath)) { return $stats }
    
    $content = Get-Content $LogPath -Tail 30
    foreach ($line in $content) {
        if ($line -match "^\s*Files\s*:\s*\d+\s+(\d+)\s+(\d+)\s+\d+\s+(\d+)") {
            $stats.Copied  = [int]$Matches[1]
            $stats.Skipped = [int]$Matches[2]
            $stats.Failed  = [int]$Matches[3]
        }
        if ($line -match "^\s*Bytes\s*:\s*[\d\.]+\s+\w*\s+([\d\.]+)\s+(\w+)") {
            $size = [double]$Matches[1]
            $unit = $Matches[2]
            
            switch ($unit) {
                "g"   { $stats.CopiedBytes = [long]($size * 1GB) }
                "m"   { $stats.CopiedBytes = [long]($size * 1MB) }
                "k"   { $stats.CopiedBytes = [long]($size * 1KB) }
                "b"   { $stats.CopiedBytes = [long]$size }
                default { $stats.CopiedBytes = [long]$size }
            }
            
            $stats.TotalSize = "$size $unit"
        }
    }
    return $stats
}

function Rotate-Log {
    param([string]$LogPath)
    
    if (!(Test-Path $LogPath)) {
        return
    }
    
    $file = Get-Item $LogPath
    if ($file.Length -ge $LOG_MAX_SIZE_BYTES) {
        $timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
        $newName = "$($file.DirectoryName)\$($file.BaseName)-$timestamp$($file.Extension)"
        Move-Item -Path $LogPath -Destination $newName -Force
    }
}

function Cleanup-OldLogs {
    param([string]$LogFolder)
    
    if (!(Test-Path $LogFolder)) {
        return
    }
    
    $cutoffDate = (Get-Date).AddDays(-$LOG_RETENTION_DAYS)
    $oldLogs = Get-ChildItem -Path $LogFolder -File | Where-Object { $_.LastWriteTime -lt $cutoffDate }
    
    if ($oldLogs) {
        foreach ($log in $oldLogs) {
            Remove-Item -Path $log.FullName -Force
            Write-Info "Removed old log: $($log.Name)"
        }
    }
}

function Update-RobocopyProgressState {
    param(
        [string]$LogPath,
        [hashtable]$State
    )
    
    if (!(Test-Path $LogPath)) {
        return $State
    }
    
    $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $fs.Seek($State.Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader = New-Object System.IO.StreamReader($fs)
        $newText = $reader.ReadToEnd()
        $State.Offset = $fs.Position
    }
    finally {
        $fs.Close()
    }
    
    if ([string]::IsNullOrEmpty($newText)) {
        return $State
    }
    
    $combined = $State.Buffer + $newText
    $lines = $combined -split "`r?`n"
    
    if ($combined -notmatch "(`r`n|`n)$") {
        $State.Buffer = $lines[-1]
        if ($lines.Count -gt 1) {
            $lines = $lines[0..($lines.Count - 2)]
        } else {
            $lines = @()
        }
    } else {
        $State.Buffer = ""
    }
    
    foreach ($line in $lines) {
        if ($line -match "^\s*(\d+%)?\s*(New File|Older|Newer|Changed|Tweaked|Same|Lonely|Extra File)\s+\d+\s+(.+)$") {
            $State.ProcessedFiles++
            $State.LastFile = $Matches[3].Trim()
        }
    }
    
    return $State
}

function Get-LastTouchedFile {
    param([string]$Path)
    
    if (!(Test-Path $Path)) {
        return $null
    }
    
    try {
        $file = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        if ($file) {
            return $file.FullName.Substring($Path.Length).TrimStart('\', '/')
        }
    } catch {
    }
    return $null
}

function Write-ProgressLine {
    param(
        [string]$Text,
        [int]$MaxWidth = 100
    )
    
    $line = "  " + $Text
    if ($line.Length -gt $MaxWidth) {
        $line = $line.Substring(0, $MaxWidth - 3) + "..."
    }
    
    $pad = ""
    if ($line.Length -lt $MaxWidth) {
        $pad = " " * ($MaxWidth - $line.Length)
    }
    
    [Console]::Write("`r" + $line + $pad)
}

function Start-RobocopyWithProgress {
    param(
        [string[]]$RobocopyArgs,
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$FolderLabel,
        [string]$LogPath,
        [int]$ProgressId
    )
    
    $stdoutPath = Join-Path $LOG_FOLDER_PATH "robocopy-$($FolderLabel)-stdout.tmp"
    $stderrPath = Join-Path $LOG_FOLDER_PATH "robocopy-$($FolderLabel)-stderr.tmp"
    
    if (Test-Path $stdoutPath) { Remove-Item $stdoutPath -Force }
    if (Test-Path $stderrPath) { Remove-Item $stderrPath -Force }
    
    $process = Start-Process -FilePath "robocopy.exe" `
        -ArgumentList $RobocopyArgs `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -NoNewWindow `
        -PassThru
    
    $progressStartTime = Get-Date
    
    Write-Host "  Copying $FolderLabel..." -ForegroundColor Yellow
    
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 1500
        $process.Refresh()

        $destMeasure = Get-DirectoryMeasure -Path $DestinationPath
        $now = Get-Date
        $elapsedSeconds = [math]::Max(1, ($now - $progressStartTime).TotalSeconds)
        $bytesPerSecond = if ($destMeasure.Bytes -gt 0) { [long]($destMeasure.Bytes / $elapsedSeconds) } else { 0L }
        $elapsedText = Format-Duration -Duration ($now - $progressStartTime)
        
        $currentFile = Get-LastTouchedFile -Path $DestinationPath

        $line = "[$FolderLabel] " +
            "files $($destMeasure.Count) | " +
            "size $(Format-Size $destMeasure.Bytes) | " +
            "speed $(Format-Size $bytesPerSecond)/s | " +
            "elapsed $elapsedText"
        if ($currentFile) {
            $line += " | $currentFile"
        }
        Write-ProgressLine -Text $line
    }
    
    $process.WaitForExit()
    [Console]::Write("`r" + (" " * 120) + "`r")
    
    $destMeasure = Get-DirectoryMeasure -Path $DestinationPath
    $now = Get-Date
    $elapsedSeconds = [math]::Max(1, ($now - $progressStartTime).TotalSeconds)
    $bytesPerSecond = if ($destMeasure.Bytes -gt 0) { [long]($destMeasure.Bytes / $elapsedSeconds) } else { 0L }
    $elapsedText = Format-Duration -Duration ($now - $progressStartTime)

    Write-Host ("  [{0}] done: files {1} | size {2} | avg speed {3}/s | elapsed {4}" -f `
        $FolderLabel, $destMeasure.Count, (Format-Size $destMeasure.Bytes), (Format-Size $bytesPerSecond), $elapsedText) -ForegroundColor Green
    
    Write-Progress -Id $ProgressId -Activity "Copying $FolderLabel" -Completed
    
    if (Test-Path $stdoutPath) { Remove-Item $stdoutPath -Force }
    if (Test-Path $stderrPath) { Remove-Item $stderrPath -Force }
    
    return @{
        ExitCode = $process.ExitCode
        SourceFileCount = $destMeasure.Count
        SourceTotalBytes = $destMeasure.Bytes
        ProcessedFiles = $destMeasure.Count
    }
}

# ============================================================
# [1/4] DESTINATION SELECTION
# ============================================================
Write-Step "[1/4]" "Destination selection"

# Local mode: optional. Set via config.local_target_path or -LocalPath.
# If a local folder is specified, the backup is saved there instead of a USB drive.
$LOCAL_TARGET_PATH = if ($null -ne $CONFIG.local_target_path) { $CONFIG.local_target_path.Trim() } else { "" }
if ($LocalPath) {
    $LOCAL_TARGET_PATH = $LocalPath.Trim()
}

if ($LOCAL_TARGET_PATH -ne "") {
    # ---- LOCAL MODE: save to a folder on this PC ----
    $Mode = "local"
    $USB = $LOCAL_TARGET_PATH

    if (Test-Path $USB -PathType Leaf) {
        Write-Err "Local target path points to a file, not a folder: $USB"
        exit 1
    }
    if (!(Test-Path $USB)) {
        New-Item -ItemType Directory -Force -Path $USB | Out-Null
        Write-Info "Created local folder: $USB"
    }
    $DriveLetter = (Split-Path -Qualifier $USB).TrimEnd(":")
    $vol = if ($DriveLetter) { Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'" } else { $null }
    Write-Ok "Local mode: $USB"
    if ($vol) {
        Write-Info "Free on ${DriveLetter}: $(Format-Size $vol.FreeSpace)"
    }
}
else {
    # ---- USB MODE: save to a USB drive (original behavior) ----
    $Mode = "usb"

    # Priority: 1) command line parameter, 2) config, 3) interactive selection
    $DriveToUse = if ($Drive) { $Drive } elseif ($CONFIG.usb_drive_letter) { $CONFIG.usb_drive_letter } else { $null }

    if ($DriveToUse) {
        $DriveLetter = $DriveToUse.TrimEnd(":", "\", "/").ToUpper()
        $DriveRoot = "${DriveLetter}:\"
        
        if (!(Test-Path $DriveRoot)) {
            Write-Err "Drive ${DriveLetter}: not found!"
            exit 1
        }
        
        $source = if ($Drive) { "parameter" } else { "config" }
        Write-Ok "Using drive ${DriveLetter}: (from $source)"
    }
    else {
        # Interactive selection - show all removable USB drives
        $removableDrives = Get-CimInstance Win32_DiskDrive -Filter "InterfaceType='USB'" | 
            ForEach-Object {
                $disk = $_
                Get-CimAssociatedInstance -InputObject $disk -ResultClassName Win32_DiskPartition |
                ForEach-Object {
                    Get-CimAssociatedInstance -InputObject $_ -ResultClassName Win32_LogicalDisk
                }
            } | Where-Object { $_ -ne $null }

        if (!$removableDrives -or @($removableDrives).Count -eq 0) {
            Write-Err "No USB drives found! Connect a USB drive and try again."
            exit 1
        }

        Write-Host ""
        Write-Host "  Available USB drives:" -ForegroundColor White
        Write-Host ""
        $header = "  {0,-4} {1,-8} {2,-20} {3,-12} {4,-12}" -f "#", "Drive", "Label", "Size", "Free"
        Write-Host $header -ForegroundColor DarkCyan
        Write-Host ("  " + ("-" * 56)) -ForegroundColor DarkGray

        $driveList = @()
        $i = 1
        foreach ($d in @($removableDrives)) {
            $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($d.DeviceID)'"
            $label = if ($vol.VolumeName) { $vol.VolumeName } else { "(no label)" }
            $size = Format-Size $vol.Size
            $free = Format-Size $vol.FreeSpace
            $freePercent = if ($vol.Size -gt 0) { [math]::Round($vol.FreeSpace / $vol.Size * 100) } else { 0 }
            
            $row = "  {0,-4} {1,-8} {2,-20} {3,-12} {4}" -f $i, "$($d.DeviceID)", $label, $size, "$free ($freePercent%)"
            Write-Host $row -ForegroundColor White
            $driveList += $d
            $i++
        }

        Write-Host ""
        $choice = Read-Host "  Select drive number (1-$($driveList.Count))"
        
        if ($choice -notmatch "^\d+$" -or [int]$choice -lt 1 -or [int]$choice -gt $driveList.Count) {
            Write-Err "Invalid selection!"
            exit 1
        }

        $selected = $driveList[[int]$choice - 1]
        $DriveLetter = $selected.DeviceID.TrimEnd(":")
        $DriveRoot = "${DriveLetter}:\"
        
        $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($selected.DeviceID)'"
        $label = if ($vol.VolumeName) { $vol.VolumeName } else { "(no label)" }
        Write-Ok "Selected drive ${DriveLetter}: [$label]"
    }

    $USB = "${DriveLetter}:\$BACKUP_FOLDER"
}

$LOG_FOLDER_PATH = Join-Path $USB $LOGS_FOLDER
$LOG_FILE = Join-Path $LOG_FOLDER_PATH "backup-log.txt"

# Create backup directories
New-Item -ItemType Directory -Force -Path $USB | Out-Null
New-Item -ItemType Directory -Force -Path "$USB\verify" | Out-Null
New-Item -ItemType Directory -Force -Path $LOG_FOLDER_PATH | Out-Null

# Rotate and clean up logs
Rotate-Log -LogPath $LOG_FILE
Cleanup-OldLogs -LogFolder $LOG_FOLDER_PATH

# Start log
"" | Out-File -Append $LOG_FILE
"===== BACKUP START $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====" | Out-File -Append $LOG_FILE
"Destination: $Mode -> $USB" | Out-File -Append $LOG_FILE

# ============================================================
# [2/4] NAS AVAILABILITY CHECK
# ============================================================
Write-Step "[2/4]" "Checking NAS availability"

# Check each source folder
$allFoldersOk = $true
foreach ($folder in $SYNC_FOLDERS) {
    $path = Join-Path $folder.SourceRoot $folder.Src
    if (Test-Path $path) {
        if ($COUNT_FILES_ON_CHECK) {
            $count = (Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-Ok "$($folder.Src) - available ($count files)"
        } else {
            Write-Ok "$($folder.Src) - available"
        }
    } else {
        Write-Warn "$($folder.Src) - folder not found on NAS, skipping"
        $allFoldersOk = $false
    }
}

# Check free space on destination
if ($DriveLetter) {
    $usbDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'"
    if ($usbDisk -and $usbDisk.FreeSpace -lt 1GB) {
        Write-Err "Less than 1 GB free on ${DriveLetter}:! ($(Format-Size $usbDisk.FreeSpace))"
        exit 1
    }
    if ($usbDisk) {
        Write-Info "Free on ${DriveLetter}: $(Format-Size $usbDisk.FreeSpace)"
    }
} else {
    Write-Warn "Cannot determine destination drive - skipping free space check"
}

# ============================================================
# [3/4] FILE SYNCHRONIZATION
# ============================================================
Write-Step "[3/4]" "File synchronization (robocopy)"

$totalCopied = 0
$totalSkipped = 0
$totalFailed = 0
$folderIndex = 0

foreach ($folder in $SYNC_FOLDERS) {
    $folderIndex++
    $srcPath = Join-Path $folder.SourceRoot $folder.Src
    
    # Build destination path with optional subfolder
    if ($BACKUP_SUBFOLDER) {
        $dstPath = Join-Path (Join-Path $USB $BACKUP_SUBFOLDER) $folder.Dst
    } else {
        $dstPath = Join-Path $USB $folder.Dst
    }
    
    $logPath = Join-Path $LOG_FOLDER_PATH "robocopy-$($folder.Dst).log"
    
    # Rotate robocopy log before writing
    Rotate-Log -LogPath $logPath
    
    if (!(Test-Path $srcPath)) {
        Write-Warn "  [$folderIndex/$($SYNC_FOLDERS.Count)] $($folder.Src) - skip (folder not found)"
        continue
    }

    Write-Host "  ... [$folderIndex/$($SYNC_FOLDERS.Count)] $($folder.Src) -> $($folder.Dst) ..." -ForegroundColor Yellow

    $folderStartTime = Get-Date

    # /MIR  - mirror (deletes extra files on destination)
    # /R:2  - 2 retries on error
    # /W:5  - 5 sec wait between retries
    # /NP   - no progress in robocopy output (we draw our own bar)
    # /NDL  - no directory listing in log
    # /NC   - no file class output (reduces log size)
    # /NS   - no file size output (reduces log size)
    # /NFL  - no file list output (reduces log size)
    # /MT:2 - 2 threads (single-thread reduces progress % noise, keeps moderate speed)
    $robocopyArgs = @(
        "`"$srcPath`"", "`"$dstPath`"",
        "/MIR", "/R:2", "/W:5", "/NDL",
        "/NP", "/NC", "/NS", "/NFL",
        "/MT:2",
        "/LOG+:`"$logPath`""
    )

    $robocopyResult = Start-RobocopyWithProgress -RobocopyArgs $robocopyArgs -SourcePath $srcPath -DestinationPath $dstPath -FolderLabel $folder.Dst -LogPath $logPath -ProgressId $folderIndex
    $exitCode = $robocopyResult.ExitCode

    $folderEndTime = Get-Date
    $folderDuration = $folderEndTime - $folderStartTime

    # Robocopy exit codes: 0=nothing copied, 1=files copied, 2=extra files, 3=both
    # Codes >= 8 indicate errors
    $stats = Get-RobocopyStats -LogPath $logPath
    Filter-RobocopyLog -LogPath $logPath
    $totalCopied  += $stats.Copied
    $totalSkipped += $stats.Skipped
    $totalFailed  += $stats.Failed

    if ($exitCode -ge 8) {
        Write-Host ""
        Write-Err "  $($folder.Src) - ERROR (code $exitCode). See $logPath"
        "ERR: robocopy $($folder.Src) error (code $exitCode)" | Out-File -Append $LOG_FILE
    } else {
        Write-Host ""
        $durationStr = "{0:hh\:mm\:ss}" -f $folderDuration
        
        $speedStr = ""
        if ($stats.CopiedBytes -gt 0 -and $folderDuration.TotalSeconds -gt 0) {
            $bytesPerSec = $stats.CopiedBytes / $folderDuration.TotalSeconds
            $speedStr = ", speed: $(Format-Size $bytesPerSec)/s"
        }
        
        Write-Ok "  $($folder.Src) - done (copied: $($stats.Copied), skipped: $($stats.Skipped), duration: $durationStr$speedStr)"
        "OK: robocopy $($folder.Src): copied=$($stats.Copied) skipped=$($stats.Skipped) duration=$durationStr" | Out-File -Append $LOG_FILE
    }
    Write-Host ("  " + ("-" * 78)) -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host ""
Write-Info "Robocopy total: copied=$totalCopied, skipped=$totalSkipped, errors=$totalFailed"
"Robocopy total: copied=$totalCopied skipped=$totalSkipped failed=$totalFailed" | Out-File -Append $LOG_FILE

# ============================================================
# [3.5/4] CRC VERIFICATION (only with -Verify)
# ============================================================
if ($Verify) {
    Write-Step "[3.5/4]" "Integrity check (SHA256)"

    $HASH_SOURCE = "$USB\verify\source-hash-$DATE.txt"
    $HASH_BACKUP = "$USB\verify\backup-hash-$DATE.txt"

    # Verify only upload (the most important folder with originals)
    $sourceUpload = Join-Path $SOURCE "upload"
    if ($BACKUP_SUBFOLDER) {
        $backupUpload = Join-Path (Join-Path $USB $BACKUP_SUBFOLDER) "upload"
    } else {
        $backupUpload = Join-Path $USB "upload"
    }

    if ((Test-Path $sourceUpload) -and (Test-Path $backupUpload)) {
        Write-Host "  ... Computing hashes for upload (this may take a long time)..." -ForegroundColor Yellow

        # Source hashes
        Write-Host "  ... Source hashes..." -ForegroundColor Yellow -NoNewline
        $sourceFiles = Get-ChildItem -Path $sourceUpload -Recurse -Include $VERIFY_EXTENSIONS -ErrorAction SilentlyContinue
        $sourceTotal = @($sourceFiles).Count
        $sourceIndex = 0
        $sourceHashes = @()

        foreach ($file in $sourceFiles) {
            $sourceIndex++
            if ($sourceIndex % 100 -eq 0) {
                $pct = [math]::Round($sourceIndex / $sourceTotal * 100)
                Write-Host "`r  ... Source hashes... $sourceIndex/$sourceTotal ($pct%)" -ForegroundColor Yellow -NoNewline
            }
            $hash = Get-FileHash -Path $file.FullName -Algorithm SHA256
            $relativePath = $file.FullName.Substring($sourceUpload.Length)
            $sourceHashes += "$($hash.Hash) $relativePath"
        }
        Write-Host ""
        Write-Ok "Source hashes: $sourceTotal files"
        $sourceHashes | Out-File $HASH_SOURCE -Encoding UTF8

        # Backup hashes
        Write-Host "  ... Backup hashes..." -ForegroundColor Yellow -NoNewline
        $backupFiles = Get-ChildItem -Path $backupUpload -Recurse -Include $VERIFY_EXTENSIONS -ErrorAction SilentlyContinue
        $backupTotal = @($backupFiles).Count
        $backupIndex = 0
        $backupHashes = @()

        foreach ($file in $backupFiles) {
            $backupIndex++
            if ($backupIndex % 100 -eq 0) {
                $pct = [math]::Round($backupIndex / $backupTotal * 100)
                Write-Host "`r  ... Backup hashes... $backupIndex/$backupTotal ($pct%)" -ForegroundColor Yellow -NoNewline
            }
            $hash = Get-FileHash -Path $file.FullName -Algorithm SHA256
            $relativePath = $file.FullName.Substring($backupUpload.Length)
            $backupHashes += "$($hash.Hash) $relativePath"
        }
        Write-Host ""
        Write-Ok "Backup hashes: $backupTotal files"
        $backupHashes | Out-File $HASH_BACKUP -Encoding UTF8

        # Compare
        $sourceContent = Get-Content $HASH_SOURCE
        $backupContent = Get-Content $HASH_BACKUP
        
        if ($sourceContent -and $backupContent) {
            $diff = Compare-Object $sourceContent $backupContent
            if ($diff) {
                $diffCount = @($diff).Count
                Write-Warn "DIFFERENCES FOUND: $diffCount mismatches!"
                $diff | Out-File "$USB\verify\diff-$DATE.txt" -Encoding UTF8
                "WARN: CRC: $diffCount differences (see diff-$DATE.txt)" | Out-File -Append $LOG_FILE
            } else {
                Write-Ok "All files identical ($sourceTotal total)"
                "OK: CRC: all files identical ($sourceTotal)" | Out-File -Append $LOG_FILE
            }
        }
    } else {
        Write-Warn "Upload folder not found - verification skipped"
    }
} else {
    Write-Info "CRC verification skipped (run with -Verify to enable)"
}

# ============================================================
# [4/4] CLEANUP + SUMMARY
# ============================================================
Write-Step "[4/4]" "Cleanup and summary"

# Delete old dumps
$dumpsPath = Join-Path $USB "backups"
if (Test-Path $dumpsPath) {
    $oldDumps = Get-ChildItem "$dumpsPath\*" -Recurse -File | 
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$DUMP_RETENTION_DAYS) }
    
    if ($oldDumps) {
        $oldCount = @($oldDumps).Count
        Write-Info "Deleting dumps older than $DUMP_RETENTION_DAYS days ($oldCount files)..."
        foreach ($f in $oldDumps) {
            Remove-Item $f.FullName -Force
            Write-Host "    DEL: $($f.Name)" -ForegroundColor DarkGray
        }
        "DEL: Removed $oldCount old dumps" | Out-File -Append $LOG_FILE
    } else {
        Write-Info "No old dumps to delete"
    }
}

# ===== FINAL REPORT =====
$TIMESTAMP_END = Get-Date
$duration = $TIMESTAMP_END - $TIMESTAMP_START
$durationStr = "{0:hh\:mm\:ss}" -f $duration

# Backup size
$backupSize = (Get-ChildItem -Path $USB -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
$usbDiskFinal = if ($DriveLetter) { Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'" } else { $null }

Write-Host ""
Write-Host "  +============================================+" -ForegroundColor Green
Write-Host "  |         BACKUP COMPLETED SUCCESSFULLY      |" -ForegroundColor Green
Write-Host "  +============================================+" -ForegroundColor Green
Write-Host "  |  Mode:     $Mode" -ForegroundColor Green
Write-Host "  |  Target:   $USB" -ForegroundColor Green
Write-Host "  |  Duration: $durationStr" -ForegroundColor Green
Write-Host "  |  Copied:   $totalCopied files" -ForegroundColor Green
Write-Host "  |  Skipped:  $totalSkipped files" -ForegroundColor Green
if ($totalFailed -gt 0) {
    Write-Host "  |  Errors:   $totalFailed files" -ForegroundColor Yellow
}
Write-Host "  |  Size:     $(Format-Size $backupSize)" -ForegroundColor Green
if ($usbDiskFinal) {
    Write-Host "  |  Free:     $(Format-Size $usbDiskFinal.FreeSpace)" -ForegroundColor Green
}
if ($Verify) {
    Write-Host "  |  CRC:      verified" -ForegroundColor Green
}
Write-Host "  |  Log:      $LOG_FILE" -ForegroundColor Green
Write-Host "  +============================================+" -ForegroundColor Green

# Log
"Duration: $durationStr | Copied: $totalCopied | Skipped: $totalSkipped | Failed: $totalFailed | Size: $(Format-Size $backupSize)" | Out-File -Append $LOG_FILE
"===== COMPLETED $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====" | Out-File -Append $LOG_FILE
