#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY_OWNER="val8elster"
readonly REPOSITORY_NAME="lagekarte-relais-deployment"
readonly REPOSITORY_REF="main"

readonly DOWNLOAD_BASE_URL="https://raw.githubusercontent.com/${REPOSITORY_OWNER}/${REPOSITORY_NAME}/${REPOSITORY_REF}"

readonly INSTALLER_DIR="/opt/relais-installer"
readonly INSTALLER_SCRIPT_DIR="${INSTALLER_DIR}/scripts/linux"
readonly INSTALLER_DEPLOY_DIR="${INSTALLER_DIR}/deploy/raspberry-pi"

readonly INSTALL_SCRIPT="${INSTALLER_SCRIPT_DIR}/install.sh"
readonly CREATE_CONFIG_SCRIPT="${INSTALLER_SCRIPT_DIR}/create-config.sh"
readonly UPDATE_SCRIPT="${INSTALLER_SCRIPT_DIR}/update.sh"
readonly UNINSTALL_SCRIPT="${INSTALLER_SCRIPT_DIR}/uninstall.sh"
readonly COMPOSE_FILE="${INSTALLER_DEPLOY_DIR}/compose.yml"

readonly REQUIRED_ARCHITECTURE="arm64"

# Gibt eine Fehlermeldung aus und beendet das Skript.
#
# Parameter:
#   $1: Fehlermeldung
#
# Rückgabewert:
#   Beendet das Skript immer mit Exitcode 1.
fail() {
    echo "Fehler: $1" >&2
    exit 1
}

# Gibt eine Statusmeldung aus.
#
# Parameter:
#   $1: Statusmeldung
#
# Ausgabe:
#   Formatierte Meldung auf stdout.
log() {
    echo
    echo "==> $1"
}

# Prüft, ob das Skript mit Root-Rechten ausgeführt wird.
#
# Rückgabewert:
#   0, wenn das Skript als root ausgeführt wird.
#   Beendet das Skript andernfalls mit Exitcode 1.
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "Bitte dieses Skript mit sudo ausführen."
    fi
}

# Prüft, ob ein benötigter Befehl vorhanden ist.
#
# Parameter:
#   $1: Name des benötigten Befehls
#
# Rückgabewert:
#   0, wenn der Befehl vorhanden ist.
#   Beendet das Skript andernfalls mit Exitcode 1.
require_command() {
    local command_name="$1"

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        fail "Benötigter Befehl fehlt: ${command_name}"
    fi
}

# Prüft, ob das System die erwartete ARM64-Architektur verwendet.
#
# Rückgabewert:
#   0, wenn die Architektur arm64 ist.
#   Beendet das Skript andernfalls mit Exitcode 1.
verify_architecture() {
    local architecture

    architecture="$(dpkg --print-architecture)"

    if [[ "${architecture}" != "${REQUIRED_ARCHITECTURE}" ]]; then
        fail "Erwartete Architektur: ${REQUIRED_ARCHITECTURE}, erkannt: ${architecture}"
    fi

    echo "Architektur erkannt: ${architecture}"
}

# Prüft, ob die Systemzeit plausibel ist.
#
# Eine stark falsche Systemzeit kann dazu führen, dass APT Signaturen
# als noch nicht gültig ablehnt.
#
# Rückgabewert:
#   0, wenn das erkannte Jahr mindestens 2026 ist.
#   Beendet das Skript andernfalls mit Exitcode 1.
verify_system_time() {
    local current_year

    current_year="$(date +%Y)"

    if (( current_year >= 2026 )); then
        return
    fi

    echo "Die Systemzeit scheint falsch zu sein."
    echo "Aktuelle Zeit:"
    date

    timedatectl set-ntp true || true
    systemctl restart systemd-timesyncd || true

    sleep 10

    current_year="$(date +%Y)"

    if (( current_year < 2026 )); then
        fail "Die Systemzeit ist weiterhin falsch. Bitte Datum und Uhrzeit manuell korrigieren."
    fi
}

# Installiert grundlegende Werkzeuge, die für Bootstrap und Downloads
# benötigt werden.
#
# Installierte Pakete:
#   - ca-certificates
#   - curl
#   - git
#
# Rückgabewert:
#   0 bei erfolgreicher Installation.
install_base_packages() {
    apt-get update

    apt-get install \
        --yes \
        --no-install-recommends \
        ca-certificates \
        curl \
        git
}

# Entfernt Pakete, die mit der offiziellen Docker-Installation
# kollidieren können.
#
# Rückgabewert:
#   0 nach allen Entfernungsversuchen.
remove_conflicting_docker_packages() {
    local package

    local conflicting_packages=(
        docker.io
        docker-doc
        docker-compose
        podman-docker
        containerd
        runc
    )

    for package in "${conflicting_packages[@]}"; do
        apt-get remove \
            --yes \
            "${package}" \
            >/dev/null 2>&1 || true
    done
}

