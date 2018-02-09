[CmdletBinding()]
Param(
    [Parameter(Mandatory=$True)][string]$csv_file,       # Example:  "/home/user/azcopy_out.csv"
    
    [Parameter(Mandatory=$True)][string]$azcopy_jnl_dir, # Example:  "/home/user/Microsoft/Azure/AzCopy"
    
    [Parameter(Mandatory=$True)][string]$local_dir,      # Example:  "/home/user/mydir"
    
    [Parameter(Mandatory=$True)][string]$action,         # Examples: "download" or "upload"
    
    [Parameter(Mandatory=$True)][int]$threads,           # Example:  "16"
    
    [Parameter(Mandatory=$True)][string]$protocol,       # Examples: "http" or "https"
    
    [Parameter(Mandatory=$True)]
    [AllowEmptyString()][string]$proxy,                  # Examples: "localhost:8000", "localhost:8443", "" (no proxy)
    
    [Parameter(Mandatory=$True)][string]$container,      # Example:  "myblob.blob.core.windows.net/mycontainer
    
    [Parameter(Mandatory=$True)][string]$pattern,        # Example:  Upload: Directory and filenames matched recursively, wildcard supported; Download: Prefix/exact name, NO wildcard supported
    
    [Parameter(Mandatory=$True)][string]$key
)

# Paths to some essentials (executables, config file)
$azcopy_bin_dir     = "C:\Program Files (x86)\Microsoft SDKs\Azure\AzCopy\"
$azcopy_bin         = "$azcopy_bin_dir" + "AzCopy.exe"
$azcopy_config_path = "$azcopy_bin_dir" + "AzCopy.exe.config"

$flightgw_bin        = "C:\Users\az-user\AppData\Local\Signiant\Flight Gateway\flight-gateway.exe"

$azcopy_config_template = @'
<configuration>
<system.net>
  <defaultProxy>
     <proxy proxyaddress="<PROTOCOL>://<PROXY_ADDRESS_AND_PORT>" bypassonlocal="false" />
  </defaultProxy>
</system.net>
</configuration>
'@

function epoch_millis()
{
	$epoch = Get-Date -Year 1970 -Month 1 -Day 1 -Hour 0 -Minute 0 -Second 0
    Get-Date | % {
		return [math]::truncate($_.ToUniversalTime().Subtract($epoch).TotalMilliSeconds)
	}	
}

function generate_config_file()
{
    if (Test-Path $azcopy_config_path)
    {
        Write-Verbose "Backing up an existing config file"
        Copy-Item -Path $azcopy_config_path -Destination ("$azcopy_config_path" + ".bak") -Force
    }

    if ("$proxy" -ne "")
    {
        $azcopy_config = $azcopy_config_template.Replace("<PROTOCOL>", "$protocol")
        $azcopy_config = $azcopy_config.Replace("<PROXY_ADDRESS_AND_PORT>", "$proxy")
        Write-Verbose "Proxy Configuration:"
        Write-Verbose "$azcopy_config"
    
        $config_file = New-Item -Path $azcopy_config_path -ItemType "file" -Force
        $azcopy_config >> $config_file
    }
    else 
    {
        if (Test-Path $azcopy_config_path)
        {
            Remove-Item $azcopy_config_path -Force
        }
    }
}

function get_results()
{
    $after = epoch_millis
    Write-Host "Logging results at $after"

    $err_code = switch ($?)
    {
        $true    { "Success" }
        $false   { "Failure" }
    }

    # Compute the sum of all sizes of files found recursively in the local directory.
    $filesize = ((Get-ChildItem "$local_dir" -Recurse) | Measure-Object -sum length).Sum
    $bits = $filesize * 8
    $duration = $after - $before
    $bitrate = $bits * 1000 / $duration

    if (!(Test-Path $csv_file))
    {
        "#epoch_timestamp_msec,vm_location,vm_type,os_version,azcopy_version,flight_version,flight_pid,max_thread_count,block_size,packet_loss,app_protocol,proxy_setting,blob_url,transfer_direction,transfer_errno,transfer_size_bytes,transfer_duration_msec,goodput_bps" >> $csv_file
    }
    
    $block_size = $null # For compatibility with shell verion; Windows AzCopy doesn't seem to support block size.
    $packet_loss = 0 # For compatibility with shell verion; We can't manipulate packet loss.
    
    ("${before},${vm_location},${vm_size},${os_version},${azcopy_version},${flightgw_version},${flightgw_pid},${threads},${block_size},${packet_loss},${protocol},${proxy},${container},${action},${err_code},${filesize},${duration},${bitrate}") >> ${csv_file}
}

function get_versions()
{
    $Script:azcopy_version   = "unknown"
    $Script:flightgw_pid     = 0
    $Script:flightgw_version = "unknown"
    $Script:vm_location      = "unknown"
    $Script:vm_size          = "unknown"

    if (Test-Path "${azcopy_bin}")
    {
        $Script:azcopy_version_text = & "${azcopy_bin}"
        $pieces = ($azcopy_version_text | select-string -Pattern "Copyright").Line.Split(" ") # Get the line containing Version and Copyright info.
        $Script:azcopy_version = $pieces[1] # Grab the second word. Should be version number (as of 7.1.0).
    }

    if (Test-Path "${flightgw_bin}")
    {
        $flightgw_version = (& "${flightgw_bin}" --version) | select-string flight-gateway
    }

    $Script:os_version = (Get-WmiObject -class Win32_OperatingSystem).Caption

    $vm_metadata = $null
    try 
    {
        $vm_metadata = (Invoke-WebRequest -Uri "http://169.254.169.254/metadata/instance?api-version=2017-04-02" -Headers @{'Metadata' = 'True'}).ToString()
    }
    catch 
    {
        $vm_metadata = ""
    }

    if ($vm_metadata -ne "") 
    {
        Write-Verbose "Succesfully retrieved VM Metadata -- parsing."
        $vm_metadata_json = ConvertFrom-Json $vm_metadata

        $Script:vm_location = $vm_metadata_json.compute.location
        $Script:vm_size = $vm_metadata_json.compute.vmSize
    }

    $Script:flightgw_pid = (Get-Process -Name "flight-gateway" -ea SilentlyContinue).Id
}

function on_signal() 
{
    Write-Verbose "Getting results"
    get_results
    exit
}

function run_azcopy()
{
    $Script:before = epoch_millis
    Write-Host "Began running at $Script:before"

    if ("$action" -eq "download")
    {
        & "${azcopy_bin}" /Dest:"${local_dir}" /Source:"${protocol}://${container}" /SourceKey:"${key}" /Y /NC:"${threads}" /S /Z:"${azcopy_jnl_dir}" /Pattern:"$pattern"
    } 
    elseif ("$action" -eq "upload")
    {
        & "${azcopy_bin}" /Source:"${local_dir}" /Dest:"${protocol}://${container}" /DestKey:"${key}" /Y /NC:"${threads}" /S /Z:"${azcopy_jnl_dir}" /Pattern:"$pattern"
    }

    Write-Verbose "Finished running"
}

function set_configs()
{
    if ((Get-Item "${azcopy_jnl_dir}").PSISContainer)
    {
        Remove-Item ${azcopy_jnl_dir}/*.jnl -Force
    }

    generate_config_file
}

#################### MAIN ####################
$action      = "$action".ToLower()
$protocol    = "$protocol".ToLower()

try {
    get_versions
    set_configs
    run_azcopy
} finally {
    on_signal
}
