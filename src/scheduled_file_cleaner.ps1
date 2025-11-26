<#
    Windows Scheduled File Cleaner Script
    --------------------------------------
    Author  : Anonymous
    Date    : 2025-11-26
    Version : 1.0.0

    Purpose:
    - Scan a user-specified folder for files matching one or more patterns.
    - Each pattern consists of: (1) a substring the filename must contain, and (2) an exact file extension.
    - If a matching file is older than the configured age (in hours), treat it as eligible for deletion.
    - In TEST mode: only output/log the eligible files (no deletion).
    - In LIVE mode: delete the eligible files after logging.

    Logging approach:
    - Try once at the start to create a per-run .log file in the central logs folder.
    - If that fails, write a single INIT_FAILED .stub and continue with logging disabled (no-op logger).
    - If logging later fails mid-run, rename the existing .log to a single PARTIAL .stub, append the error, and disable logging for the rest of the run.
    - Retain .log and .stub files only for a fixed number of days to stop unbounded growth.

    How to use:
    - Edit the CONFIGURATION VARIABLES section below to specify your search folder, patterns, and run mode.
    - Run the script manually or schedule it via Windows Task Scheduler.
#>

# =========================
# CONFIGURATION VARIABLES
# =========================

# Folder to scan for files
# Example: "C:\Users\YourUsername\Downloads"
[string]$s_searchFolderPath = "C:\Users\YourUsername\Downloads" # Folder to scan for files matching the patterns below

# Search patterns - each entry defines a filename substring and an exact extension to match
# The script will delete files that match ANY of these patterns (if they are also older than the age threshold)
# Example patterns:
#   @{ s_fileNameContains = "report";  s_extension = ".pdf" }  - matches files like "monthly_report_2025.pdf"
#   @{ s_fileNameContains = "backup";  s_extension = ".zip" }  - matches files like "backup_20251126.zip"
[array]$array_o_searchPatterns = @(
    @{ s_fileNameContains = "example_pattern_1"; s_extension = ".txt" }, # Pattern 1: files containing "example_pattern_1" with .txt extension
    @{ s_fileNameContains = "example_pattern_2"; s_extension = ".log" }  # Pattern 2: files containing "example_pattern_2" with .log extension
)

# Files older than this many hours (based on CreationTime) are eligible for deletion
[int]$i_deleteIfOlderThanHours = 72 # Delete files older than 72 hours (3 days)

# How many days to keep log and stub files before cleaning them up
[int]$i_logRetentionDays = 14 # Keep logs/stubs for 14 days

# Path to the folder where log files will be written
# This should be an absolute path; the script will create the folder if it does not exist
[string]$s_logRoot = "C:\Users\YourUsername\Documents\file-cleaner-logs" # Central log/stub folder

# Run mode: "TEST" (safe - only logs what would be deleted) or "LIVE" (actually deletes files)
[string]$s_runMode = "TEST" # Set to "LIVE" to enable actual file deletion

# =========================
# SCRIPT STATE / WORKING VARIABLES
# =========================
[datetime]$dt_scriptStartTime = Get-Date # When the script started executing
[datetime]$dt_cutoffTime = (Get-Date).AddHours(-$i_deleteIfOlderThanHours) # Files with CreationTime older than this are eligible for deletion
[string]$s_logFileName = "" # Per-run log filename (set during initialization)
[string]$s_logFile = "" # Per-run log full path (set during initialization)
[int]$i_filesScanned = 0 # Counter: how many files we examined in total
[int]$i_filesMatched = 0 # Counter: how many files matched extension + name + age criteria
[int]$i_filesDeleted = 0 # Counter: how many files we actually deleted (only incremented in LIVE mode)
[object[]]$array_o_filesInFolder = @() # Array to hold all files retrieved from the target folder
[object]$o_currentFile = $null # The file object currently being processed in the loop
[string]$s_consoleOutput = "" # Human-readable output line constructed for console/log display
[Nullable[datetime]]$dt_tempTimestamp = $null # Temporary datetime variable for age comparisons
[bool]$b_matchedAnyPattern = $false # Flag indicating whether current file matched any of the search patterns
[object]$o_currentPattern = $null # The pattern object currently being checked against the file

# =========================
# LOGGER SCRIPTBLOCKS
# =========================
# The logger uses PowerShell scriptblocks instead of functions.
# $WriteLogLine dynamically points to either $WriteLog_RealImpl or $WriteLog_NoopImpl depending on whether logging is active.
[scriptblock]$WriteLogLine = $null # Will be assigned to either the real or no-op logger during initialization

# No-op logger: used when logging is unavailable (init failed or mid-run failure)
# This scriptblock accepts the same parameters as the real logger but does nothing.
[scriptblock]$WriteLog_NoopImpl =
{
    param([string]$s_level, [string]$s_message)
    # Intentionally empty - logging is disabled
}

