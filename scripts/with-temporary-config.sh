#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 6 || $5 != -- ]]; then
    echo "Usage: $0 CONFIG FILE_SERVER_IP HOME_PATH SOURCE_PATH -- COMMAND [ARG ...]" >&2
    exit 2
fi

config=$1
file_server_ip=$2
home_path=$3
source_path=$4
shift 5

for value in "$file_server_ip" "$home_path" "$source_path"; do
    if [[ -z $value || $value == *$'\n'* || $value == *$'\r'* || $value == *'"'* ]]; then
        echo "Config values must be non-empty and must not contain quotes or line breaks" >&2
        exit 2
    fi
done

config_dir=$(dirname "$config")
[[ -d $config_dir ]] || { echo "Config directory not found: $config_dir" >&2; exit 2; }

backup=$(mktemp "${config}.backup.XXXXXX")
replacement=$(mktemp "${config}.replacement.XXXXXX")
had_original=false
if [[ -e $config ]]; then
    cp -p "$config" "$backup"
    had_original=true
fi

restore_config() {
    if [[ $had_original == true ]]; then
        cp -p "$backup" "$config"
    else
        rm -f "$config"
    fi
    rm -f "$backup" "$replacement"
}
trap restore_config EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$replacement" <<EOF
(in-package :mezzano.internals)
(defparameter *file-server-host-ip* "$file_server_ip")
(defparameter *home-directory-path* "REMOTE:$home_path")
(defparameter *mezzano-source-path* "REMOTE:$source_path")
(setf *compile-parallel* t)
EOF
mv "$replacement" "$config"

"$@"
