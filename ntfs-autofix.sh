#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_NAME="ntfs-autofix"
readonly INSTALL_PATH="/usr/local/bin/${SCRIPT_NAME}"
readonly UDEV_RULE_PATH="/etc/udev/rules.d/99-ntfs-autofix.rules"
readonly LOG_FILE="/var/log/ntfs-autofix.log"
readonly LOCK_FILE="/var/run/ntfs-autofix.lock"
readonly CONFIG_FILE="/etc/ntfs-autofix.conf"

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

ENABLE_NOTIFICATIONS="${ENABLE_NOTIFICATIONS:-1}"
ENABLE_LOGGING="${ENABLE_LOGGING:-1}"

load_config() {
    local env_notifications="${ENABLE_NOTIFICATIONS:-}"
    local env_logging="${ENABLE_LOGGING:-}"
    
    if [[ -f "${CONFIG_FILE}" ]]; then
        source "${CONFIG_FILE}"
    fi
    
    if [[ -n "${env_notifications}" ]]; then
        ENABLE_NOTIFICATIONS="${env_notifications}"
    else
        ENABLE_NOTIFICATIONS="${ENABLE_NOTIFICATIONS:-1}"
    fi
    
    if [[ -n "${env_logging}" ]]; then
        ENABLE_LOGGING="${env_logging}"
    else
        ENABLE_LOGGING="${ENABLE_LOGGING:-1}"
    fi
}

save_config() {
    cat > "${CONFIG_FILE}" << EOF
ENABLE_NOTIFICATIONS=${ENABLE_NOTIFICATIONS}
ENABLE_LOGGING=${ENABLE_LOGGING}
EOF
}

load_config

log_message() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ "${ENABLE_LOGGING}" -eq 1 ]]; then
        echo "${timestamp} - ${message}" | tee -a "${LOG_FILE}"
    else
        echo "${timestamp} - ${message}"
    fi
}

ensure_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${COLOR_RED}ERROR: This script must be executed as root.${COLOR_RESET}" >&2
        exit 1
    fi
}

ensure_ntfs_tools() {
    if command -v ntfsfix &>/dev/null && command -v ntfsinfo &>/dev/null; then
        log_message "ntfs-3g tools are already installed."
        return 0
    fi
    log_message "ntfs-3g tools not found. Attempting installation..."
    echo -e "${COLOR_YELLOW}Installing ntfs-3g...${COLOR_RESET}"
    if pacman -Sy --noconfirm ntfs-3g; then
        log_message "ntfs-3g installed successfully."
        echo -e "${COLOR_GREEN}ntfs-3g installation completed.${COLOR_RESET}"
    else
        log_message "ERROR: Failed to install ntfs-3g."
        echo -e "${COLOR_RED}ERROR: ntfs-3g installation failed.${COLOR_RESET}" >&2
        exit 1
    fi
}

is_ntfs_filesystem() {
    local device="$1"
    local fstype
    fstype=$(blkid -o value -s TYPE "${device}" 2>/dev/null || echo "unknown")
    [[ "${fstype}" == "ntfs" ]]
}

is_filesystem_dirty() {
    local device="$1"
    local output
    output=$(ntfsinfo -m "${device}" 2>&1)
    if echo "${output}" | grep -q "Volume is scheduled for check"; then
        return 0
    fi
    if ! echo "${output}" | grep -q "Access is denied"; then
        return 0
    fi
    return 1
}

send_notification() {
    local title="$1"
    local message="$2"
    
    if [[ "${ENABLE_NOTIFICATIONS}" -eq 0 ]]; then
        log_message "Desktop notifications are disabled."
        return 0
    fi
    
    log_message "Preparing notification: Title='${title}', Message='${message}'"
    
    get_current_user() {
        local user=""
        
        user=$(loginctl list-sessions --no-legend 2>/dev/null | \
               grep -E 'seat|active' | \
               awk '{print $3}' | \
               head -1)
        
        if [[ -n "${user}" ]] && [[ "${user}" != "root" ]]; then
            echo "${user}"
            return 0
        fi
        
        user=$(who 2>/dev/null | \
               grep -E ':[0-9]+' | \
               head -1 | \
               awk '{print $1}')
        
        if [[ -n "${user}" ]] && [[ "${user}" != "root" ]]; then
            echo "${user}"
            return 0
        fi
        
        if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
            echo "${SUDO_USER}"
            return 0
        fi
        
        if [[ -n "${USER:-}" ]] && [[ "${USER}" != "root" ]]; then
            echo "${USER}"
            return 0
        fi
        
        echo "unknown"
    }
    
    run_as_user() {
        local cmd="$1"
        local user
        user=$(get_current_user)
        
        if [[ -z "${user}" ]] || [[ "${user}" == "unknown" ]]; then
            echo -e "${COLOR_YELLOW}NOTIFICATION: ${title} - ${message}${COLOR_RESET}" | wall -n 2>/dev/null || true
            return 1
        fi
        
        local uid
        uid=$(id -u "${user}" 2>/dev/null || echo "")
        
        if [[ -z "${uid}" ]]; then
            echo -e "${COLOR_YELLOW}NOTIFICATION: ${title} - ${message}${COLOR_RESET}" | wall -n 2>/dev/null || true
            return 1
        fi
        
        local full_command="export DISPLAY=:0; "
        full_command+="export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus; "
        full_command+="export XDG_RUNTIME_DIR=/run/user/${uid}; "
        full_command+="timeout 3 ${cmd}"
        
        local result
        if result=$(su "${user}" -c "${full_command}" 2>&1); then
            log_message "Notification sent successfully as user ${user}"
            return 0
        else
            log_message "Failed to send notification as user ${user}: ${result}"
            echo -e "${COLOR_YELLOW}NOTIFICATION: ${title} - ${message}${COLOR_RESET}" | wall -n 2>/dev/null || true
            return 1
        fi
    }
    
    if ! command -v notify-send &>/dev/null; then
        log_message "notify-send not found. Using wall broadcast."
        echo -e "${COLOR_YELLOW}NOTIFICATION: ${title} - ${message}${COLOR_RESET}" | wall -n 2>/dev/null || true
        return 1
    fi
    
    local notify_cmd="notify-send \"${title}\" \"${message}\""
    
    run_as_user "${notify_cmd}"
}

