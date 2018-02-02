#!/bin/bash

if [ "$#" -ne 11 ]; then
    printf "Usage: ${0} [csv output file] [azcopy journal directory] [data directory] [download|upload] [threads] [block size] [packet loss] [http|https] [proxy] [container URL] [access key]\n"
    exit 0
fi

azcopy_bin=/usr/bin/azcopy
flightgw_bin=/usr/local/bin/flight-gateway
net_dev=eth0

csv_file="${1}"                                 # Example:  "/home/user/azcopy_out.csv"
azcopy_jnl_dir="${2}"                           # Example:  "/home/user/Microsoft/Azure/AzCopy"
local_dir="${3}"                                # Example:  "/home/user/mydir"
action=$(tr '[:upper:]' '[:lower:]'<<<"${4}")   # Examples: "download" or "upload"
threads="${5}"                                  # Example:  "16"
block_size="${6}"                               # Example:  "4"
packet_loss="${7}"                              # Example:  "0.1"
protocol=$(tr '[:upper:]' '[:lower:]'<<<"${8}") # Examples: "http" or "https"
proxy="${9}"                                    # Examples: "localhost:8000", "localhost:8443", ""
container="${10}"                               # Example:  "myblob.blob.core.windows.net/mycontainer
access_key="${11}"

function get_results() {
    err_code=$?
    after=$(date +%s%3N)
    filesize=$(du -sb ${local_dir} | awk '{ print $1 }')
    bits=$((filesize*8))
    duration=$((after-before))
    bitrate=$((bits*1000/duration))

    if [ ! -s ${csv_file} ]; then
        printf "#epoch_timestamp_msec,vm_location,vm_type,os_version,azcopy_version,flight_version,flight_pid,max_thread_count,block_size,packet_loss,app_protocol,proxy_setting,blob_url,transfer_direction,transfer_errno,transfer_size_bytes,transfer_duration_msec,goodput_bps\n" >> ${csv_file}
    fi

    printf "%d,%s,%s,%s,%s,%s,%d,%s,%d,%f,%s,%s,%s,%s,%d,%d,%d,%d\n" ${before} "${vm_location}" "${vm_size}" "${os_version}" "${azcopy_version}" "${flightgw_version}" "${flightgw_pid}" "${threads}" "${block_size}" "${packet_loss}" "${protocol}" "${proxy}" "${container}" "${action}" "${err_code}" "${filesize}" "${duration}" "${bitrate}" >> ${csv_file}
}

function get_versions() {
    azcopy_version=unknown
    flightgw_pid=0
    flightgw_version=unknown
    os_version=unknown
    os_version_file="/etc/os-release"
    vm_location=unknown
    vm_size=unknown

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

    # jq could be used instead but is not installed by default
    local vm_metadata=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2017-04-02")

    if [ $? -eq 0 ]; then
        vm_location=$(echo ${vm_metadata} | grep -Po '"location":.*?[^\\]"' | awk -F':' '{print $2}')
        vm_size=$(echo ${vm_metadata} | grep -Po '"vmSize":.*?[^\\]"' | awk -F':' '{print $2}')

        # Trim leading/trailing double quotes
        vm_location="${vm_location%\"}" && vm_location="${vm_location#\"}"
        vm_size="${vm_size%\"}" && vm_size="${vm_size#\"}"
    fi

    local pid=$(pgrep flight-gateway)

    if [ $? -eq 0 ]; then
        flightgw_pid=${pid}
    fi
}

function on_signal() {
    get_results
    exit "${err_code}"
}

function reset_configs() {
    # Clear previous packet loss configurations
    if [ $(echo "${packet_loss} > 0" | bc -l) -eq 1 ]; then
        iptables -D INPUT -i "${net_dev}" -m statistic --mode random --probability $(echo "${packet_loss}/100" | bc -l) -j DROP
        tc qdisc del dev "${net_dev}" root netem
        #iptables -D OUTPUT -o "${net_dev}" -m statistic --mode random --probability "${packet_loss}" -j DROP
    fi
}

function run_azcopy() {
    before=$(date +%s%3N)
    local cmd=

    if [ "${action}" == "download" ]; then
        cmd="${azcopy_bin} --quiet --recursive --destination ${local_dir} --source "${protocol}://${container}" --source-key ${access_key} --parallel-level ${threads}"
    elif [ "${action}" == "upload" ]; then
        cmd="${azcopy_bin} --quiet --recursive --source ${local_dir} --destination "${protocol}://${container}" --dest-key ${access_key} --parallel-level ${threads}"
    fi

    if [ "${block_size}" -ne 4 ]; then
        cmd="${cmd} --block-size ${block_size}"
    fi

    eval "${cmd}"
}

function set_configs() {
    if [ -d "${azcopy_jnl_dir}" ]; then
        rm -f ${azcopy_jnl_dir}/*.jnl
    fi

    if [[ "${EUID}" -eq 0 ]]; then
        iptables -F
        tc qdisc del dev "${net_dev}" root netem

        if [ $(echo "${packet_loss} > 0" | bc -l) -eq 1 ]; then
            tc qdisc add dev "${net_dev}" root netem loss "${packet_loss}%" limit 100m
            iptables -A INPUT -i "${net_dev}" -m statistic --mode random --probability $(echo "${packet_loss}/100" | bc -l) -j DROP
            #iptables -A OUTPUT -o "${net_dev}" -m statistic --mode random --probability "${packet_loss}" -j DROP
        fi
    else
        packet_loss=0
    fi

    if [ "${protocol}" == "http" ]; then
        export http_proxy="${proxy}"
    elif [ "${protocol}" == "https" ]; then
        export https_proxy="${proxy}"
    fi
}

trap on_signal SIGINT TERM

get_versions
set_configs
run_azcopy
get_results
reset_configs
