On a single-cluster single-node setup with kubeadm,
node.kubernetes.io/exclude-from-external-load-balancers label should be
removed in order for MetalLB to pick up the single node. Use the below
command after running apply.sh

kubectl label node --all \
    node.kubernetes.io/exclude-from-external-load-balancers- --overwrite
    2>/dev/null || true