# Real logger: writes to the per-run log file; on failure it renames to PARTIAL.stub and disables logging
[scriptblock]$WriteLog_RealImpl =
{
    param([string]$s_level, [string]$s_message)

    try
    {
        [string]$s_timeStamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK") # Get timestamp in ISO 8601 format with timezone offset
        [string]$s_line = "$s_timeStamp | $s_level | $s_message" # Construct the log line with timestamp, level, and message
        Add-Content -Path $script:s_logFile -Value $s_line -Encoding UTF8 # Append the log line to the log file
    }
    catch
    {
        # Logging was working earlier but now it failed mid-run.
        # Attempt to rename the log file to a PARTIAL.stub to indicate incomplete logging.
        if (Test-Path -LiteralPath $script:s_logFile) # Check if the log file still exists before attempting rename
        {
            [string]$s_dirName = [System.IO.Path]::GetDirectoryName($script:s_logFile) # Extract directory path from full log file path
            [string]$s_fileName = [System.IO.Path]::GetFileName($script:s_logFile) # Extract filename from full log file path

            # Construct the PARTIAL stub filename by replacing prefix and extension
            [string]$s_partialName = $s_fileName -replace '^file_cleaner_', 'file_cleaner_PARTIAL_' -replace '\.log$', '.stub'
            [string]$s_partialPath = Join-Path -Path $s_dirName -ChildPath $s_partialName # Full path to the PARTIAL stub file

            try
            {
                Rename-Item -LiteralPath $script:s_logFile -NewName $s_partialName -Force # Rename the log file to PARTIAL stub
                [string]$s_errorTimeStamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK") # Timestamp for the error entry
                [string]$s_errorLine = "$s_errorTimeStamp | ERROR | Mid-run logging failed: $($_.Exception.Message)" # Error message to append
                Add-Content -Path $s_partialPath -Value $s_errorLine -Encoding UTF8 # Append error details to the stub file
            }
            catch
            {
                # If rename/append also fails, we still disable logging below.
                # Nothing more we can do at this point.
            }
        }

        # In all cases after a mid-run logging failure, disable logging for the rest of the script.
        $script:WriteLogLine = $script:WriteLog_NoopImpl
    }
}

# =========================
# MAIN SCRIPT
# =========================

# 1) Try to initialize logging for this run
# Creates the log folder if needed, creates a new per-run log file, and writes the initial entry.
try
{
    if (-not (Test-Path -LiteralPath $s_logRoot)) # Create log root folder if it doesn't exist
    {
        New-Item -Path $s_logRoot -ItemType Directory -Force | Out-Null
    }

    $s_logFileName = "file_cleaner_{0:yyyy-MM-dd_HH-mm-ss}.log" -f (Get-Date) # Generate timestamped log filename
    $s_logFile = Join-Path -Path $s_logRoot -ChildPath $s_logFileName # Construct full path to the log file

    New-Item -Path $s_logFile -ItemType File -Force | Out-Null # Create the empty log file

    $WriteLogLine = $WriteLog_RealImpl # Assign the real logger implementation
    & $WriteLogLine "INFO" ("START | Mode=" + $s_runMode + " | Folder=" + $s_searchFolderPath) # Log the start of the script run
}
catch
{
    # Logging could not be initialized; write an init stub if possible, then fall back to no-op.
    try
    {
        if (-not (Test-Path -LiteralPath $s_logRoot)) # Attempt to create log root folder for the stub file
        {
            New-Item -Path $s_logRoot -ItemType Directory -Force | Out-Null
        }

        [string]$s_initStubName = "file_cleaner_INIT_FAILED_{0:yyyy-MM-dd_HH-mm-ss}.stub" -f (Get-Date) # Timestamped init failure stub filename
        [string]$s_initStubPath = Join-Path -Path $s_logRoot -ChildPath $s_initStubName # Full path to the init failure stub
        [string]$s_initMsg = "Logging initialization failed: " + $_.Exception.Message # Error message describing the failure
        Set-Content -Path $s_initStubPath -Value $s_initMsg -Encoding UTF8 # Write the error message to the stub file
    }
    catch
    {
        # If even the stub creation fails, just continue without any file logging.
    }

    $WriteLogLine = $WriteLog_NoopImpl # Fall back to the no-op logger
    Write-Output ("Logging initialization failed. Continuing without logging. Reason: " + $_.Exception.Message)
}

