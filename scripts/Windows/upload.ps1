$output_file = "C:\AzCopyWorkspace\azcopy.csv"
$azcopy_jnl_dir = "C:\AzCopyWorkspace\jnl\out"
$local_dir = "C:\AzCopyWorkspace\out\data"
$action = "upload"
$threads = 64
$protocol = "https"
$proxy = "localhost:8443"
$container = "dlalancettewestus.blob.core.windows.net/davidcontainer/data"
$pattern = "*.*"
$key = "<KEY>"

& "C:\GoPackages\src\github.com\shanebarnes\errand\scripts\Windows\azcopy.ps1" "$output_file" "$azcopy_jnl_dir" "$local_dir" "$action" "$threads" "$protocol" "$proxy" "$container" "$pattern" "$key" -Verbose
