#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_DIR="/opt/gateway"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly ENV_PATH="${INSTALL_DIR}/.env"
readonly COMPOSE_PATH="${INSTALL_DIR}/compose.yml"

readonly DEFAULT_IMAGE_REPOSITORY="ghcr.io/val8elster/lagekarte-gateway"

PURGE=false
REMOVE_IMAGES=false
REMOVE_SOURCE_FILES=false

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

# Zeigt die Verwendung des Skripts an.
#
# Ausgabe:
#   Beschreibung der verfügbaren Optionen.
show_usage() {
    cat <<'EOF'
Verwendung:

  sudo ./uninstall.sh [OPTIONEN]

Optionen:

  --purge
      Löscht zusätzlich /opt/gateway vollständig.
      Dadurch werden auch folgende Daten entfernt:

      - config.toml
      - .env
      - DEVICE_REGISTRATION_TOKEN
      - SQLite-Datenbank
      - gespeicherter Geräte-API-Key
      - noch nicht übertragene Positionen

  --remove-images
      Entfernt zusätzlich alle lokal vorhandenen Gateway-Images aus GHCR.

  --remove-source-files
      Entfernt zusätzlich den übertragenen Ordner ~/gateway des Benutzers,
      der sudo aufgerufen hat.

  --all
      Entspricht:
      --purge --remove-images --remove-source-files

  --help
      Zeigt diese Hilfe an.

Beispiele:

  Container entfernen, Daten behalten:

      sudo ./uninstall.sh

  Anwendung und Laufzeitdaten vollständig entfernen:

      sudo ./uninstall.sh --purge

  Alles einschließlich Images und übertragener Skripte entfernen:

      sudo ./uninstall.sh --all
EOF
}

# Prüft, ob das Skript mit Root-Rechten ausgeführt wird.
#
# Rückgabewert:
#   0, wenn das Skript als root läuft.
#   Beendet das Skript andernfalls.
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "Bitte dieses Skript mit sudo ausführen."
    fi
}

# Verarbeitet die übergebenen Kommandozeilenoptionen.
#
# Parameter:
#   Alle an das Skript übergebenen Argumente.
#
# Ausgabe:
#   Setzt die globalen Steuerungsvariablen.
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge)
                PURGE=true
                ;;

            --remove-images)
                REMOVE_IMAGES=true
                ;;

            --remove-source-files)
                REMOVE_SOURCE_FILES=true
                ;;

            --all)
                PURGE=true
                REMOVE_IMAGES=true
                REMOVE_SOURCE_FILES=true
                ;;

            --help|-h)
                show_usage
                exit 0
                ;;

            *)
                fail "Unbekannte Option: $1"
                ;;
        esac

        shift
    done
}

# Fordert eine ausdrückliche Bestätigung für das Löschen persistenter Daten an.
#
# Rückgabewert:
#   0 bei bestätigter Löschung.
#   Beendet das Skript, wenn nicht bestätigt wurde.
confirm_purge() {
    local confirmation=""

    if [[ "${PURGE}" != true ]]; then
        return
    fi

    echo
    echo "WARNUNG:"
    echo "Das Verzeichnis ${INSTALL_DIR} wird vollständig gelöscht."
    echo
    echo "Dadurch gehen unter anderem verloren:"
    echo "  - Konfiguration"
    echo "  - Registrierungs-Token"
    echo "  - Geräte-API-Key"
    echo "  - SQLite-Datenbank"
    echo "  - noch nicht übertragene Positionen"
    echo

    read -r -p 'Zum Bestätigen exakt "LOESCHEN" eingeben: ' confirmation

    if [[ "${confirmation}" != "LOESCHEN" ]]; then
        echo "Deinstallation wurde abgebrochen."
        exit 0
    fi
}

# Stoppt und entfernt den Gateway-Compose-Stack.
#
# Die Funktion verwendet bevorzugt die installierte Compose-Datei.
# Falls diese nicht verfügbar oder fehlerhaft ist, wird der Container
# direkt über Docker entfernt.
#
# Rückgabewert:
#   0 nach dem Entfernungsversuch.
remove_compose_stack() {
    echo "Gateway-Container wird gestoppt und entfernt ..."

    if [[ -f "${COMPOSE_PATH}" && -f "${ENV_PATH}" ]]; then
        if docker compose \
            --env-file "${ENV_PATH}" \
            --file "${COMPOSE_PATH}" \
            down \
            --remove-orphans; then

            echo "Compose-Stack wurde entfernt."
            return
        fi

        echo "Compose konnte den Stack nicht vollständig entfernen."
        echo "Direkte Container-Entfernung wird versucht ..."
    fi

    if docker container inspect gateway >/dev/null 2>&1; then
        docker rm \
            --force \
            gateway

        echo "Container gateway wurde direkt entfernt."
    else
        echo "Kein Container namens gateway vorhanden."
    fi
}

# Entfernt lokal gespeicherte Gateway-Container-Images.
#
# Es werden alle Tags entfernt, deren Repository dem konfigurierten
# Gateway-Repository entspricht.
#
# Rückgabewert:
#   0 nach dem Entfernungsversuch.
remove_gateway_images() {
    local images=()

    if [[ "${REMOVE_IMAGES}" != true ]]; then
        return
    fi

    echo
    echo "Lokale Gateway-Images werden gesucht ..."

    mapfile -t images < <(
        docker images \
            --format '{{.Repository}}:{{.Tag}}' |
            grep -E "^${DEFAULT_IMAGE_REPOSITORY//\//\\/}:" ||
            true
    )

    if [[ "${#images[@]}" -eq 0 ]]; then
        echo "Keine lokalen Gateway-Images gefunden."
        return
    fi

    printf 'Folgende Images werden entfernt:\n'

    printf '  %s\n' "${images[@]}"

    docker image rm \
        --force \
        "${images[@]}"

    echo "Gateway-Images wurden entfernt."
}

