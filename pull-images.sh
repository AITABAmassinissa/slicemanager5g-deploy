#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# pull-images.sh — Pre-pull every image deploy.sh will need, before running it
#
# Usage: ./pull-images.sh
#
# Useful on a slow/metered link, or just to see all the pulling happen up
# front instead of scattered across deploy.sh's own rollout waits and every
# later core/slice deploy from the UI. Safe to re-run (skips what's already
# present). Every image ends up in containerd's own "k8s.io" namespace --
# the same store kubelet pulls from -- via `crictl` (preferred) or `ctr`.
#
# This list is the UNION of:
#   - slicemanager5g itself
#   - what deploy.sh's own dependencies use (Multus, setpodnet-scheduler,
#     host-net-setup, the monitoring stack, the iperf3 pool)
#   - what a core deploy (classic AND VPP UPF) and a slice deploy actually
#     pull afterwards, for BOTH the shared core release (image tag v2.1.0)
#     and each slice's own dedicated NFs (tag v2.1.9 -- yes, genuinely a
#     different tag; see templates/slice2/oai-smf2/values.yaml vs.
#     templates/oai-5g-core/oai-smf/values.yaml)
# Re-derive it with:
#   kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
fail() { echo -e "${RED}❌ $*${NC}"; }
step() { echo -e "\n${BOLD}══ $* ══${NC}"; }

IMAGES=(
  # ── slicemanager5g itself ──────────────────────────────────────────────
  docker.io/maitaba/slicemanager5g:v1
  docker.io/busybox:1.36

  # ── Cluster bootstrap dependencies (deploy.sh) ─────────────────────────
  ghcr.io/k8snetworkplumbingwg/multus-cni:snapshot-thick
  docker.io/maitaba/setpodnet:v1.0

  # ── Monitoring stack (Prometheus + Grafana + Kepler) ───────────────────
  docker.io/grafana/grafana:12.0.2
  quay.io/prometheus/alertmanager:v0.28.1
  quay.io/prometheus/prometheus:v3.4.2
  quay.io/prometheus/node-exporter:v1.9.1
  quay.io/prometheus-operator/prometheus-operator:v0.83.0
  quay.io/prometheus-operator/prometheus-config-reloader:v0.83.0
  quay.io/kiwigrid/k8s-sidecar:1.30.3
  registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.16.0
  quay.io/sustainable_computing_io/kepler:release-0.8.0

  # ── iperf3 test pool ─────────────────────────────────────────────────
  docker.io/networkstatic/iperf3:latest

  # ── 5G core, shared release (core deploy, either UPF type) ─────────────
  docker.io/oaisoftwarealliance/oai-amf:v2.1.0
  docker.io/oaisoftwarealliance/oai-ausf:v2.1.0
  docker.io/oaisoftwarealliance/oai-lmf:v2.1.0
  docker.io/oaisoftwarealliance/oai-nrf:v2.1.0
  docker.io/oaisoftwarealliance/oai-nssf:v2.1.0
  docker.io/oaisoftwarealliance/oai-smf:v2.1.0
  docker.io/oaisoftwarealliance/oai-udm:v2.1.0
  docker.io/oaisoftwarealliance/oai-udr:v2.1.0
  docker.io/oaisoftwarealliance/oai-upf:v2.1.0
  docker.io/oaisoftwarealliance/oai-upf-vpp:v2.1.0
  docker.io/oaisoftwarealliance/oai-tcpdump-init:alpine-3.20
  docker.io/mysql:9.0.1

  # ── Per-slice NFs (own dedicated SMF/UPF/NRF per slice, tag v2.1.9) ────
  docker.io/oaisoftwarealliance/oai-smf:v2.1.9
  docker.io/oaisoftwarealliance/oai-upf:v2.1.9
  docker.io/oaisoftwarealliance/oai-nrf:v2.1.9

  # ── RAN (gNB + UE simulator) ────────────────────────────────────────────
  docker.io/gradiant/ueransim:3.2.6

  # ── gNB anchor pod (setpodnet co-scheduling placeholder) ────────────────
  docker.io/alpine:3.18
)

