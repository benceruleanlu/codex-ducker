#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
bundle_id="com.benluwu.Ducker"
legacy_bundle_id="com.bendodson.CodexDucker"
user_applications="${HOME}/Applications"
installed_app="${user_applications}/Ducker.app"
launch_agents="${HOME}/Library/LaunchAgents"
launch_agent="${launch_agents}/${bundle_id}.plist"
legacy_launch_agent="${launch_agents}/${legacy_bundle_id}.plist"
legacy_app="${user_applications}/Codex Ducker.app"
log_dir="${HOME}/Library/Logs/Ducker"
log_path="${log_dir}/Ducker.log"
domain="gui/$(id -u)"
timestamp="$(date +%Y%m%d-%H%M%S)"

"${project_dir}/scripts/build.sh"
mkdir -p "${user_applications}" "${launch_agents}" "${log_dir}"

launchctl bootout "${domain}/${bundle_id}" 2>/dev/null || true
launchctl bootout "${domain}/${legacy_bundle_id}" 2>/dev/null || true
pkill -x Ducker 2>/dev/null || true
pkill -x CodexDucker 2>/dev/null || true

# Installs predating the rename leave an agent, an app bundle and a preferences
# domain under the old name. Retire all three, or two builds compete for the tap.
if [[ -f "${legacy_launch_agent}" ]]; then
    defaults export "${legacy_bundle_id}" - 2>/dev/null \
        | defaults import "${bundle_id}" - 2>/dev/null || true
    mv "${legacy_launch_agent}" "${HOME}/.Trash/${legacy_bundle_id}-${timestamp}.plist"
    echo "Retired the ${legacy_bundle_id} launch agent and kept its settings"
fi
if [[ -d "${legacy_app}" ]]; then
    mv "${legacy_app}" "${HOME}/.Trash/Codex Ducker-${timestamp}.app"
    echo "Moved the previous Codex Ducker app to the Trash"
fi

if [[ -d "${installed_app}" ]]; then
    archived_app="${HOME}/.Trash/Ducker-${timestamp}.app"
    mv "${installed_app}" "${archived_app}"
    echo "Moved the previous app to ${archived_app}"
fi
ditto "${project_dir}/build/Ducker.app" "${installed_app}"

sed \
    -e "s|__EXECUTABLE__|${installed_app}/Contents/MacOS/Ducker|g" \
    -e "s|__LOG_PATH__|${log_path}|g" \
    "${project_dir}/${bundle_id}.plist.template" \
    > "${launch_agent}"
plutil -lint "${launch_agent}"

launchctl bootstrap "${domain}" "${launch_agent}"
launchctl kickstart -k "${domain}/${bundle_id}"

echo "Installed ${installed_app}"
echo "Ducker now starts at login. Its menu-bar icon controls level and testing."