repair_filesystem() {
    local device="$1"
    local mount_point="$2"
    log_message "Starting repair operation on ${device}."
    if mountpoint -q "${mount_point}" 2>/dev/null; then
        log_message "Unmounting ${device} from ${mount_point}."
        if ! umount "${device}" 2>/dev/null; then
            log_message "WARNING: Failed to unmount ${device}."
            echo -e "${COLOR_YELLOW}Warning: Could not unmount ${device}.${COLOR_RESET}"
        fi
    fi
    echo -e "${COLOR_BLUE}Repairing NTFS filesystem on ${device}...${COLOR_RESET}"
    if ntfsfix -d "${device}"; then
        log_message "Repair completed successfully on ${device}."
        echo -e "${COLOR_GREEN}Repair completed successfully for ${device}.${COLOR_RESET}"
        send_notification "NTFS Repair Complete" "Successfully repaired ${device}." "drive-removable-media"
        return 0
    else
        log_message "ERROR: Repair failed on ${device}."
        echo -e "${COLOR_RED}Repair failed for ${device}.${COLOR_RESET}" >&2
        send_notification "NTFS Repair Failed" "Failed to repair ${device}." "dialog-error"
        return 1
    fi
}

process_device() {
    local device="$1"
    local device_lock="/var/run/ntfs-autofix-$(basename "${device}").lock"
    if [[ -f "${device_lock}" ]]; then
        log_message "Device ${device} is already being processed. Skipping."
        return 0
    fi
    touch "${device_lock}"
    trap "rm -f '${device_lock}'; trap - EXIT" EXIT
    log_message "Processing device: ${device}"
    sleep 3
    if [[ ! -b "${device}" ]]; then
        log_message "Device ${device} is not a valid block device."
        rm -f "${device_lock}"
        trap - EXIT
        return 1
    fi
    if ! is_ntfs_filesystem "${device}"; then
        log_message "Device ${device} is not NTFS. Skipping."
        rm -f "${device_lock}"
        trap - EXIT
        return 0
    fi
    log_message "NTFS filesystem detected on ${device}."
    echo -e "${COLOR_BLUE}NTFS filesystem detected on ${device}.${COLOR_RESET}"
    local mount_point
    mount_point=$(findmnt -n -o TARGET --source "${device}" 2>/dev/null || echo "/mnt/$(basename "${device}")")
    if is_filesystem_dirty "${device}"; then
        log_message "Dirty NTFS filesystem detected on ${device}."
        echo -e "${COLOR_YELLOW}Dirty NTFS filesystem detected on ${device}.${COLOR_RESET}"
        send_notification "NTFS Fix" "Dirty filesystem detected on ${device}." "drive-harddisk-usb"
        repair_filesystem "${device}" "${mount_point}"
    else
        log_message "NTFS filesystem on ${device} is clean."
        echo -e "${COLOR_GREEN}NTFS filesystem on ${device} is clean.${COLOR_RESET}"
        send_notification "NTFS Check Complete" "Filesystem on ${device} is clean." "drive-removable-media"
    fi
    rm -f "${device_lock}"
    trap - EXIT
    return 0
}

install_service() {
    ensure_root
    echo -e "${COLOR_BLUE}Installing NTFS Auto-Fix Service...${COLOR_RESET}"
    if ! command -v notify-send &>/dev/null; then
        echo -e "${COLOR_YELLOW}Warning: notify-send not found. Desktop notifications will not work.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Install libnotify to enable notifications.${COLOR_RESET}"
        sleep 2
    fi
    cp "$0" "${INSTALL_PATH}"
    chmod +x "${INSTALL_PATH}"
    log_message "Installed script to ${INSTALL_PATH}"
    cat > "${UDEV_RULE_PATH}" << 'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_TYPE}=="ntfs", KERNEL=="sd[a-z][0-9]*", RUN+="/usr/local/bin/ntfs-autofix"
EOF
    log_message "Created udev rule: ${UDEV_RULE_PATH}"
    echo -e "${COLOR_BLUE}Reloading udev rules...${COLOR_RESET}"
    udevadm control --reload-rules
    udevadm trigger --action=add --subsystem-match=block
    touch "${LOG_FILE}"
    chmod 644 "${LOG_FILE}"
    save_config
    log_message "Saved configuration to ${CONFIG_FILE}"
    echo -e "${COLOR_GREEN}Installation complete.${COLOR_RESET}"
    echo -e "Log file: ${LOG_FILE}"
    echo -e "To uninstall: sudo ${SCRIPT_NAME} uninstall"
    echo -e "Check status: sudo ${SCRIPT_NAME} status"
}

