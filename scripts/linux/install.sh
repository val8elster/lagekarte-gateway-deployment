#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_DIR="/opt/gateway"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly CONFIG_PATH="${INSTALL_DIR}/config.toml"
readonly ENV_PATH="${INSTALL_DIR}/.env"
readonly COMPOSE_PATH="${INSTALL_DIR}/compose.yml"

readonly CONTAINER_UID="10001"
readonly CONTAINER_GID="10001"

readonly DEFAULT_IMAGE_REPOSITORY="ghcr.io/val8elster/lagekarte-gateway"
readonly DEFAULT_IMAGE_VERSION="prod"
readonly DEFAULT_RUST_LOG="info"

readonly MINIMUM_ADMIN_PASSWORD_LENGTH="12"
readonly ADMIN_PASSWORD_HASH_VARIABLE="GATEWAY_ADMIN_PASSWORD_HASH"
readonly SESSION_SECURE_VARIABLE="GATEWAY_SESSION_SECURE"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

readonly CONFIG_SCRIPT="${SCRIPT_DIR}/create-config.sh"
readonly COMPOSE_SOURCE="${PROJECT_DIR}/deploy/raspberry-pi/compose.yml"
readonly DESKTOP_SHORTCUT_SCRIPT="${SCRIPT_DIR}/create-desktop-shortcuts.sh"

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
        fail "Bitte dieses Skript mit sudo ausführen."
    fi
}

# Prüft, ob ein benötigter Befehl installiert ist.
#
# Parameter:
#   $1: Name des Befehls
#
# Rückgabewert:
#   0, wenn der Befehl vorhanden ist.
require_command() {
    local command_name="$1"

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        fail "Benötigter Befehl fehlt: ${command_name}"
    fi
}

# Prüft, ob eine benötigte Datei vorhanden ist.
#
# Parameter:
#   $1: Dateipfad
#
# Rückgabewert:
#   0, wenn die Datei vorhanden ist.
require_file() {
    local file_path="$1"

    if [[ ! -f "${file_path}" ]]; then
        fail "Benötigte Datei fehlt: ${file_path}"
    fi
}

