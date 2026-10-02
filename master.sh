#!/usr/bin/env bash
# Initialise un NOUVEAU master après all_nodes.sh et affiche le join des workers.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NODE_NAME=lab-master
POD_CIDR=10.244.0.0/16
SERVICE_CIDR=10.96.0.0/12
FLANNEL_VERSION=v0.28.9
FLANNEL_MTU=
TOKEN_TTL=2h
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
sudo bash master.sh [options]
  --node-name NOM       Défaut lab-master
  --flannel-version V  Défaut v0.28.9 (manifeste versionné)
  --flannel-mtu N      MTU du chemin sous-jacent, AVANT les 50 octets VXLAN
                       Détecté depuis l'interface et la route par défaut
  --token-ttl DURÉE    Défaut 2h
  --help

Préparer d'abord tous les nœuds avec all_nodes.sh. Ce script refuse un master
déjà initialisé et ne lance jamais kubeadm reset. Le join des workers est
une commande kubeadm standard, avec le socket dédié et l'exception du lab.
EOF
}
while (($#)); do
  case "$1" in
    --node-name|--flannel-version|--flannel-mtu|--token-ttl)
      (($# >= 2)) || die "Valeur manquante pour $1"
      case "$1" in
        --node-name) NODE_NAME=$2;; --flannel-version) FLANNEL_VERSION=$2;;
        --flannel-mtu) FLANNEL_MTU=$2;; --token-ttl) TOKEN_TTL=$2;;
      esac
      shift 2;;
    -h|--help) help; exit 0;; *) die "Option inconnue : $1";;
  esac
