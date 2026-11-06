# PROJET — Portail de suivi des tournées

**Auteur** : Beka Kamewe Manuel — **Date** : 05/11/2026 — **Cible** : srv-core (Rocky Linux 9.8), test réseau depuis srv-edge, 

## 1. Tableau de conformité

| Exigence | Commande de preuve | Sortie utile |
|---|---|---|
| E1 Comptes | `id lea`, `chage -l lea`, `getent passwd helios-suivi` (`02`) | `uid=5104(lea) gid=5003(suivi)` · min 1 / max 90 / alerte 14 / inactif 7 j · `helios-suivi` uid 994, `/srv/helios/suivi`, `/sbin/nologin` |
| E2 setgid + ACL | `ls -ld`, `getfacl`, `runuser` (`03`, `04`) | `drwxrws---+ root suivi www` · `user:helios-suivi:rwx`, `user:zabbix:--x`, `default:group::rwx`, `other::---` · zabbix : `ls` refusé, `stat` OK · nadia : `cat index.html` refusé |
| E3 Publication | codes provoqués, `json.tool` (`05`) | rc `0` (helios-suivi), `2` (verrou tenu), `3` (www non inscriptible) · JSON valide avec les 6 champs |
| E4 Units | `systemctl status`, `kill -9`, `systemd-analyze security`, `list-timers` (`06`, `07`, `08`) | `active`, relancé en 2 s (`NRestarts=1`) · exposition **1.1 OK** · `/` et `/etat.json` → 200 · timer toutes les 2 min · units TP1-TP3 inchangées (`preuves/units-tp-avant.sha256`) |
| E5 sudo | `visudo -c`, `sudo -l -U lea …` (`09`) | 5 commandes figées, sans NOPASSWD · `systemctl restart sshd` → rien, rc=1 |
| E6 Pare-feu | `firewall-cmd --list-ports` (`10`), tests depuis srv-edge (`14`) | 8080/tcp seulement dans `internal` (runtime + permanent), zone par défaut `drop` · `10.42.0.10:8080` → 200, `192.168.56.10:8080` → `No route to host` |
| E7 Non-régression | `sshd -T` (`11`) | `port 2242`, `permitrootlogin no`, `passwordauthentication no`, `allowgroups ssh-admins` · watch-auth actif · SELinux `Enforcing` · lea refusé en SSH (`not allowed because none of user's groups are listed in AllowGroups`) |
| E8 Supervision | `zabbix_get` (`12`) | zabbix-agent2 et sysstat-collect actifs · `helios.suivi.http` = 200 · `helios.suivi.age` < 300 |
| E9 Sauvegarde | `ls`, `sha256sum -c` (`13`) | `/srv/helios/archives` `helios:helios 750` · 7 archives maximum, empreintes `Réussi` · timer 03:15, `Persistent=yes` |
| E10 Audit (bonus) | `helios-suivi-audit.sh` (`01`, `preuves/audit.txt`) | `Bilan : 9/9`, rc=0, aussi après redémarrage · `[KO]` détecté pour : portail arrêté, 8080 retiré, etat.json > 5 min, sudo `restart sshd`, empreinte invalide |

## 2. Justifications

**(a) Durcissement (score 1.1)**
- `ProtectSystem=strict` sans `ReadWritePaths`, `ReadOnlyPaths=/tmp /var/tmp /run /dev/shm` : le serveur ne peut écrire nulle part.
- `CapabilityBoundingSet=` vide, `NoNewPrivileges`, `PrivateUsers/Devices/IPC`, `ProtectKernel*`, `SystemCallFilter=@system-service`.
- **Adaptée** : `RestrictAddressFamilies=AF_UNIX` (celle du TP1) aurait bloqué le socket HTTP → `AF_INET AF_INET6`. `PrivateNetwork` et `IPAddressDeny` sont impossibles pour un service réseau ; c'est firewalld qui filtre.

**(b) `--x` et pas `r-x` pour zabbix**
- `x` permet d'atteindre un fichier connu (`stat etat.json`) ; `r` permet de lister le répertoire.
- La sonde n'a besoin que de `stat` : `r-x` exposerait inutilement les noms des fichiers de l'équipe.
- Sans l'entrée, j'ai observé `stat … Permission non accordée` (rc=1) : la sonde d'âge était cassée.

**(c) Joker `*` derrière `journalctl`**
- Le joker laisse ajouter n'importe quelle option exécutée en root : `--vacuum-time=1s` efface tous les journaux (dont les traces d'intrusion), `-u sshd` lit d'autres journaux, `--file`/`-D` d'autres fichiers ; sans `--no-pager`, `less` en root permet `!sh`.
- Ma règle écrit chaque commande avec tous ses arguments, `--no-pager` compris. sudo refuse donc tout ajout : `… --vacuum-time=1s` → rc=1.

## 3. Restauration (E9.5)

- **(a)** Extraction de la dernière archive dans `/root/restauration-test`, puis `diff` des `getfacl -R` production/test → `ACL identiques`.
- **(b)** Restauration de `index.html` seul :
  - suppression de `index.html` à 14:22:35.817 : le portail affiche « Directory listing » ;
  - `tar --acls --xattrs --selinux -xzpf <archive> -C / srv/helios/suivi/www/index.html` → rc=0 à 14:22:35.889 ;
  - le fichier revient en `lea:suivi` avec ses ACL d'origine (`diff` vide), sans toucher à `etat.json`.
- **Temps** : 72 ms pour les commandes (lancées par script). À la main, il faut ajouter le temps de taper la commande (procédure dans `RUNBOOK.md`).

## 4. Mesure sous charge (2000 `curl`, 20,2 s)

| | Avant | Après |
|---|---|---|
| `CPUUsageNSec` | 0,19 s | 2,39 s |
| `MemoryCurrent` | 9,6 Mio | 9,8 Mio |
| `nr_throttled` | 3 | 3 |

`sar -u 1` pendant la boucle : environ 25 % user et 27 % system, surtout dus aux processus `curl`. Le portail a utilisé 2,2 s de CPU en 20,2 s, soit 11 % d'un CPU : **le quota de 50 % n'a pas joué** (aucun nouvel étranglement).

## 5. Limites connues

- L'UID 5104 imposé pour lea était déjà pris par `sysops` (créé au TP3) : sysops est passé en 5110.
- Le code retour 1 (ligne de télémétrie invalide) est prévu dans le script mais pas provoqué : il aurait fallu modifier `telemetry.csv` du TP1.
- `python3 -m http.server` est mono-processus, sans TLS. Avec une journée de plus : nginx en HTTPS, et le bonus E8.5 (serveur Zabbix et déclencheurs), non fait.
- Les commandes de mise en place ont été exécutées par des scripts lancés en SSH depuis le poste Windows.
