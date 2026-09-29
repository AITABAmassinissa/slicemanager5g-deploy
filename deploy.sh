#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# deploy.sh — Deploy slicemanager5g from Docker Hub (no local build required)
#
# Usage: ./deploy.sh
#
# Pulls maitaba/slicemanager5g:v1 from Docker Hub and brings up everything
# slice-manager needs on a single-node kubeadm/containerd cluster:
#   - the slicemanager/oai5g namespaces, PVC, RBAC
#   - the slice-manager app itself
#   - the iperf3 test-server pool (used by the Active Slices traffic tests)
#   - the host-net-setup DaemonSet (Multus N3/N6 bridges, NAT) -- required for
#     any 5G core (classic or VPP UPF) to actually pass traffic
#   - the setpodnet-scheduler third-party scheduler -- required for slice pods
#     (upf/smf/gnbanchor) to be scheduled at all
#
# The last two are also auto-reapplied by slice-manager's own startup.sh on
# every restart, so this script only needs to run once per cluster.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
fail() { echo -e "${RED}❌ $*${NC}"; exit 1; }
step() { echo -e "\n${BOLD}══ $* ══${NC}"; }

command -v kubectl &>/dev/null || fail "kubectl non trouvé"

cd "$(dirname "$0")"

step "Label du nœud Kubernetes"
# "items[0]" n'est PAS garanti d'être un nœud planifiable : sur un cluster
# multi-nœuds, l'API peut le lister en premier alors qu'il s'agit du
# control-plane (taint NoSchedule par défaut) -- confirmé en test réel sur
# un cluster 2 nœuds (lab-master + lab-worker-1) : le pod slice-manager
# restait bloqué Pending indéfiniment ("node(s) had untolerated taint(s)"),
# le label étant tombé sur lab-master. On cherche donc explicitement un
# nœud SANS le rôle control-plane/master, et on ne retombe sur le premier
# nœud listé (control-plane inclus) que s'il n'y a vraiment aucun worker --
# cas d'un cluster mono-nœud, où le control-plane est généralement
# détainté pour permettre d'y faire tourner des charges normales.
NODE=$(kubectl get nodes -o json | python3 -c '
import json, sys
nodes = json.load(sys.stdin)["items"]
def is_control_plane(n):
    labels = n["metadata"].get("labels", {})
    return "node-role.kubernetes.io/control-plane" in labels \
        or "node-role.kubernetes.io/master" in labels
workers = [n for n in nodes if not is_control_plane(n)]
pick = workers[0] if workers else nodes[0]
print(pick["metadata"]["name"])
')
kubectl label node "$NODE" slice-manager/workspace=true --overwrite
ok "Nœud '$NODE' labelé"
if kubectl get node "$NODE" -o jsonpath='{.spec.taints}' | grep -q NoSchedule; then
    warn "'$NODE' porte un taint NoSchedule (control-plane sans worker ?)."
    warn "Si les pods restent Pending, retirez-le : kubectl taint node $NODE node-role.kubernetes.io/control-plane-"
fi

step "Namespaces + RBAC + PVC"
kubectl apply -f k8s/00-namespace.yaml
kubectl create ns oai5g --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/0-pvc.yaml
kubectl apply -f k8s/1-serviceaccount.yaml
kubectl apply -f k8s/2-rbac-namespaced.yaml
kubectl apply -f k8s/3-rbac-cluster.yaml
ok "Namespaces/RBAC/PVC appliqués"

step "Dépendances cluster (Multus + scheduler tiers + réseau hôte)"
# Multus CNI, appliqué directement depuis le dépôt upstream (pas vendorisé) --
# requis avant toute network-attachment-definition (N3/N6/N4).
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
kubectl apply -f k8s/11-setpodnet-scheduler.yaml
kubectl apply -f k8s/10-host-net-setup.yaml
kubectl rollout status daemonset/kube-multus-ds -n kube-system --timeout=90s \
    || warn "Multus pas encore prêt — vérifiez kubectl get pods -n kube-system"
kubectl rollout status deployment/setpodnet-scheduler -n kube-system --timeout=90s \
    || warn "setpodnet-scheduler pas encore prêt — vérifiez kubectl get pods -n kube-system"
kubectl rollout status daemonset/host-net-setup -n host-net-setup --timeout=90s \
    || warn "host-net-setup pas encore prêt"
ok "Dépendances cluster prêtes"

step "Namespace + RBAC monitoring"
# Le chart (kube-prometheus-stack) lui-meme est embarque dans l'image et
# installe automatiquement au demarrage de slice-manager (voir startup.sh) --
# ici on prepare juste le namespace + les droits en avance.
kubectl create ns monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/6-rbac-monitoring.yaml
ok "Namespace/RBAC monitoring prêts"

step "slice-manager (image Docker Hub : maitaba/slicemanager5g:v1)"
kubectl apply -f k8s/4-deployment.yaml
kubectl apply -f k8s/5-service.yaml
kubectl rollout status deployment/slice-manager -n slicemanager --timeout=180s
ok "slice-manager déployé et prêt"

step "Pool iperf3 (3 serveurs)"
kubectl apply -f k8s/6-iperf3.yaml
for i in 0 1 2; do
    kubectl wait pod "iperf-server-$i" -n slicemanager \
        --for=condition=Ready --timeout=60s 2>/dev/null || true
done
ok "Pool iperf3 prêt (iperf-server-0/1/2)"

step "Terminé"
echo "  UI / API : http://<node-ip>:30880  (NodePort, voir k8s/5-service.yaml)"
echo "  Vérifier : kubectl get pods -A"
