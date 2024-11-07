# MgExp
MgGraph (Microsoft Graph) PowerShell experiments and utilities

Main (almost finalized one) is recursive\_upload.ps1 - recursively upload local directory contents to a remote drive.

Usage (must have both recursive_upload.ps1 and helperfunc.ps1 in the same directory):

  ./recursive\_upload.psq -Path <localpath> -DriveId <drive_id> -FolderId <drive_folder_id>

Ranty story about how this came to be at https://hawk.ro/stories/mgdrive/
