# quick (well, 2 weekend days) and dirty (hardcoded variables below, some global variables, other stuff) tool to recursively upload a bunch of files to a SharePoint Document Library
# Mihai Gaitos, 2024-10-27

param( 
	[Parameter(Mandatory=$true)][string]$Path,
	[Parameter(Mandatory=$true)][string]$DriveId,
	[Parameter(Mandatory=$true)][string]$FolderId
)
Connect-MgGraph -NoWelcome

# all that we need in one convenient place
class XMyFileInfo
{
	[string]$Name
	[string]$FullPath
	[boolean]$IsDir
	[string]$mtime
	[long]$FSize
	[string]$DriveId
	[string]$DriveParentId
	[string]$DriveFileId
	[boolean]$Uploaded
	[object]$us
	[object]$LastResponse
	[string]$State
	[string]$ErrInfo
}

# gen_friendly_size helper function returning friendly (KB/MB/GB/...) string for large sizes
function gen_friendly_size{
	param([long]$size)
	# naive and simplistic approach but it's enough for powershell
	# keep it to 6 significant digits, but GB is enough for my purpose.
	if($size -gt 999999999999)
	{
		return $size.ToString('#,#,,, GB');
	}
	elseif($size -gt 999999999)
	{
		return $size.ToString('#,#,, MB');
	}
	elseif($size -gt 999999)
	{
		return $size.ToString('#,#, KB');
	}
	else
	{
		return $size.ToString('#,# B');
	}
}

function upload_data{
	# Path is local path, DriveId is DriveId, FileId is "DriveItemId" for the already created (and empty) file
	param( 
		[Parameter(Mandatory=$true)][object]$MFI
	)
	

	# MS strongly suggests the chunk size to be a multiple of 320KB (327680 bytes) - see https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0
	# however, there seems to be a rate limitation on API calls, so higher slice sizes give better speeds (up to a point).
	# let's start with 10 times that. *Do not change msslice*
	$slices_per_call=10
	$msslice=327680
	# don't retry (want to check headers in case of error)
	$maxtries=1

	# internal helper function (build slice header)
	function bld_header
	{
		param(
			[Parameter(Mandatory=$true)][long]$clen,
			[Parameter(Mandatory=$true)][long]$cpos,
			[Parameter(Mandatory=$true)][long]$tlen
		)
		$rend=$cpos+$clen-1

		$hdr=@{
			'Content-Length'=$clen
			'Content-Range'="bytes $cpos-$rend/$tlen"
		}
		return $hdr
	}

	# open local file
	$stream=[System.IO.File]::OpenRead($($MFI.FullPath))
	if($stream -eq $null)
	{
		Write-Error "Unable to open file $($MFI.FullPath)"
		$MFI.State="Local open"
		$MFI.ErrInfo=$_
		$FailList.Add($MFI)
		return $false
	}

	Write-Host "File $($MFI.FullPath) opened. Size is $($stream.Length)"

	# initialize upload session
	$us=New-MgDriveItemUploadSession -DriveId $MFI.DriveId -DriveItemId $MFI.DriveFileId
	if($us.UploadUrl -eq $null)
	{
		Write-Error "Unable to start upload session"
		$MFI.State="Init upload"
		$MFI.ErrInfo=$_
		return $false
	}
	$MFI.us=$us
	Write-Host -NoNewLine "Upload session opened. Starting transfer..."

	$cp=0
	$tl=$stream.Length
	$remain=$stream.Length

	$csize=$slices_per_call*$msslice

	$buf=New-Object byte[] $csize

	# for debug
#	$global:ResList=New-Object System.Collections.Generic.List[System.Object]
#	$global:HdrList=New-Object System.Collections.Generic.List[System.Object]

	$tries=$maxtries

	# timer to determine upload rate
	$swt=[system.diagnostics.stopwatch]::StartNew()
	$lswt=0

	# send chunks
	while($remain -gt 0)
	{
		$rc=$stream.Read($buf,0,$csize)
		if($rc -lt $csize -and $rc -lt $remain)
		{
			Write-Error "Read did not deliver. Unexpected end of file?"
			$MFI.State="Local read"
			$MFI.ErrInfo=$_
			break
		}
		$hdr=bld_header -clen $rc -cpos $cp -tlen $tl
		# buf manipulation, because of stupidity in either Invoke-MgGraphRequest or byte array in powershell
		# array[0..x] doesn't work (despite having the correct length, count, etc)
		# and of course Invoke-MgGraphRequest can't send just part of the buffer
		# lost 2 hours trying to determine how to deal with this stupidity! [EXPLETIVE] MS!
		if($csize -ne $rc)
		{
			$ubuf=New-Object byte[] $rc
			[Array]::Copy($buf,0,$ubuf,0,$rc)
		}
		else
		{
			$ubuf=$buf
		}

#		$HdrList.Add($hdr)
		try
		{
			$urr=Invoke-MgGraphRequest -Uri $us.UploadUrl -Method PUT -Headers $hdr -Body $ubuf -SkipHeaderValidation
		}
		catch
		{
			write-host "failed uploading at position $cp"
			write-host $_
#			$ResList.Add($urr)
			$tries--
			if($tries -gt 0)
			{
				continue
			}
			else
			{
				$MFI.State="Upload chunk"
				$MFI.ErrInfo=$_
				$MFI.LastResponse=$urr
				break
			}
		}
		# if we're here, we've had one success, so reset tries counter :)
		$tries=$maxtries
		# update remaining bytes, current position and update status
		$remain-=$rc
		$cp+=$rc
		$sent_str=gen_friendly_size($cp)
		$total_str=gen_friendly_size($tl)
		$cswt=$swt.Elapsed.TotalSeconds
		if($cswt -ne $lswt) { $rate_str=gen_friendly_size($rc/($cswt-$lswt)) } else { $rate_str='?' }
		$lswt=$cswt
		Write-Host -NoNewLine "`r$sent_str / $total_str sent at $rate_str/s      "
	}


	# Invoke-MgGraphRequest seems to be breaking something in the internal variables of the session; quickest solution is to reconnect
	# there might be another (quicker) method to restore the default URI Mg* functions use, but... yeah, good luck with MS docs. Thus q&d we remain.
#	Connect-MgGraph -NoWelcome
	# see https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/2437
	# would this be this quicker?
	Invoke-MgGraphRequest -Method GET https://graph.microsoft.com/v1.0/me | Out-Null

	# final message (total time)
	$swt.Stop()
	if($remain -eq 0)
	{
		$totalsec=$swt.Elapsed.TotalSeconds
		if($totalsec -ne 0) { $rate_str=gen_friendly_size($cp/$totalsec) } else { $rate_str='?' }
		Write-Host "`rUpload complete. $sent_str sent at $rate_str/s      "
		return $true
	}
	else
	{
		Write-Host "`nError uploading!"
		# relevant $MFI data should already be set from the loop above
		$FailList.Add($MFI)
		return $false
	}
}

