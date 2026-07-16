$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ============================================================
# Settings
# ============================================================

$RemoteName = "origin"
$BranchName = "main"
$PartSizeMB = 5
$LfsThresholdMB = 10
$MaxRetries = 6
$RetryDelaySeconds = 10

$ExcludedFileNames = @(
    "PushOnlyNewChangesInParts-LFS.ps1",
    "PushNewChangesInParts-LFS-Fixed.ps1",
    "PushNewChangesInParts-LFS.ps1",
    "PushNewChangesInParts.ps1",
    "PushIn100Parts.ps1"
)

$env:GIT_SSH_COMMAND = "ssh -p 443 -o HostName=ssh.github.com -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o TCPKeepAlive=yes -o IPQoS=none -o Compression=no"

# ============================================================
# Helpers
# ============================================================

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    Write-Host "git $($Arguments -join ' ')" -ForegroundColor DarkGray
    & git.exe @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: git $($Arguments -join ' ')"
    }
}

function Get-RepositoryRoot {
    $value = & git.exe rev-parse --show-toplevel 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Run this script inside a Git repository."
    }

    return $value.Trim()
}

function Get-Head {
    $value = & git.exe rev-parse HEAD 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Could not read HEAD."
    }

    return $value.Trim()
}

function Get-RemoteHead {
    $value = & git.exe ls-remote $RemoteName "refs/heads/$BranchName" 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return (($value -split "\s+")[0]).Trim()
}

function Test-RemoteHead {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Hash
    )

    return (Get-RemoteHead) -eq $Hash
}

function Convert-RemoteToSsh443 {
    $url = (& git.exe remote get-url $RemoteName).Trim()

    $match = [regex]::Match(
        $url,
        '^https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($match.Success) {
        $url = "ssh://git@ssh.github.com:443/$($match.Groups['owner'].Value)/$($match.Groups['repo'].Value).git"
        Invoke-Git -Arguments @("remote", "set-url", $RemoteName, $url)
    }

    return $url
}

function Test-GitLfs {
    & git.exe lfs version *> $null

    if ($LASTEXITCODE -ne 0) {
        throw @"
Git LFS is not installed.
Install it and then run:

git lfs install
"@
    }

    Invoke-Git -Arguments @("lfs", "install", "--local")
}

function Get-GitLines {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = @(& git.exe @Arguments)

    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: git $($Arguments -join ' ')"
    }

    return @(
        $output |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-ChangedFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    # Only differences from current HEAD are included.
    # Git does not re-upload unchanged objects already present on the remote.
    $tracked = @(
        Get-GitLines -Arguments @("diff", "--name-only", "HEAD", "--")
    )

    $staged = @(
        Get-GitLines -Arguments @("diff", "--cached", "--name-only", "HEAD", "--")
    )

    $untracked = @(
        Get-GitLines -Arguments @("ls-files", "--others", "--exclude-standard")
    )

    $paths = @(
        @($tracked) + @($staged) + @($untracked) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    )

    $result = @()

    foreach ($pathValue in $paths) {
        $relativePath = ([string]$pathValue).Replace("\", "/")
        $fileName = [System.IO.Path]::GetFileName($relativePath)

        if ($ExcludedFileNames -contains $fileName) {
            Write-Host "Excluded: $relativePath" -ForegroundColor DarkYellow
            continue
        }

        $fullPath = Join-Path $Root $relativePath
        $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
        $size = [long]0

        if ($exists) {
            $size = [long](Get-Item -LiteralPath $fullPath).Length
        }

        $result += [PSCustomObject]@{
            Path    = $relativePath
            FullPath = $fullPath
            Exists  = [bool]$exists
            Deleted = [bool](-not $exists)
            Size    = [long]$size
            Lfs     = $false
        }
    }

    return @($result)
}

function Assert-HistorySafe {
    $remoteReference = "$RemoteName/$BranchName"
    $localHash = Get-Head
    $remoteHash = (& git.exe rev-parse $remoteReference).Trim()

    if ($localHash -eq $remoteHash) {
        return
    }

    $mergeBase = & git.exe merge-base HEAD $remoteReference 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($mergeBase)) {
        throw "Local and remote histories are unrelated. No changes were made."
    }

    $mergeBase = $mergeBase.Trim()

    if ($mergeBase -eq $localHash) {
        throw @"
The remote branch contains newer commits.

Keep your files safe and synchronize first:

git stash -u
git pull --ff-only origin $BranchName
git stash pop
"@
    }

    if ($mergeBase -ne $remoteHash) {
        throw "Local and remote branches have diverged. Resolve with merge or rebase."
    }

    # Do not reset or rebuild history automatically.
    # Existing local commits are not re-created and no source snapshot is generated.
    throw @"
There are already local commits that have not been pushed.
This script will not reset or rebuild them automatically.

To push those existing commits normally, run:

git push origin $BranchName

To split a previous large unpushed commit, create a backup and reset it once:

git branch backup-before-split
git reset --mixed origin/$BranchName

Then run this script again.
"@
}

