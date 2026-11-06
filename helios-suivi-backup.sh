#!/bin/bash
# helios-suivi-backup.sh — sauvegarde du portail de suivi (ACL comprises) + empreinte SHA-256, 7 archives gardées
# Codes retour : 0 succès · 1 erreur interne · 2 autre instance en cours · 3 prérequis manquant
set -euo pipefail
IFS=$'\n\t'

readonly TAG="helios-suivi-backup"
readonly BASE="/srv/helios/archives"
readonly DEST="${BASE}/suivi"
readonly WWW="/srv/helios/suivi/www"
readonly GARDER=7
readonly SOURCES=(
    /srv/helios/suivi
    /etc/systemd/system/helios-suivi.service
    /etc/systemd/system/helios-suivi-publish.service
    /etc/systemd/system/helios-suivi-publish.timer
    /etc/systemd/system/helios-suivi-backup.service
    /etc/systemd/system/helios-suivi-backup.timer
    /etc/sudoers.d/92-helios-suivi
    /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
    /usr/local/sbin/helios-suivi-publish.sh
    /usr/local/sbin/helios-suivi-backup.sh
)
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
[[ $EUID -eq 0 ]] || { log err "doit etre lance en root"; exit 3; }
for cmd in tar sha256sum flock logger mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || { log err "commande absente : $cmd"; exit 3; }
done
[[ -d "$BASE" ]] || { log err "repertoire de sauvegarde absent : $BASE"; exit 3; }
for s in "${SOURCES[@]}"; do
    [[ -e "$s" ]] || { log err "source absente : $s"; exit 3; }
done

# Verrou exclusif (code 2), sans écrire : sur le répertoire de sauvegarde ouvert en lecture
exec 9<"$BASE"
flock -n 9 || { log warning "une autre instance tourne deja"; exit 2; }
# Pendant l'archivage, on prend aussi le verrou de la publication : etat.json ne bouge pas sous tar
exec 8<"$WWW"
flock -w 60 8 || { log err "publication bloquee depuis 60 s, abandon"; exit 1; }

install -d -o root -g root -m 0750 "$DEST"
nom="suivi-$(date +%Y%m%d-%H%M%S).tar.gz"
TMP="$(mktemp "${DEST}/.${nom}.XXXXXX")"
# --acls/--xattrs/--selinux : les ACL et contextes sont dans l'archive ; chemins relatifs à /
tar --acls --xattrs --selinux -czpf "$TMP" -C / "${SOURCES[@]#/}"
mv -f -- "$TMP" "${DEST}/${nom}"
TMP=""
( cd "$DEST" && sha256sum "$nom" > "${nom}.sha256" && sha256sum -c --quiet "${nom}.sha256" ) \
    || { log err "empreinte invalide pour ${nom}"; exit 1; }

# Rotation : on garde les 7 archives les plus récentes
mapfile -t vieux < <(ls -1t "$DEST"/suivi-*.tar.gz | tail -n +$((GARDER + 1)))
for f in "${vieux[@]}"; do
    rm -f -- "$f" "${f}.sha256"
    log info "rotation : suppression de ${f##*/}"
done
log info "archive ${nom} creee ($(du -h "${DEST}/${nom}" | cut -f1)), ${#vieux[@]} ancienne(s) supprimee(s)"
exit 0
