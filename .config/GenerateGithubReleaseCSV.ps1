param(
    [string]$GitHubToken = $env:GITHUB_TOKEN
)

$CsvPath = Join-Path $PSScriptRoot "SoftwareGithubReleases.csv"
if (-not (Test-Path $CsvPath)) {
    Write-Error "Could not find SoftwareGithubReleases.csv at $CsvPath"
    exit 1
}

$Repositories = Import-Csv -Path $CsvPath -Delimiter ';'
$RepositoryLookup = $Repositories | Group-Object -Property "SourceLocation" -AsHashTable

$headers = @{
    "Accept"               = "vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}
if ($GitHubToken) {
    $headers["Authorization"] = "Bearer $GitHubToken"
}

$releaseData = foreach ($repo in $Repositories) {
    $Owner = $repo.Owner
    $RepositoryName = $repo.Repository
    $uri = "https://api.github.com/repos/$Owner/$RepositoryName/releases"
    Write-Host "Looking for $RepositoryName..."
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        if (-not $response) { continue }
        
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
        Write-Warning "Could not fetch release for $RepositoryName"
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

# Prepare output directory
$DistDir = Join-Path $PSScriptRoot "../dist"
if (!(Test-Path $DistDir)) { New-Item -ItemType Directory -Path $DistDir -Force }
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

# Export to CSV with semicolon delimiter
$csvRows | Export-Csv -Path $CsvOutputPath -NoTypeInformation -Delimiter ';' -Encoding utf8
Write-Host "Successfully generated CSV at $CsvOutputPath"