# Liest den Wert einer Variablen aus einer .env-Datei.
#
# Einfache oder doppelte Anführungszeichen am Anfang und Ende des Wertes
# werden entfernt.
#
# Parameter:
#   $1: Variablenname
#   $2: Pfad zur .env-Datei
#
# Ausgabe:
#   Wert der Variable oder eine leere Ausgabe.
read_env_value() {
    local variable_name="$1"
    local env_file="$2"
    local value=""

    if [[ ! -f "${env_file}" ]]; then
        return 0
    fi

    value="$(
        grep -E "^${variable_name}=" "${env_file}" |
            tail -n 1 |
            cut -d= -f2- || true
    )"

    if [[ "${value}" == \'*\' ]] &&
       [[ "${#value}" -ge 2 ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \"*\" ]] &&
         [[ "${#value}" -ge 2 ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "${value}"
}

# Erkennt ein angeschlossenes serielles GPS-Gerät.
#
# Bevorzugt wird ein stabiler Pfad unter /dev/serial/by-id.
#
# Ausgabe:
#   Pfad zum GPS-Gerät oder /dev/ttyUSB0 als Fallback.
detect_gps_device() {
    local device=""

    if [[ -d /dev/serial/by-id ]]; then
        device="$(
            find /dev/serial/by-id \
                -maxdepth 1 \
                -type l \
                -print \
                -quit \
                2>/dev/null || true
        )"
    fi

    if [[ -z "${device}" ]]; then
        device="$(
            find /dev \
                -maxdepth 1 \
                \( -name 'ttyUSB*' -o -name 'ttyACM*' \) \
                -print \
                -quit \
                2>/dev/null || true
        )"
    fi

    printf '%s' "${device:-/dev/ttyUSB0}"
}

# Ermittelt die numerische Gruppen-ID von dialout.
#
# Ausgabe:
#   Gruppen-ID von dialout oder 20 als Fallback.
detect_dialout_gid() {
    local gid=""

    gid="$(
        getent group dialout 2>/dev/null |
            cut -d: -f3 || true
    )"

    printf '%s' "${gid:-20}"
}

# Erstellt die Installationsverzeichnisse und setzt die Berechtigungen.
#
# /opt/gateway bleibt root-owned.
# /opt/gateway/data gehört dem Containerbenutzer mit UID 10001.
#
# Ausgabe:
#   Erstellt beziehungsweise repariert die Verzeichnisse.
prepare_directories() {
    install \
        --directory \
        --mode 0755 \
        --owner root \
        --group root \
        "${INSTALL_DIR}"

    install \
        --directory \
        --mode 0750 \
        --owner "${CONTAINER_UID}" \
        --group "${CONTAINER_GID}" \
        "${DATA_DIR}"

    chown -R \
        "${CONTAINER_UID}:${CONTAINER_GID}" \
        "${DATA_DIR}"

    find "${DATA_DIR}" \
        -type d \
        -exec chmod 0750 {} +

    find "${DATA_DIR}" \
        -type f \
        -exec chmod 0640 {} +
}

# Kopiert die Compose-Datei in das Installationsverzeichnis.
#
# Ausgabe:
#   Erstellt oder überschreibt /opt/gateway/compose.yml.
install_compose_file() {
    install \
        --mode 0644 \
        --owner root \
        --group root \
        "${COMPOSE_SOURCE}" \
        "${COMPOSE_PATH}"

    echo "Compose-Datei installiert:"
    echo "  ${COMPOSE_PATH}"
}

# Erstellt die config.toml, sofern noch keine gültige Datei vorhanden ist.
#
# Die Datei wird root-owned, aber für den Container lesbar gesetzt.
#
# Ausgabe:
#   Erstellt oder übernimmt /opt/gateway/config.toml.
prepare_config_file() {
    if [[ -s "${CONFIG_PATH}" ]]; then
        echo "Bestehende Konfiguration wird verwendet:"
        echo "  ${CONFIG_PATH}"
    else
        chmod +x "${CONFIG_SCRIPT}"

        "${CONFIG_SCRIPT}" \
            --config-path "${CONFIG_PATH}" \
            --database-path "data/positions.db"

        if [[ ! -s "${CONFIG_PATH}" ]]; then
            fail "Die Konfigurationsdatei wurde nicht korrekt erstellt."
        fi
    fi

    chown root:root "${CONFIG_PATH}"
    chmod 0644 "${CONFIG_PATH}"
}

# Installiert die zum Erzeugen des Argon2id-Passworthashs benötigten
# Systempakete, sofern sie noch nicht verfügbar sind.
#
# Ausgabe:
#   Installiert bei Bedarf python3 und python3-argon2.
ensure_password_hash_dependencies() {
    if command -v python3 >/dev/null 2>&1 &&
       python3 -c 'import argon2' >/dev/null 2>&1; then
        return
    fi

    echo
    echo "Abhängigkeiten für die Adminpasswort-Einrichtung werden installiert ..."

    apt-get update

    apt-get install \
        --yes \
        --no-install-recommends \
        python3 \
        python3-argon2

    if ! python3 -c 'import argon2' >/dev/null 2>&1; then
        fail "Das Python-Modul argon2 konnte nicht installiert werden."
    fi
}

# Liest das Adminpasswort verdeckt ein und fordert eine Bestätigung an.
#
# Das Passwort muss mindestens zwölf Zeichen lang sein. Es wird nur
# vorübergehend in der globalen Variable ADMIN_PASSWORD gehalten.
#
# Ausgabe:
#   Setzt die globale Variable ADMIN_PASSWORD.
read_admin_password() {
    local password=""
    local password_confirmation=""

    while true; do
        echo
        echo "Adminpasswort für die Gateway-Benutzeroberfläche"
        echo "================================================"
        echo "Das Passwort muss mindestens ${MINIMUM_ADMIN_PASSWORD_LENGTH} Zeichen lang sein."
        echo

        read \
            -r \
            -s \
            -p "Adminpasswort: " \
            password

        echo

        read \
            -r \
            -s \
            -p "Adminpasswort wiederholen: " \
            password_confirmation

        echo

        if [[ -z "${password}" ]]; then
            echo "Das Adminpasswort darf nicht leer sein."
            continue
        fi

        if [[ "${#password}" -lt "${MINIMUM_ADMIN_PASSWORD_LENGTH}" ]]; then
            echo "Das Adminpasswort ist zu kurz."
            continue
        fi

        if [[ "${password}" != "${password_confirmation}" ]]; then
            echo "Die eingegebenen Passwörter stimmen nicht überein."
            continue
        fi

        ADMIN_PASSWORD="${password}"

        unset password
        unset password_confirmation

        return
    done
}

# Erzeugt einen Argon2id-PHC-Hash aus einem Klartextpasswort.
#
# Parameter:
#   $1: Klartextpasswort
#
# Ausgabe:
#   Vollständiger Argon2id-PHC-Hash.
generate_admin_password_hash() {
    local password="$1"

    ADMIN_PASSWORD_INPUT="${password}" \
        python3 <<'PYTHON'
import os

from argon2 import PasswordHasher
from argon2.low_level import Type

password = os.environ["ADMIN_PASSWORD_INPUT"]

password_hasher = PasswordHasher(
    time_cost=2,
    memory_cost=19456,
    parallelism=1,
    hash_len=32,
    salt_len=16,
    type=Type.ID,
)

print(password_hasher.hash(password))
PYTHON
}

# Prüft, ob ein erzeugter Wert wie ein vollständiger Argon2id-PHC-Hash
# aufgebaut ist.
#
# Parameter:
#   $1: Zu prüfender Hash
#
# Rückgabewert:
#   0 bei einem plausiblen Argon2id-Hash.
#   1 bei einem ungültigen Wert.
admin_password_hash_is_valid() {
    local password_hash="$1"

    [[ "${password_hash}" == '$argon2id$'* ]] &&
        [[ "${password_hash}" == *'$v='* ]] &&
        [[ "${password_hash}" == *'$m='* ]]
}

# Prüft, ob die vorhandene .env alle benötigten Werte enthält.
#
# Rückgabewert:
#   0, wenn alle benötigten Variablen vorhanden und gültig sind.
#   1, wenn die Datei fehlt oder unvollständig ist.
env_file_is_compatible() {
    local required_variables=(
        "GATEWAY_IMAGE_REPOSITORY"
        "GATEWAY_VERSION"
        "DEVICE_REGISTRATION_TOKEN"
        "GPS_DEVICE"
        "DIALOUT_GID"
        "GATEWAY_ADMIN_PASSWORD_HASH"
        "GATEWAY_SESSION_SECURE"
    )

    local variable_name
    local variable_value
    local admin_password_hash

    if [[ ! -s "${ENV_PATH}" ]]; then
        return 1
    fi

    for variable_name in "${required_variables[@]}"; do
        variable_value="$(
            read_env_value "${variable_name}" "${ENV_PATH}"
        )"

        if [[ -z "${variable_value}" ]]; then
            return 1
        fi
    done

    admin_password_hash="$(
        read_env_value \
            "${ADMIN_PASSWORD_HASH_VARIABLE}" \
            "${ENV_PATH}"
    )"

    if ! admin_password_hash_is_valid "${admin_password_hash}"; then
        return 1
    fi

    return 0
}

