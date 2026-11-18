param(
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [string]$InputFileSpreadsheetURL = $env:GITHUBRELEASECSVURL,
    [string]$gid = $env:GITHUBRELEASECSVGID,
    [string]$CurrentEmu68ImagerVersion = $env:EMU68IMAGERVERSION
)

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

$PathtoGoogleDrivetouse = "$($InputFileSpreadsheetURL.TrimEnd('/'))/export?format=tsv&gid=$gid"

try {
    $RawTsv = Invoke-RestMethod -Uri $PathtoGoogleDrivetouse -ErrorAction Stop
}
catch {
    Write-Error "CRITICAL: Failed to download the Google Sheet. Error: $_"
    exit 1
}

# Stop if Google returned an HTML login/error page instead of raw TSV text
if ([string]::IsNullOrWhiteSpace($RawTsv) -or $RawTsv.TrimStart() -match '^(<!DOCTYPE|<html)' -or $RawTsv -notmatch 'SourceLocation') {
    Write-Error "CRITICAL: The Google Sheet URL did not return valid TSV data (it likely returned a Google login page). Check that the sheet's sharing permissions are set to 'Anyone with the link can view'."
    exit 1
}

# $CurrentEmu68ImagerVersion = '2.3'
$CurrentEmu68ImagerVersionSemantic = [version]$CurrentEmu68ImagerVersion

$Repositories = $RawTsv | ConvertFrom-Csv -Delimiter ';' | Where-Object {
    if ($_.include -ne "TRUE") { return $false }

    $minVer = if (-not [string]::IsNullOrWhiteSpace($_.MinimumInstallerVersion)) { [version]$_.MinimumInstallerVersion } else { $null }
    $maxVer = if (-not [string]::IsNullOrWhiteSpace($_.InstallerVersionLessThan)) { [version]$_.InstallerVersionLessThan } else { $null }

    if ($minVer -and $CurrentEmu68ImagerVersionSemantic -lt $minVer) { return $false }
    if ($maxVer -and $CurrentEmu68ImagerVersionSemantic -ge $maxVer) { return $false }

    return $true
} | Select-Object SourceLocation,GithubReleaseType,GithubName,GithubNameExclude,GithubSortTagPrefix,GithubSortSemanticVersion,GithubRelease,GithubMinimumPublishedDate,Repository, Owner -Unique | Sort-Object Owner,Repository

$headers = @{
    "Accept"               = [string]"application/vnd.github+json"
    "X-GitHub-Api-Version" = [string]"2022-11-28"
}
if ($GitHubToken) {
    $headers["Authorization"] = [string]"Bearer $GitHubToken"
    Write-Host "Using provided GitHub token for API requests."
}
else {
    Write-Warning "No GitHub token provided. API requests will be unauthenticated and subject to strict rate limits."
}

$Owner = $null
$RepositoryName = $null

$releaseData = foreach ($Line in $Repositories) {
    If ($Owner -ne $Line.Owner -or $RepositoryName -ne $Line.Repository){
        $Owner = $Line.Owner
        $RepositoryName = $Line.Repository
        $uri = "https://api.github.com/repos/$Owner/$RepositoryName/releases"
        Write-Host "Fetching releases for $Owner/$RepositoryName..."
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        }
        catch {
            Write-Error "CRITICAL: Could not fetch release for $Owner/$RepositoryName. Error: $_"
            exit 1

        }
        if (-not ($response)){
            Write-Error "CRITICAL: No data from Github repository."                       
            exit 1
        }
    }
    foreach ($release in $response) {
        if ($line.GithubSortSemanticVersion -eq "TRUE") {
            $TagNametoSort = $($release.tag_name) -replace "^$($line.GithubSortTagPrefix)", "" -as [version]
        }
        else {
            $TagNametoSort = $($release.tag_name) -replace "^$($line.GithubSortTagPrefix)", "" 
        }
        foreach ($asset in $release.assets) {
            [PSCustomObject]@{
                SourceLocation             = $line.SourceLocation
                Repository                 = $RepositoryName
                Owner                      = $Owner            
                Release_Draft              = $release.draft
                Release_prerelease         = $release.prerelease
                Release_TagName            = $release.tag_name
                Release_TagNametoSort      = $TagNametoSort
                Release_Name               = $release.name
                Release_HtmlUrl            = $release.html_url
                Release_Published          = $release.published_at
                Asset_browser_download_url = $asset.browser_download_url
                Asset_Name                 = $asset.name
                Asset_size                 = $asset.size
                Asset_digest               = $asset.digest
                Asset_content_type         = $asset.content_type
            }
        }
    }
}

