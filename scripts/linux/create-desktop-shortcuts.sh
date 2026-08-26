#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALLER_DIR="/opt/gateway-installer"
readonly UPDATE_SCRIPT="${INSTALLER_DIR}/scripts/linux/update.sh"
readonly UNINSTALL_SCRIPT="${INSTALLER_DIR}/scripts/linux/uninstall.sh"

readonly WEB_INTERFACE_URL="http://localhost:8080"

readonly UPDATE_DESKTOP_FILENAME="gateway-update.desktop"
readonly UNINSTALL_DESKTOP_FILENAME="gateway-uninstall.desktop"
readonly WEB_DESKTOP_FILENAME="gateway-configuration.desktop"

# Gibt eine formatierte Statusmeldung aus.
#
# Eingaben:
#   $1: Auszugebende Meldung
#
# Ausgaben:
#   Schreibt die Meldung auf stdout.
log() {
    echo
    echo "==> $1"
}

# Gibt eine Fehlermeldung aus und beendet das Skript.
#
# Eingaben:
#   $1: Fehlermeldung
#
# Ausgaben:
#   Beendet das Skript mit Exitcode 1.
fail() {
    echo "Fehler: $1" >&2
    exit 1
}

# Prüft, ob das Skript mit Root-Rechten ausgeführt wird.
#
# Ausgaben:
#   Beendet das Skript, wenn keine Root-Rechte vorhanden sind.
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "Bitte dieses Skript mit sudo ausführen."
    fi
}

# Ermittelt den Benutzer, für den die Desktop-Starter angelegt werden.
#
# Bevorzugt wird der Benutzer, der sudo aufgerufen hat. Falls das Skript
# bereits direkt als normaler Benutzer läuft, wird der aktuelle Benutzer
# verwendet.
#
# Ausgaben:
#   Gibt den Benutzernamen auf stdout aus.
resolve_target_user() {
    if [[ -n "${SUDO_USER:-}" ]] &&
       [[ "${SUDO_USER}" != "root" ]]; then
        printf '%s\n' "${SUDO_USER}"
        return
    fi

    if [[ -n "${PKEXEC_UID:-}" ]]; then
        getent passwd "${PKEXEC_UID}" |
            cut -d: -f1
        return
    fi

    if [[ "${EUID}" -ne 0 ]]; then
        id --user --name
        return
    fi

    local first_desktop_user

    first_desktop_user="$(
        getent passwd |
            awk -F: '
                $3 >= 1000 &&
                $3 < 65534 &&
                $7 !~ /(nologin|false)$/ {
                    print $1
                    exit
                }
            '
    )"

    if [[ -z "${first_desktop_user}" ]]; then
        fail "Es konnte kein Desktop-Benutzer ermittelt werden."
    fi

    printf '%s\n' "${first_desktop_user}"
}

# Ermittelt das Home-Verzeichnis eines Benutzers.
#
# Eingaben:
#   $1: Benutzername
#
# Ausgaben:
#   Gibt das Home-Verzeichnis auf stdout aus.
resolve_home_directory() {
    local target_user="$1"
    local home_directory

    home_directory="$(
        getent passwd "${target_user}" |
            cut -d: -f6
    )"

    if [[ -z "${home_directory}" ]]; then
        fail "Home-Verzeichnis für ${target_user} konnte nicht ermittelt werden."
    fi

    printf '%s\n' "${home_directory}"
}

# Ermittelt den tatsächlichen Desktop-Ordner des Benutzers.
#
# Berücksichtigt sowohl englische als auch deutsche Desktop-Verzeichnisse
# sowie die XDG-Benutzerkonfiguration.
#
# Eingaben:
#   $1: Benutzername
#   $2: Home-Verzeichnis
#
# Ausgaben:
#   Gibt den Desktop-Pfad auf stdout aus.
resolve_desktop_directory() {
    local target_user="$1"
    local home_directory="$2"
    local desktop_directory=""

    if command -v xdg-user-dir >/dev/null 2>&1; then
        desktop_directory="$(
            sudo \
                --user "${target_user}" \
                HOME="${home_directory}" \
                xdg-user-dir DESKTOP \
                2>/dev/null || true
        )"
    fi

    if [[ -z "${desktop_directory}" ]] ||
       [[ "${desktop_directory}" == "${home_directory}" ]]; then
        if [[ -d "${home_directory}/Schreibtisch" ]]; then
            desktop_directory="${home_directory}/Schreibtisch"
        else
            desktop_directory="${home_directory}/Desktop"
        fi
    fi

    printf '%s\n' "${desktop_directory}"
}