# Erzeugt eine neue Laufzeit-.env für Docker Compose.
#
# Abgefragt werden:
#   - Image-Repository
#   - Image-Version
#   - GPS-Gerät
#   - Registrierungs-Token
#   - Adminpasswort für die Benutzeroberfläche
#
# Nur der Argon2id-Hash des Adminpassworts wird gespeichert.
#
# Ausgabe:
#   Erstellt /opt/gateway/.env mit Berechtigung 0600.
create_env_file() {
    local image_repository="${DEFAULT_IMAGE_REPOSITORY}"
    local image_version="${DEFAULT_IMAGE_VERSION}"
    local gps_device
    local dialout_gid
    local registration_token=""
    local entered_value=""
    local admin_password_hash=""

    gps_device="$(detect_gps_device)"
    dialout_gid="$(detect_dialout_gid)"

    echo
    echo "Container-Konfiguration"
    echo "======================="

    read -r \
        -p "Image-Repository [${image_repository}]: " \
        entered_value

    image_repository="${entered_value:-${image_repository}}"

    entered_value=""

    read -r \
        -p "Image-Version [${image_version}]: " \
        entered_value

    image_version="${entered_value:-${image_version}}"

    entered_value=""

    echo
    echo "GPS-Gerät gefunden:"
    echo "  ${gps_device}"

    read -r \
        -p "GPS-Gerät [${gps_device}]: " \
        entered_value

    gps_device="${entered_value:-${gps_device}}"

    echo

    read \
        -r \
        -s \
        -p "DEVICE_REGISTRATION_TOKEN: " \
        registration_token

    echo

    if [[ -z "${registration_token}" ]]; then
        fail "DEVICE_REGISTRATION_TOKEN darf nicht leer sein."
    fi

    ensure_password_hash_dependencies
    read_admin_password

    admin_password_hash="$(
        generate_admin_password_hash "${ADMIN_PASSWORD}"
    )"

    unset ADMIN_PASSWORD

    if ! admin_password_hash_is_valid "${admin_password_hash}"; then
        fail "Es wurde kein gültiger Argon2id-Passworthash erzeugt."
    fi

    cat > "${ENV_PATH}" <<EOF
