#!/bin/bash

if [ "$#" -ne 13 ]; then
    printf "Usage: ${0} [csv output file] [client] [client configuration directory] [data directory] [download|upload] [threads] [chunk size] [packet loss] [http|https] [proxy] [storage URL] [storage access key] [storage region]\n"
    exit 0
fi

flightgw_bin=/usr/local/bin/flight-gateway
net_dev=eth0

# figure out cloud provider by making a rest call

csv_file="${1}"                                 # Example:  "/home/user/azcopy_out.csv"
client_bin="${2}"                               # Examples: "/usr/bin/azcopy" or "/usr/bin/aws"
client_conf_dir="${3}"                          # Example:  "/home/user/Microsoft/Azure/AzCopy"
local_dir="${4}"                                # Example:  "/home/user/mydir"
action=$(tr '[:upper:]' '[:lower:]'<<<"${5}")   # Examples: "download" or "upload"
threads="${6}"                                  # Example:  "16"
chunk_size="${7}"                               # Example:  "4"
packet_loss="${8}"                              # Example:  "0.1"
protocol=$(tr '[:upper:]' '[:lower:]'<<<"${9}") # Examples: "http" or "https"
proxy="${10}"                                   # Examples: "localhost:8000", "localhost:8443", ""
container="${11}"                               # Examples: "myblob.blob.core.windows.net/mycontainer" or "mybucket/mykey"
access_key="${12}"                              # Example:  "myawsaccesskey myawssecretkey"
region="${13}"                                  # Example:  "us-west-2" or "westus2"

function get_results() {
    local err_code=$?
    local after=$(date +%s%3N)
    local proxy_setting="${proxy}"
    local filesize=$(du -sb ${local_dir} | awk '{ print $1 }')
    local bits=$((filesize*8))
    local duration_msec=$((after-before))
    local goodput_mbps=$(bc <<< "scale=6; $bits/$duration_msec/1000")
    local epoch="${before%???}"
    local date=$(date -d "@${epoch}" +"%Y-%m-%d %H:%M:%S %Z")

    if [ -z ${proxy_setting} ]; then
        proxy_setting="null"
    fi

    if [ ! -s ${csv_file} ]; then
        printf "epoch_timestamp,date,vm_location,vm_type,os_version,client_version,flight_version,flight_pid,max_thread_count,chunk_size,packet_loss,app_protocol,proxy_setting,blob_url,transfer_direction,transfer_errno,transfer_size_bytes,transfer_duration_msec,goodput_mbps\n" >> ${csv_file}
    fi

    printf "%d,%s,%s,%s,%s,%s,%s,%d,%s,%d,%f,%s,%s,%s,%s,%d,%d,%d,%f\n" ${epoch} "${date}" "${vm_location}" "${vm_size}" "${os_version}" "${client_version}" "${flightgw_version}" "${flightgw_pid}" "${threads}" "${chunk_size}" "${packet_loss}" "${protocol}" "${proxy_setting}" "${container}" "${action}" "${err_code}" "${filesize}" "${duration_msec}" "${goodput_mbps}" >> ${csv_file}
}

function get_versions() {
    client_version=unknown
    flightgw_pid=0
    flightgw_version=unknown
    os_version=unknown
    os_version_file="/etc/os-release"
    vm_location=unknown
    vm_size=unknown

    if command -v "${client_bin}"; then
        client_version=$(eval "${client_bin} --version 2>&1")
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

function run_awscli() {
    before=$(date +%s%3N)
    local cmd=

    local keys=( $access_key )
    local aws_access_key=
    local aws_secret_key=

    if [ ${#keys[@]} -eq 2 ]; then
        aws_access_key="${keys[0]}"
        aws_secret_key="${keys[1]}"
    fi

    export AWS_ACCESS_KEY_ID="${aws_access_key}"
    export AWS_SECRET_ACCESS_KEY="${aws_secret_key}"
    export AWS_CONFIG_FILE="${client_conf_dir}/config"

    eval "${client_bin} configure set default.s3.max_concurrent_requests ${threads}"
    eval "${client_bin} configure set default.s3.multipart_chunksize ${chunk_size}MB"
    eval "${client_bin} configure set s3.addressing_style virtual"

    if [ "${action}" == "download" ]; then
        cmd="${client_bin} s3 cp --recursive s3://${container} ${local_dir} --region ${region}"
    elif [ "${action}" == "upload" ]; then
        cmd="${client_bin} s3 cp --recursive ${local_dir} s3://${container} --region ${region}"
    fi

    cmd="${cmd} --endpoint-url ${protocol}://s3.${region}.amazonaws.com"

    eval "${cmd}"
}

function run_azcopy() {
    before=$(date +%s%3N)
    local cmd=

    if [ "${action}" == "download" ]; then
        cmd="${client_bin} --quiet --recursive --resume ${client_conf_dir} --destination ${local_dir} --source "${protocol}://${container}" --source-key ${access_key} --parallel-level ${threads}"
    elif [ "${action}" == "upload" ]; then
        cmd="${client_bin} --quiet --recursive --resume ${client_conf_dir} --source ${local_dir} --destination "${protocol}://${container}" --dest-key ${access_key} --parallel-level ${threads}"
    fi

    if [ "${chunk_size}" -ne 4 ]; then
        cmd="${cmd} --block-size ${chunk_size}"
    fi

    eval "${cmd}"
}

function run_client() {
    local client_name=$(basename "${client_bin}")

    case "$client_name" in
    "azcopy")
        run_azcopy
        ;;
    "aws")
        run_awscli
        ;;
    *)
        false
        ;;
    esac
}

function set_configs() {
    if [ -d "${client_conf_dir}" ]; then
        rm -f ${client_conf_dir}/*.jnl
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
run_client
get_results
reset_configs
