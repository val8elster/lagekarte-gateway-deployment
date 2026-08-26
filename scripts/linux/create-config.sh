#!/usr/bin/env bash

set -Eeuo pipefail

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

CONFIG_PATH="${PROJECT_DIR}/config.toml"

DEVICE_UUID=""
DEVICE_NAME=""

BAUD_RATE=4800
MIN_POSITION_INTERVAL_SECONDS=10
MIN_DISTANCE_METERS="0.0"

BACKEND_URL="https://backend.lagekarte.elster.dev"
DATABASE_PATH="data/positions.db"

SEND_MODE="batch"
SEND_INTERVAL_SECONDS=60
SEND_BATCH_LIMIT=20


# Gibt die Verwendung des Config-Skripts aus.
#
# Ausgabe:
#   Schreibt alle verfügbaren Parameter und ein Beispiel in die
#   Standardausgabe.
usage() {
    cat <<EOF
Verwendung:

  $0 [Optionen]

Optionen:
  --config-path PFAD
  --device-uuid UUID
  --device-id UUID
  --device-name NAME
  --baud-rate RATE
  --min-position-interval-seconds SEKUNDEN
  --min-distance-meters METER
  --backend-url URL
  --database-path PFAD
  --send-mode batch|direct
  --send-interval-seconds SEKUNDEN
  --send-batch-limit ANZAHL
  -h, --help

Hinweise:

  --device-uuid setzt die Geräte-UUID manuell.

  --device-id wird aus Kompatibilitätsgründen weiterhin unterstützt,
  ist aber nur ein Alias für --device-uuid.

  Wird keine Geräte-UUID angegeben, erzeugt das Skript eine stabile
  UUID auf Grundlage der Linux machine-id.

Beispiel:

  $0 \\
    --config-path "/opt/gaetway/config.toml" \\
    --device-name "GPS Gateway Linux" \\
    --device-uuid "a26186e1-9238-5c42-a933-3a4c69030dbd" \\
    --backend-url "https://backend.lagekarte.elster.dev" \\
    --database-path "data/positions.db"
EOF
}


# Gibt eine Fehlermeldung aus und beendet das Skript.
#
# Eingabe:
#   Beliebiger Fehlertext.
#
# Ausgabe:
#   Schreibt den Fehler nach stderr und beendet das Skript mit Exitcode 1.
error() {
    echo "Fehler: $*" >&2
    exit 1
}


# Maskiert einen String für die Verwendung als TOML-String.
#
# Eingabe:
#   Zu maskierender String.
#
# Ausgabe:
#   Gibt den für TOML maskierten String über stdout zurück.
escape_toml_string() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"

    printf '%s' "${value}"
}


# Prüft, ob ein Wert eine nicht negative ganze Zahl ist.
#
# Eingabe:
#   Zu prüfender String.
#
# Ausgabe:
#   Gibt Exitcode 0 für eine ganze Zahl, andernfalls Exitcode 1 zurück.
is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}


# Prüft, ob ein Wert eine nicht negative Dezimalzahl ist.
#
# Eingabe:
#   Zu prüfender String.
#
# Ausgabe:
#   Gibt Exitcode 0 für eine gültige Zahl, andernfalls Exitcode 1 zurück.
is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}


# Prüft, ob ein Wert größer als null ist.
#
# Eingabe:
#   Zu prüfende ganze Zahl.
#
# Ausgabe:
#   Gibt Exitcode 0 zurück, wenn der Wert größer als null ist.
is_positive_integer() {
    is_integer "$1" && (( "$1" > 0 ))
}


# Prüft, ob ein String dem üblichen UUID-Format entspricht.
#
# Eingabe:
#   Zu prüfende UUID.
#
# Ausgabe:
#   Gibt Exitcode 0 für eine syntaktisch gültige UUID zurück.
is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}


# Ermittelt die machine-id des Linux-Hosts.
#
# Ausgabe:
#   Gibt die machine-id über stdout zurück. Falls keine machine-id vorhanden
#   ist, wird das Skript mit einem Fehler beendet.
read_machine_id() {
    local machine_id=""

    if [[ -r "/etc/machine-id" ]]; then
        machine_id="$(
            tr -d '[:space:]' < /etc/machine-id
        )"
    elif [[ -r "/var/lib/dbus/machine-id" ]]; then
        machine_id="$(
            tr -d '[:space:]' < /var/lib/dbus/machine-id
        )"
    fi

    if [[ -z "${machine_id}" ]]; then
        error \
            "Keine Linux machine-id gefunden. Bitte --device-uuid manuell setzen."
    fi

    printf '%s' "${machine_id}"
}


