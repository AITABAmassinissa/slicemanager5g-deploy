#!/usr/bin/env bash
# Prépare un nouveau nœud Kubernetes imbriqué dans un Pod Linux privilégié.
# Usage : sudo bash all_nodes.sh [--node-ip IP] [--interface eth0]
# Après préparation : sudo bash all_nodes.sh --start-only
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

K8S_VERSION=v1.35.9
CNI_VERSION=v1.9.1
NODE_IFACE=eth0
NODE_IP=
START_ONLY=0
DATA_ROOT=/var/lib/k8s-lab
MIN_FREE_GIB=10
CONFIG_DIR=/etc/kubernetes-lab
RUNTIME_CONFIG=/etc/containerd-lab/config.toml
RUNTIME_STATE=/run/containerd-lab
RUNTIME_SOCKET=/run/containerd-lab/containerd.sock

# Animation d'activité : aucun pourcentage inventé pour les commandes CRI.
run_with_status() (
  set +e
  trap - ERR
  local label=$1 logfile=$2
  shift 2
  local pid= rc=0 start=$SECONDS tick=0 elapsed completed
  local frames=('|' '/' '-' '\')
  mkdir -p "$(dirname "$logfile")" || exit 1
  : > "$logfile" || exit 1
  chmod 0600 "$logfile"
  cleanup_status() {
    if [[ -n $pid ]]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    if [[ -t 1 ]]; then printf '\r\033[2K'; fi
  }
  trap cleanup_status EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Groupe séparé pour arrêter aussi les descendants si l'utilisateur annule.
  setsid "$@" > "$logfile" 2>&1 8>&- &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS-start))
    completed=$(grep -c '^\[config/images\] Pulled ' "$logfile" || true)
    if [[ -t 1 ]]; then
      printf '\r\033[2K[%s] %s | %02d:%02d' "${frames[tick%4]}" "$label" "$((elapsed/60))" "$((elapsed%60))"
      if ((completed>0)); then printf ' | %s images terminées' "$completed"; fi
    elif ((tick%50==0)); then
      printf '[EN COURS] %s | %ss | images terminées : %s\n' "$label" "$elapsed" "$completed"
    fi
    tick=$((tick+1))
    sleep 0.2
  done
  wait "$pid"
  rc=$?
  pid=
  if [[ -t 1 ]]; then printf '\r\033[2K'; fi
  elapsed=$((SECONDS-start))
  if ((rc==0)); then
    printf '[OK] %s (%02d:%02d)\n' "$label" "$((elapsed/60))" "$((elapsed%60))"
    cat "$logfile"
  else
    printf '[ÉCHEC] %s (code %s) — journal : %s\n' "$label" "$rc" "$logfile" >&2
    tail -n 40 "$logfile" >&2
  fi
  exit "$rc"
)

die() { echo "ERREUR : $*" >&2; exit 1; }
help() {
  cat <<'EOF'
Préparation d'un nœud Ubuntu 24.04/26.04 dans un Pod privilégié.
Stockage local éphémère dans /var/lib/k8s-lab, sans PVC.

  sudo bash all_nodes.sh [options]
  --node-ip IP              IP IPv4 du nœud (détection sur eth0 par défaut)
  --interface NOM           Interface à utiliser (défaut eth0)
  --kubernetes-version VER  Défaut v1.35.9, identique sur tous les nœuds
  --cni-version VER         Défaut v1.9.1
  --min-free-gib N          Espace libre minimal avant installation (défaut 10 Gio)
  --start-only              Relance les processus déjà préparés, sans installation
  --help                    Affiche cette aide

Ce script ne lance pas kubeadm init ou join. Kubelet attend automatiquement
les fichiers que ces commandes vont générer. Pas de kubeadm reset automatique.
EOF
}
while (($#)); do
  case "$1" in
    --node-ip|--interface|--kubernetes-version|--cni-version|--min-free-gib)
      (($# >= 2)) || die "Valeur manquante pour $1"
      case "$1" in
        --node-ip) NODE_IP=$2;; --interface) NODE_IFACE=$2;;
        --kubernetes-version) K8S_VERSION=$2;; --cni-version) CNI_VERSION=$2;;
        --min-free-gib) MIN_FREE_GIB=$2;;
      esac
      shift 2;;
    --start-only) START_ONLY=1; shift;;
    -h|--help) help; exit 0;;
    *) die "Option inconnue : $1";;
  esac