function Enable-LfsForLargeChangedFiles {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Files
    )

    $threshold = [long]($LfsThresholdMB * 1MB)
    $largeFiles = @(
        $Files |
        Where-Object {
            -not $_.Deleted -and [long]$_.Size -ge $threshold
        }
    )

    foreach ($file in $largeFiles) {
        Write-Host (
            "LFS: {0} ({1} MiB)" -f
            $file.Path,
            [Math]::Round($file.Size / 1MB, 2)
        ) -ForegroundColor Yellow

        & git.exe lfs track -- $file.Path

        if ($LASTEXITCODE -ne 0) {
            throw "Could not track '$($file.Path)' with Git LFS."
        }

        $file.Lfs = $true
    }
}

function New-Parts {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Files
    )

    $limit = [long]($PartSizeMB * 1MB)
    $parts = @()

    # Each large LFS file gets its own commit for simple retries.
    foreach ($file in @($Files | Where-Object { $_.Lfs -and -not $_.Deleted })) {
        $parts += [PSCustomObject]@{
            Files = @($file)
            Size  = [long]$file.Size
            Lfs   = $true
        }
    }

    $normalFiles = @(
        $Files |
        Where-Object { -not $_.Lfs -and -not $_.Deleted } |
        Sort-Object Size -Descending
    )

    foreach ($file in $normalFiles) {
        $selectedIndex = -1

        for ($index = 0; $index -lt $parts.Count; $index++) {
            if ($parts[$index].Lfs) {
                continue
            }

            $newSize = [long]$parts[$index].Size + [long]$file.Size

            if ($newSize -le $limit) {
                $selectedIndex = $index
                break
            }
        }

        if ($selectedIndex -eq -1) {
            $parts += [PSCustomObject]@{
                Files = @($file)
                Size  = [long]$file.Size
                Lfs   = $false
            }
        }
        else {
            $parts[$selectedIndex].Files = @(
                @($parts[$selectedIndex].Files) + @($file)
            )

            $parts[$selectedIndex].Size = (
                [long]$parts[$selectedIndex].Size + [long]$file.Size
            )
        }
    }

    $deletedFiles = @($Files | Where-Object { $_.Deleted })

    if ($deletedFiles.Count -gt 0) {
        if ($parts.Count -eq 0) {
            $parts += [PSCustomObject]@{
                Files = @()
                Size  = [long]0
                Lfs   = $false
            }
        }

        $lastIndex = $parts.Count - 1
        $parts[$lastIndex].Files = @(
            @($parts[$lastIndex].Files) + @($deletedFiles)
        )
    }

    return @($parts)
}

function Push-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Hash,

        [Parameter(Mandatory = $true)]
        [int] $Part,

        [Parameter(Mandatory = $true)]
        [int] $Total
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Host "Push part $Part/$Total - attempt $attempt/$MaxRetries" -ForegroundColor Yellow

        if (Test-RemoteHead -Hash $Hash) {
            Write-Host "Commit already exists on GitHub." -ForegroundColor Green
            return
        }

        & git.exe push $RemoteName "${BranchName}:refs/heads/$BranchName"

        if ($LASTEXITCODE -eq 0 -or (Test-RemoteHead -Hash $Hash)) {
            Write-Host "Part $Part pushed successfully." -ForegroundColor Green
            return
        }

        if ($attempt -lt $MaxRetries) {
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw "Push failed for part $Part."
}

# ============================================================
# Start
# ============================================================

$root = Get-RepositoryRoot
Set-Location -LiteralPath $root

$currentBranch = (& git.exe branch --show-current).Trim()

