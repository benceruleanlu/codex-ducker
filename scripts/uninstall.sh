#!/bin/zsh
set -euo pipefail

bundle_id="com.benluwu.Ducker"
legacy_bundle_id="com.bendodson.CodexDucker"
installed_app="${HOME}/Applications/Ducker.app"
launch_agent="${HOME}/Library/LaunchAgents/${bundle_id}.plist"
legacy_launch_agent="${HOME}/Library/LaunchAgents/${legacy_bundle_id}.plist"
legacy_app="${HOME}/Applications/Codex Ducker.app"
domain="gui/$(id -u)"
trash_dir="${HOME}/.Trash"
timestamp="$(date +%Y%m%d-%H%M%S)"

launchctl bootout "${domain}/${bundle_id}" 2>/dev/null || true
launchctl bootout "${domain}/${legacy_bundle_id}" 2>/dev/null || true
pkill -x Ducker 2>/dev/null || true
pkill -x CodexDucker 2>/dev/null || true

if [[ -d "${installed_app}" ]]; then
    mv "${installed_app}" "${trash_dir}/Ducker-${timestamp}.app"
fi
if [[ -f "${launch_agent}" ]]; then
    mv "${launch_agent}" "${trash_dir}/${bundle_id}-${timestamp}.plist"
fi
if [[ -f "${legacy_launch_agent}" ]]; then
    mv "${legacy_launch_agent}" "${trash_dir}/${legacy_bundle_id}-${timestamp}.plist"
fi
if [[ -d "${legacy_app}" ]]; then
    mv "${legacy_app}" "${trash_dir}/Codex Ducker-${timestamp}.app"
fi

echo "Stopped Ducker and moved its app and launch agent to the Trash."