GATEWAY_IMAGE_REPOSITORY=${image_repository}
GATEWAY_VERSION=${image_version}
DEVICE_REGISTRATION_TOKEN=${registration_token}
GPS_DEVICE=${gps_device}
DIALOUT_GID=${dialout_gid}
RUST_LOG=${DEFAULT_RUST_LOG}
GATEWAY_ADMIN_PASSWORD_HASH='${admin_password_hash}'
GATEWAY_SESSION_SECURE='false'
EOF

    unset registration_token
    unset admin_password_hash

    chown root:root "${ENV_PATH}"
    chmod 0600 "${ENV_PATH}"

    echo
    echo "Umgebungsdatei erstellt:"
    echo "  ${ENV_PATH}"
    echo
    echo "Das Adminpasswort wurde eingerichtet."
    echo "Gespeichert wurde ausschließlich der Argon2id-Hash."
}

# Erstellt eine neue .env, wenn die vorhandene Datei inkompatibel ist.
#
# Eine inkompatible Datei wird vor dem Überschreiben mit Zeitstempel
# gesichert.
#
# Ausgabe:
#   Erstellt oder übernimmt /opt/gateway/.env.
prepare_env_file() {
    local backup_path

    if env_file_is_compatible; then
        echo "Bestehende Umgebungsdatei wird verwendet:"
        echo "  ${ENV_PATH}"

        chown root:root "${ENV_PATH}"
        chmod 0600 "${ENV_PATH}"

        return
    fi

    if [[ -e "${ENV_PATH}" ]]; then
        backup_path="${ENV_PATH}.invalid.$(date +%Y%m%d-%H%M%S)"

        cp \
            --preserve=mode \
            "${ENV_PATH}" \
            "${backup_path}"

        chmod 0600 "${backup_path}"

        echo "Inkompatible Umgebungsdatei wurde gesichert:"
        echo "  ${backup_path}"
    fi

    create_env_file
}

# Erstellt Desktop-Starter für Update, Deinstallation und
# Konfigurationsoberfläche.
#
# Ausgabe:
#   Führt das Shortcut-Skript aus, sofern es vorhanden und ausführbar ist.
create_desktop_shortcuts() {
    if [[ ! -x "${DESKTOP_SHORTCUT_SCRIPT}" ]]; then
        echo "Hinweis: Desktop-Shortcut-Skript wurde nicht gefunden."
        echo "Übersprungen: ${DESKTOP_SHORTCUT_SCRIPT}"
        return
    fi

    "${DESKTOP_SHORTCUT_SCRIPT}"
}

# Prüft, ob der in der .env konfigurierte GPS-Gerätepfad existiert.
#
# Rückgabewert:
#   0, wenn das Gerät existiert.
#   Beendet das Skript andernfalls mit einer Fehlermeldung.
verify_gps_device() {
    local gps_device

    gps_device="$(
        read_env_value \
            "GPS_DEVICE" \
            "${ENV_PATH}"
    )"

    if [[ ! -e "${gps_device}" ]]; then
        fail "GPS-Gerät existiert nicht: ${gps_device}"
    fi

    echo "GPS-Gerät:"
    echo "  ${gps_device}"
}

