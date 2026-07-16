$ErrorActionPreference = "Stop"

# ============================================================
# Settings
# ============================================================

$PartCount = 100
$MaxRetries = 5
$RetryDelaySeconds = 8
$PushTimeoutSeconds = 350
$ScriptFileName = "PushIn100Parts.ps1"

# SSH through port 443
$env:GIT_SSH_COMMAND = "ssh -p 443 -o HostName=ssh.github.com -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o TCPKeepAlive=yes -o IPQoS=none"

# ============================================================
# Helper functions
# ============================================================

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    Write-Host "git $($Arguments -join ' ')" -ForegroundColor DarkGray

    & git @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($Arguments -join ' ')"
    }
}

function Get-CompatibleRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BasePath,

        [Parameter(Mandatory = $true)]
        [string] $FullPath
    )

    $normalizedBasePath = $BasePath.TrimEnd("\", "/") + "\"

    $baseUri = New-Object System.Uri($normalizedBasePath)
    $fileUri = New-Object System.Uri($FullPath)

    $relativePath = $baseUri.MakeRelativeUri($fileUri).ToString()

    return [System.Uri]::UnescapeDataString($relativePath).Replace("\", "/")
}

function Write-NullSeparatedPathFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $OutputPath,

        [Parameter(Mandatory = $true)]
        [string[]] $Paths
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)

    $stream = New-Object System.IO.FileStream(
        $OutputPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )

    try {
        foreach ($path in $Paths) {
            $bytes = $encoding.GetBytes($path)

            $stream.Write($bytes, 0, $bytes.Length)
            $stream.WriteByte(0)
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-CurrentCommitHash {
    $hash = & git rev-parse HEAD 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hash)) {
        throw "Could not read the current commit hash."
    }

    return $hash.Trim()
}

function Get-RemoteMainHash {
    $output = & git ls-remote origin refs/heads/main 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
        return $null
    }

    return (($output -split "\s+")[0]).Trim()
}

function Test-RemoteCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CommitHash
    )

    $remoteHash = Get-RemoteMainHash

    if ([string]::IsNullOrWhiteSpace($remoteHash)) {
        return $false
    }

    return $remoteHash -eq $CommitHash
}

function Stop-ProcessTree {
    param(
        [Parameter(Mandatory = $true)]
        [int] $ProcessId
    )

    & taskkill.exe /PID $ProcessId /T /F *> $null
}

