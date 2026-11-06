#!/bin/bash
# helios-suivi-audit.sh — audit de conformité du portail de suivi (projet, E10)
# Lancé en root. Ne modifie rien. Une ligne [OK]/[KO] par exigence E1 à E9, puis « Bilan : n/9 ».
# Code retour 0 si et seulement si 9/9. Un contrôle qui ne peut pas s'exécuter compte comme un échec.
set -u
export LC_ALL=C
readonly WWW=/srv/helios/suivi/www
readonly ARCH=/srv/helios/archives/suivi
readonly REF=/usr/local/share/helios-suivi/units-tp.sha256
score=0; KO=""

# t "description" commande... : exécute un contrôle ; le premier échec de l'exigence est retenu
t() { local d=$1; shift
      if ! "$@" >/dev/null 2>&1; then [[ -z "$KO" ]] && KO="$d"; fi; }
# eq "description" valeur_obtenue valeur_attendue
eq() { [[ "$2" == "$3" ]] || { [[ -z "$KO" ]] && KO="$1 (obtenu : '${2:-vide}', attendu : '$3')"; }; }
fin() { if [[ -z "$KO" ]]; then printf '[OK] %s - %s\n' "$1" "$2"; score=$((score + 1))
        else printf '[KO] %s - %s : %s\n' "$1" "$2" "$KO"; fi; KO=""; }
[[ $EUID -eq 0 ]] || { echo "[KO] audit : doit etre lance en root"; echo "Bilan : 0/9"; exit 1; }

# ---------- E1 : comptes et groupe
eq "gid de suivi" "$(getent group suivi | cut -d: -f3)" "5003"
eq "uid de lea" "$(id -u lea 2>/dev/null)" "5104"
eq "groupe primaire de lea" "$(id -gn lea 2>/dev/null)" "suivi"
eq "vieillissement lea (min:max:alerte:inactif)" "$(getent shadow lea | cut -d: -f4-7)" "1:90:14:7"
t "lea membre de wheel ou ssh-admins" bash -c '! id -nG lea | grep -qwE "wheel|ssh-admins"'
u=$(id -u helios-suivi 2>/dev/null || echo 99999)
t "helios-suivi n est pas un compte systeme" test "$u" -lt 1000
eq "shell de helios-suivi" "$(getent passwd helios-suivi | cut -d: -f7)" "/sbin/nologin"
eq "repertoire de helios-suivi" "$(getent passwd helios-suivi | cut -d: -f6)" "/srv/helios/suivi"
t "/home/helios-suivi existe" test ! -e /home/helios-suivi
fin E1 "comptes lea / helios-suivi et groupe suivi"

# ---------- E2 : setgid et ACL
eq "proprietaire et mode de www" "$(stat -c '%U:%G %a' "$WWW" 2>/dev/null)" "root:suivi 2770"
acl=$(getfacl -p "$WWW" 2>/dev/null)
for e in "user:helios-suivi:rwx" "user:zabbix:--x" "other::---" "default:group::rwx" "default:user:helios-suivi:r-x" "default:other::---"; do
    t "entree ACL absente : $e" grep -qx -- "$e" <<<"$acl"
done
t "zabbix ne peut pas faire stat sur etat.json" runuser -u zabbix -- stat "$WWW/etat.json"
t "zabbix peut lister www" bash -c "! runuser -u zabbix -- ls $WWW"
t "nadia peut lire index.html" bash -c "! runuser -u nadia -- cat $WWW/index.html"
t "helios-suivi ne peut pas lire index.html" runuser -u helios-suivi -- cat "$WWW/index.html"
eq "proprietaire de index.html" "$(stat -c '%U:%G' "$WWW/index.html" 2>/dev/null)" "lea:suivi"
fin E2 "repertoire publie (2770 root:suivi, ACL, zabbix --x)"