function od_add_file{
	param([Parameter(Mandatory)][object]$MFI)

	# build creation request
	$nfparam=@{
		name=$MFI.Name
		file=@{
			MimeType='application/octet-stream'
		}
		fileSystemInfo=@{
			createdDateTime=$MFI.mtime
			lastModifiedDateTime=$MFI.mtime
		}
	}

	# try to create remote file
	Write-Host -NoNewLine "Creating remote file..."
	$nf=New-MgDriveItemChild -DriveId $MFI.DriveId -DriveItemId $MFI.DriveParentId -BodyParameter $nfparam
	if($nf -eq $null)
	{
		Write-Host "Failed creating file $($MFI.Name)"
		$MFI.State="Remote create"
		$MFI.ErrInfo=$_
		$FailList.Add($MFI)
		return $false
	}
	$MFI.DriveFileId=$nf.id
	Write-Host -NoNewLine "`rCreated. "

	# upload is now a separate funcion that takes the same structure argument
	$ures=upload_data $MFI # -Path $MFI.FullPath -DriveId $MFI.DriveId -FileId $MFI.DriveFileId
	if(!$ures)
	{
		write-host "failed uploading $($MFI.Name)"
		write-host $_
		# at this point, upload_data added MFI to the faillist
		return $false
	}
	# we should test this one as well, but... eh... not that important
	Update-MgDriveItem -DriveId $MFI.DriveId -DriveItemId $MFI.DriveFileId -BodyParameter $nfparam | Out-Null
	return $true
}

# remote mkdir :)
function od_add_folder{
	param([Parameter(Mandatory)][object]$MFI)
	$nfparam=@{
		name=$MFI.Name
		folder=@{
			childCount=0
		}
		fileSystemInfo=@{
			createdDateTime=$MFI.mtime
			lastModifiedDateTime=$MFI.mtime
		}
	}
	$nf=New-MgDriveItemChild -DriveId $MFI.DriveID -DriveItemId $MFI.DriveParentId -BodyParameter $nfparam
	if($nf -eq $null)
	{
		Write-Error "Failed creating folder $Name"
		$FailList.Add($MFI)
		return $null
	}
	return $nf.Id
}

function od_upd_mtime{
	param([Parameter(Mandatory)][string]$DriveId, [Parameter(Mandatory)][string]$ItemId, [Parameter(Mandatory)][string]$mtime)
	$nfparam=@{
		fileSystemInfo=@{
			createdDateTime=$mtime
			lastModifiedDateTime=$mtime
		}
	}
	Update-MgDriveItem -DriveId $DriveId -DriveItemId $ItemId -BodyParameter $nfparam | Out-Null
}

function dig_dir
{
	param([Parameter(Mandatory)][string]$did,[Parameter(Mandatory)][string]$fid,[Parameter(Mandatory)][string]$Path)
	Write-Host "Entering $Path"
	$dlist=Get-ChildItem -Path $Path
	foreach($de in $dlist)
	{
		$MFI=[XMyFileInfo]::new()
		$MFI.Name=$de.Name
		$MFI.FullPath=$de.FullName
		$MFI.IsDir=$de.PSIsContainer
		$MFI.mtime=$de.LastWriteTimeUtc.GetDateTimeFormats('O')[0]
		$MFI.FSize=$de.Length
		$MFI.DriveId=$did
		$MFI.DriveParentId=$fid

		if($de.PSIsContainer)
		{
			# create OD directory, get new $OD, start dig
			$nfid=od_add_folder -MFI $MFI
			if($nfid -eq $null)
			{
				Write-Error "Failed getting new remote directory for $name"
				continue
			}
			dig_dir -did $did -fid $nfid -Path $de.FullName
			od_upd_mtime -DriveId $did -ItemId $nfid -mtime $MFI.mtime
		}
		else
		{
			$rv=od_add_file -MFI $MFI
			if($rv) { $global:FileCount++ }
		}
	}
}

# Should probably keep the status in a separate file, update it with each uploaded file, but this is good enough for now
$global:FailList=New-Object System.Collections.Generic.List[System.Object]
$global:FileCount=0

# Start the recursive process
dig_dir -did $DriveId -fid $FolderId -Path $Path

# Final message
if($FailList.count -ne 0) { Write-Host "Failed uploads: $($FailList.count)" } else { Write-Host "Success! $FileCount files uploaded." }
