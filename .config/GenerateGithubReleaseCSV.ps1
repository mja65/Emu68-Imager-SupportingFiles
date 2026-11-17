param(
    [string]$GitHubToken = $env:GITHUB_TOKEN
)

Write-Host "Starting CSV generation..."
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$CsvPath = Join-Path $ScriptDir "SoftwareGithubReleases.csv"
if (-not (Test-Path $CsvPath)) {
    Write-Error "CRITICAL: Could not find SoftwareGithubReleases.csv at $CsvPath"
    exit 1
}

$Repositories = Import-Csv -Path $CsvPath -Delimiter ';'
Write-Host "Loaded $($Repositories.Count) repositories from configuration."

$RepositoryLookup = $Repositories | Group-Object -Property "SourceLocation" -AsHashTable

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

$releaseData = foreach ($repo in $Repositories) {
    $Owner = $repo.Owner
    $RepositoryName = $repo.Repository
    $uri = "https://api.github.com/repos/$Owner/$RepositoryName/releases"
    Write-Host "Fetching releases for $Owner/$RepositoryName..."
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        if (-not $response) { 
            Write-Host "No response data for $RepositoryName"
            continue 
        }
        
        foreach ($release in $response) {
            if ($repo.GithubSortSemanticVersion -eq $true) {
                $TagNametoSort = $($release.tag_name) -replace "^$($repo.GithubSortTagPrefix)", "" -as [version]
            }
            else {
                $TagNametoSort = $($release.tag_name) -replace "^$($repo.GithubSortTagPrefix)", "" 
            }
            foreach ($asset in $release.assets) {
                [PSCustomObject]@{
                    SourceLocation             = $repo.SourceLocation
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
    catch {
        Write-Warning "Could not fetch release for $RepositoryName. Error: $_"
    }
}

$ReleaseDataRevised = foreach ($Line in $releaseData) {
    $Lookup = $RepositoryLookup[$line.SourceLocation]
    $MinimumPublishedDate = if ($Lookup.GithubMinimumPublishedDate) { [DateTime]::FromOADate($Lookup.GithubMinimumPublishedDate) } else { $null }
    $GithubNameExcludeList = ($Lookup.GithubNameExclude -split ',' | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '|'

    if ($Line.Release_prerelease -eq "TRUE" -and $Lookup.GithubReleaseType -ne "PreRelease-NoArchive" -and $Lookup.GithubReleaseType -ne "PreRelease") { continue }
    if (($MinimumPublishedDate) -and ([datetime]$line.Release_Published -lt $MinimumPublishedDate)) { continue }
    If (($Lookup.GithubRelease) -and ($Lookup.GithubRelease -ne $line.Release_TagName)) { continue }
    if ($line.Asset_Name -notlike $Lookup.GithubName) { continue }
    if (($GithubNameExcludeList) -and ($line.Asset_Name -match $GithubNameExcludeList)) { continue }
    $line
} 

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
            SourceLocation = $line.SourceLocation
            DownloadURL    = $line.Asset_browser_download_url
        }
        $SourceLocationLookup = $line.SourceLocation
    }
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