# Erstellt die für Desktop und Anwendungsmenü benötigten Verzeichnisse.
#
# Eingaben:
#   $1: Zielbenutzer
#   $2: Home-Verzeichnis
#   $3: Desktop-Verzeichnis
#
# Ausgaben:
#   Erstellt die Verzeichnisse mit passenden Eigentümern und Berechtigungen.
prepare_directories() {
    local target_user="$1"
    local home_directory="$2"
    local desktop_directory="$3"
    local target_group

    target_group="$(
        id --group --name "${target_user}"
    )"

    install \
        --directory \
        --mode 0755 \
        --owner "${target_user}" \
        --group "${target_group}" \
        "${desktop_directory}"

    install \
        --directory \
        --mode 0755 \
        --owner "${target_user}" \
        --group "${target_group}" \
        "${home_directory}/.local"

    install \
        --directory \
        --mode 0755 \
        --owner "${target_user}" \
        --group "${target_group}" \
        "${home_directory}/.local/share"

    install \
        --directory \
        --mode 0755 \
        --owner "${target_user}" \
        --group "${target_group}" \
        "${home_directory}/.local/share/applications"
}

# Erstellt einen Starter zum Aktualisieren des Gateway.
#
# Eingaben:
#   $1: Zielpfad der Desktop-Datei
#
# Ausgaben:
#   Schreibt eine ausführbare `.desktop`-Datei.
create_update_shortcut() {
    local destination_path="$1"

    cat > "${destination_path}" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Gateway aktualisieren
Comment=Aktualisiert das Gateway und startet den Container neu
Exec=sh -c 'sudo ${UPDATE_SCRIPT}; printf "\\nDrücke Enter zum Schließen..."; read answer'
Icon=system-software-update
Terminal=true
Categories=System;Utility;
StartupNotify=true
EOF

    chmod 0755 "${destination_path}"
}

# Erstellt einen Starter zum Deinstallieren des Gateway.
#
# Eingaben:
#   $1: Zielpfad der Desktop-Datei
#
# Ausgaben:
#   Schreibt eine ausführbare `.desktop`-Datei.
create_uninstall_shortcut() {
    local destination_path="$1"

    cat > "${destination_path}" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Gateway deinstallieren
Comment=Entfernt den Gateway-Container und behält standardmäßig die Konfiguration
Exec=sh -c 'sudo ${UNINSTALL_SCRIPT}; printf "\\nDrücke Enter zum Schließen..."; read answer'
Icon=edit-delete
Terminal=true
Categories=System;Utility;
StartupNotify=true
EOF

    chmod 0755 "${destination_path}"
}

# Erstellt einen Weblink zur Gateway-Konfigurationsoberfläche.
#
# Eingaben:
#   $1: Zielpfad der Desktop-Datei
#
# Ausgaben:
#   Schreibt eine ausführbare `.desktop`-Datei.
create_web_shortcut() {
    local destination_path="$1"

    cat > "${destination_path}" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Gateway-Konfiguration
Comment=Öffnet die lokale Konfigurationsoberfläche des Gateways
Exec=xdg-open ${WEB_INTERFACE_URL}
Icon=preferences-system
Terminal=false
Categories=Settings;System;
StartupNotify=true
EOF

    chmod 0755 "${destination_path}"
}

# Kopiert einen Starter zusätzlich in das lokale Anwendungsmenü.
#
# Eingaben:
#   $1: Quelldatei
#   $2: Zielpfad im Anwendungsmenü
#   $3: Zielbenutzer
#
# Ausgaben:
#   Kopiert die Datei mit passenden Berechtigungen.
install_application_menu_entry() {
    local source_path="$1"
    local destination_path="$2"
    local target_user="$3"
    local target_group

    target_group="$(
        id --group --name "${target_user}"
    )"

    install \
        --mode 0755 \
        --owner "${target_user}" \
        --group "${target_group}" \
        "${source_path}" \
        "${destination_path}"
}

# Setzt die Eigentümer der Desktop-Starter.
#
# Eingaben:
#   $1: Zielbenutzer
#   $2: Liste der zu korrigierenden Dateien
#
# Ausgaben:
#   Setzt Benutzer und primäre Gruppe.
set_shortcut_ownership() {
    local target_user="$1"
    shift

    local target_group

    target_group="$(
        id --group --name "${target_user}"
    )"

    chown \
        "${target_user}:${target_group}" \
        "$@"
}

