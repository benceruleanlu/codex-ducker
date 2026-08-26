#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="${project_dir}/build"
app_bundle="${build_dir}/Codex Ducker.app"
contents_dir="${app_bundle}/Contents"
macos_dir="${contents_dir}/MacOS"

mkdir -p "${build_dir}" "${macos_dir}"
find "${build_dir}" -mindepth 1 -maxdepth 1 ! -name 'Codex Ducker.app' -delete
if [[ -d "${app_bundle}" ]]; then
    find "${app_bundle}" -mindepth 1 -delete
fi
mkdir -p "${macos_dir}"

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
deployment_target="14.2"
architecture="$(uname -m)"

if [[ "${architecture}" != "arm64" && "${architecture}" != "x86_64" ]]; then
    echo "Unsupported architecture: ${architecture}" >&2
    exit 1
fi

xcrun clang \
    -std=c11 \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -mmacosx-version-min="${deployment_target}" \
    -isysroot "${sdk_path}" \
    -I "${project_dir}/Sources" \
    -c "${project_dir}/Sources/DuckerDSP.c" \
    -o "${build_dir}/DuckerDSP.o"

xcrun swiftc \
    -swift-version 5 \
    -target "${architecture}-apple-macosx${deployment_target}" \
    -O \
    -warnings-as-errors \
    -framework AppKit \
    -framework CoreAudio \
    -framework Foundation \
    -import-objc-header "${project_dir}/Sources/DuckerDSP.h" \
    "${project_dir}/Sources/CoreAudioSupport.swift" \
    "${project_dir}/Sources/Logger.swift" \
    "${project_dir}/Sources/OutputPolicy.swift" \
    "${project_dir}/Sources/PreferredInputPolicy.swift" \
    "${project_dir}/Sources/DuckingEngine.swift" \
    "${project_dir}/Sources/AppDelegate.swift" \
    "${project_dir}/Sources/main.swift" \
    "${build_dir}/DuckerDSP.o" \
    -o "${macos_dir}/CodexDucker"

cp "${project_dir}/Info.plist" "${contents_dir}/Info.plist"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${contents_dir}/Info.plist")"
codesign --force --sign - \
    --identifier "${bundle_identifier}" \
    "${app_bundle}"

echo "Built ${app_bundle}"