# Richtet das offizielle Docker-APT-Repository ein.
#
# Ausgabe:
#   Erstellt:
#   - /etc/apt/keyrings/docker.asc
#   - /etc/apt/sources.list.d/docker.sources
#
# Rückgabewert:
#   0 bei erfolgreicher Einrichtung.
configure_docker_repository() {
    local distribution_codename
    local architecture

    distribution_codename="$(
        . /etc/os-release
        printf '%s' "${VERSION_CODENAME}"
    )"

    architecture="$(dpkg --print-architecture)"

    install \
        --directory \
        --mode 0755 \
        /etc/apt/keyrings

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        https://download.docker.com/linux/debian/gpg \
        --output /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${distribution_codename}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

# Installiert Docker Engine, Docker Buildx und Docker Compose.
#
# Eine vorhandene funktionsfähige Docker-Installation wird weiterverwendet.
#
# Rückgabewert:
#   0, wenn Docker und Docker Compose verfügbar sind.
install_docker() {
    if command -v docker >/dev/null 2>&1 &&
       docker compose version >/dev/null 2>&1; then

        echo "Docker und Docker Compose sind bereits installiert."

        systemctl enable --now docker

        return
    fi

    log "Docker wird installiert"

    install_base_packages
    remove_conflicting_docker_packages
    configure_docker_repository

    apt-get update

    apt-get install \
        --yes \
        --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    docker version >/dev/null
    docker compose version >/dev/null

    echo "Docker wurde erfolgreich installiert."
}

# Erstellt die lokale Verzeichnisstruktur für die heruntergeladenen
# Deployment-Dateien.
#
# Ausgabe:
#   Erstellt:
#   - /opt/relais-installer
#   - /opt/relais-installer/scripts/linux
#   - /opt/relais-installer/deploy/raspberry-pi
#
# Rückgabewert:
#   0 bei erfolgreicher Erstellung.
prepare_installer_directories() {
    install \
        --directory \
        --mode 0755 \
        --owner root \
        --group root \
        "${INSTALLER_DIR}"

    install \
        --directory \
        --mode 0755 \
        --owner root \
        --group root \
        "${INSTALLER_SCRIPT_DIR}"

    install \
        --directory \
        --mode 0755 \
        --owner root \
        --group root \
        "${INSTALLER_DEPLOY_DIR}"
}

# Lädt eine einzelne Datei aus dem öffentlichen Deployment-Repository.
#
# Parameter:
#   $1: Relativer Pfad im GitHub-Repository
#   $2: Lokaler Zielpfad
#   $3: Dateimodus, beispielsweise 0755 oder 0644
#
# Rückgabewert:
#   0 bei erfolgreichem Download und Installation.
download_file() {
    local repository_path="$1"
    local destination_path="$2"
    local file_mode="$3"

    local temporary_path

    temporary_path="$(mktemp)"

    if ! curl \
        --fail \
        --silent \
        --show-error \
        --location \
        "${DOWNLOAD_BASE_URL}/${repository_path}" \
        --output "${temporary_path}"; then

        rm -f "${temporary_path}"

        fail "Datei konnte nicht heruntergeladen werden: ${repository_path}"
    fi

    if [[ ! -s "${temporary_path}" ]]; then
        rm -f "${temporary_path}"

        fail "Heruntergeladene Datei ist leer: ${repository_path}"
    fi

    install \
        --mode "${file_mode}" \
        --owner root \
        --group root \
        "${temporary_path}" \
        "${destination_path}"

    rm -f "${temporary_path}"

    echo "Heruntergeladen:"
    echo "  ${repository_path}"
    echo "  -> ${destination_path}"
}

# Lädt alle für Installation, Update und Deinstallation benötigten
# Deployment-Dateien herunter.
#
# Heruntergeladene Dateien:
#   - install.sh
#   - create-config.sh
#   - update.sh
#   - uninstall.sh
#   - compose.yml
#
# Rückgabewert:
#   0, wenn alle Dateien erfolgreich geladen wurden.
download_deployment_files() {
    log "Deployment-Dateien werden heruntergeladen"

    prepare_installer_directories

    download_file \
        "scripts/linux/install.sh" \
        "${INSTALL_SCRIPT}" \
        "0755"

    download_file \
        "scripts/linux/create-config.sh" \
        "${CREATE_CONFIG_SCRIPT}" \
        "0755"

    download_file \
        "scripts/linux/update.sh" \
        "${UPDATE_SCRIPT}" \
        "0755"

    download_file \
        "scripts/linux/uninstall.sh" \
        "${UNINSTALL_SCRIPT}" \
        "0755"

    download_file \
        "deploy/raspberry-pi/compose.yml" \
        "${COMPOSE_FILE}" \
        "0644"
}