uninstall_service() {
    ensure_root
    echo -e "${COLOR_BLUE}Uninstalling NTFS Auto-Fix Service...${COLOR_RESET}"
    rm -f "${INSTALL_PATH}"
    rm -f "${UDEV_RULE_PATH}"
    rm -f "${LOG_FILE}"
    rm -f "${CONFIG_FILE}"
    rm -f "${LOCK_FILE}"
    udevadm control --reload-rules
    udevadm trigger
    echo -e "${COLOR_GREEN}Uninstallation complete.${COLOR_RESET}"
}

show_status() {
    echo ""
    echo -e "${COLOR_BLUE}NTFS Auto-Fix Service Status${COLOR_RESET}"
    echo ""
    if [[ -f "${INSTALL_PATH}" ]] && [[ -f "${UDEV_RULE_PATH}" ]]; then
        echo -e "Service: ${COLOR_GREEN}Installed${COLOR_RESET}"
    else
        echo -e "Service: ${COLOR_RED}Not Installed${COLOR_RESET}"
    fi
    if command -v ntfsfix &>/dev/null; then
        echo -e "ntfs-3g:  ${COLOR_GREEN}Installed${COLOR_RESET}"
    else
        echo -e "ntfs-3g:  ${COLOR_RED}Not Installed${COLOR_RESET}"
    fi
    if command -v notify-send &>/dev/null; then
        echo -e "notify-send: ${COLOR_GREEN}Available${COLOR_RESET}"
    else
        echo -e "notify-send: ${COLOR_YELLOW}Not Available${COLOR_RESET}"
    fi
    echo -e "${COLOR_BLUE}Current Settings:${COLOR_RESET}"
    if [[ "${ENABLE_NOTIFICATIONS}" -eq 1 ]]; then
        echo -e "Notifications: ${COLOR_GREEN}Enabled${COLOR_RESET}"
    else
        echo -e "Notifications: ${COLOR_RED}Disabled${COLOR_RESET}"
    fi
    if [[ "${ENABLE_LOGGING}" -eq 1 ]]; then
        echo -e "Logging:       ${COLOR_GREEN}Enabled${COLOR_RESET}"
    else
        echo -e "Logging:       ${COLOR_RED}Disabled${COLOR_RESET}"
    fi
    echo "Log file: ${LOG_FILE}"
    if [[ -f "${LOG_FILE}" ]]; then
        echo "Recent entries:"
        tail -n 10 "${LOG_FILE}" 2>/dev/null || echo "  (no entries)"
    else
        echo "  (log file does not exist)"
    fi
    if [[ -f "${LOCK_FILE}" ]]; then
        echo -e "Lock file: ${COLOR_YELLOW}Active (PID: $(cat "${LOCK_FILE}" 2>/dev/null || echo 'unknown'))${COLOR_RESET}"
    else
        echo -e "Lock file: ${COLOR_GREEN}Inactive${COLOR_RESET}"
    fi
}

main() {
    if [[ -f "${LOCK_FILE}" ]] && kill -0 "$(cat "${LOCK_FILE}")" 2>/dev/null; then
        log_message "Another instance is already running (PID: $(cat "${LOCK_FILE}")). Exiting."
        exit 0
    fi
    echo $$ > "${LOCK_FILE}"
    trap "rm -f '${LOCK_FILE}'; trap - EXIT" EXIT
    ensure_root
    ensure_ntfs_tools
    if [[ -n "${DEVNAME:-}" ]]; then
        log_message "Invoked by udev for device: ${DEVNAME}"
        process_device "${DEVNAME}"
    else
        echo -e "${COLOR_GREEN}NTFS Auto-Fix Service${COLOR_RESET}"
        echo -e "${COLOR_BLUE}Commands:${COLOR_RESET}"
        echo "  sudo ${SCRIPT_NAME} install   - Install the service"
        echo "  sudo ${SCRIPT_NAME} uninstall - Uninstall the service"
        echo "  sudo ${SCRIPT_NAME} status    - Show service status"
    fi
    rm -f "${LOCK_FILE}"
    trap - EXIT
}

case "${1:-}" in
    install)
        install_service
        ;;
    uninstall)
        uninstall_service
        ;;
    status)
        show_status
        ;;
    "")
        main
        ;;
    *)
        echo -e "${COLOR_YELLOW}Unknown command: ${1}${COLOR_RESET}" >&2
        echo "Usage: ${SCRIPT_NAME} [install|uninstall|status]"
        exit 1
        ;;
esac
