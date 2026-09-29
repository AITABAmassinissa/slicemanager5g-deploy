#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# clean.sh — Tear down everything deploy.sh creates
#
# Usage: ./clean.sh
#
# Removes the app namespaces (slicemanager, oai5g), the monitoring stack, the
# cluster-wide dependencies (Multus is left alone -- see note below), and all
# cluster-scoped RBAC/PV objects this package owns. Safe to re-run (every
# delete is --ignore-not-found).
#
# Multus CNI is deliberately NOT removed here: it's a base cluster capability
# other workloads may depend on, not something owned by this package, and
# tearing it down risks breaking the node's networking outright. Remove it
# yourself if you really want to (kubectl delete -f https://raw.githubusercon
# tent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemons
# et-thick.yml) -- deploy.sh will simply reapply it next run either way.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
step() { echo -e "\n${BOLD}══ $* ══${NC}"; }

cd "$(dirname "$0")"

step "Namespaces applicatifs (oai5g, slicemanager, qperf, monitoring)"
kubectl delete ns oai5g slicemanager qperf monitoring --ignore-not-found --wait=true
ok "Namespaces supprimés"

step "host-net-setup (DaemonSet réseau hôte)"
kubectl delete -f k8s/10-host-net-setup.yaml --ignore-not-found
ok "host-net-setup supprimé"

step "setpodnet-scheduler (kube-system)"
kubectl delete -f k8s/11-setpodnet-scheduler.yaml --ignore-not-found
ok "setpodnet-scheduler supprimé"

step "Kepler (Helm release, si installé)"
helm uninstall kepler -n monitoring 2>/dev/null || warn "Kepler déjà absent"

step "RBAC cluster-scoped"
kubectl delete clusterrole slice-manager-cluster-role --ignore-not-found
kubectl delete clusterrolebinding \
    slice-manager-cluster-rolebinding \
    slice-manager-as-kube-scheduler \
    slice-manager-cluster-admin \
    --ignore-not-found
ok "RBAC cluster-scoped supprimé"

step "PersistentVolume"
kubectl delete pv slice-manager-pv --ignore-not-found
ok "PV supprimé"

step "Terminé"
echo "  Cluster remis à zéro. Relancer ./deploy.sh pour redéployer."
