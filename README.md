# Windows Scheduled File Cleaner Script

A PowerShell script for automatically cleaning up files based on configurable patterns. Ideal for removing temporary files, old downloads, or any recurring file clutter.

## Features

- **Multiple search patterns**: Define multiple filename + extension combinations to match
- **Age-based deletion**: Only deletes files older than a configurable threshold (default: 72 hours)
- **Safe TEST mode**: Run in TEST mode to preview what would be deleted without actually removing files
- **Robust logging**: Per-run log files with automatic retention cleanup
- **Fail-safe design**: Logging failures never crash the script; it continues gracefully

## Installation

1. Clone or download this repository
2. Edit `src/scheduled_file_cleaner.ps1` to configure your settings (see Configuration below)
3. Run manually or set up as a scheduled task

## Configuration

Open `src/scheduled_file_cleaner.ps1` and edit the **CONFIGURATION VARIABLES** section at the top:

### Search Folder

```powershell
[string]$s_searchFolderPath = "C:\Users\YourUsername\Downloads"
```

Set this to the folder you want to scan for files.

### Search Patterns

```powershell
[array]$array_o_searchPatterns = @(
    @{ s_fileNameContains = "report";  s_extension = ".pdf" },
    @{ s_fileNameContains = "backup";  s_extension = ".zip" }
)
```

Each pattern has two properties:
- `s_fileNameContains`: A substring that must appear in the filename (case-insensitive)
- `s_extension`: The exact file extension to match (case-insensitive)

A file is eligible for deletion if it matches **any** of the patterns.

**Examples:**
| Pattern | Matches | Does NOT Match |
|---------|---------|----------------|
| `@{ s_fileNameContains = "report"; s_extension = ".pdf" }` | `monthly_report_2025.pdf`, `REPORT.pdf` | `report.txt`, `myfile.pdf` |
| `@{ s_fileNameContains = "backup"; s_extension = ".zip" }` | `backup_20251126.zip`, `full_backup.zip` | `backup.tar`, `archive.zip` |

### Log Folder

```powershell
[string]$s_logRoot = "C:\Users\YourUsername\Documents\file-cleaner-logs"
```

Set this to where you want log files to be stored. The folder will be created automatically if it does not exist.

### Run Mode

```powershell
[string]$s_runMode = "TEST"
```

- `TEST`: Only logs what would be deleted (safe mode for testing your configuration)
- `LIVE`: Actually deletes matching files

**Recommendation:** Always run in TEST mode first to verify your patterns are correct.

## Usage

### Manual Execution

Open PowerShell and run:

```powershell
.\src\scheduled_file_cleaner.ps1
```

### Windows Task Scheduler

To run the script automatically on a schedule:

1. Open **Task Scheduler** (search for it in the Start menu)
2. Click **Create Task** (not "Create Basic Task")
3. **General tab:**
   - Name: `File Cleaner`
   - Select "Run whether user is logged on or not"
4. **Triggers tab:**
   - Click **New** and set your desired schedule (e.g., daily at 2:00 AM)
5. **Actions tab:**
   - Click **New**
   - Action: "Start a program"
   - Program/script: `powershell.exe`
   - Arguments: `-ExecutionPolicy Bypass -File "C:\path\to\scheduled_file_cleaner.ps1"`
6. Click **OK** and enter your password if prompted

## Logging

The script creates a log file for each run in the configured log folder:

- **Normal logs**: `file_cleaner_2025-11-26_14-30-00.log`
- **Partial logs** (if logging failed mid-run): `file_cleaner_PARTIAL_2025-11-26_14-30-00.stub`
- **Init failure stubs** (if logging could not start): `file_cleaner_INIT_FAILED_2025-11-26_14-30-00.stub`

Old log files are automatically cleaned up after 14 days (configurable via `$i_logRetentionDays`).

### Log Format

Each log entry contains:
- ISO 8601 timestamp
- Log level (INFO, WARN, ERROR)
- Message

Example:
```
2025-11-26T14:30:00+00:00 | INFO | START | Mode=TEST | Folder=C:\Users\Example\Downloads
2025-11-26T14:30:00+00:00 | INFO | MATCH FOUND (by CreationTime): C:\Users\Example\Downloads\report_old.pdf
2025-11-26T14:30:01+00:00 | INFO | SUMMARY | Scanned=150 | Matched=3 | Deleted=0 | Mode=TEST
```

## Logging Architecture

The script uses a **scriptblock-based logger pattern** to avoid repetitive conditional checks throughout the code.

### The Problem This Solves

An inelegant approach to optional logging would require wrapping every log call in a conditional:

```powershell
# Inelegant approach - repetitive and clutters the code
if ($b_loggingEnabled)
{
    Write-ToLogFile "INFO" "Starting process..."
}

# ... later in code ...

if ($b_loggingEnabled)
{
    Write-ToLogFile "INFO" "File deleted: $s_fileName"
}

# ... repeated dozens of times throughout the script
```

This creates code duplication and makes the main logic harder to read.

### The Solution: Swappable Scriptblocks

Instead, we define two scriptblocks with identical signatures:

1. **`$WriteLog_RealImpl`** - Actually writes to the log file
2. **`$WriteLog_NoopImpl`** - Does nothing (empty implementation)

A single variable `$WriteLogLine` acts as a pointer that can reference either implementation:

```powershell
# At initialization, point to the real logger
$WriteLogLine = $WriteLog_RealImpl

# If logging fails at any point, swap to the no-op logger
$WriteLogLine = $WriteLog_NoopImpl
```

Throughout the script, we simply call `& $WriteLogLine "INFO" "message"` without any conditionals. The behaviour changes based on which implementation is currently assigned.

### Benefits

- **Clean main logic**: No `if` statements cluttering the business logic
- **Single point of control**: Logging can be enabled/disabled by changing one variable
- **Graceful degradation**: If logging fails mid-run, the script swaps to the no-op logger and continues without crashing
- **Consistent interface**: All log calls look identical regardless of whether logging is active

## How It Works

1. **Initialize logging**: Creates a per-run log file (falls back to no-op logging if this fails)
2. **Clean old logs**: Removes log/stub files older than the retention period
3. **Scan folder**: Gets all files from the target folder
4. **For each file**:
   - Check if the extension matches any pattern (exact match)
   - Check if the filename contains the required substring (case-insensitive)
   - Check if the file's CreationTime is older than the threshold
5. **If all criteria match**:
   - In TEST mode: Log the file details only
   - In LIVE mode: Delete the file and log the action
6. **Output summary**: Display and log counts of scanned, matched, and deleted files

## License

MIT License - feel free to use and modify as needed.
