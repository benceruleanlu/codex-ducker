#!/bin/zsh
set -euo pipefail

installed_app="${HOME}/Applications/Codex Ducker.app"
launch_agent="${HOME}/Library/LaunchAgents/com.bendodson.CodexDucker.plist"
domain="gui/$(id -u)"
trash_dir="${HOME}/.Trash"
timestamp="$(date +%Y%m%d-%H%M%S)"

launchctl bootout "${domain}/com.bendodson.CodexDucker" 2>/dev/null || true
pkill -x CodexDucker 2>/dev/null || true

if [[ -d "${installed_app}" ]]; then
    mv "${installed_app}" "${trash_dir}/Codex Ducker-${timestamp}.app"
fi
if [[ -f "${launch_agent}" ]]; then
    mv "${launch_agent}" "${trash_dir}/com.bendodson.CodexDucker-${timestamp}.plist"
fi

echo "Stopped Codex Ducker and moved its app and launch agent to the Trash."
