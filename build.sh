#!/bin/bash

set -e
set -o errtrace

function err_handler() {
    local frame=0
    while caller $frame; do
        ((frame++));
    done
    echo "$*"
    exit 1
}

trap 'err_handler' SIGINT ERR

export GO111MODULE=on

printf "Downloading and installing packages and dependencies...\n"
go mod vendor -v

targets=
targets="$targets darwin/amd64"
targets="$targets linux/amd64"
targets="$targets windows/amd64"

for target in $targets; do
    GOARCH=${target#*/}
    GOOS=${target%/*}

    printf "Compiling packages and dependencies %s...\n" "${target}"
    bin_name="errand-${GOOS}-${GOARCH}"
    [[ "${GOOS}" == "windows" ]] && bin_name="${bin_name}.exe"
    go build -v -ldflags -s -o "${bin_name}"
done

exit $?
