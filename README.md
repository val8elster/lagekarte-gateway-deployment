# Lagekarte Relais Deployment

Dieses Repository enthält die Installations-, Update- und Deinstallationsskripte für das GPS-Relais der digitalen Lagekarte.

Das Relais wird als Docker-Container auf einem Raspberry Pi betrieben. Die Anwendung liest Positionsdaten von einem seriell angeschlossenen GPS-Empfänger, speichert sie lokal zwischen und überträgt sie an das Backend der digitalen Lagekarte.

Die Installation erfolgt über ein einziges öffentlich erreichbares Bootstrap-Skript.

## Voraussetzungen

Empfohlen wird:

* Raspberry Pi 5
* Raspberry Pi OS Lite 64-Bit
* ARM64-Architektur
* Internetverbindung
* aktivierter SSH-Zugang
* seriell angeschlossener GPS-Empfänger
* gültiger `DEVICE_REGISTRATION_TOKEN`
* bei einem privaten GHCR-Package:

  * GitHub-Benutzername
  * GitHub Personal Access Token classic mit `read:packages`

Docker muss nicht vorinstalliert sein. Das Bootstrap-Skript installiert Docker Engine und Docker Compose automatisch.

## Unterstützte Architektur

Das bereitgestellte Container-Image wird aktuell für folgende Plattform gebaut:

```text
linux/arm64
```

Die lokale Architektur kann auf dem Raspberry Pi geprüft werden:

```bash
dpkg --print-architecture
```

Erwartete Ausgabe:

```text
arm64
```

## Schnellinstallation

Auf dem Raspberry Pi wird nur folgender Befehl ausgeführt:

```bash
curl \
  --fail \
  --silent \
  --show-error \
  --location \
  "https://raw.githubusercontent.com/val8elster/lagekarte-relais-deployment/main/bootstrap.sh?nocache=$(date +%s)" \
  --output /tmp/relais-bootstrap.sh \
&& sudo bash /tmp/relais-bootstrap.sh
```

Das Bootstrap-Skript führt anschließend automatisch folgende Schritte aus:

1. Systemarchitektur prüfen
2. Systemzeit prüfen
3. Docker Engine installieren oder vorhandene Installation verwenden
4. Docker Compose installieren oder vorhandene Installation verwenden
5. Deployment-Dateien aus diesem Repository herunterladen
6. Shell-Skripte syntaktisch prüfen
7. optional bei GitHub Container Registry anmelden
8. GPS-Gerät erkennen
9. Relais-Konfiguration erzeugen
10. Laufzeitumgebung erzeugen
11. Container-Image herunterladen
12. Relais-Container starten

## Interaktive Eingaben

Während der Installation werden mehrere Werte abgefragt.

### Privates GHCR-Package

```text
Ist das GHCR-Package privat? [j/N]:
```

Bei einem privaten Package:

```text
j
```

Danach werden der GitHub-Benutzername und ein GitHub Personal Access Token classic abgefragt.

Der Token benötigt ausschließlich:

```text
read:packages
```

Der Token wird nur für `docker login ghcr.io` verwendet und nicht in der Relais-Konfiguration gespeichert. Bei Bedarf muss ein neues Token erstellt werden.

### Image-Repository

Standardwert:

```text
ghcr.io/val8elster/relais
```

Der Standardwert kann normalerweise mit Enter übernommen werden.

### Image-Version

Standardwert:

```text
dev
```

Für spätere produktive Deployments kann stattdessen beispielsweise ein stabiler Tag verwendet werden:

```text
stable
```

### GPS-Gerät

Das Skript bevorzugt stabile Gerätepfade unter:

```text
/dev/serial/by-id/
```

Beispiel:

```text
/dev/serial/by-id/usb-Prolific_Technology_Inc._USB-Serial_Controller_D-if00-port0
```

Falls kein stabiles Gerät gefunden wird, sucht das Skript nach:

```text
/dev/ttyUSB*
/dev/ttyACM*
```

### Geräte-Registrierungs-Token

Das Backend-Registrierungstoken wird verdeckt abgefragt:

```text
DEVICE_REGISTRATION_TOKEN:
```

Während der Eingabe werden keine Zeichen angezeigt.

Der Token wird lokal gespeichert in:

```text
/opt/relais/.env
```

Die Datei wird mit restriktiven Berechtigungen angelegt.

