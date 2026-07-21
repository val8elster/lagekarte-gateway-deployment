#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly INSTALL_SCRIPT="${SCRIPT_DIR}/install.sh"
readonly REQUIRED_ARCHITECTURE="arm64"

# Gibt eine Fehlermeldung aus und beendet das Skript.
#
# Parameter:
#   $1: Fehlermeldung
#
# Rückgabewert:
#   Beendet das Skript mit Exitcode 1.
fail() {
    echo "Fehler: $1" >&2
    exit 1
}

# Prüft, ob das Skript mit Root-Rechten ausgeführt wird.
#
# Rückgabewert:
#   0, wenn das Skript als root ausgeführt wird.
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "Bitte mit sudo ausführen."
    fi
}

# Prüft, ob der Raspberry Pi ein ARM64-System verwendet.
#
# Rückgabewert:
#   0, wenn die Architektur arm64 ist.
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
# Eine falsche Systemzeit führt häufig dazu, dass APT-Signaturen als
# noch nicht gültig abgelehnt werden.
#
# Rückgabewert:
#   0, wenn das erkannte Jahr mindestens 2026 ist.
verify_system_time() {
    local current_year

    current_year="$(date +%Y)"

    if (( current_year < 2026 )); then
        echo "Die Systemzeit scheint falsch zu sein."
        echo "Aktuelle Zeit:"
        date
        echo
        echo "Versuche, die Zeitsynchronisierung zu aktivieren ..."

        timedatectl set-ntp true || true
        systemctl restart systemd-timesyncd || true
        sleep 10

        current_year="$(date +%Y)"

        if (( current_year < 2026 )); then
            fail "Systemzeit ist weiterhin falsch. Bitte Datum und Uhrzeit manuell korrigieren."
        fi
    fi
}

# Entfernt Docker-Pakete, die mit dem offiziellen Docker-Repository
# kollidieren können.
#
# Rückgabewert:
#   0 nach dem Entfernungsversuch.
remove_conflicting_packages() {
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
        apt-get remove --yes "${package}" >/dev/null 2>&1 || true
    done
}

# Richtet das offizielle Docker-APT-Repository ein.
#
# Ausgabe:
#   Erstellt den Docker-Schlüssel und die Repository-Datei.
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

# Installiert Docker Engine, Buildx und das Docker-Compose-Plugin.
#
# Rückgabewert:
#   0, wenn Docker erfolgreich installiert wurde.
install_docker() {
    if command -v docker >/dev/null 2>&1 &&
       docker compose version >/dev/null 2>&1; then
        echo "Docker und Compose sind bereits installiert."
        return
    fi

    echo "Docker wird installiert ..."

    apt-get update

    apt-get install \
        --yes \
        ca-certificates \
        curl \
        git

    remove_conflicting_packages
    configure_docker_repository

    apt-get update

    apt-get install \
        --yes \
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

# Meldet Docker optional bei der GitHub Container Registry an.
#
# Die Anmeldung ist nur erforderlich, wenn das GHCR-Package privat ist.
# Der Token wird verdeckt eingelesen und nicht in der Relais-.env gespeichert.
#
# Rückgabewert:
#   0, wenn keine Anmeldung benötigt oder die Anmeldung erfolgreich war.
configure_ghcr_login() {
    local answer=""
    local github_username=""
    local github_token=""

    read -r -p "Ist das GHCR-Package privat? [j/N]: " answer

    case "${answer,,}" in
        j|ja|y|yes)
            read -r -p "GitHub-Benutzername: " github_username
            read -r -s -p "GitHub PAT classic mit read:packages: " github_token
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

# Startet die eigentliche Relais-Installation.
#
# Schnittstelle:
#   Ruft install.sh ohne weitere Parameter auf.
#
# Rückgabewert:
#   Exitcode des Installationsskripts.
run_installation() {
    if [[ ! -f "${INSTALL_SCRIPT}" ]]; then
        fail "Installationsskript fehlt: ${INSTALL_SCRIPT}"
    fi

    chmod +x "${INSTALL_SCRIPT}"

    "${INSTALL_SCRIPT}"
}

# Führt den vollständigen Bootstrap-Ablauf aus.
#
# Ablauf:
#   1. Root-Rechte prüfen
#   2. Architektur prüfen
#   3. Systemzeit prüfen
#   4. Docker installieren
#   5. Optional bei GHCR anmelden
#   6. Relais installieren
main() {
    require_root
    verify_architecture
    verify_system_time
    install_docker
    configure_ghcr_login
    run_installation
}

main "$@"