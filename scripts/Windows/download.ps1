$output_file = "C:\AzCopyWorkspace\azcopy.csv"
$azcopy_jnl_dir = "C:\AzCopyWorkspace\jnl\in"
$local_dir = "C:\AzCopyWorkspace\in"
$action = "download"
$threads = 64
$protocol = "http"
$proxy = "localhost:8000"
$container = "dlalancettewestus.blob.core.windows.net/davidcontainer"
$pattern = "data"
$key = "<Key>"

& "C:\GoPackages\src\github.com\shanebarnes\errand\scripts\Windows\azcopy.ps1" "$output_file" "$azcopy_jnl_dir" "$local_dir" "$action" "$threads" "$protocol" "$proxy" "$container" "$pattern" "$key" -Verbose
