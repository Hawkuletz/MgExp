param([Parameter(Mandatory=$true)][string]$Site)
Connect-MgGraph -NoWelcome
Write-Host "Showing drives for $Site"
$site_info=Get-MgSite -SiteId $Site
Get-MgSiteDrive -SiteId $site_info.Id