# ---------- E3 : script de publication
S=/usr/local/sbin/helios-suivi-publish.sh
t "script de publication absent ou non executable" test -x "$S"
t "syntaxe du script de publication" bash -n "$S"
for m in 'set -euo pipefail' 'flock -n' 'trap cleanup EXIT' 'logger -t' 'TAG="helios-suivi-publish"' 'mv -f'; do
    t "regle absente du script : $m" grep -qF -- "$m" "$S"
done
t "etat.json n est pas un JSON valide" python3 -c "import json,sys; d=json.load(open('$WWW/etat.json')); sys.exit(0 if all(k in d for k in ('genere','hote','derniere_mesure','charge_1min','mem_dispo_ko','mesures')) else 1)"
t "aucune publication reussie depuis 10 min" bash -c "journalctl -t helios-suivi-publish --since '-10min' -o cat --no-pager | grep -q 'rc=0'"
fin E3 "script de publication et etat.json"

# ---------- E4 : units
t "portail arrete" systemctl is-active --quiet helios-suivi.service
t "portail non active au boot" systemctl is-enabled --quiet helios-suivi.service
t "portail non rattache a helios.target" bash -c "systemctl list-dependencies helios.target --plain --no-pager | grep -q helios-suivi.service"
eq "identite du portail" "$(systemctl show -p User --value helios-suivi.service)" "helios-suivi"
eq "MemoryMax" "$(systemctl show -p MemoryMax --value helios-suivi.service)" "134217728"
eq "CPUQuota" "$(systemctl show -p CPUQuotaPerSecUSec --value helios-suivi.service)" "500ms"
eq "Restart" "$(systemctl show -p Restart --value helios-suivi.service)" "on-failure"
sc=$(systemd-analyze security helios-suivi.service --no-pager 2>/dev/null | sed -n 's/.*exposure level for helios-suivi.service: \([0-9.]*\).*/\1/p')
t "score systemd-analyze security > 4.0 ou illisible" awk -v s="${sc:-99}" 'BEGIN{exit !(s<=4.0)}'
eq "HTTP /" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/)" "200"
eq "HTTP /etat.json" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/etat.json)" "200"
t "timer de publication inactif" systemctl is-active --quiet helios-suivi-publish.timer
age=$(( $(date +%s) - $(stat -c %Y "$WWW/etat.json" 2>/dev/null || echo 0) ))
t "etat.json vieux de ${age} s (> 300)" test "$age" -le 300
t "une unit des TP1-TP3 a ete modifiee" sha256sum -c --quiet "$REF"
fin E4 "units du portail et de la publication"

# ---------- E5 : sudo
f=/etc/sudoers.d/92-helios-suivi
eq "droits du fichier sudoers" "$(stat -c '%U:%G %a' "$f" 2>/dev/null)" "root:root 440"
t "visudo -c en echec" visudo -c
t "fichier sudoers illisible" test -r "$f"
t "NOPASSWD present" bash -c "! grep -v '^[[:space:]]*#' $f | grep -q NOPASSWD"
for c in "/usr/bin/systemctl restart helios-suivi.service" "/usr/bin/systemctl status --no-pager helios-suivi.service" \
         "/usr/bin/systemctl start helios-suivi-publish.service" \
         "/usr/bin/journalctl --no-pager -n 100 -u helios-suivi.service" "/usr/bin/journalctl --no-pager -n 100 -u helios-suivi-publish.service"; do
    t "commande deleguee manquante : $c" sudo -l -U lea $c
done
for c in "/usr/bin/systemctl restart sshd" "/usr/bin/systemctl stop helios-suivi.service" "/bin/bash" \
         "/usr/bin/journalctl --no-pager -n 100 -u helios-suivi.service --vacuum-time=1s"; do
    t "commande interdite autorisee : $c" bash -c "! sudo -l -U lea $c"
done
fin E5 "delegation sudo du groupe suivi"