# ── Pick a pull tool ───────────────────────────────────────────────────────
# "ctr" defaults to /run/containerd/containerd.sock, which isn't universal --
# confirmed in test on a real 2-node lab cluster: the socket lived elsewhere
# entirely, and ctr failed outright ("no such file or directory") with the
# default. Auto-detect it instead of assuming, checking every path an actual
# containerd/kubeadm/k3s/microk8s install commonly uses. CTR_SOCK=/path
# ./pull-images.sh overrides this if none of them match your setup.
CTR_SOCK="${CTR_SOCK:-}"
if [ -z "$CTR_SOCK" ]; then
    for s in /run/containerd/containerd.sock \
             /var/run/containerd/containerd.sock \
             /run/k3s/containerd/containerd.sock \
             /var/snap/microk8s/common/run/containerd.sock; do
        # A socket's own permissions don't gate stat()/existence checks --
        # only actually connecting to it needs sudo -- so no sudo needed
        # here, and it avoids an extra unnecessary password prompt.
        if [ -S "$s" ]; then
            CTR_SOCK="$s"
            break
        fi
    done
fi

if command -v crictl &>/dev/null; then
    PULL="crictl"
    ok "Outil de pull : crictl (nécessite sudo — mot de passe demandé au premier pull)"
elif command -v ctr &>/dev/null && [ -n "$CTR_SOCK" ]; then
    PULL="ctr"
    ok "Outil de pull : ctr (socket: $CTR_SOCK — nécessite sudo)"
elif command -v ctr &>/dev/null; then
    fail "'ctr' trouvé mais aucun socket containerd connu détecté."
    fail "Cherchez-le : sudo find / -xdev -name 'containerd.sock' 2>/dev/null"
    fail "puis relancez avec : CTR_SOCK=/chemin/trouvé ./pull-images.sh"
    exit 1
else
    fail "Ni 'crictl' ni 'ctr' trouvés — impossible de précharger dans containerd."
    fail "Installez l'un des deux, ou lancez directement ./deploy.sh (les images seront tirées à la volée)."
    exit 1
fi

do_pull() {
    if [ "$PULL" = "crictl" ]; then
        sudo crictl pull "$1"
    else
        sudo ctr -a "$CTR_SOCK" -n k8s.io images pull "$1"
    fi
}

step "Test — un seul pull, en clair, avant de lancer toute la liste"
# Si CETTE toute première commande echoue, les 31 suivantes echoueront pour
# la MEME raison (mot de passe sudo refuse, pas d'acces reseau, etc.) --
# inutile de le decouvrir 31 fois. On montre la vraie erreur ici et on
# s'arrete net, plutot que de la masquer dans un fichier temp supprime
# aussitot (ce que ce script faisait avant -- confirme inutilisable en
# test reel : 31/31 "echec", aucun moyen de savoir pourquoi).
if ! do_pull "${IMAGES[0]}"; then
    echo
    fail "Le tout premier pull a échoué (erreur ci-dessus) — inutile de continuer."
    fail "Causes fréquentes : mot de passe sudo refusé/non saisi, pas d'accès"
    fail "réseau sortant depuis ce nœud."
    exit 1
fi
ok "${IMAGES[0]}"

step "Préchargement des $(( ${#IMAGES[@]} - 1 )) images restantes dans containerd"
failed=()
for img in "${IMAGES[@]:1}"; do
    echo "  → $img"
    if do_pull "$img"; then
        ok "  $img"
    else
        warn "  $img — échec (erreur ci-dessus)"
        failed+=("$img")
    fi
done

step "Terminé"
ok "$(( ${#IMAGES[@]} - ${#failed[@]} ))/${#IMAGES[@]} images prêtes"
if [ "${#failed[@]}" -gt 0 ]; then
    warn "Échecs (seront retentés au déploiement normal) :"
    for img in "${failed[@]}"; do echo "    - $img"; done
fi
echo "  Vous pouvez maintenant lancer ./deploy.sh"