# Erzeugt eine stabile UUIDv5 aus der Linux machine-id.
#
# Schnittstelle:
#   Verwendet bevorzugt Python 3 und die Standardbibliothek uuid.
#
# Ausgabe:
#   Gibt eine RFC-4122-kompatible UUIDv5 über stdout zurück.
generate_host_uuid() {
    local machine_id=""

    machine_id="$(read_machine_id)"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "${machine_id}" <<'PYTHON'
import sys
import uuid

machine_id = sys.argv[1]

namespace = uuid.UUID("07f4c8d4-ef59-4dde-90ef-b9db03aa2074")

print(uuid.uuid5(namespace, f"gateway:{machine_id}"))
PYTHON
        return
    fi

    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen \
            --sha1 \
            --namespace @dns \
            --name "gateway-${machine_id}"
        return
    fi

    error \
        "Weder python3 noch uuidgen ist installiert. Bitte --device-uuid manuell setzen."
}


# Ermittelt einen sinnvollen Standardnamen für das Gerät.
#
# Ausgabe:
#   Gibt den Hostnamen als Vorschlag zurück. Ist kein Hostname verfügbar,
#   wird "GPS Gateway Linux" zurückgegeben.
default_device_name() {
    local host_name=""

    if command -v hostnamectl >/dev/null 2>&1; then
        host_name="$(
            hostnamectl --static 2>/dev/null || true
        )"
    fi

    if [[ -z "${host_name}" ]] &&
        command -v hostname >/dev/null 2>&1
    then
        host_name="$(
            hostname 2>/dev/null || true
        )"
    fi

    if [[ -z "${host_name}" ]]; then
        host_name="GPS Gateway Linux"
    else
        host_name="GPS Gateway ${host_name}"
    fi

    printf '%s' "${host_name}"
}


# Fragt den Gerätenamen interaktiv ab.
#
# Eingabe:
#   Verwendet den Hostnamen als Vorschlag.
#
# Ausgabe:
#   Setzt die globale Variable DEVICE_NAME.
read_device_name() {
    local default_name=""
    local entered_name=""

    default_name="$(default_device_name)"

    while [[ -z "${DEVICE_NAME//[[:space:]]/}" ]]; do
        read -r -p \
            "Bitte Gerätenamen eingeben [${default_name}]: " \
            entered_name

        if [[ -z "${entered_name//[[:space:]]/}" ]]; then
            DEVICE_NAME="${default_name}"
        else
            DEVICE_NAME="${entered_name}"
        fi
    done
}