# Prüft, ob alle heruntergeladenen Dateien vorhanden und nicht leer sind.
#
# Rückgabewert:
#   0, wenn alle benötigten Dateien vorhanden sind.
#   Beendet das Skript andernfalls mit Exitcode 1.
verify_downloaded_files() {
    local required_files=(
        "${INSTALL_SCRIPT}"
        "${CREATE_CONFIG_SCRIPT}"
        "${UPDATE_SCRIPT}"
        "${UNINSTALL_SCRIPT}"
        "${COMPOSE_FILE}"
    )

    local file_path

    for file_path in "${required_files[@]}"; do
        if [[ ! -s "${file_path}" ]]; then
            fail "Deployment-Datei fehlt oder ist leer: ${file_path}"
        fi
    done
}

# Prüft die Bash-Syntax aller heruntergeladenen Shell-Skripte.
#
# Rückgabewert:
#   0, wenn alle Skripte syntaktisch gültig sind.
#   Beendet das Skript andernfalls mit Exitcode 1.
validate_downloaded_scripts() {
    local scripts=(
        "${INSTALL_SCRIPT}"
        "${CREATE_CONFIG_SCRIPT}"
        "${UPDATE_SCRIPT}"
        "${UNINSTALL_SCRIPT}"
    )

    local script_path

    for script_path in "${scripts[@]}"; do
        if ! bash -n "${script_path}"; then
            fail "Ungültige Bash-Syntax in: ${script_path}"
        fi
    done
}

# Meldet Docker optional bei GHCR an.
#
# Eine Anmeldung ist nur notwendig, wenn das Container-Package privat ist.
# Das GitHub PAT wird verdeckt eingelesen und nicht in der Relais-.env
# gespeichert.
#
# Rückgabewert:
#   0, wenn keine Anmeldung notwendig oder der Login erfolgreich war.
configure_ghcr_login() {
    local answer=""
    local github_username=""
    local github_token=""

    echo

    read -r \
        -p "Ist das GHCR-Package privat? [j/N]: " \
        answer

    case "${answer,,}" in
        j|ja|y|yes)
            read -r \
                -p "GitHub-Benutzername: " \
                github_username

            read -r \
                -s \
                -p "GitHub PAT classic mit read:packages: " \
                github_token

            echo

            if [[ -z "${github_username}" ]]; then
                fail "Der GitHub-Benutzername darf nicht leer sein."
            fi

            if [[ -z "${github_token}" ]]; then
                fail "Der GitHub-Token darf nicht leer sein."
            fi

            printf '%s' "${github_token}" |
                docker login ghcr.io \
                    --username "${github_username}" \
                    --password-stdin

            unset github_token
            ;;

        *)
            echo "GHCR-Anmeldung wird übersprungen."
            ;;
    esac
}

# Führt das heruntergeladene Installationsskript aus.
#
# Schnittstelle:
#   Startet /opt/relais-installer/scripts/linux/install.sh ohne
#   zusätzliche Argumente.
#
# Rückgabewert:
#   Exitcode des Installationsskripts.
run_installation() {
    log "Relais wird installiert"

    "${INSTALL_SCRIPT}"
}

# Zeigt nach erfolgreicher Installation die wichtigsten lokalen Pfade
# und Verwaltungsbefehle an.
#
# Ausgabe:
#   Hinweise für Status, Logs, Update und Deinstallation.
show_completion_message() {
    echo
    echo "Bootstrap und Installation wurden abgeschlossen."
    echo
    echo "Laufzeitdateien:"
    echo "  /opt/relais"
    echo
    echo "Deployment-Skripte:"
    echo "  ${INSTALLER_DIR}"
    echo
    echo "Status anzeigen:"
    echo "  sudo docker compose \\"
    echo "    --env-file /opt/relais/.env \\"
    echo "    --file /opt/relais/compose.yml \\"
    echo "    ps"
    echo
    echo "Logs anzeigen:"
    echo "  sudo docker logs --follow relais"
    echo
    echo "Update ausführen:"
    echo "  sudo ${UPDATE_SCRIPT}"
    echo
    echo "Deinstallation:"
    echo "  sudo ${UNINSTALL_SCRIPT}"
    echo
    echo "Vollständige Deinstallation:"
    echo "  sudo ${UNINSTALL_SCRIPT} --all"
}

# Führt den vollständigen Bootstrap-Ablauf aus.
#
# Ablauf:
#   1. Root-Rechte prüfen
#   2. Architektur prüfen
#   3. Systemzeit prüfen
#   4. Docker installieren oder vorhandene Installation verwenden
#   5. Deployment-Dateien aus dem öffentlichen GitHub-Repository laden
#   6. Downloads und Shell-Syntax prüfen
#   7. optional bei GHCR anmelden
#   8. Installationsskript ausführen
#   9. Verwaltungsbefehle anzeigen
main() {
    require_root
    require_command "apt-get"
    require_command "dpkg"
    require_command "date"
    require_command "systemctl"
    require_command "timedatectl"
    require_command "mktemp"

    log "System wird geprüft"

    verify_architecture
    verify_system_time

    install_docker

    require_command "curl"
    require_command "docker"

    download_deployment_files
    verify_downloaded_files
    validate_downloaded_scripts
    configure_ghcr_login
    run_installation
    show_completion_message
}

main "$@"