function Invoke-PushWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CommitHash,

        [Parameter(Mandatory = $true)]
        [int] $PartNumber,

        [Parameter(Mandatory = $true)]
        [int] $TotalParts,

        [Parameter(Mandatory = $true)]
        [string] $TemporaryDirectory
    )

    $stdoutFile = Join-Path $TemporaryDirectory "push-$PartNumber-stdout.log"
    $stderrFile = Join-Path $TemporaryDirectory "push-$PartNumber-stderr.log"

    Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue

    $argumentList = @(
        "push",
        "--force",
        "origin",
        "${CommitHash}:refs/heads/main"
    )

    $process = Start-Process `
        -FilePath "git.exe" `
        -ArgumentList $argumentList `
        -NoNewWindow `
        -PassThru `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile

    $finished = $process.WaitForExit($PushTimeoutSeconds * 1000)

    if (-not $finished) {
        Write-Host ""
        Write-Host "Push response timed out after $PushTimeoutSeconds seconds." -ForegroundColor Yellow
        Write-Host "Stopping the Git/SSH process and checking GitHub..." -ForegroundColor Yellow

        Stop-ProcessTree -ProcessId $process.Id

        Start-Sleep -Seconds 3

        if (Test-RemoteCommit -CommitHash $CommitHash) {
            Write-Host "GitHub received part $PartNumber successfully." -ForegroundColor Green
            return $true
        }

        return $false
    }

    $process.WaitForExit()

    if (Test-Path -LiteralPath $stdoutFile) {
        $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue

        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            Write-Host $stdout.Trim()
        }
    }

    if (Test-Path -LiteralPath $stderrFile) {
        $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Host $stderr.Trim()
        }
    }

    if ($process.ExitCode -eq 0) {
        if (Test-RemoteCommit -CommitHash $CommitHash) {
            return $true
        }

        Start-Sleep -Seconds 3

        return Test-RemoteCommit -CommitHash $CommitHash
    }

    Start-Sleep -Seconds 3

    return Test-RemoteCommit -CommitHash $CommitHash
}

function Push-CurrentPart {
    param(
        [Parameter(Mandatory = $true)]
        [int] $PartNumber,

        [Parameter(Mandatory = $true)]
        [int] $TotalParts,

        [Parameter(Mandatory = $true)]
        [string] $TemporaryDirectory
    )

    $commitHash = Get-CurrentCommitHash

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Host ""
        Write-Host "====================================================" -ForegroundColor Yellow
        Write-Host "Pushing part $PartNumber of $TotalParts" -ForegroundColor Yellow
        Write-Host "Attempt $attempt of $MaxRetries" -ForegroundColor DarkYellow
        Write-Host "Commit: $commitHash" -ForegroundColor DarkGray
        Write-Host "====================================================" -ForegroundColor Yellow

        if (Test-RemoteCommit -CommitHash $commitHash) {
            Write-Host "This part already exists on GitHub." -ForegroundColor Green
            return
        }

        $success = Invoke-PushWithTimeout `
            -CommitHash $commitHash `
            -PartNumber $PartNumber `
            -TotalParts $TotalParts `
            -TemporaryDirectory $TemporaryDirectory

        if ($success) {
            Write-Host ""
            Write-Host "Part $PartNumber pushed successfully." -ForegroundColor Green
            return
        }

        if ($attempt -lt $MaxRetries) {
            Write-Host ""
            Write-Host "Part was not registered on GitHub." -ForegroundColor Yellow
            Write-Host "Retrying in $RetryDelaySeconds seconds..." -ForegroundColor Yellow

            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    if (Test-RemoteCommit -CommitHash $commitHash) {
        Write-Host "GitHub received part $PartNumber." -ForegroundColor Green
        return
    }

    throw "Push failed for part $PartNumber after $MaxRetries attempts."
}

# ============================================================
# Locate repository
# ============================================================

$RepoRoot = & git rev-parse --show-toplevel 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Run this script inside the Git repository."
}

$RepoRoot = $RepoRoot.Trim()

Set-Location -LiteralPath $RepoRoot

Write-Host ""
Write-Host "Repository: $RepoRoot" -ForegroundColor Cyan

$GitDirectory = (& git rev-parse --git-dir).Trim()

if (-not [System.IO.Path]::IsPathRooted($GitDirectory)) {
    $GitDirectory = Join-Path $RepoRoot $GitDirectory
}

$GitDirectory = [System.IO.Path]::GetFullPath($GitDirectory)

# ============================================================
# Validate remote
# ============================================================

$RemoteUrl = & git remote get-url origin 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RemoteUrl)) {
    throw "Remote named 'origin' does not exist."
}

$RemoteUrl = $RemoteUrl.Trim()

Write-Host "Remote: $RemoteUrl" -ForegroundColor Cyan
Write-Host "SSH endpoint: ssh.github.com:443" -ForegroundColor Cyan

# Test SSH connection
Write-Host ""
Write-Host "Testing GitHub SSH connection on port 443..." -ForegroundColor Cyan

& ssh `
    -p 443 `
    -o HostName=ssh.github.com `
    -o ConnectTimeout=20 `
    -o StrictHostKeyChecking=accept-new `
    -T git@github.com

$sshExitCode = $LASTEXITCODE

# GitHub SSH authentication can return code 1 even after successful authentication.
if ($sshExitCode -ne 0 -and $sshExitCode -ne 1) {
    throw "Could not connect to GitHub SSH through port 443."
}

# Reduce pack processing pressure
Invoke-Git -Arguments @("config", "pack.threads", "10")
Invoke-Git -Arguments @("config", "core.compression", "9")
Invoke-Git -Arguments @("config", "pack.compression", "9")

# ============================================================
# Scan files
# ============================================================

Write-Host ""
Write-Host "Scanning project files..." -ForegroundColor Cyan

