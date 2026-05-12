# Proxmox Bastion Discord Webhook Watchdog

Tämä skripti valvoo Proxmox-nodeja pingillä, lähettää tarvittaessa WOL-komentoja ja raportoi Discordiin ilman turhaa spämmiä.

## Toimintalogiikka (production-ready)

### Node offline -ilmoitukset (yksi incident kerrallaan)
Ilmoitukset lähetetään vain seuraavissa vaiheissa:

1. heti kun node menee offline
2. kun offlinea on kestänyt 10 min
3. kun offlinea on kestänyt 1 h
4. kun offlinea on kestänyt 24 h

24h jälkeen samasta incidentistä ei lähetetä enää uusia offline-ilmoituksia.

### Cluster offline -ilmoitukset
Jos **2 tai enemmän nodeja** on yhtä aikaa offline, lähetetään lisäksi cluster-tason ilmoitukset samoilla vaiheilla:

1. heti
2. 10 min
3. 1 h
4. 24 h

### WOL-aikataulu
WOL lähetetään vain jos node on edelleen offline. Aikataulu incidentin alusta:

1. 1 min
2. 10 min
3. 30 min

WOL-lähetyksistä ei lähetetä Discord-viestiä joka kerta (ei spämmiä).

### Node palaa online
Kun node palaa online:

- jos se tapahtuu `WOL_SUCCESS_WINDOW`-ajan sisällä (oletus 10 min) viimeisestä WOL-lähetyksestä, viesti on: **Node Online (WOL Success)**
- muuten viesti on normaali: **Node Online**

## Discord-viestien design
Skripti käyttää Discord embed -viestejä:

- selkeät otsikot (Node Offline / Cluster Offline / Node Online / WOL Success)
- värit tilan mukaan
- timestamp
- host footer
- logo thumbnail + avatar

Logo on konfiguroitava muuttujalla `DISCORD_LOGO_URL`.

## Konfiguraatio
Skripti lukee konfiguraation tiedostosta:

- `/etc/pve-wol-watch.conf`

Esimerkki:

```bash
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
DISCORD_USERNAME="PVE Bastion Watchdog"
DISCORD_LOGO_URL="https://i.imgur.com/zlKIds2.png"

PING_COUNT=1
PING_TIMEOUT=1

WOL_SUCCESS_WINDOW=600

OFFLINE_NOTIFY_SCHEDULE=(0 600 3600 86400)
WOL_SCHEDULE=(60 600 1800)

NODES=(
  "pve4 172.16.67.4 98:e7:f4:f2:af:7e"
  "pve5 172.16.67.5 80:ce:62:2f:6a:d6"
  "pve6 172.16.67.6 98:e7:f4:ee:c2:00"
)
```

## Asennus

1. Asenna riippuvuudet:
   - `bash`
   - `curl`
   - `iputils-ping`
   - `wakeonlan`
2. Kopioi skripti esim. `/usr/local/bin/pve-script.sh`
3. Tee executable:
   - `chmod +x /usr/local/bin/pve-script.sh`
4. Luo `/etc/pve-wol-watch.conf`
5. Aja skripti ajastetusti (suositus: systemd timer 10-30 sek välein)

## Huomio

- Skripti käyttää lockia (`flock`), joten päällekkäisiä ajoja ei tapahdu.
- Incident-tila tallennetaan hakemistoon `/var/lib/pve-wol`.