# Verarbeitet alle Kommandozeilenparameter.
#
# Eingabe:
#   Alle an das Skript übergebenen Parameter.
#
# Ausgabe:
#   Setzt die entsprechenden globalen Konfigurationsvariablen.
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config-path)
                [[ $# -ge 2 ]] ||
                    error "Wert für --config-path fehlt."

                CONFIG_PATH="$2"
                shift 2
                ;;

            --device-uuid|--device-id)
                [[ $# -ge 2 ]] ||
                    error "Wert für $1 fehlt."

                DEVICE_UUID="$2"
                shift 2
                ;;

            --device-name)
                [[ $# -ge 2 ]] ||
                    error "Wert für --device-name fehlt."

                DEVICE_NAME="$2"
                shift 2
                ;;

            --baud-rate)
                [[ $# -ge 2 ]] ||
                    error "Wert für --baud-rate fehlt."

                BAUD_RATE="$2"
                shift 2
                ;;

            --min-position-interval-seconds)
                [[ $# -ge 2 ]] ||
                    error \
                        "Wert für --min-position-interval-seconds fehlt."

                MIN_POSITION_INTERVAL_SECONDS="$2"
                shift 2
                ;;

            --min-distance-meters)
                [[ $# -ge 2 ]] ||
                    error \
                        "Wert für --min-distance-meters fehlt."

                MIN_DISTANCE_METERS="$2"
                shift 2
                ;;

            --backend-url)
                [[ $# -ge 2 ]] ||
                    error "Wert für --backend-url fehlt."

                BACKEND_URL="$2"
                shift 2
                ;;

            --database-path)
                [[ $# -ge 2 ]] ||
                    error "Wert für --database-path fehlt."

                DATABASE_PATH="$2"
                shift 2
                ;;

            --send-mode)
                [[ $# -ge 2 ]] ||
                    error "Wert für --send-mode fehlt."

                SEND_MODE="$2"
                shift 2
                ;;

            --send-interval-seconds)
                [[ $# -ge 2 ]] ||
                    error \
                        "Wert für --send-interval-seconds fehlt."

                SEND_INTERVAL_SECONDS="$2"
                shift 2
                ;;

            --send-batch-limit)
                [[ $# -ge 2 ]] ||
                    error "Wert für --send-batch-limit fehlt."

                SEND_BATCH_LIMIT="$2"
                shift 2
                ;;

            -h|--help)
                usage
                exit 0
                ;;

            *)
                error "Unbekannte Option: $1"
                ;;
        esac
    done
}


# Prüft alle Konfigurationswerte vor dem Schreiben der TOML-Datei.
#
# Ausgabe:
#   Beendet das Skript beim ersten ungültigen Konfigurationswert.
validate_configuration() {
    if [[ -z "${DEVICE_UUID}" ]]; then
        DEVICE_UUID="$(generate_host_uuid)"

        echo
        echo "Keine Geräte-UUID angegeben."
        echo "Aus der Linux machine-id wurde folgende stabile UUID erzeugt:"
        echo "  ${DEVICE_UUID}"
    fi

    is_uuid "${DEVICE_UUID}" ||
        error \
            "device UUID muss eine gültige RFC-4122-UUID sein: ${DEVICE_UUID}"

    if [[ -z "${DEVICE_NAME//[[:space:]]/}" ]]; then
        read_device_name
    fi

    is_positive_integer "${BAUD_RATE}" ||
        error "Baudrate muss eine positive ganze Zahl sein."

    is_positive_integer "${MIN_POSITION_INTERVAL_SECONDS}" ||
        error \
            "min_position_interval_seconds muss größer als 0 sein."

    is_number "${MIN_DISTANCE_METERS}" ||
        error \
            "min_distance_meters muss eine nicht negative Zahl sein."

    is_positive_integer "${SEND_INTERVAL_SECONDS}" ||
        error \
            "send_interval_seconds muss größer als 0 sein."

    is_positive_integer "${SEND_BATCH_LIMIT}" ||
        error \
            "send_batch_limit muss größer als 0 sein."

    case "${SEND_MODE}" in
        batch|direct)
            ;;

        *)
            error "send_mode muss 'batch' oder 'direct' sein."
            ;;
    esac

    if [[ -z "${BACKEND_URL//[[:space:]]/}" ]]; then
        error "backend-url darf nicht leer sein."
    fi

    if [[ -z "${DATABASE_PATH//[[:space:]]/}" ]]; then
        error "database-path darf nicht leer sein."
    fi
}


# Fügt eine serielle Schnittstelle zur Auswahlliste hinzu.
#
# Eingabe:
#   Gerätepfad und lesbarer Gerätename.
#
# Ausgabe:
#   Ergänzt PORTS und PORT_NAMES, sofern der Pfad existiert und noch nicht
#   enthalten ist.
add_port() {
    local path="$1"
    local name="$2"
    local existing=""

    [[ -e "${path}" ]] || return 0

    for existing in "${PORTS[@]:-}"; do
        if [[ "${existing}" == "${path}" ]]; then
            return 0
        fi
    done

    PORTS+=("${path}")
    PORT_NAMES+=("${name}")
}


# Sucht nach seriellen Schnittstellen für den GPS-Empfänger.
#
# Ausgabe:
#   Befüllt die Arrays PORTS und PORT_NAMES mit möglichen Geräten.
find_gps_ports() {
    local device=""
    local basename_value=""

    echo
    echo "Suche GPS-Schnittstelle ..."

    declare -g -a PORTS=()
    declare -g -a PORT_NAMES=()

    if [[ -d "/dev/serial/by-id" ]]; then
        while IFS= read -r device; do
            [[ -n "${device}" ]] || continue

            basename_value="$(basename "${device}")"

            if [[ "${basename_value}" =~ GPS|Navilock|u-blox|Prolific|CP210|CH340|Serial ]]; then
                add_port "${device}" "${basename_value}"
            fi
        done < <(
            find /dev/serial/by-id \
                -maxdepth 1 \
                -type l \
                -print 2>/dev/null |
                sort
        )
    fi

    if [[ ${#PORTS[@]} -eq 0 ]] &&
        [[ -d "/dev/serial/by-id" ]]
    then
        while IFS= read -r device; do
            [[ -n "${device}" ]] || continue

            add_port \
                "${device}" \
                "$(basename "${device}")"
        done < <(
            find /dev/serial/by-id \
                -maxdepth 1 \
                -type l \
                -print 2>/dev/null |
                sort
        )
    fi

    if [[ ${#PORTS[@]} -eq 0 ]]; then
        shopt -s nullglob

        for device in \
            /dev/ttyUSB* \
            /dev/ttyACM* \
            /dev/ttyAMA* \
            /dev/ttyS*
        do
            add_port \
                "${device}" \
                "$(basename "${device}")"
        done

        shopt -u nullglob
    fi

    if [[ ${#PORTS[@]} -eq 0 ]]; then
        error \
            "Keine serielle Schnittstelle gefunden. Ist der GPS-Empfänger angeschlossen?"
    fi
}


# Lässt den Benutzer eine serielle GPS-Schnittstelle auswählen.
#
# Ausgabe:
#   Setzt SELECTED_PORT und SELECTED_NAME.
select_gps_port() {
    local index=""
    local selection=""

    if [[ ${#PORTS[@]} -gt 1 ]]; then
        echo
        echo "Mehrere mögliche Schnittstellen gefunden:"

        for index in "${!PORTS[@]}"; do
            printf '[%d] %s (%s)\n' \
                "${index}" \
                "${PORTS[$index]}" \
                "${PORT_NAMES[$index]}"
        done

        while true; do
            read -r -p \
                "Bitte Index auswählen: " \
                selection

            if [[ "${selection}" =~ ^[0-9]+$ ]] &&
                (( selection >= 0 && selection < ${#PORTS[@]} ))
            then
                break
            fi

            echo "Ungültige Auswahl." >&2
        done

        SELECTED_PORT="${PORTS[$selection]}"
        SELECTED_NAME="${PORT_NAMES[$selection]}"
    else
        SELECTED_PORT="${PORTS[0]}"
        SELECTED_NAME="${PORT_NAMES[0]}"
    fi

    readonly SELECTED_PORT
    readonly SELECTED_NAME

    echo
    echo "Gewählt:"
    echo "  Port:   ${SELECTED_PORT}"
    echo "  Gerät:  ${SELECTED_NAME}"
}


# Schreibt die validierte Konfiguration atomar als TOML-Datei.
#
# Schnittstelle:
#   Die erzeugte Datei entspricht der von gateway-config erwarteten
#   AppConfig-Struktur.
#
# Ausgabe:
#   Erstellt oder ersetzt CONFIG_PATH.
write_configuration() {
    local config_dir=""
    local temporary_config=""

    local device_uuid_escaped=""
    local device_name_escaped=""
    local selected_port_escaped=""
    local database_path_escaped=""
    local backend_url_escaped=""
    local send_mode_escaped=""

    config_dir="$(dirname "${CONFIG_PATH}")"

    if [[ "${config_dir}" != "." ]]; then
        mkdir -p -- "${config_dir}"
    fi

    device_uuid_escaped="$(
        escape_toml_string "${DEVICE_UUID}"
    )"

    device_name_escaped="$(
        escape_toml_string "${DEVICE_NAME}"
    )"

    selected_port_escaped="$(
        escape_toml_string "${SELECTED_PORT}"
    )"

    database_path_escaped="$(
        escape_toml_string "${DATABASE_PATH}"
    )"

    backend_url_escaped="$(
        escape_toml_string "${BACKEND_URL}"
    )"

    send_mode_escaped="$(
        escape_toml_string "${SEND_MODE}"
    )"

    temporary_config="${CONFIG_PATH}.tmp"

    cleanup() {
        rm -f -- "${temporary_config}"
    }

    trap cleanup EXIT

    cat > "${temporary_config}" <<EOF
[device]
id = "${device_uuid_escaped}"
name = "${device_name_escaped}"

[gps]
port = "${selected_port_escaped}"
baud_rate = ${BAUD_RATE}
min_position_interval_seconds = ${MIN_POSITION_INTERVAL_SECONDS}
min_distance_meters = ${MIN_DISTANCE_METERS}

[database]
path = "${database_path_escaped}"

[backend]
url = "${backend_url_escaped}"

[relay]
send_mode = "${send_mode_escaped}"
send_interval_seconds = ${SEND_INTERVAL_SECONDS}
send_batch_limit = ${SEND_BATCH_LIMIT}
EOF

    mv -f -- "${temporary_config}" "${CONFIG_PATH}"
    trap - EXIT

    echo
    echo "Config geschrieben nach:"
    echo "  ${CONFIG_PATH}"
    echo
    echo "Gerätename: ${DEVICE_NAME}"
    echo "Geräte-UUID: ${DEVICE_UUID}"
    echo
    echo "Inhalt:"
    echo

    cat -- "${CONFIG_PATH}"
}


# Führt die vollständige Konfigurationserstellung aus.
#
# Ausgabe:
#   Erzeugt eine validierte config.toml für das Rust-Gateway.
main() {
    parse_arguments "$@"
    validate_configuration
    find_gps_ports
    select_gps_port
    write_configuration
}

main "$@"