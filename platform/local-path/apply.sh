#!/usr/bin/env bash

set -euo pipefail

VERSION="${VERSION:-v0.0.37}"
DATA_DIR="${DATA_DIR:-/mnt/data/local-path}"

K='kubectl'

$K apply -f \
    "https://raw.githubusercontent.com/rancher/local-path-provisioner/refs/tags/$VERSION/deploy/local-path-storage.yaml"

$K -n local-path-storage patch cm local-path-config --type merge -p \
      '{"data":{"config.json":"{\"nodePathMap\":[{\"node\":\"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\"paths\":[\"/mnt/data/local-path\"]}]}"}}'
$K -n local-path-storage rollout restart deploy local-path-provisioner
$K patch sc local-path -p \
      '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