# 2) Retention: delete old .log and .stub files
# This prevents unbounded growth of log files over time.
try
{
    [datetime]$dt_retentionCutoff = (Get-Date).AddDays(-$i_logRetentionDays) # Files last modified before this datetime will be deleted

    # Delete old .log files beyond the retention period
    Get-ChildItem -Path $s_logRoot -Filter "file_cleaner_*.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $dt_retentionCutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Delete old .stub files beyond the retention period
    Get-ChildItem -Path $s_logRoot -Filter "file_cleaner_*.stub" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $dt_retentionCutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
catch
{
    & $WriteLogLine "WARN" ("Log retention cleanup failed: " + $_.Exception.Message)
}

# 3) Validate that the search folder exists before proceeding
if (-not (Test-Path -LiteralPath $s_searchFolderPath))
{
    [string]$s_errorMsg = "ERROR: Search folder does not exist: $s_searchFolderPath" # Error message for missing folder
    Write-Output $s_errorMsg
    & $WriteLogLine "ERROR" $s_errorMsg
    exit 1 # Exit with error code since we cannot proceed without the search folder
}

# 4) Get and sort all files from the target folder (oldest first so console output is tidy)
$array_o_filesInFolder = Get-ChildItem -Path $s_searchFolderPath -File | Sort-Object -Property CreationTime

# 5) Process each file against our criteria
# For each file, check if it matches any of the configured patterns and is old enough for deletion.
foreach ($o_currentFile in $array_o_filesInFolder)
{
    $i_filesScanned++ # Increment the scanned files counter

    if (-not $o_currentFile) # Sanity check: skip null entries (should not happen, but defensive)
    {
        continue
    }

    $b_matchedAnyPattern = $false # Reset the pattern match flag for each file

    # Check the current file against each search pattern
    foreach ($o_currentPattern in $array_o_searchPatterns)
    {
        [string]$s_requiredExtension = $o_currentPattern.s_extension # The exact extension this pattern requires
        [string]$s_requiredNameSubstring = $o_currentPattern.s_fileNameContains # The substring the filename must contain

        # Extension must match exactly (case-insensitive comparison)
        if ($o_currentFile.Extension -ine $s_requiredExtension)
        {
            continue # Extension does not match this pattern, try the next pattern
        }

        # Filename must contain the required substring (case-insensitive wildcard match)
        if ($o_currentFile.Name -notlike "*$s_requiredNameSubstring*")
        {
            continue # Filename does not contain the required substring, try the next pattern
        }

        # Both extension and name criteria matched for this pattern
        $b_matchedAnyPattern = $true
        break # No need to check remaining patterns since we found a match
    }

    if (-not $b_matchedAnyPattern) # If the file did not match any pattern, skip to the next file
    {
        continue
    }

    # Age check: file must be older than the cutoff time (based on CreationTime)
    $dt_tempTimestamp = $o_currentFile.CreationTime # Get the file's creation timestamp
    if ($dt_tempTimestamp -ge $dt_cutoffTime) # If the file is newer than or equal to the cutoff, skip it
    {
        continue
    }

    # File matched all criteria: extension, name substring, and age
    $i_filesMatched++ # Increment the matched files counter

    # Build output string with file details for console and log
    $s_consoleOutput = "MATCH FOUND (by CreationTime): " + $o_currentFile.FullName
    $s_consoleOutput += "`n    Created : " + $o_currentFile.CreationTime
    $s_consoleOutput += "`n    Modified: " + $o_currentFile.LastWriteTime
    $s_consoleOutput += "`n    Accessed: " + $o_currentFile.LastAccessTime
    $s_consoleOutput += "`n------------------------------------------------------------"

    Write-Output $s_consoleOutput # Output to console for visibility
    & $WriteLogLine "INFO" $s_consoleOutput # Write to log file

    if ($s_runMode -ieq "LIVE") # If in LIVE mode, attempt to delete the file
    {
        try
        {
            Remove-Item -Path $o_currentFile.FullName -Force # Delete the file
            $i_filesDeleted++ # Increment the deleted files counter
            & $WriteLogLine "INFO" ("Deleted: " + $o_currentFile.FullName)
        }
        catch
        {
            & $WriteLogLine "ERROR" ("Failed to delete: " + $o_currentFile.FullName + " | Reason: " + $_.Exception.Message)
        }
    }
}

# =========================
# FINAL SUMMARY
# =========================
# At the end of the execution, calculate how long the script took to run,
# output a concise summary to the console, and write both summary and
# duration to the log file.

# Capture and calculate the total duration
[datetime]$dt_scriptEndTime = Get-Date # Current time at script end
[timespan]$ts_duration = $dt_scriptEndTime - $dt_scriptStartTime # Total run duration

# Build the summary line (overall counts)
[string]$s_summaryLine = "SUMMARY | Scanned=$i_filesScanned | Matched=$i_filesMatched | Deleted=$i_filesDeleted | Mode=$s_runMode"

# Build the duration line (elapsed time in hh:mm:ss)
[string]$s_durationLine = "Run duration: " + $ts_duration.ToString("hh\:mm\:ss")

# Output to console for visibility
Write-Output $s_summaryLine
Write-Output $s_durationLine

# Write summary and timing to log
& $WriteLogLine "INFO" "Started at: $dt_scriptStartTime | Ended at: $dt_scriptEndTime"
& $WriteLogLine "INFO" $s_summaryLine
& $WriteLogLine "INFO" $s_durationLine