# Markiert Desktop-Dateien bei unterstützten Desktopumgebungen als
# vertrauenswürdig.
#
# Eingaben:
#   $1: Zielbenutzer
#   $2: Home-Verzeichnis
#   $3: Liste der Desktop-Dateien
#
# Ausgaben:
#   Setzt nach Möglichkeit das Metadatum `metadata::trusted`.
mark_shortcuts_as_trusted() {
    local target_user="$1"
    local home_directory="$2"
    shift 2

    if ! command -v gio >/dev/null 2>&1; then
        return
    fi

    local shortcut_path

    for shortcut_path in "$@"; do
        sudo \
            --user "${target_user}" \
            HOME="${home_directory}" \
            gio set \
                "${shortcut_path}" \
                metadata::trusted \
                true \
                >/dev/null 2>&1 || true
    done
}

# Aktualisiert nach Möglichkeit die Datenbank der Desktop-Anwendungen.
#
# Eingaben:
#   $1: Anwendungsverzeichnis
#
# Ausgaben:
#   Aktualisiert die Desktop-Datenbank, sofern das Werkzeug vorhanden ist.
update_desktop_database_if_available() {
    local applications_directory="$1"

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database \
            "${applications_directory}" \
            >/dev/null 2>&1 || true
    fi
}

# Führt die vollständige Erstellung der Desktop-Starter aus.
#
# Ausgaben:
#   Erstellt Starter auf dem Desktop und im lokalen Anwendungsmenü.
main() {
    require_root

    if [[ ! -x "${UPDATE_SCRIPT}" ]]; then
        fail "Update-Skript fehlt oder ist nicht ausführbar: ${UPDATE_SCRIPT}"
    fi

    if [[ ! -x "${UNINSTALL_SCRIPT}" ]]; then
        fail "Uninstall-Skript fehlt oder ist nicht ausführbar: ${UNINSTALL_SCRIPT}"
    fi

    log "Desktop-Starter werden erstellt"

    local target_user
    local home_directory
    local desktop_directory
    local applications_directory

    target_user="$(
        resolve_target_user
    )"

    home_directory="$(
        resolve_home_directory "${target_user}"
    )"

    desktop_directory="$(
        resolve_desktop_directory \
            "${target_user}" \
            "${home_directory}"
    )"

    applications_directory="${home_directory}/.local/share/applications"

    prepare_directories \
        "${target_user}" \
        "${home_directory}" \
        "${desktop_directory}"

    local update_desktop_path
    local uninstall_desktop_path
    local web_desktop_path

    update_desktop_path="${desktop_directory}/${UPDATE_DESKTOP_FILENAME}"
    uninstall_desktop_path="${desktop_directory}/${UNINSTALL_DESKTOP_FILENAME}"
    web_desktop_path="${desktop_directory}/${WEB_DESKTOP_FILENAME}"

    create_update_shortcut \
        "${update_desktop_path}"

    create_uninstall_shortcut \
        "${uninstall_desktop_path}"

    create_web_shortcut \
        "${web_desktop_path}"

    set_shortcut_ownership \
        "${target_user}" \
        "${update_desktop_path}" \
        "${uninstall_desktop_path}" \
        "${web_desktop_path}"

    install_application_menu_entry \
        "${update_desktop_path}" \
        "${applications_directory}/${UPDATE_DESKTOP_FILENAME}" \
        "${target_user}"

    install_application_menu_entry \
        "${uninstall_desktop_path}" \
        "${applications_directory}/${UNINSTALL_DESKTOP_FILENAME}" \
        "${target_user}"

    install_application_menu_entry \
        "${web_desktop_path}" \
        "${applications_directory}/${WEB_DESKTOP_FILENAME}" \
        "${target_user}"

    mark_shortcuts_as_trusted \
        "${target_user}" \
        "${home_directory}" \
        "${update_desktop_path}" \
        "${uninstall_desktop_path}" \
        "${web_desktop_path}"

    update_desktop_database_if_available \
        "${applications_directory}"

    echo
    echo "Desktop-Starter wurden erstellt:"
    echo "  ${update_desktop_path}"
    echo "  ${uninstall_desktop_path}"
    echo "  ${web_desktop_path}"
}

main "$@"