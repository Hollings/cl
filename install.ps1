# cl - Claude Code session manager installer for Windows

$ErrorActionPreference = "Stop"
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script = Join-Path $RepoDir "cl"

# Create ~/.local/bin equivalent
$InstallDir = Join-Path $env:USERPROFILE ".local\bin"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# Create a wrapper batch file so 'cl' works from cmd/powershell
# Detect the right Python command — Windows typically has 'python', not 'python3'
$PythonCmd = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" }
             elseif (Get-Command python -ErrorAction SilentlyContinue) { "python" }
             else { "python3" }

$Wrapper = Join-Path $InstallDir "cl.cmd"
@"
@echo off
$PythonCmd "%~dp0cl.py" %*
"@ | Set-Content $Wrapper

# Copy the actual script
Copy-Item $Script (Join-Path $InstallDir "cl.py") -Force

Write-Host "Installed to $InstallDir"

# Check PATH
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$InstallDir*") {
    $AddToPath = Read-Host "Add $InstallDir to PATH? (y/n)"
    if ($AddToPath -eq "y") {
        [Environment]::SetEnvironmentVariable("Path", "$UserPath;$InstallDir", "User")
        Write-Host "Added to PATH. Restart your terminal for it to take effect."
    } else {
        Write-Host ""
        Write-Host "Add this to your PATH manually:"
        Write-Host "  `$env:PATH += `";$InstallDir`""
    }
}

# Check dependencies
$Missing = @()
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { $Missing += "claude" }
if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) { $Missing += "fzf" }
if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) { $Missing += "python3" }
}

if ($Missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Missing dependencies: $($Missing -join ', ')"
    Write-Host ""
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host "  scoop install $($Missing -join ' ')"
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  winget install $($Missing -join ' ')"
    }
}
