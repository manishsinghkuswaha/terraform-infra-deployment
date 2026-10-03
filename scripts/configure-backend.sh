#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap="$root/bootstrap-state"
bucket="$(terraform -chdir="$bootstrap" output -raw state_bucket)"
kms="$(terraform -chdir="$bootstrap" output -raw state_kms_key_arn)"
region="$(terraform -chdir="$bootstrap" output -raw aws_region)"
for env in dev prod; do
  cat > "$root/environments/$env/backend.hcl" <<EOF
bucket       = "$bucket"
key          = "session24/$env/terraform.tfstate"
region       = "$region"
profile      = "default"
encrypt      = true
kms_key_id   = "$kms"
use_lockfile = true
EOF
done
echo "Generated ignored backend configs. Review them before terraform init."