# Prüft, ob der Adminpasswort-Hash in der Laufzeitkonfiguration vorhanden
# und plausibel aufgebaut ist.
#
# Rückgabewert:
#   0, wenn der Hash gültig erscheint.
#   Beendet das Skript andernfalls mit einer Fehlermeldung.
verify_admin_password_hash() {
    local admin_password_hash

    admin_password_hash="$(
        read_env_value \
            "${ADMIN_PASSWORD_HASH_VARIABLE}" \
            "${ENV_PATH}"
    )"

    if ! admin_password_hash_is_valid "${admin_password_hash}"; then
        fail "GATEWAY_ADMIN_PASSWORD_HASH fehlt oder ist ungültig."
    fi

    echo "Adminpasswort-Hash:"
    echo "  Argon2id-Hash ist vorhanden."
}

# Prüft die Docker-Compose-Konfiguration.
#
# Rückgabewert:
#   0, wenn Compose die Konfiguration erfolgreich auflösen kann.
validate_compose_configuration() {
    docker compose \
        --env-file "${ENV_PATH}" \
        --file "${COMPOSE_PATH}" \
        config \
        --quiet
}

# Lädt das konfigurierte Gateway-Image aus GHCR.
#
# Rückgabewert:
#   0, wenn das Image geladen wurde.
pull_container_image() {
    docker compose \
        --env-file "${ENV_PATH}" \
        --file "${COMPOSE_PATH}" \
        pull \
        gateway
}

# Startet oder aktualisiert den Gateway-Container.
#
# Der Container wird bei Bedarf neu erstellt. Persistente Dateien unter
# /opt/gateway/data bleiben erhalten.
#
# Rückgabewert:
#   0, wenn der Container erfolgreich gestartet wurde.
start_container() {
    docker compose \
        --env-file "${ENV_PATH}" \
        --file "${COMPOSE_PATH}" \
        up \
        --detach \
        --remove-orphans \
        --force-recreate \
        gateway
}

# Zeigt den aktuellen Compose-Status an.
#
# Ausgabe:
#   Status des Gateway-Containers.
show_status() {
    docker compose \
        --env-file "${ENV_PATH}" \
        --file "${COMPOSE_PATH}" \
        ps
}

# Führt die vollständige Gateway-Installation aus.
#
# Ablauf:
#   1. Voraussetzungen prüfen
#   2. Verzeichnisse und Dateirechte vorbereiten
#   3. Compose-Datei kopieren
#   4. Konfiguration vorbereiten
#   5. Laufzeit-.env und Adminpasswort vorbereiten
#   6. GPS-Gerät und Passworthash prüfen
#   7. Compose-Konfiguration validieren
#   8. Image laden
#   9. Container starten
#  10. Desktop-Starter erstellen
main() {
    require_root
    require_command "docker"
    require_command "find"
    require_command "getent"
    require_command "apt-get"

    if ! docker compose version >/dev/null 2>&1; then
        fail "Docker Compose Plugin fehlt. Zuerst bootstrap.sh ausführen."
    fi

    require_file "${CONFIG_SCRIPT}"
    require_file "${COMPOSE_SOURCE}"

    prepare_directories
    install_compose_file
    prepare_config_file
    prepare_env_file
    verify_gps_device
    verify_admin_password_hash

    echo
    echo "Docker-Compose-Konfiguration wird geprüft ..."
    validate_compose_configuration

    echo "Container-Image wird geladen ..."
    pull_container_image

    echo "Gateway-Container wird gestartet ..."
    start_container

    echo "Desktop-Shortcuts werden erstellt ..."
    create_desktop_shortcuts

    echo
    show_status

    echo
    echo "Installation abgeschlossen."
    echo
    echo "Benutzeroberfläche:"
    echo "  http://localhost:8080"
    echo
    echo "Von einem anderen Gerät im Netzwerk:"
    echo "  http://IP-DES-GATEWAYS:8080"
    echo
    echo "Status anzeigen:"
    echo "  sudo docker compose \\"
    echo "    --env-file ${ENV_PATH} \\"
    echo "    --file ${COMPOSE_PATH} \\"
    echo "    ps"
    echo
    echo "Logs anzeigen:"
    echo "  sudo docker logs --follow gateway"
    echo
    echo "Anwendung stoppen:"
    echo "  sudo docker compose \\"
    echo "    --env-file ${ENV_PATH} \\"
    echo "    --file ${COMPOSE_PATH} \\"
    echo "    stop gateway"
}

main "$@"
