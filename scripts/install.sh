#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
user_applications="${HOME}/Applications"
installed_app="${user_applications}/Codex Ducker.app"
launch_agents="${HOME}/Library/LaunchAgents"
launch_agent="${launch_agents}/com.bendodson.CodexDucker.plist"
log_dir="${HOME}/Library/Logs/CodexDucker"
log_path="${log_dir}/CodexDucker.log"
domain="gui/$(id -u)"

"${project_dir}/scripts/build.sh"
mkdir -p "${user_applications}" "${launch_agents}" "${log_dir}"

launchctl bootout "${domain}/com.bendodson.CodexDucker" 2>/dev/null || true
pkill -x CodexDucker 2>/dev/null || true

if [[ -d "${installed_app}" ]]; then
    archived_app="${HOME}/.Trash/Codex Ducker-$(date +%Y%m%d-%H%M%S).app"
    mv "${installed_app}" "${archived_app}"
    echo "Moved the previous app to ${archived_app}"
fi
ditto "${project_dir}/build/Codex Ducker.app" "${installed_app}"

sed \
    -e "s|__EXECUTABLE__|${installed_app}/Contents/MacOS/CodexDucker|g" \
    -e "s|__LOG_PATH__|${log_path}|g" \
    "${project_dir}/com.bendodson.CodexDucker.plist.template" \
    > "${launch_agent}"
plutil -lint "${launch_agent}"

launchctl bootstrap "${domain}" "${launch_agent}"
launchctl kickstart -k "${domain}/com.bendodson.CodexDucker"

echo "Installed ${installed_app}"
echo "Codex Ducker now starts at login. Its menu-bar icon controls level and testing."