# ---------- E6 : pare-feu
t "firewalld arrete" systemctl is-active --quiet firewalld
eq "zone par defaut" "$(firewall-cmd --get-default-zone 2>/dev/null)" "drop"
t "8080/tcp absent de internal (runtime)" firewall-cmd --zone=internal --query-port=8080/tcp
t "8080/tcp absent de internal (permanent)" firewall-cmd --permanent --zone=internal --query-port=8080/tcp
for z in $(firewall-cmd --get-zones 2>/dev/null); do
    [[ "$z" == internal ]] && continue
    t "8080 ouvert dans la zone $z (ou zone illisible)" bash -c "o=\$(firewall-cmd --zone=$z --list-all) && p=\$(firewall-cmd --permanent --zone=$z --list-all) && ! grep -q 8080 <<< \"\$o \$p\""
done
t "8080 absent du jeu de regles nftables" bash -c "nft list ruleset | grep -q 'dport 8080'"
fin E6 "pare-feu (8080 uniquement en internal)"

# ---------- E7 : non-régression
d=$(sshd -T 2>/dev/null)
for l in "port 2242" "permitrootlogin no" "passwordauthentication no" "allowgroups ssh-admins"; do
    t "sshd : $l" grep -qx "$l" <<<"$d"
done
t "helios-watch-auth.timer inactif" systemctl is-active --quiet helios-watch-auth.timer
t "journald non persistant" bash -c "ls -d /var/log/journal/*/ && grep -qs '^Storage=persistent' /etc/systemd/journald.conf.d/*.conf"
eq "SELinux" "$(getenforce 2>/dev/null)" "Enforcing"
t "lea dans ssh-admins" bash -c "! id -nG lea | grep -qw ssh-admins"
fin E7 "non-regression securite (sshd, watch-auth, journald, SELinux)"

# ---------- E8 : supervision
t "zabbix-agent2 arrete" systemctl is-active --quiet zabbix-agent2
t "zabbix-agent2 non active au boot" systemctl is-enabled --quiet zabbix-agent2
t "sysstat-collect.timer inactif" systemctl is-active --quiet sysstat-collect.timer
t "sondes non declarees" grep -qs 'UserParameter=helios.suivi.http,' /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
eq "helios.suivi.http" "$(zabbix_get -s 127.0.0.1 -k helios.suivi.http 2>/dev/null)" "200"
a=$(zabbix_get -s 127.0.0.1 -k helios.suivi.age 2>/dev/null)
t "helios.suivi.age = '${a:-vide}' (attendu < 300)" bash -c "[[ '$a' =~ ^[0-9]+$ ]] && (( $a < 300 ))"
fin E8 "supervision Zabbix (agent, sondes, sysstat)"

# ---------- E9 : sauvegarde
eq "repertoire /srv/helios/archives" "$(stat -c '%U:%G %a' /srv/helios/archives 2>/dev/null)" "helios:helios 750"
last=$(ls -1t "$ARCH"/suivi-*.tar.gz 2>/dev/null | head -1)
t "aucune archive" test -n "$last"
t "empreinte absente ou invalide" bash -c "cd $ARCH && sha256sum -c --quiet ${last##*/}.sha256"
n=$(ls -1 "$ARCH"/suivi-*.tar.gz 2>/dev/null | wc -l)
t "plus de 7 archives ($n)" test "$n" -le 7
c=$(tar -tzf "$last" 2>/dev/null)
for m in srv/helios/suivi/www/index.html etc/systemd/system/helios-suivi.service etc/sudoers.d/92-helios-suivi \
         etc/zabbix/zabbix_agent2.d/helios-suivi.conf usr/local/sbin/helios-suivi-publish.sh usr/local/sbin/helios-suivi-backup.sh; do
    t "archive incomplete : $m" grep -qx "$m" <<<"$c"
done
t "timer de sauvegarde inactif" systemctl is-active --quiet helios-suivi-backup.timer
eq "Persistent du timer" "$(systemctl show -p Persistent --value helios-suivi-backup.timer)" "yes"
fin E9 "sauvegarde (archive, empreinte, rotation, timer)"

echo "Bilan : ${score}/9"
[[ $score -eq 9 ]]
