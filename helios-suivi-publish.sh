#!/bin/bash
# helios-suivi-publish.sh — publie /srv/helios/suivi/www/etat.json à partir de la télémétrie
# Codes retour : 0 succès · 1 erreur interne · 2 autre instance en cours · 3 prérequis manquant
set -euo pipefail
IFS=$'\n\t'

readonly TAG="helios-suivi-publish"
readonly SRC="/var/lib/helios/telemetry.csv"
readonly WWW="/srv/helios/suivi/www"
readonly DEST="${WWW}/etat.json"
TMP=""

log() { logger -t "$TAG" -p "user.$1" -- "$2"; }

cleanup() {
    local rc=$?
    [[ -n "$TMP" && -e "$TMP" ]] && rm -f -- "$TMP"
    log info "fin d execution rc=${rc}"
    exit "$rc"
}
trap cleanup EXIT
trap 'log warning "signal recu, arret"; exit 1' INT TERM

# Prérequis (code 3)
for cmd in flock logger mktemp hostname wc tail; do
    command -v "$cmd" >/dev/null 2>&1 || { log err "commande absente : $cmd"; exit 3; }
done
[[ -r "$SRC" ]] || { log err "telemetrie illisible : $SRC"; exit 3; }
[[ -d "$WWW" && -w "$WWW" ]] || { log err "repertoire publie non inscriptible : $WWW"; exit 3; }

# Verrou exclusif (code 2) : posé sur le répertoire publié ouvert en LECTURE,
# il n'exige d'écrire nulle part (compatible ProtectSystem=strict).
exec 9<"$WWW"
flock -n 9 || { log warning "une autre instance tourne deja"; exit 2; }

# Lecture et contrôle de la dernière mesure (code 1 si la ligne est invalide)
ligne="$(tail -n 1 -- "$SRC")"
mesures="$(wc -l < "$SRC")"
if [[ ! "$ligne" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}),([0-9]+(\.[0-9]+)?),([0-9]+)$ ]]; then
    log err "ligne de telemetrie invalide : ${ligne:0:80}"
    exit 1
fi
derniere="${BASH_REMATCH[1]}"; charge="${BASH_REMATCH[2]}"; mem="${BASH_REMATCH[4]}"

# Écriture atomique : fichier temporaire dans le MÊME répertoire, puis rename(2)
TMP="$(mktemp "${WWW}/.etat.json.XXXXXX")"
printf '{\n  "genere": "%s",\n  "hote": "%s",\n  "derniere_mesure": "%s",\n  "charge_1min": %s,\n  "mem_dispo_ko": %s,\n  "mesures": %s\n}\n' \
    "$(date --iso-8601=seconds)" "$(hostname)" "$derniere" "$charge" "$mem" "$mesures" > "$TMP"
chmod 0640 "$TMP"
mv -f -- "$TMP" "$DEST"
TMP=""
log info "etat.json publie : mesure ${derniere}, charge ${charge}, ${mesures} mesures"
exit 0