# Entfernt das Installationsverzeichnis einschließlich persistenter Daten.
#
# Diese Funktion wird nur ausgeführt, wenn --purge gesetzt wurde.
#
# Ausgabe:
#   Löscht /opt/gateway vollständig.
remove_installation_directory() {
    if [[ "${PURGE}" != true ]]; then
        echo
        echo "Persistente Daten bleiben erhalten:"
        echo "  ${INSTALL_DIR}"
        return
    fi

    echo
    echo "Installationsverzeichnis wird vollständig gelöscht ..."

    rm -rf -- "${INSTALL_DIR}"

    if [[ -e "${INSTALL_DIR}" ]]; then
        fail "Installationsverzeichnis konnte nicht vollständig gelöscht werden."
    fi

    echo "Installationsverzeichnis wurde entfernt:"
    echo "  ${INSTALL_DIR}"
}

# Ermittelt das Home-Verzeichnis des Benutzers, der sudo aufgerufen hat.
#
# Ausgabe:
#   Home-Verzeichnis des ursprünglichen Benutzers.
#
# Rückgabewert:
#   0, wenn ein Benutzer ermittelt werden konnte.
#   1, wenn kein ursprünglicher Benutzer bekannt ist.
get_original_user_home() {
    local original_user=""

    original_user="${SUDO_USER:-}"

    if [[ -z "${original_user}" || "${original_user}" == "root" ]]; then
        return 1
    fi

    getent passwd "${original_user}" |
        cut -d: -f6
}

# Entfernt den übertragenen Quell- und Skriptordner aus dem Benutzer-Home.
#
# Standardmäßig wird ~/gateway des ursprünglichen sudo-Benutzers entfernt.
# Diese Funktion wird nur mit --remove-source-files ausgeführt.
#
# Rückgabewert:
#   0 nach dem Entfernungsversuch.
remove_source_files() {
    local original_home=""
    local source_directory=""

    if [[ "${REMOVE_SOURCE_FILES}" != true ]]; then
        return
    fi

    echo

    if ! original_home="$(get_original_user_home)"; then
        echo "Der ursprüngliche sudo-Benutzer konnte nicht ermittelt werden."
        echo "Quellordner wird nicht automatisch gelöscht."
        return
    fi

    source_directory="${original_home}/gateway"

    if [[ ! -e "${source_directory}" ]]; then
        echo "Kein übertragener Gateway-Ordner vorhanden:"
        echo "  ${source_directory}"
        return
    fi

    rm -rf -- "${source_directory}"

    echo "Übertragener Gateway-Ordner wurde entfernt:"
    echo "  ${source_directory}"
}

# Entfernt die lokal gespeicherte Anmeldung bei GHCR.
#
# Die Abmeldung wird nur bei einer vollständigen Entfernung mit --all
# durchgeführt.
#
# Rückgabewert:
#   0 nach dem Abmeldeversuch.
logout_from_ghcr() {
    if [[ "${PURGE}" != true ||
          "${REMOVE_IMAGES}" != true ||
          "${REMOVE_SOURCE_FILES}" != true ]]; then
        return
    fi

    echo
    echo "Lokale GHCR-Anmeldung wird entfernt ..."

    docker logout ghcr.io >/dev/null 2>&1 || true

    echo "GHCR-Abmeldung abgeschlossen."
}

# Zeigt den abschließenden Zustand der Deinstallation an.
#
# Ausgabe:
#   Zusammenfassung der entfernten und behaltenen Komponenten.
show_summary() {
    echo
    echo "Deinstallation abgeschlossen."
    echo

    if [[ "${PURGE}" == true ]]; then
        echo "Laufzeitdaten:"
        echo "  vollständig entfernt"
    else
        echo "Laufzeitdaten:"
        echo "  beibehalten unter ${INSTALL_DIR}"
    fi

    if [[ "${REMOVE_IMAGES}" == true ]]; then
        echo "Container-Images:"
        echo "  entfernt"
    else
        echo "Container-Images:"
        echo "  beibehalten"
    fi

    if [[ "${REMOVE_SOURCE_FILES}" == true ]]; then
        echo "Übertragene Skriptdateien:"
        echo "  entfernt"
    else
        echo "Übertragene Skriptdateien:"
        echo "  beibehalten"
    fi
}

# Führt die vollständige Deinstallation aus.
#
# Ablauf:
#   1. Optionen verarbeiten
#   2. Root-Rechte prüfen
#   3. Löschung persistenter Daten bestätigen
#   4. Container und Compose-Ressourcen entfernen
#   5. optional Images entfernen
#   6. optional /opt/gateway entfernen
#   7. optional übertragenen Skriptordner entfernen
#   8. optional von GHCR abmelden
main() {
    parse_arguments "$@"
    require_root
    confirm_purge

    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker ist nicht installiert."
        echo "Container-Entfernung wird übersprungen."
    else
        remove_compose_stack
        remove_gateway_images
        logout_from_ghcr
    fi

    remove_installation_directory
    remove_source_files
    show_summary
}

main "$@"
