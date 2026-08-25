#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="${project_dir}/build/tests"
mkdir -p "${build_dir}"

xcrun clang \
    -std=c11 \
    -O0 \
    -g \
    -Wall \
    -Wextra \
    -Werror \
    -framework CoreAudio \
    -I "${project_dir}/Sources" \
    "${project_dir}/Sources/DuckerDSP.c" \
    "${project_dir}/Tests/DuckerDSPTests.c" \
    -o "${build_dir}/DuckerDSPTests"

"${build_dir}/DuckerDSPTests"
"${project_dir}/scripts/build.sh"
"${project_dir}/build/Codex Ducker.app/Contents/MacOS/CodexDucker" --policy-check
"${project_dir}/build/Codex Ducker.app/Contents/MacOS/CodexDucker" --pipeline-check
codesign --verify --deep --strict "${project_dir}/build/Codex Ducker.app"
plutil -lint "${project_dir}/build/Codex Ducker.app/Contents/Info.plist"

echo "All checks passed"
