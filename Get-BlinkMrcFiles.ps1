<#
.SYNOPSIS
    Recursively finds all .blinkmrc.json files under a specified root directory,
    excluding specified directories.

.DESCRIPTION
    This script defines the Get-BlinkMrcFiles function.

    Example location:
        Documents\Sda\Code\Powershell\Get-BlinkMrcFiles.ps1

    If you want to run it from:
        Documents\

    Dot-source the script to load the function into your current session, then call it.

.EXAMPLE
    PS ..\Documents> . .\Sda\Code\Powershell\Get-BlinkMrcFiles.ps1
    PS ..\Documents> Get-BlinkMrcFiles

.EXAMPLE
    PS ..\Documents> . .\Sda\Code\Powershell\Get-BlinkMrcFiles.ps1
    PS ..\Documents> Get-BlinkMrcFiles -RootPath .\Sda\Code `
        -ExcludeDirectories @('node_modules','dist') `
        -ExcludeAdditionalDirectories @('BugTester','GeneralFormTester','LinkMapper') `
        -OutputFormat Json

.EXAMPLE
    PS ..\Documents> . .\Sda\Code\Powershell\Get-BlinkMrcFiles.ps1
    PS ..\Documents> Get-BlinkMrcFiles -ZipFoundFiles

    Creates a zip file named:
        blinkmrc-files.zip
    in the current directory, containing all found .blinkmrc.json files,
    preserving their relative directory structure.

.EXAMPLE
    PS ..\Documents> . .\Sda\Code\Powershell\Get-BlinkMrcFiles.ps1
    PS ..\Documents> Get-BlinkMrcFiles -ZipFoundFiles -ZipPath .\artifacts\blinkmrc-files.zip

    Creates a zip file at the specified path.

.PARAMETER RootPath
    Root directory to scan. Defaults to the current directory.

.PARAMETER ExcludeDirectories
    Default directories to always exclude.

.PARAMETER ExcludeAdditionalDirectories
    Additional directories to exclude (additive to defaults).
    Example:
        Get-BlinkMrcFiles -ExcludeAdditionalDirectories @('BugTester','GeneralFormTester','LinkMapper')

.PARAMETER OutputFormat
    Output format: Text, Json, or Object.

.PARAMETER FailIfFound
    Exit with code 1 if any .blinkmrc.json files are found.

.PARAMETER ZipFoundFiles
    Copy all found .blinkmrc.json files into a zip archive.

.PARAMETER ZipPath
    Path of the zip file to create.
#>

function Get-BlinkMrcFiles {
    [CmdletBinding()]
    param (
        [string]$RootPath = (Get-Location).Path,

        # Default exclusions (always applied)
        [string[]]$ExcludeDirectories = @(
            'node_modules',
            'dist',
            'build',
            'out',
            '.git'
        ),

        # Additional exclusions (opt-in)
        [string[]]$ExcludeAdditionalDirectories,

        [ValidateSet('Text', 'Json', 'Object')]
        [string]$OutputFormat = 'Text',

        [switch]$FailIfFound,

        [switch]$ZipFoundFiles,

        [string]$ZipPath = 'blinkmrc-files.zip'
    )

    if (-not (Test-Path -LiteralPath $RootPath)) {
        throw "RootPath does not exist: $RootPath"
    }

    # Track whether we created a zip (so we can output it LAST)
    $zipCreatedPath = $null

    # Resolve and normalise root
    $rootFull    = (Resolve-Path -LiteralPath $RootPath).Path
    $rootTrimmed = $rootFull.TrimEnd('\','/')

    # Merge default + additional exclusions (additive)
    $allExcludedDirectories =
        $ExcludeDirectories +
        ($ExcludeAdditionalDirectories | Where-Object { $_ })

    $allExcludedDirectories = $allExcludedDirectories | Sort-Object -Unique

    # Build regex matching excluded dirs as path segments (case-insensitive)
    $excludeRegex = if ($allExcludedDirectories.Count -gt 0) {
        '(?i)[\\/](?:' +
        ( ($allExcludedDirectories | ForEach-Object { [regex]::Escape($_) }) -join '|' ) +
        ')(?:[\\/]|$)'
    } else {
        $null
    }

    # Stack-based traversal to avoid recursing into excluded dirs
    $results = New-Object System.Collections.Generic.List[string]
    $stack   = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($rootFull)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()

        # Find .blinkmrc.json files in this directory
        Get-ChildItem -LiteralPath $dir -File -Filter '.blinkmrc.json' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $full = $_.FullName
                $rel  = $full.Substring($rootTrimmed.Length).TrimStart('\','/')
                $results.Add($rel)
            }

        # Recurse into subdirectories, pruning excluded ones
        Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                if ($excludeRegex) {
                    $_.FullName -notmatch $excludeRegex
                } else {
                    $true
                }
            } |
            ForEach-Object {
                $stack.Push($_.FullName)
            }
    }

    # De-dupe + sort
    $files = $results | Sort-Object -Unique

    # Zip found files (optional)
    if ($ZipFoundFiles -and $files.Count -gt 0) {

        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        foreach ($relPath in $files) {
            $source = Join-Path $rootFull $relPath
            $dest   = Join-Path $tempDir $relPath

            $destDir = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }

            Copy-Item -LiteralPath $source -Destination $dest -Force
        }

        if (Test-Path $ZipPath) {
            Remove-Item $ZipPath -Force
        }

        Compress-Archive -Path (Join-Path $tempDir '*') -DestinationPath $ZipPath -Force

        Remove-Item $tempDir -Recurse -Force

        # Capture for final (last line) output
        $zipCreatedPath = (Resolve-Path $ZipPath).Path
    }

    # CI-style failure (note: happens AFTER zipping so you still get the artifact)
    if ($FailIfFound -and $files.Count -gt 0) {
        Write-Error "Found $($files.Count) .blinkmrc.json file(s)"
        exit 1
    }

    # Output results first
    switch ($OutputFormat) {
        'Json'   { $files | ConvertTo-Json }
        'Object' { $files }
        default  { $files }
    }

    # Output zip message last
    if ($zipCreatedPath) {
        Write-Host
        Write-Host "Zip file created: $zipCreatedPath"
    }
}