if ($currentBranch -ne $BranchName) {
    throw "Switch to branch '$BranchName'."
}

$remoteUrl = Convert-RemoteToSsh443

Write-Host "Repository: $root" -ForegroundColor Cyan
Write-Host "Remote: $remoteUrl" -ForegroundColor Cyan
Write-Host "Normal part size: $PartSizeMB MiB" -ForegroundColor Cyan
Write-Host "LFS threshold: $LfsThresholdMB MiB" -ForegroundColor Cyan

& ssh -p 443 -o HostName=ssh.github.com -o StrictHostKeyChecking=accept-new -T git@github.com

if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
    throw "GitHub SSH authentication failed."
}

Test-GitLfs

Invoke-Git -Arguments @("config", "--local", "pack.threads", "2")
Invoke-Git -Arguments @("config", "--local", "core.compression", "1")
Invoke-Git -Arguments @("config", "--local", "pack.compression", "1")

Invoke-Git -Arguments @("fetch", "--prune", $RemoteName, $BranchName)
Assert-HistorySafe

# Only clear the staging area; no files or commits are reset.
Invoke-Git -Arguments @("reset")

$files = @(Get-ChangedFiles -Root $root)

if ($files.Count -eq 0) {
    Write-Host "No new changes. Nothing was uploaded." -ForegroundColor Green
    exit 0
}

Write-Host "Changed paths: $($files.Count)" -ForegroundColor Cyan
Write-Host (
    "Changed size: {0} MiB" -f
    [Math]::Round((($files | Measure-Object Size -Sum).Sum) / 1MB, 2)
) -ForegroundColor Cyan

Enable-LfsForLargeChangedFiles -Files $files

# Re-read because git lfs track may create or update .gitattributes.
$files = @(Get-ChangedFiles -Root $root)
$thresholdBytes = [long]($LfsThresholdMB * 1MB)

foreach ($file in $files) {
    if (-not $file.Deleted -and [long]$file.Size -ge $thresholdBytes) {
        $file.Lfs = $true
    }
}

$parts = @(New-Parts -Files $files)

if ($parts.Count -eq 0) {
    throw "No upload parts were generated."
}

Write-Host "Generated $($parts.Count) part(s)." -ForegroundColor Cyan

for ($index = 0; $index -lt $parts.Count; $index++) {
    $kind = if ($parts[$index].Lfs) { "LFS" } else { "Git" }

    Write-Host (
        "Part {0}: {1} path(s), {2} MiB, {3}" -f
        ($index + 1),
        @($parts[$index].Files).Count,
        [Math]::Round($parts[$index].Size / 1MB, 2),
        $kind
    )
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

for ($index = 0; $index -lt $parts.Count; $index++) {
    $number = $index + 1
    $part = $parts[$index]
    $paths = @($part.Files | ForEach-Object { $_.Path })

    if ($number -eq 1 -and (Test-Path -LiteralPath ".gitattributes")) {
        $paths = @($paths + ".gitattributes" | Sort-Object -Unique)
    }

    Write-Host "" 
    Write-Host "Preparing part $number of $($parts.Count)..." -ForegroundColor Cyan

    foreach ($path in $paths) {
        & git.exe add --all -- $path

        if ($LASTEXITCODE -ne 0) {
            throw "Could not stage '$path'."
        }
    }

    & git.exe diff --cached --quiet

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Nothing to commit in part $number; skipped." -ForegroundColor Yellow
        continue
    }

    & git.exe diff --cached --stat

    $kind = if ($part.Lfs) { "LFS" } else { "Git" }
    $message = "Update $kind files part $number of $($parts.Count) [$stamp]"

    Invoke-Git -Arguments @("commit", "-m", $message)

    $hash = Get-Head
    Push-WithRetry -Hash $hash -Part $number -Total $parts.Count
}

$localHash = Get-Head
$remoteHash = Get-RemoteHead

Write-Host ""
Write-Host "Local:  $localHash" -ForegroundColor DarkGray
Write-Host "Remote: $remoteHash" -ForegroundColor DarkGray

if ($localHash -eq $remoteHash) {
    Write-Host "Only new changes were uploaded successfully." -ForegroundColor Green
    Write-Host "Previous Git history was preserved." -ForegroundColor Green
}
else {
    Write-Host "Final verification failed." -ForegroundColor Yellow
}
