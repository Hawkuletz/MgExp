# helper function returning friendly (KB/MB/GB/...) string for large sizes
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
