#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir="$repo_root/dist"
if [ "$#" -ge 1 ]; then output_dir=$1; fi
staging_dir=$(mktemp -d)
archive_path="$output_dir/einkmotionlab.koplugin.zip"
temporary_archive="$staging_dir/einkmotionlab.koplugin.zip"

metadata_version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$repo_root/einkmotionlab.koplugin/_meta.lua")
version_file=$(tr -d '\r\n' < "$repo_root/VERSION")
test -n "$metadata_version"
test "$metadata_version" = "$version_file" || {
    echo "VERSION ($version_file) does not match einkmotionlab.koplugin/_meta.lua ($metadata_version)." >&2
    exit 1
}

cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT INT TERM

mkdir -p "$output_dir" "$staging_dir"

(
    cd "$repo_root"
    zip -qr "$temporary_archive" einkmotionlab.koplugin
)
mv "$temporary_archive" "$archive_path"

echo "Created $archive_path"