$GitDirectoryPrefix = $GitDirectory.TrimEnd("\", "/") + "\"

$Files = @(
    Get-ChildItem `
        -LiteralPath $RepoRoot `
        -Recurse `
        -Force `
        -File |
    Where-Object {
        $insideGitDirectory = $_.FullName.StartsWith(
            $GitDirectoryPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )

        $isCurrentScript = $_.Name -eq $ScriptFileName

        -not $insideGitDirectory -and -not $isCurrentScript
    } |
    ForEach-Object {
        [PSCustomObject]@{
            FullName = $_.FullName

            RelativePath = Get-CompatibleRelativePath `
                -BasePath $RepoRoot `
                -FullPath $_.FullName

            Length = [long]$_.Length
        }
    }
)

if ($Files.Count -eq 0) {
    throw "No project files were found."
}

$TotalSize = ($Files | Measure-Object -Property Length -Sum).Sum

Write-Host "Files: $($Files.Count)" -ForegroundColor White
Write-Host "Total size: $([Math]::Round($TotalSize / 1MB, 2)) MiB" -ForegroundColor White

# ============================================================
# Check individual file limit
# ============================================================

$OversizedFiles = @(
    $Files |
    Where-Object {
        $_.Length -gt 100MB
    } |
    Sort-Object Length -Descending
)

if ($OversizedFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "These files are larger than 100 MB:" -ForegroundColor Red

    $OversizedFiles |
    Select-Object `
        @{
            Name = "SizeMB"
            Expression = {
                [Math]::Round($_.Length / 1MB, 2)
            }
        },
        RelativePath |
    Format-Table -AutoSize

    throw "Files larger than 100 MB must use Git LFS."
}

# ============================================================
# Divide files into balanced parts
# ============================================================

$ActualPartCount = [Math]::Min($PartCount, $Files.Count)

$Parts = @()

for ($index = 0; $index -lt $ActualPartCount; $index++) {
    $Parts += [PSCustomObject]@{
        Number = $index + 1
        TotalSize = [long]0
        Files = New-Object System.Collections.ArrayList
    }
}

foreach ($File in ($Files | Sort-Object Length -Descending)) {
    $SmallestPart = $Parts |
        Sort-Object TotalSize |
        Select-Object -First 1

    [void]$SmallestPart.Files.Add($File)
    $SmallestPart.TotalSize += $File.Length
}

Write-Host ""
Write-Host "Generated parts:" -ForegroundColor Cyan

$Parts |
Sort-Object Number |
Select-Object `
    Number,
    @{
        Name = "Files"
        Expression = {
            $_.Files.Count
        }
    },
    @{
        Name = "SizeMB"
        Expression = {
            [Math]::Round($_.TotalSize / 1MB, 2)
        }
    } |
Format-Table -AutoSize

# ============================================================
# Create local backup branch
# ============================================================

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupBranch = "backup-before-100-parts-$Timestamp"

& git rev-parse --verify HEAD *> $null

$HasExistingCommit = $LASTEXITCODE -eq 0

if ($HasExistingCommit) {
    Invoke-Git -Arguments @(
        "branch",
        $BackupBranch,
        "HEAD"
    )

    Write-Host ""
    Write-Host "Local backup branch created:" -ForegroundColor Green
    Write-Host $BackupBranch -ForegroundColor Green
}

# ============================================================
# Create new clean history
# ============================================================

$TemporaryBranch = "upload-100-parts-$Timestamp"

Invoke-Git -Arguments @(
    "checkout",
    "--orphan",
    $TemporaryBranch
)

# Clear index without deleting physical files
Invoke-Git -Arguments @(
    "read-tree",
    "--empty"
)

$TemporaryDirectory = Join-Path $env:TEMP "git-upload-100-parts-$Timestamp"

New-Item `
    -ItemType Directory `
    -Path $TemporaryDirectory `
    -Force |
Out-Null

try {
    foreach ($Part in ($Parts | Sort-Object Number)) {
        $PartNumber = [int]$Part.Number

        Write-Host ""
        Write-Host "####################################################" -ForegroundColor Cyan
        Write-Host "Processing part $PartNumber of $ActualPartCount" -ForegroundColor Cyan
        Write-Host "Files: $($Part.Files.Count)" -ForegroundColor White
        Write-Host "Size: $([Math]::Round($Part.TotalSize / 1MB, 2)) MiB" -ForegroundColor White
        Write-Host "####################################################" -ForegroundColor Cyan

        $PathspecFile = Join-Path $TemporaryDirectory "part-$PartNumber.paths"

        $Paths = @(
            $Part.Files |
            ForEach-Object {
                $_.RelativePath
            }
        )

        Write-NullSeparatedPathFile `
            -OutputPath $PathspecFile `
            -Paths $Paths

        # Add current part only
        Invoke-Git -Arguments @(
            "add",
            "-f",
            "--pathspec-from-file=$PathspecFile",
            "--pathspec-file-nul"
        )

        # Commit current part
        Invoke-Git -Arguments @(
            "commit",
            "-m",
            "Project snapshot part $PartNumber of $ActualPartCount"
        )

        # First generated commit becomes main
        if ($PartNumber -eq 1) {
            Invoke-Git -Arguments @(
                "branch",
                "-M",
                "main"
            )
        }

        # Push immediately
        Push-CurrentPart `
            -PartNumber $PartNumber `
            -TotalParts $ActualPartCount `
            -TemporaryDirectory $TemporaryDirectory

        Write-Host ""
        Write-Host "Part $PartNumber completed successfully." -ForegroundColor Green
    }
}
finally {
    if (Test-Path -LiteralPath $TemporaryDirectory) {
        Remove-Item `
            -LiteralPath $TemporaryDirectory `
            -Recurse `
            -Force
    }
}

# ============================================================
# Finalize
# ============================================================

& git branch --set-upstream-to=origin/main main

if ($LASTEXITCODE -ne 0) {
    Write-Host "Pushes completed, but upstream was not set automatically." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "====================================================" -ForegroundColor Green
Write-Host "All $ActualPartCount parts uploaded successfully." -ForegroundColor Green
Write-Host "Local branch: main" -ForegroundColor Green
Write-Host "Remote branch: origin/main" -ForegroundColor Green

if ($HasExistingCommit) {
    Write-Host "Backup branch: $BackupBranch" -ForegroundColor Green
}

Write-Host "====================================================" -ForegroundColor Green