done
[[ $EUID == 0 ]] || die "Exécuter avec sudo bash all_nodes.sh."
if ((START_ONLY)); then
  [[ -x /usr/local/sbin/k8s-lab-start ]] || die "Préparation absente."
  exec /usr/local/sbin/k8s-lab-start
fi
trap 'echo "Échec de la préparation à la ligne $LINENO. Corriger avant de continuer." >&2' ERR
[[ -r /etc/os-release ]] || die "Distribution Linux non identifiée."
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || die "Script prévu pour Ubuntu."
[[ $K8S_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version Kubernetes invalide."
[[ $CNI_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version CNI invalide."
[[ $NODE_IFACE =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "Interface invalide."
[[ $MIN_FREE_GIB =~ ^[1-9][0-9]?$ ]] || die "--min-free-gib doit être un entier entre 1 et 99."
install -d -m 0755 "$DATA_ROOT"
[[ -w $DATA_ROOT ]] || die "Stockage local non accessible en écriture."
[[ ! -f /etc/kubernetes/kubelet.conf && ! -f /etc/kubernetes/admin.conf ]] ||
  die "Nœud déjà configuré : utiliser --start-only, pas une nouvelle installation."
[[ -z $(pgrep -x kubelet || true) ]] || die "Un kubelet existe déjà. Ne pas modifier un nœud actif."
[[ $(awk 'NR>1 {n++} END {print n+0}' /proc/swaps) == 0 ]] ||
  die "Swap actif. Le script ne désactive pas le swap du noyau partagé."
[[ $(df -Pk "$DATA_ROOT" | awk 'END {print $4}') -ge $((MIN_FREE_GIB*1048576)) ]] ||
  die "Moins de $MIN_FREE_GIB Gio libres sur le stockage local. Vérifier le disque du worker hébergeur."
echo "Stockage local : $DATA_ROOT (éphémère, partagé avec les autres Pods du worker)."
df -h "$DATA_ROOT"
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || die "Ce lab attend cgroups v2."
[[ -w /sys/fs/cgroup ]] || die "Cgroups non accessibles en écriture."

echo '[1/7] Dépendances Ubuntu'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -o Dpkg::Progress-Fancy=1 install -y curl ca-certificates conntrack socat ethtool iproute2 \
  iptables util-linux procps python3 python3-yaml
# Dans webtop, Docker fournit déjà containerd et runc : ne pas les remplacer.
if ! command -v containerd >/dev/null || ! command -v runc >/dev/null; then
  apt-get -o Dpkg::Progress-Fancy=1 install -y containerd runc
fi
for bin in containerd runc ctr; do command -v "$bin" >/dev/null || die "$bin absent."; done
NODE_IP=${NODE_IP:-$(ip -4 -o addr show dev "$NODE_IFACE" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')}
python3 - "$NODE_IP" <<'PY'
import ipaddress, sys
ip = ipaddress.IPv4Address(sys.argv[1])
if ip.is_loopback or ip.is_unspecified: raise SystemExit('IP du nœud invalide')
PY
ip -4 -o addr show dev "$NODE_IFACE" | awk '{split($4,a,"/"); print a[1]}' |
  grep -Fxq "$NODE_IP" || die "L'IP $NODE_IP n'appartient pas à $NODE_IFACE."
sysctl -w net.ipv4.ip_forward=1
[[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]] ||
  die "bridge-nf-call-iptables absent du noyau. À préparer côté hôte."
sysctl -w net.bridge.bridge-nf-call-iptables=1
if [[ -e /proc/sys/net/bridge/bridge-nf-call-ip6tables ]]; then
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1
fi

install -d -m 0755 "$DATA_ROOT"
install -d -m 0700 "$CONFIG_DIR" /etc/containerd-lab "$DATA_ROOT/logs" \
  "$DATA_ROOT/containerd" "$DATA_ROOT/etcd" "$DATA_ROOT/kubelet" "$DATA_ROOT/pod-logs"
exec 8>"$CONFIG_DIR/prepare.lock"
flock -n 8 || die "Autre préparation en cours."
TMP_DIR=$(mktemp -d "$DATA_ROOT/install.XXXXXX")
trap 'rm -rf -- "$TMP_DIR"' EXIT

echo '[2/7] Test de montage bind et VXLAN sur le nœud'
# Native copie les fichiers : pas d'OverlayFS imbriqué sur la couche du Pod.
# Un montage bind reste nécessaire au runtime pour exécuter les conteneurs.
(
  set -e
  T="$TMP_DIR/bind-test"
  mkdir -p "$T"/{source,target}
  trap 'if mountpoint -q "$T/target"; then umount "$T/target"; fi' EXIT
  echo bind-ok > "$T/source/check"
  mount --bind "$T/source" "$T/target"
  grep -Fxq bind-ok "$T/target/check"
)
VXLAN_TEST="klab$$"
ip link add "$VXLAN_TEST" type vxlan id 4090 dev "$NODE_IFACE" dstport 8472 nolearning
ip link delete "$VXLAN_TEST"

echo '[3/7] Binaires Kubernetes avec SHA256'
case $(dpkg --print-architecture) in amd64) ARCH=amd64;; arm64) ARCH=arm64;; *) die "Architecture non prise en charge.";; esac
download() {
  printf "\nTéléchargement : %s\n" "${1##*/}"
  curl --progress-bar --fail --location --retry 3 --retry-all-errors --connect-timeout 20 --max-time 600 "$1" -o "$2"
}
for BIN in kubeadm kubelet kubectl; do
  URL="https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/${BIN}"
  download "$URL" "$TMP_DIR/$BIN"
  download "$URL.sha256" "$TMP_DIR/$BIN.sha256"
  (cd "$TMP_DIR"; printf '%s  %s\n' "$(cat "$BIN.sha256")" "$BIN" | sha256sum -c -)
done
for BIN in kubeadm kubelet kubectl; do install -m 0755 "$TMP_DIR/$BIN" "/usr/local/bin/$BIN"; done

echo '[4/7] Plugins CNI avec SHA256'
ARCHIVE="cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"
URL="https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/${ARCHIVE}"
download "$URL" "$TMP_DIR/$ARCHIVE"
download "$URL.sha256" "$TMP_DIR/$ARCHIVE.sha256"
(cd "$TMP_DIR"; printf '%s  %s\n' "$(awk '{print $1}' "$ARCHIVE.sha256")" "$ARCHIVE" | sha256sum -c -)
install -d -m 0755 /opt/cni/bin /etc/cni/net.d
run_with_status "Extraction des plugins CNI" "$DATA_ROOT/logs/cni-install.log" \
  tar -xzf "$TMP_DIR/$ARCHIVE" -C /opt/cni/bin

echo '[5/7] Configuration du containerd dédié'
containerd config default > "$TMP_DIR/containerd.toml"
python3 - "$TMP_DIR/containerd.toml" "$RUNTIME_CONFIG" "$RUNTIME_STATE" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r'(?m)^(\s*snapshotter\s*=\s*)[\x27\x22]overlayfs[\x27\x22]', r"\1'native'", text)
text = re.sub(r'(?m)^(\s*use_local_image_pull\s*=\s*)false', r'\1true', text)
text = re.sub(r'(?m)^(\s*SystemdCgroup\s*=\s*)true', r'\1false', text)
state = sys.argv[3]
# Séparer aussi le socket ttrpc, pour ne pas utiliser celui d'une autre instance.
text, n = re.subn(r'(?ms)(^\[ttrpc\]\s*\n)(.*?)(?=^\[|\Z)',
    lambda m: m[1] + re.sub(r'(?m)^\s*address\s*=.*$', "  address = '" + state + "/containerd.sock.ttrpc'", m[2]), text)
open(sys.argv[2], 'w').write(text)
PY
chmod 0600 "$RUNTIME_CONFIG"
containerd --config "$RUNTIME_CONFIG" config dump >/dev/null
for KV in \
  "K8S_VERSION=$K8S_VERSION" "CNI_VERSION=$CNI_VERSION" "NODE_IP=$NODE_IP" \
  "NODE_IFACE=$NODE_IFACE" "DATA_ROOT=$DATA_ROOT" "MIN_FREE_GIB=$MIN_FREE_GIB" "RUNTIME_CONFIG=$RUNTIME_CONFIG" \
  "RUNTIME_STATE=$RUNTIME_STATE" "RUNTIME_SOCKET=$RUNTIME_SOCKET"; do
  printf '%s\n' "$KV"
done > "$CONFIG_DIR/environment"
chmod 0600 "$CONFIG_DIR/environment"

echo '[6/7] Supervision de kubelet sans systemd'
install -d -m 0755 /usr/local/lib/k8s-lab
cat > /usr/local/lib/k8s-lab/kubelet-supervisor.sh <<'SUPERVISOR'
#!/usr/bin/env bash
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /etc/kubernetes-lab/environment
exec 9>/run/kubelet-lab-supervisor.lock
flock -n 9 || exit 0
echo 'Kubelet attend la configuration produite par kubeadm init ou join.'
while true; do
  if [[ -s /var/lib/kubelet/config.yaml && -s /var/lib/kubelet/kubeadm-flags.env ]] &&
     [[ -s /etc/kubernetes/kubelet.conf || -s /etc/kubernetes/bootstrap-kubelet.conf ]] &&
     [[ -S $RUNTIME_SOCKET ]]; then
    if pgrep -x kubelet >/dev/null; then
      echo 'Un kubelet existe déjà ; attendre sa sortie sans lancer de doublon.'
      sleep 5; continue
    fi
    KUBELET_KUBEADM_ARGS=
    . /var/lib/kubelet/kubeadm-flags.env
    read -r -a kubelet_args <<< "$KUBELET_KUBEADM_ARGS"
    /usr/local/bin/kubelet \
      --config=/var/lib/kubelet/config.yaml \
      --kubeconfig=/etc/kubernetes/kubelet.conf \
      --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
      "${kubelet_args[@]}" --node-ip="$NODE_IP" --root-dir="$DATA_ROOT/kubelet"
    result=$?
    echo "Kubelet arrêté (code $result), nouvel essai dans 5 secondes."
    sleep 5
  else
    sleep 2
  fi
done
SUPERVISOR
chmod 0755 /usr/local/lib/k8s-lab/kubelet-supervisor.sh
cat > /usr/local/sbin/k8s-lab-start <<'START'
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID == 0 ]] || { echo 'Exécuter avec sudo.' >&2; exit 1; }
. /etc/kubernetes-lab/environment
[[ -d $DATA_ROOT && -w $DATA_ROOT ]] || { echo 'Stockage local absent ou inaccessible.' >&2; exit 1; }
mkdir -p "$RUNTIME_STATE" "$DATA_ROOT/logs"
exec 7>/run/k8s-lab-start.lock
flock -n 7 || { echo 'Démarrage déjà en cours.' >&2; exit 1; }
if ! ctr --address "$RUNTIME_SOCKET" version >/dev/null 2>&1; then
  if pgrep -af '^/usr/bin/containerd .*--address /run/containerd-lab/containerd.sock' >/dev/null; then
    echo 'Instance containerd existante mais socket indisponible. Examiner les logs.' >&2
    exit 1
  fi
  nohup /usr/bin/containerd --config "$RUNTIME_CONFIG" \
    --root "$DATA_ROOT/containerd" --state "$RUNTIME_STATE" \
  --address "$RUNTIME_SOCKET" >> "$DATA_ROOT/logs/containerd.log" 2>&1 < /dev/null 7>&- 8>&- &
fi
for ((i=0;i<30;i++)); do
  if ctr --address "$RUNTIME_SOCKET" version >/dev/null 2>&1; then break; fi
  sleep 1
done
ctr --address "$RUNTIME_SOCKET" version >/dev/null || { tail -n 30 "$DATA_ROOT/logs/containerd.log"; exit 1; }
PLUGINS=$(ctr --address "$RUNTIME_SOCKET" plugins ls)
for plugin in 'io.containerd.snapshotter.v1.*native' 'io.containerd.grpc.v1.*cri'; do
  grep -E "$plugin.*[[:space:]]ok[[:space:]]*$" <<< "$PLUGINS" >/dev/null || {
    echo 'Plugin native ou CRI non sain.' >&2; printf '%s\n' "$PLUGINS"; exit 1;
  }
done
nohup /usr/local/lib/k8s-lab/kubelet-supervisor.sh \
  >> "$DATA_ROOT/logs/kubelet.log" 2>&1 < /dev/null 7>&- 8>&- &
echo 'Containerd prêt ; superviseur kubelet démarré ou déjà présent.'
START
chmod 0755 /usr/local/sbin/k8s-lab-start

echo '[7/7] Démarrage et vérifications'
/usr/local/sbin/k8s-lab-start 8>&-
kubeadm version -o short
kubelet --version
df -h "$DATA_ROOT" /
printf '\nNœud préparé : %s (%s).\n' "$(hostname -s)" "$NODE_IP"
echo 'Master : sudo bash master.sh'
echo 'Worker : exécuter la commande join affichée par master.sh.'
echo 'Logs : /var/lib/k8s-lab/logs/{containerd,kubelet}.log'
