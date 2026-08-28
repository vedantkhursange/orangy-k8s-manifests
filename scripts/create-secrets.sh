#!/usr/bin/env bash
#
# Creates (or updates) the `orangy-secrets` Secret in orangy-dev and
# orangy-prod.
#
# Values you type are never echoed, never written to disk, and never passed as
# command-line arguments — argv is visible to other users via `ps`, so the
# Secret is built as YAML and piped straight into kubectl.
#
# The two JWT secrets are generated here, freshly and independently per
# environment, so a dev token is never valid in prod.
#
# Usage:  ./scripts/create-secrets.sh
#
# On the k3s node, kubectl needs sudo and is not on the ubuntu user's PATH:
#   KUBECTL="sudo kubectl" ./create-secrets.sh
#
set -euo pipefail
set +x   # never trace: this script handles secrets

DEV_NS="orangy-dev"
PROD_NS="orangy-prod"
SECRET_NAME="orangy-secrets"

die() { printf '\n\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
note() { printf '\033[36m%s\033[0m\n' "$1"; }

# k3s installs kubectl under sudo, so allow the command to be overridden:
#   KUBECTL="sudo kubectl" ./create-secrets.sh
KUBECTL="${KUBECTL:-kubectl}"

$KUBECTL version --client >/dev/null 2>&1 || die "'$KUBECTL' does not work. On the k3s node try: KUBECTL=\"sudo kubectl\" $0"
command -v openssl >/dev/null || die "openssl not found in PATH"

# ── confirm the target cluster before writing anything ──────────────────────
CTX="$($KUBECTL config current-context 2>/dev/null)" || die "no kubectl context is set"
printf '\nAbout to write the "%s" Secret into namespaces %s and %s\n' \
  "$SECRET_NAME" "$DEV_NS" "$PROD_NS"
printf 'Cluster context: \033[1m%s\033[0m\n\n' "$CTX"
read -r -p "Is that the right cluster? [y/N] " ok
[[ "$ok" == "y" || "$ok" == "Y" ]] || die "aborted"

# ── values only you can obtain ──────────────────────────────────────────────
cat <<'EOF'

You will be prompted for four values. Nothing you type is displayed.

  1. Gmail address used to send OTP mail
  2. Gmail APP PASSWORD  — generate a NEW one at
     https://myaccount.google.com/apppasswords
     The old one (gddu hlzk lkhh yten) was committed publicly: revoke it.
  3. Razorpay key id      — rotate at https://dashboard.razorpay.com
  4. Razorpay key secret

EOF

read -r -p  "Gmail address        : " MAIL_USER;   [[ -n "$MAIL_USER" ]] || die "mail username is required (OTP login needs it)"
read -rs -p "Gmail app password   : " MAIL_PASS; echo; [[ -n "$MAIL_PASS" ]] || die "mail password is required (OTP login needs it)"
read -r -p  "Razorpay key id      : " RZP_ID;     [[ -n "$RZP_ID" ]] || die "razorpay key id is required"
read -rs -p "Razorpay key secret  : " RZP_SECRET; echo; [[ -n "$RZP_SECRET" ]] || die "razorpay key secret is required"

# Cloudflare tunnel token: prod only, and only once the tunnel exists.
printf '\nCloudflare tunnel token (prod only — leave blank to fill in later)\n'
read -rs -p "Tunnel token         : " CF_TOKEN; echo

# Admin seeding is optional. Absent => DataSeeder creates no admin at all.
printf '\nSeed an initial admin? Only needed on a fresh database.\n'
read -r -p "Seed admin? [y/N] " seed_admin
ADMIN_EMAIL=""; ADMIN_PASS=""
if [[ "$seed_admin" == "y" || "$seed_admin" == "Y" ]]; then
  read -r -p "Admin email          : " ADMIN_EMAIL
  ADMIN_PASS="$(openssl rand -base64 24)"
  note "Generated a random admin password. It is shown ONCE — store it in your password manager now:"
  printf '\n    %s\n\n' "$ADMIN_PASS"
  read -r -p "Saved it? [y/N] " saved
  [[ "$saved" == "y" || "$saved" == "Y" ]] || die "aborted before writing secrets"
fi

b64() { printf '%s' "$1" | openssl base64 -A; }

apply_secret() {
  local ns="$1" jwt="$2" cf="$3"
  # Built as YAML and piped in: keeps every value out of argv and off disk.
  # `apply` so re-running updates in place rather than failing on conflict.
  $KUBECTL apply -n "$ns" -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
type: Opaque
data:
  # quoted: an empty value (e.g. no tunnel token yet) must serialise as "" —
  # unquoted it becomes YAML null, which kubectl rejects for a data field
  jwt-secret: "$(b64 "$jwt")"
  razorpay-key-id: "$(b64 "$RZP_ID")"
  razorpay-key-secret: "$(b64 "$RZP_SECRET")"
  mail-username: "$(b64 "$MAIL_USER")"
  mail-password: "$(b64 "$MAIL_PASS")"
  cloudflared-token: "$(b64 "$cf")"
$( [[ -n "$ADMIN_EMAIL" ]] && printf '  admin-email: "%s"\n  admin-password: "%s"' "$(b64 "$ADMIN_EMAIL")" "$(b64 "$ADMIN_PASS")" )
YAML
  note "  ✓ ${SECRET_NAME} written to ${ns}"
}

# Independent secrets per environment: a dev token must not authenticate in prod.
JWT_DEV="$(openssl rand -base64 48)"
JWT_PROD="$(openssl rand -base64 48)"

printf '\n'
$KUBECTL get namespace "$DEV_NS"  >/dev/null 2>&1 || die "namespace $DEV_NS does not exist"
$KUBECTL get namespace "$PROD_NS" >/dev/null 2>&1 || die "namespace $PROD_NS does not exist"

apply_secret "$DEV_NS"  "$JWT_DEV"  ""
apply_secret "$PROD_NS" "$JWT_PROD" "$CF_TOKEN"

unset MAIL_PASS RZP_SECRET CF_TOKEN ADMIN_PASS JWT_DEV JWT_PROD

cat <<EOF

Done. Verify (shows key names only, never values):

  ${KUBECTL} -n ${DEV_NS}  describe secret ${SECRET_NAME}
  ${KUBECTL} -n ${PROD_NS} describe secret ${SECRET_NAME}

Next:
  1. Push the manifests repo — orangy-dev auto-syncs and now has its Secret.
  2. argocd app sync orangy-prod
  3. Rotating jwt-secret invalidates existing sessions; users log in again.

EOF
