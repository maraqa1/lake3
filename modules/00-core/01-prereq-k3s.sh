# ==============================================================================
# PRE-REQ — k3s + kubectl must exist before 00-env.sh runs
# ==============================================================================
_ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log(){ echo "$(_ts) [01-core] $*"; }
die(){ echo "$(_ts) [01-core][FATAL] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

ensure_k3s(){
  if have kubectl && systemctl is-active --quiet k3s 2>/dev/null; then
    log "pre-req: k3s already running"
  else
    log "pre-req: installing k3s (server, disable traefik)"
    curl -sfL https://get.k3s.io | sh -s - server \
      --write-kubeconfig-mode 644 \
      --disable traefik
  fi

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install -d /etc/profile.d
  cat >/etc/profile.d/k3s-kubeconfig.sh <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF

  log "pre-req: wait node Ready"
  for i in {1..60}; do
    kubectl get nodes >/dev/null 2>&1 && break || true
    sleep 2
  done
  kubectl get nodes -o wide || die "kubectl cannot reach cluster"
  kubectl wait --for=condition=Ready node --all --timeout=180s || die "node not Ready"
}

ensure_k3s