done
[[ $EUID == 0 ]] || die "Exécuter avec sudo bash master.sh."
[[ -r /etc/kubernetes-lab/environment ]] || die "Exécuter all_nodes.sh d'abord."
. /etc/kubernetes-lab/environment
[[ $NODE_NAME =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && ${#NODE_NAME} -le 63 ]] || die 'Nom de nœud invalide.'
[[ $FLANNEL_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Version Flannel invalide.'
[[ $TOKEN_TTL =~ ^[0-9]+[hm]$ ]] || die 'Durée du token attendue : 2h, 60m, etc.'
[[ $DATA_ROOT == /var/lib/k8s-lab ]] || die "Configuration issue des anciens scripts PVC. Préparer un nouveau Pod avec la version locale de all_nodes.sh."
[[ -d $DATA_ROOT && -w $DATA_ROOT ]] || die "Stockage local inaccessible."
[[ $(df -Pk "$DATA_ROOT" | awk 'END {print $4}') -ge 2097152 ]] || die "Moins de 2 Gio libres avant initialisation. Augmenter l'espace disponible sur le worker hébergeur."
[[ ! -f /etc/kubernetes/admin.conf && ! -f /etc/kubernetes/manifests/kube-apiserver.yaml && ! -d $DATA_ROOT/etcd/member ]] ||
  die 'Master déjà initialisé ou installation partielle. Aucun reset automatique.'
exec 8>/etc/kubernetes-lab/master.lock
flock -n 8 || die 'Autre initialisation en cours.'
on_error() {
  echo 'Initialisation interrompue. Aucun fichier ni cluster ne sera supprimé.' >&2
  echo "Examiner $DATA_ROOT/logs/kubelet.log et $DATA_ROOT/logs/containerd.log." >&2
}
trap on_error ERR
/usr/local/sbin/k8s-lab-start 8>&-
export KUBECONFIG=/etc/kubernetes/admin.conf
CONFIG="$DATA_ROOT/kubeadm-master.yaml"
umask 077

if [[ -z $FLANNEL_MTU ]]; then
  FLANNEL_MTU=$(cat "/sys/class/net/$NODE_IFACE/mtu")
  ROUTE_MTU=$(ip -4 route show default dev "$NODE_IFACE" |
    awk '{for(i=1;i<NF;i++) if($i=="mtu") {print $(i+1); exit}}')
  if [[ -n $ROUTE_MTU && $ROUTE_MTU -lt $FLANNEL_MTU ]]; then FLANNEL_MTU=$ROUTE_MTU; fi
fi
[[ $FLANNEL_MTU =~ ^[0-9]+$ && $FLANNEL_MTU -ge 1280 && $FLANNEL_MTU -le 9000 ]] || die 'MTU Flannel invalide.'
echo "Master $NODE_NAME, IP $NODE_IP, MTU chemin $FLANNEL_MTU (Pods $((FLANNEL_MTU-50)))."

cat > "$CONFIG" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$NODE_IP"
  bindPort: 6443
nodeRegistration:
  name: "$NODE_NAME"
  criSocket: unix://$RUNTIME_SOCKET
  kubeletExtraArgs:
    - name: node-ip
      value: "$NODE_IP"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: $K8S_VERSION
networking:
  podSubnet: "$POD_CIDR"
  serviceSubnet: "$SERVICE_CIDR"
  dnsDomain: cluster.local
etcd:
  local:
    dataDir: $DATA_ROOT/etcd
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: cgroupfs
failSwapOn: true
podLogsDir: $DATA_ROOT/pod-logs
containerLogMaxSize: 10Mi
containerLogMaxFiles: 3
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
conntrack:
  maxPerCore: 0
EOF
# Résolution locale du nom pour le contrôle preflight ; ne pas garder une IP obsolète.
python3 - "$NODE_NAME" "$NODE_IP" <<'PY'
import sys
name, ip = sys.argv[1:]
lines = open('/etc/hosts').read().splitlines()
result = []
for line in lines:
    fields = line.split('#',1)[0].split()
    if len(fields)>1 and name in fields[1:]:
        aliases = [x for x in fields[1:] if x != name]
        if aliases: result.append(fields[0]+' '+ ' '.join(aliases))
    else: result.append(line)
result.append(ip+' '+name)
# /etc/hosts peut être un montage du runtime : écrire sans remplacement atomique.
with open('/etc/hosts','w') as f: f.write('\n'.join(result)+'\n')
PY
kubeadm config validate --config "$CONFIG"

echo '[1/4] Téléchargement des images sur le stockage local'
run_with_status "Pull et décompression des images Kubernetes" "$DATA_ROOT/logs/images-pull.log" \
  kubeadm config images pull --config "$CONFIG"
echo '[2/4] Initialisation du control plane (kubelet démarre automatiquement)'
run_with_status "Initialisation du control plane" "$DATA_ROOT/logs/kubeadm-init.log" \
  kubeadm init --config "$CONFIG" --ignore-preflight-errors=SystemVerification
kubectl --request-timeout=15s get --raw=/readyz

echo '[3/4] Installation Flannel'
MANIFEST="$DATA_ROOT/kube-flannel.yaml"
echo "Téléchargement du manifeste Flannel $FLANNEL_VERSION"
curl --progress-bar --fail --location --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 \
  "https://github.com/flannel-io/flannel/releases/download/$FLANNEL_VERSION/kube-flannel.yml" \
  -o "$MANIFEST"
python3 - "$MANIFEST" "$POD_CIDR" "$FLANNEL_MTU" <<'PY'
import json, sys, yaml
path, cidr, mtu = sys.argv[1:]
docs = list(yaml.safe_load_all(open(path)))
found = False
for d in docs:
    if d and d.get('kind') == 'ConfigMap' and d.get('metadata',{}).get('name') == 'kube-flannel-cfg':
        config = json.loads(d['data']['net-conf.json'])
        config['Network'] = cidr
        config['Backend'] = {'Type':'vxlan', 'MTU':int(mtu)}
        d['data']['net-conf.json'] = json.dumps(config, indent=2)
        found = True
if not found: raise SystemExit('ConfigMap Flannel introuvable ; manifeste non appliqué.')
with open(path,'w') as f: yaml.safe_dump_all(docs, f, sort_keys=False)
PY
kubectl apply -f "$MANIFEST"
run_with_status "Démarrage Flannel (pull éventuel de son image)" "$DATA_ROOT/logs/flannel-ready.log" \
  kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=300s
run_with_status "Démarrage kube-proxy" "$DATA_ROOT/logs/proxy-ready.log" \
  kubectl -n kube-system rollout status ds/kube-proxy --timeout=180s
run_with_status "Attente du master Ready" "$DATA_ROOT/logs/node-ready.log" \
  kubectl wait --for=condition=Ready "node/$NODE_NAME" --timeout=300s
run_with_status "Démarrage CoreDNS" "$DATA_ROOT/logs/dns-ready.log" \
  kubectl -n kube-system rollout status deployment/coredns --timeout=300s

# Installer le kubeconfig pour l'utilisateur qui a lancé sudo.
LOGIN_USER=${SUDO_USER:-root}
LOGIN_HOME=$(getent passwd "$LOGIN_USER" | cut -d: -f6)
[[ -n $LOGIN_HOME ]] || die 'Répertoire utilisateur introuvable.'
install -d -m 0700 -o "$LOGIN_USER" -g "$(id -gn "$LOGIN_USER")" "$LOGIN_HOME/.kube"
install -m 0600 -o "$LOGIN_USER" -g "$(id -gn "$LOGIN_USER")" \
  /etc/kubernetes/admin.conf "$LOGIN_HOME/.kube/config"

echo '[4/4] Commande de jonction des workers'
JOIN=$(kubeadm token create --ttl "$TOKEN_TTL" --print-join-command)
JOIN="sudo env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin $JOIN --cri-socket unix://$RUNTIME_SOCKET --ignore-preflight-errors=SystemVerification"
printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$JOIN" > "$DATA_ROOT/join-command.sh"
chmod 0600 "$DATA_ROOT/join-command.sh"
kubectl get nodes -o wide
kubectl get pods -A -o wide
df -h "$DATA_ROOT" /
printf '\nSur CHAQUE worker, après all_nodes.sh, exécuter :\n\n%s\n\n' "$JOIN"
echo "Le token expire dans $TOKEN_TTL. La commande contient un secret : ne pas la publier."
echo "Optionnel : ajouter --node-name lab-worker-1 ou lab-worker-2 à la commande."
echo "Fichier privé : $DATA_ROOT/join-command.sh"
echo 'Sur le master, vérifier ensuite : kubectl get nodes -o wide'
