#!/bin/bash

if [ "$#" -ne 9 ]; then
    printf "Usage: ${0} [csv output file] [azcopy journal directory] [data directory] [download|upload] [threads] [http|https] [proxy] [container URL] [access key]\n"
    exit 0
fi

azcopy_bin=azcopy
flightgw_bin=flight-gw

csv_file="${1}"                                 # Example:  "/home/user/azcopy_out.csv"
azcopy_jnl_dir="${2}"                           # Example:  "/home/user/Microsoft/Azure/AzCopy"
local_dir="${3}"                                # Example:  "/home/user/mydir"
action=$(tr '[:upper:]' '[:lower:]'<<<"${4}")   # Examples: "download" or "upload"
threads="${5}"                                  # Example:  "16"
protocol=$(tr '[:upper:]' '[:lower:]'<<<"${6}") # Examples: "http" or "https"
proxy="${7}"                                    # Examples: "localhost:8000", "localhost:8443", ""
container="${8}"                                # Example:  "myblob.blob.core.windows.net/mycontainer
access_key="${9}"

if [ "${protocol}" == "http" ]; then
    export http_proxy="${proxy}"
elif [ "${protocol}" == "https" ]; then
    export https_proxy="${proxy}"
fi

if [ -d "${azcopy_jnl_dir}" ]; then
    rm -f ${azcopy_jnl_dir}/*.jnl
fi

before=$(date +%s%3N)

if [ "${action}" == "download" ]; then
    eval "${azcopy_bin} --quiet --recursive --destination ${local_dir} --source "${protocol}://${container}" --source-key ${access_key} --parallel-level ${threads}"
elif [ "${action}" == "upload" ]; then
    eval "${azcopy_bin} --quiet --recursive --source ${local_dir} --destination "${protocol}://${container}" --dest-key ${access_key} --parallel-level ${threads}"
fi

err_code=$?
after=$(date +%s%3N)

filesize=$(du -sb ${local_dir} | awk '{ print $1 }')
bits=$((filesize*8))
duration=$((after-before))
bitrate=$((bits*1000/duration))
azcopy_version=unknown
flightgw_version=unknown
os_version=unknown
os_version_file="/etc/os-release"

if command -v "${azcopy_bin}"; then
    azcopy_version=$(eval "${azcopy_bin} --version")
fi

if command -v "${flightgw_bin}"; then
    flightgw_version=$(eval "${flightgw_bin} --version | grep flight-gateway")
fi

if [ -f "${os_version_file}" ]; then
    source ${os_version_file}
    if [ "${ID}" == "centos" ]; then
        os_version=$(cat /etc/system-release)
    else
        os_version="${PRETTY_NAME}"
    fi
fi

if [ ! -s ${csv_file} ]; then
    printf "#start_epoch_msec,os_version,azcopy_version,flight_version,max_thread_count,app_protocol,proxy_setting,blob_url,transfer_direction,transfer_err_code,transfer_size_bytes,transfer_duration_msec,goodput_bps\n" >> ${csv_file}
fi

printf "%d,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%d,%d\n" ${before} "${os_version}" "${azcopy_version}" "${flightgw_version}" "${threads}" "${protocol}" "${proxy}" "${container}" "${action}" "${err_code}" "${filesize}" "${duration}" "${bitrate}" >> ${csv_file}