## Installationsstruktur

Die Deployment-Skripte werden auf dem Raspberry Pi unter folgendem Pfad gespeichert:

```text
/opt/relais-installer/
├── deploy/
│   └── raspberry-pi/
│       └── compose.yml
└── scripts/
    └── linux/
        ├── install.sh
        ├── create-config.sh
        ├── update.sh
        └── uninstall.sh
```

Die Laufzeitdateien der Anwendung liegen getrennt davon unter:

```text
/opt/relais/
├── compose.yml
├── config.toml
├── .env
└── data/
    ├── positions.db
    └── device_api_key
```

Die Verzeichnisse haben unterschiedliche Aufgaben:

```text
/opt/relais-installer
Deployment-, Update- und Deinstallationsskripte

/opt/relais
Gerätekonfiguration, Secrets und persistente Laufzeitdaten
```

## Container-Image

Das Relais-Image wird standardmäßig aus GitHub Container Registry geladen:

```text
ghcr.io/val8elster/relais:dev
```

Das Image enthält keine gerätespezifischen Secrets.

Folgende Werte werden erst auf dem Raspberry Pi bereitgestellt:

* `DEVICE_REGISTRATION_TOKEN`
* Geräte-API-Key
* `config.toml`
* SQLite-Datenbank
* GPS-Gerätepfad

## Containerstatus prüfen

```bash
sudo docker compose \
  --env-file /opt/relais/.env \
  --file /opt/relais/compose.yml \
  ps
```

Alternativ:

```bash
sudo docker ps --filter name=relais
```

Erwarteter Zustand:

```text
Up
```

## Logs anzeigen

Nur aktuelle Logs anzeigen:

```bash
sudo docker logs \
  --since 30s \
  --follow \
  relais
```

Alle vorhandenen Logs anzeigen:

```bash
sudo docker logs --follow relais
```

Die Anzeige wird mit `Strg+C` beendet. Der Container läuft danach weiter.

## Anwendung stoppen

Der Container bleibt vorhanden und kann später wieder gestartet werden:

```bash
sudo docker compose \
  --env-file /opt/relais/.env \
  --file /opt/relais/compose.yml \
  stop relais
```

## Anwendung wieder starten

```bash
sudo docker compose \
  --env-file /opt/relais/.env \
  --file /opt/relais/compose.yml \
  start relais
```

## Anwendung neu starten

```bash
sudo docker compose \
  --env-file /opt/relais/.env \
  --file /opt/relais/compose.yml \
  restart relais
```

## Container entfernen, Daten behalten

```bash
sudo docker compose \
  --env-file /opt/relais/.env \
  --file /opt/relais/compose.yml \
  down \
  --remove-orphans
```

Folgende Daten bleiben dabei erhalten:

```text
/opt/relais/config.toml
/opt/relais/.env
/opt/relais/data/
```

Der Container kann anschließend erneut erstellt werden:

```bash
sudo docker compose \
  --env-file /opt/relais/.env \
  --file /opt/relais/compose.yml \
  up \
  --detach
```

## Update durchführen

Das Update-Skript lädt die aktuelle Deployment-Konfiguration und das aktuelle Container-Image.

```bash
sudo /opt/relais-installer/scripts/linux/update.sh
```

Anschließend prüfen:

```bash
sudo docker compose \
  --env-file /opt/relais/.env \
  --file /opt/relais/compose.yml \
  ps
```

Logs:

```bash
sudo docker logs \
  --since 30s \
  --follow \
  relais
```

## Deinstallation

### Nur Container entfernen

Konfiguration, Token, API-Key und Datenbank bleiben erhalten:

```bash
sudo /opt/relais-installer/scripts/linux/uninstall.sh
```

### Laufzeitdaten vollständig entfernen

```bash
sudo /opt/relais-installer/scripts/linux/uninstall.sh --purge
```

Dabei werden unter anderem entfernt:

* `config.toml`
* `.env`
* Geräte-Registrierungs-Token
* Geräte-API-Key
* SQLite-Datenbank
* noch nicht übertragene Positionsdaten

Die Löschung muss ausdrücklich bestätigt werden.

### Images zusätzlich entfernen

```bash
sudo /opt/relais-installer/scripts/linux/uninstall.sh \
  --purge \
  --remove-images
```

### Vollständige Entfernung

```bash
sudo /opt/relais-installer/scripts/linux/uninstall.sh --all
```