$RepositoryLookup = $Repositories | Group-Object -Property "SourceLocation" -AsHashTable
       
$ReleaseDataRevised = foreach ($Line in $releaseData) {
    if ($Line.Release_Draft -eq $true) { continue }
    $Lookup = $RepositoryLookup[$line.SourceLocation]
    $MinimumPublishedDate = if ($Lookup.GithubMinimumPublishedDate) { [DateTime]::FromOADate($Lookup.GithubMinimumPublishedDate) } else { $null }
    $GithubNameExcludeList = if ($Lookup.GithubNameExclude) { ($Lookup.GithubNameExclude -split ',' | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '|' } else { $null }
    if ($Line.Release_prerelease -eq "TRUE" -and $Lookup.GithubReleaseType -notin @("Nightly","PreRelease-NoArchive","PreRelease","Release-AminetXDuo")) { continue }
    if ($Lookup.GithubReleaseType -eq "Release-AminetXDuo" -and $line.Release_TagName -eq "nightly") { continue }
    if (($MinimumPublishedDate) -and ([datetime]$line.Release_Published -lt $MinimumPublishedDate)) { continue }
    If (($Lookup.GithubRelease) -and ($Lookup.GithubRelease -ne $line.Release_TagName)) { continue }
    if ($line.Asset_Name -notlike $Lookup.GithubName) { continue }
    if (($GithubNameExcludeList) -and ($line.Asset_Name -match $GithubNameExcludeList)) { continue }
    $line
} 

$ReleaseDataRevised = $ReleaseDataRevised | Sort-Object -Property @{Expression="SourceLocation"; Ascending=$true}, @{Expression={$_.Release_TagNametoSort}; Descending=$true}

# Prepare absolute output directory path at repo root dist/
$RepoRoot = Split-Path -Parent $ScriptDir
$DistDir = Join-Path $RepoRoot "dist"
if (!(Test-Path $DistDir)) { 
    New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
}

$CsvOutputPath = Join-Path $DistDir "SoftwareReleases.csv"

# Collect unique SourceLocation mappings

$SourceLocationLookup = $null
$csvRows = foreach ($line in $ReleaseDataRevised){
    if ($SourceLocationLookup -ne $line.SourceLocation) {
        [PSCustomObject]@{
            SourceLocation  = $line.SourceLocation
            Release_TagName = $line.Release_TagName
            Digest          = $line.asset_digest
            Name            = $line.asset_name
            DownloadURL     = $line.Asset_browser_download_url
        }
        $SourceLocationLookup = $line.SourceLocation
    }
}

$ExpectedSources = $Repositories.SourceLocation
$GeneratedSources = $csvRows.SourceLocation
$MissingSources = $ExpectedSources | Where-Object { $_ -notin $GeneratedSources }

if ($MissingSources) {
    Write-Error "The following SourceLocations were omitted (no matching release, asset filter failed, or API returned nothing): $($MissingSources -join ', ')"
    exit 1
}

Write-Host "Filtered down to $($csvRows.Count) unique release rows to write."

if (-not $csvRows -or $csvRows.Count -eq 0) {
    Write-Error "CRITICAL: Zero rows matched your filter criteria. The generated CSV would be empty."
    exit 1
}

# Export to CSV with semicolon delimiter
$csvRows | Export-Csv -Path $CsvOutputPath -NoTypeInformation -Delimiter ';' -Encoding utf8

# Verify file size post-generation
$FileInfo = Get-Item $CsvOutputPath
Write-Host "Successfully generated CSV at $CsvOutputPath. File size: $($FileInfo.Length) bytes."
if ($FileInfo.Length -eq 0) {
    Write-Error "CRITICAL: The generated CSV file size is 0 bytes."
    exit 1
}