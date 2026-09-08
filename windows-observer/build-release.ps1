#requires -Version 7.2
<#
Build a self-contained Windows x64 ZIP. Run from PowerShell on Windows.
The result includes .NET and the official embeddable CPython runtime; users do
not need either runtime installed. Existing release files are never replaced.
#>
[CmdletBinding()]
param([string]$Version = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows release packaging must run on Windows.' }

$projectRoot = Split-Path -Parent $PSScriptRoot
$projectFile = Join-Path $PSScriptRoot 'CodexTokenObserver.Windows.csproj'
$plist = [xml](Get-Content -LiteralPath (Join-Path $projectRoot 'desktop-observer/Info.plist') -Raw)
$versionNode = $plist.SelectSingleNode('/plist/dict/key[text()="CFBundleShortVersionString"]/following-sibling::string[1]')
if ($null -eq $versionNode) { throw 'Info.plist is missing CFBundleShortVersionString.' }
$bundleVersion = $versionNode.InnerText
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $bundleVersion }
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Version -ne $bundleVersion) {
    throw "Version must match Info.plist ($bundleVersion) and use major.minor.patch."
}
$project = [xml](Get-Content -LiteralPath $projectFile -Raw)
$windowsVersion = $project.SelectSingleNode('/Project/PropertyGroup/Version')
if ($null -eq $windowsVersion -or $windowsVersion.InnerText -ne $Version) {
    throw 'The Windows project Version must match Info.plist before packaging.'
}

# Version and hash are pinned to the official release page, not a mutable mirror:
# https://www.python.org/downloads/release/python-3147/
$pythonVersion = '3.14.7'
$pythonArchiveUrl = "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-embed-amd64.zip"
$pythonArchiveSha256 = 'd297e5ff019966817ad8502465176139f2d3d840fa4ed84b13bed399a6ab1f15'
$zipName = "Zuno-$Version-windows-x64.zip"
$releaseDirectory = Join-Path $projectRoot 'release'
$diagnosticsDirectory = Join-Path $projectRoot '.qa/windows-build'
[void][IO.Directory]::CreateDirectory($releaseDirectory)
[void][IO.Directory]::CreateDirectory($diagnosticsDirectory)
$zipPath = Join-Path $releaseDirectory $zipName
$checksumPath = "$zipPath.sha256"
if ((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $checksumPath)) {
    throw "Release $Version already exists. Choose a new version; existing files are never overwritten."
}