Dadurch werden entfernt:

* Relais-Container
* Compose-Ressourcen
* Relais-Images
* `/opt/relais`
* `/opt/relais-installer`
* lokale GHCR-Anmeldung, sofern durch das Skript vorgesehen

Docker selbst bleibt installiert.

## GPS-Gerät prüfen

```bash
ls -l /dev/serial/by-id/
```

Alternativ:

```bash
ls -l /dev/ttyUSB*
ls -l /dev/ttyACM*
```

Die Gruppen-ID der seriellen Schnittstelle kann geprüft werden mit:

```bash
getent group dialout
```

Die erkannte Gruppen-ID wird über Docker Compose zusätzlich dem Container zugewiesen.

## Persistente Daten prüfen

```bash
sudo ls -la /opt/relais/data
```

Typische Dateien:

```text
positions.db
positions.db-wal
positions.db-shm
device_api_key
```

Der Inhalt von `device_api_key` sollte nicht ausgegeben oder veröffentlicht werden.

## Dateiberechtigungen prüfen

```bash
sudo ls -ldn \
  /opt/relais \
  /opt/relais/data
```

```bash
sudo ls -ln \
  /opt/relais/config.toml \
  /opt/relais/.env
```

Erwartete Berechtigungen:

```text
/opt/relais              root:root     0755
/opt/relais/config.toml  root:root     0644
/opt/relais/.env         root:root     0600
/opt/relais/data         10001:10001   0750
```

Der Containerprozess läuft standardmäßig mit:

```text
UID 10001
GID 10001
```

## Fehlerdiagnose

### Image nicht gefunden

Fehlermeldung:

```text
not found
```

Image-Konfiguration prüfen:

```bash
sudo grep -E \
  '^RELAIS_IMAGE_REPOSITORY=|^RELAIS_VERSION=' \
  /opt/relais/.env
```

Erwartet:

```text
RELAIS_IMAGE_REPOSITORY=ghcr.io/val8elster/relais
RELAIS_VERSION=dev
```

Direkter Test:

```bash
sudo docker pull ghcr.io/val8elster/relais:dev
```

### Zugriff auf privates Package verweigert

Erneut bei GHCR anmelden:

```bash
read -r -s -p "GitHub PAT: " GHCR_TOKEN
echo

printf '%s' "${GHCR_TOKEN}" |
  sudo docker login ghcr.io \
    --username val8elster \
    --password-stdin

unset GHCR_TOKEN
```

Der PAT benötigt:

```text
read:packages
```

### Konfiguration kann nicht gelesen werden

```bash
sudo chown root:root /opt/relais/config.toml
sudo chmod 0644 /opt/relais/config.toml
sudo chmod 0755 /opt/relais
```

Danach:

```bash
sudo docker compose \
  --env-file /opt/relais/.env \
  --file /opt/relais/compose.yml \
  up \
  --detach \
  --force-recreate
```

### SQLite-Datenbank kann nicht geöffnet werden

```bash
sudo chown -R 10001:10001 /opt/relais/data
sudo chmod 0750 /opt/relais/data
```

Vorhandene Dateien korrigieren:

```bash
sudo find /opt/relais/data \
  -type d \
  -exec chmod 0750 {} +
```

```bash
sudo find /opt/relais/data \
  -type f \
  -exec chmod 0640 {} +
```

Container neu erstellen:

```bash
sudo docker compose \
  --env-file /opt/relais/.env \
  --file /opt/relais/compose.yml \
  up \
  --detach \
  --force-recreate
```

### GPS-Gerät nicht gefunden

```bash
ls -l /dev/serial/by-id/
ls -l /dev/ttyUSB*
ls -l /dev/ttyACM*
```

Konfigurierten Pfad prüfen:

```bash
sudo grep '^GPS_DEVICE=' /opt/relais/.env
```

### Container startet ständig neu

```bash
sudo docker ps -a --filter name=relais
```

```bash
sudo docker logs \
  --tail 100 \
  relais
```

## Repository-Struktur

```text
lagekarte-relais-deployment/
├── bootstrap.sh
├── README.md
├── deploy/
│   └── raspberry-pi/
│       └── compose.yml
└── scripts/
    └── linux/
        ├── install.sh
        ├── create-config.sh
        ├── update.sh
        └── uninstall.sh
```

## Lizenz

tbd