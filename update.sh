#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALL_DIR="/opt/relais"
readonly ENV_PATH="${INSTALL_DIR}/.env"
readonly CONFIG_PATH="${INSTALL_DIR}/config.toml"
readonly COMPOSE_PATH="${INSTALL_DIR}/compose.yml"

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
    pwd
)"

PROJECT_DIR="$(
    cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1
    pwd
)"

readonly SCRIPT_DIR
readonly PROJECT_DIR
readonly COMPOSE_SOURCE="${PROJECT_DIR}/deploy/raspberry-pi/compose.yml"

PRUNE_IMAGES=false


# Gibt die Verwendung des Update-Skripts aus.
#
# Ausgabe:
#   Schreibt die verfügbaren Parameter in die Standardausgabe.
print_usage() {
    cat <<'EOF'
Verwendung:
  sudo ./scripts/linux/update.sh [OPTIONEN]

Optionen:
  --prune       Nicht mehr verwendete Container-Images entfernen
  -h, --help    Hilfe anzeigen
EOF
}


# Verarbeitet die an das Skript übergebenen Kommandozeilenparameter.
#
# Eingabe:
#   Alle Parameter des Update-Skripts.
#
# Ausgabe:
#   Setzt interne Steuerungsvariablen oder beendet das Skript bei Fehlern.
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prune)
                PRUNE_IMAGES=true
                shift
                ;;

            -h|--help)
                print_usage
                exit 0
                ;;

            *)
                echo "Unbekannter Parameter: $1" >&2
                print_usage
                exit 1
                ;;
        esac
    done
}


# Prüft, ob das Skript mit Root-Rechten ausgeführt wird.
#
# Ausgabe:
#   Beendet das Skript, wenn keine Root-Rechte vorhanden sind.
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Dieses Skript muss mit sudo oder als root ausgeführt werden." >&2
        exit 1
    fi
}


# Prüft Docker und das Docker-Compose-Plugin.
#
# Ausgabe:
#   Beendet das Skript, wenn Docker nicht erreichbar ist.
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker ist nicht installiert." >&2
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo "Docker ist nicht erreichbar oder läuft nicht." >&2
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo "Das Docker-Compose-Plugin ist nicht installiert." >&2
        exit 1
    fi
}


# Prüft, ob eine vollständige Relais-Installation vorhanden ist.
#
# Ausgabe:
#   Beendet das Skript, wenn erforderliche Dateien fehlen.
check_installation() {
    if [[ ! -d "${INSTALL_DIR}" ]]; then
        echo "Das Relais ist nicht unter ${INSTALL_DIR} installiert." >&2
        exit 1
    fi

    if [[ ! -f "${ENV_PATH}" ]]; then
        echo "Umgebungsdatei fehlt: ${ENV_PATH}" >&2
        exit 1
    fi

    if [[ ! -f "${CONFIG_PATH}" ]]; then
        echo "Konfigurationsdatei fehlt: ${CONFIG_PATH}" >&2
        exit 1
    fi
}


# Aktualisiert die installierte Compose-Datei aus dem Repository.
#
# Ausgabe:
#   Ersetzt /opt/relais/compose.yml durch die aktuelle Repository-Version.
update_compose_file() {
    if [[ ! -f "${COMPOSE_SOURCE}" ]]; then
        echo "Aktuelle Compose-Datei wurde nicht gefunden:" >&2
        echo "  ${COMPOSE_SOURCE}" >&2
        exit 1
    fi

    install \
        -m 0644 \
        "${COMPOSE_SOURCE}" \
        "${COMPOSE_PATH}"

    echo "Compose-Datei aktualisiert."
}


# Prüft die aufgelöste Docker-Compose-Konfiguration.
#
# Ausgabe:
#   Beendet das Skript, wenn die Compose-Konfiguration ungültig ist.
validate_compose_configuration() {
    docker compose \
        --env-file "${ENV_PATH}" \
        -f "${COMPOSE_PATH}" \
        config \
        --quiet

    echo "Compose-Konfiguration ist gültig."
}


# Lädt das aktuelle Container-Image.
#
# Ausgabe:
#   Lädt die in .env konfigurierte Image-Version aus der Registry.
pull_image() {
    docker compose \
        --env-file "${ENV_PATH}" \
        -f "${COMPOSE_PATH}" \
        pull
}


# Erstellt den Relais-Container mit dem aktuellen Image neu.
#
# Ausgabe:
#   Startet den aktualisierten Container im Hintergrund.
deploy_update() {
    docker compose \
        --env-file "${ENV_PATH}" \
        -f "${COMPOSE_PATH}" \
        up \
        --detach \
        --remove-orphans \
        --force-recreate
}


# Entfernt optional nicht mehr verwendete Container-Images.
#
# Ausgabe:
#   Führt nur mit --prune ein Docker Image Prune aus.
prune_unused_images() {
    if [[ "${PRUNE_IMAGES}" != true ]]; then
        return
    fi

    docker image prune --force
}


# Zeigt den aktuellen Zustand des Relais-Containers.
#
# Ausgabe:
#   Gibt die Docker-Compose-Statusübersicht aus.
show_status() {
    echo

    docker compose \
        --env-file "${ENV_PATH}" \
        -f "${COMPOSE_PATH}" \
        ps
}


# Führt das vollständige Relais-Update aus.
#
# Ausgabe:
#   Aktualisiert Compose-Datei und Container-Image und zeigt den Status.
main() {
    parse_arguments "$@"
    require_root
    check_docker
    check_installation
    update_compose_file
    validate_compose_configuration

    cd "${INSTALL_DIR}"

    pull_image
    deploy_update
    prune_unused_images
    show_status

    echo
    echo "Relais wurde aktualisiert."
    echo
    echo "Logs anzeigen:"
    echo "  cd ${INSTALL_DIR}"
    echo "  sudo docker compose logs --follow relais"
}

main "$@"