# CreateNew is an exclusive lock and does not open or truncate an existing file.
$lockPath = Join-Path $releaseDirectory ".windows-$Version.lock"
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$stagingDirectory = Join-Path $releaseDirectory ('.windows-stage-' + [Guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($stagingDirectory)
    $bundle = Join-Path $stagingDirectory 'Zuno'
    $nugetPackages = Join-Path $stagingDirectory 'nuget'
    $publishArguments = @(
        'publish', $projectFile, '--configuration', 'Release',
        '--runtime', 'win-x64', '--self-contained', 'true', '--output', $bundle,
        '-p:PublishSingleFile=false', '-p:DebugType=None', '-p:DebugSymbols=false',
        '-p:ContinuousIntegrationBuild=true', "-p:RestorePackagesPath=$nugetPackages",
        "-p:PathMap=$projectRoot=/src"
    )
    & dotnet @publishArguments 2>&1 | Tee-Object -FilePath (Join-Path $diagnosticsDirectory 'dotnet-publish.log')
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }
    $executable = Join-Path $bundle 'CodexTokenObserver.exe'
    if (-not (Test-Path -LiteralPath $executable)) { throw 'The published app executable is missing.' }

    $pythonArchive = Join-Path $stagingDirectory 'python-embed.zip'
    Invoke-WebRequest -Uri $pythonArchiveUrl -OutFile $pythonArchive
    $downloadHash = (Get-FileHash -LiteralPath $pythonArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($downloadHash -ne $pythonArchiveSha256) { throw 'Official Python archive SHA256 verification failed.' }
    $pythonDirectory = Join-Path $bundle 'python'
    Expand-Archive -LiteralPath $pythonArchive -DestinationPath $pythonDirectory
    if (-not (Test-Path -LiteralPath (Join-Path $pythonDirectory 'LICENSE.txt'))) {
        throw 'The official Python license is missing from the archive.'
    }
    $pythonPathFiles = @(Get-ChildItem -LiteralPath $pythonDirectory -Filter 'python*._pth' -File)
    if ($pythonPathFiles.Count -ne 1) { throw 'Expected exactly one embeddable Python path configuration.' }
    # Keep isolation and the official standard-library entries. Do not enable
    # site-packages or depend on PYTHONPATH (ignored by embeddable Python).
    Add-Content -LiteralPath $pythonPathFiles[0].FullName -Value '../counter/src' -Encoding utf8NoBOM

    $sourceRoot = Join-Path $projectRoot 'src'
    $counterSource = Join-Path $sourceRoot 'codex_token_counter'
    $sourceFiles = @(Get-ChildItem -LiteralPath $counterSource -File -Filter '*.py' -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]__pycache__[\\/]' })
    if ($sourceFiles.Count -eq 0) { throw 'No counter Python sources found.' }
    foreach ($source in $sourceFiles) {
        if (($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Python source symlinks are not permitted in a release.'
        }
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $source.FullName)
        $destination = Join-Path (Join-Path $bundle 'counter/src') $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath $source.FullName -Destination $destination
    }
    foreach ($document in @('LICENSE', 'PRIVACY.md')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $document) -Destination (Join-Path $bundle $document)
    }

    # Preserve .NET redistribution notices from the exact runtime packs restored
    # for this publish. These may not be copied automatically by dotnet publish.
    foreach ($runtimePackage in @('microsoft.netcore.app.runtime.win-x64', 'microsoft.windowsdesktop.app.runtime.win-x64')) {
        $runtimeRoot = Join-Path $nugetPackages $runtimePackage
        $runtimeVersions = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory)
        if ($runtimeVersions.Count -ne 1) { throw "Expected one restored version of $runtimePackage." }
        $licenseDestination = Join-Path $bundle "licenses/$runtimePackage"
        [void][IO.Directory]::CreateDirectory($licenseDestination)
        $notices = @(Get-ChildItem -LiteralPath $runtimeVersions[0].FullName -File -Recurse |
            Where-Object { $_.Name -match '^(LICENSE(\.txt)?|THIRD[-_]?PARTY[-_]?NOTICES(\.txt)?)$' })
        if (@($notices | Where-Object { $_.Name -match '^LICENSE(\.txt)?$' }).Count -eq 0) {
            throw "Missing $runtimePackage license."
        }
        foreach ($notice in $notices) {
            $noticeRelative = [IO.Path]::GetRelativePath($runtimeVersions[0].FullName, $notice.FullName)
            $noticeDestination = Join-Path $licenseDestination $noticeRelative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $noticeDestination))
            Copy-Item -LiteralPath $notice.FullName -Destination $noticeDestination
        }
    }

    # Validate the embedded interpreter without reading a user's Codex data or
    # writing .pyc caches. Host launches should also pass -B to this interpreter.
    & (Join-Path $pythonDirectory 'python.exe') -B -c 'import sys, struct, sqlite3, codex_token_counter.cli; assert struct.calcsize("P") == 8; assert sys.version_info[:3] == (3, 14, 7); print("Embedded Python imports passed")' 2>&1 |
        Tee-Object -FilePath (Join-Path $diagnosticsDirectory 'embedded-python.log')
    if ($LASTEXITCODE -ne 0) { throw 'The embedded counter import check failed.' }

    # Official Python's python314.zip includes trusted stdlib bytecode. Outside
    # that pinned archive no caches, databases, logs, debug symbols, or local
    # development runtime configuration belong in a redistributable bundle.
    $forbidden = @(Get-ChildItem -LiteralPath $bundle -Recurse -Force -File | Where-Object {
        $_.FullName -match '[\\/]__pycache__[\\/]' -or
        $_.Name -match '\.(py[co]|sqlite3?|db|log|pdb)$' -or
        $_.Name -in @('auth.json', '.env') -or $_.Name -like '*.runtimeconfig.dev.json'
    })
    if ($forbidden.Count -gt 0) { throw "Forbidden release resource: $($forbidden[0].Name)" }

    $stagedZip = Join-Path $stagingDirectory $zipName
    [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $stagedZip, [IO.Compression.CompressionLevel]::Optimal, $true)
    $archiveHash = (Get-FileHash -LiteralPath $stagedZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $stagedChecksum = "$stagedZip.sha256"
    [IO.File]::WriteAllText($stagedChecksum, "$archiveHash  $zipName`n", [Text.UTF8Encoding]::new($false))

    # File.Move's two-argument form fails when the destination already exists.
    [IO.File]::Move($stagedZip, $zipPath)
    [IO.File]::Move($stagedChecksum, $checksumPath)
    Write-Host "Created $zipName"
    Write-Host "SHA256 $archiveHash"
    Write-Output $zipPath
    Write-Output $checksumPath
}
catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $diagnosticsDirectory 'packaging-error.log') -Encoding utf8NoBOM
    throw
}
finally {
    $lock.Dispose()
    [IO.File]::Delete($lockPath)
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}
