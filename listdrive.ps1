param(
	[Parameter(Mandatory=$true)][string]$DriveId,
	[Parameter()][string]$FolderId
)

Connect-MgGraph -NoWelcome


# thanks Microsoft, really smart API, differentiating between root and non-root like that! /s
if($FolderId -ne $null -and $FolderId -ne '')
{
	Get-MgDriveItemChild -DriveId $DriveId -DriveItemId $FolderId
}
else
{
	Get-MgDriveRootChild -DriveId $DriveId
}
