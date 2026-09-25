#!/usr/bin/env bash
#
# Collect the signed certificate from an approved CertificateSigningRequest and
# assemble a self-contained kubeconfig from it.
#
# Run this after `kubectl certificate approve <username>`. It refuses to proceed
# on a request that has not been approved, or one that has been approved but not
# yet signed, rather than writing a kubeconfig with an empty certificate in it.
#
# The private key is never fetched from anywhere -- it has to already be on this
# machine, where create-user-csr.sh left it. This script reads it only to embed
# it and to confirm it matches the certificate the cluster signed.
#
# Cluster details default to whatever the current kubectl context points at, so
# the resulting kubeconfig reaches the same API server by the same address.
#
# Usage:
#   ./make-kubeconfig.sh <username> [-d dir] [-k key] [-c name] [-s url] [-a ca] [-o out] [-h]
#
#   -d  directory holding <username>.key, and where output is written
#       (default ./<username>)
#   -k  private key path (default <dir>/<username>.key)
#   -c  cluster name to record in the kubeconfig (default: from current context)
#   -s  API server URL (default: from current context)
#   -a  CA certificate file (default: extracted from current context)
#   -o  output kubeconfig path (default <dir>/<username>.kubeconfig)
set -euo pipefail

DIR=""; KEY=""; CLUSTER=""; SERVER=""; CA=""; OUT=""
CA_TMP=""

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
cleanup() { [ -n "$CA_TMP" ] && rm -f "$CA_TMP"; }
trap cleanup EXIT

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit "${1:-0}"; }

[ $# -ge 1 ] || usage 1
case "$1" in -h|--help) usage 0 ;; -*) die "first argument must be the username" ;; esac
USERNAME="$1"; shift

while getopts ':d:k:c:s:a:o:h' opt; do
  case "$opt" in
    d) DIR="$OPTARG" ;;
    k) KEY="$OPTARG" ;;
    c) CLUSTER="$OPTARG" ;;
    s) SERVER="$OPTARG" ;;
    a) CA="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    h) usage 0 ;;
    :) die "-$OPTARG requires a value" ;;
    \?) die "unknown option -$OPTARG" ;;
  esac
done

command -v kubectl >/dev/null || die "kubectl not found"
command -v openssl >/dev/null || die "openssl not found"

DIR="${DIR:-./$USERNAME}"
KEY="${KEY:-$DIR/$USERNAME.key}"
CRT="$DIR/$USERNAME.crt"
OUT="${OUT:-$DIR/$USERNAME.kubeconfig}"

[ -d "$DIR" ] || die "$DIR does not exist -- run create-user-csr.sh first, or pass -d"
[ -f "$KEY" ] || die "no private key at $KEY -- it is never recoverable from the cluster; pass -k if it is elsewhere"

# ---- the CSR must be approved AND signed -------------------------------------

kubectl get csr "$USERNAME" >/dev/null 2>&1 \
  || die "no CertificateSigningRequest named '$USERNAME'"

approved="$(kubectl get csr "$USERNAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Approved")].status}')"
denied="$(kubectl get csr "$USERNAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Denied")].status}')"
failed="$(kubectl get csr "$USERNAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')"

[ "$denied" != "True" ] || die "CSR '$USERNAME' was denied"
[ "$failed" != "True" ] || die "CSR '$USERNAME' failed signing; inspect: kubectl describe csr $USERNAME"
[ "$approved" = "True" ] \
  || die "CSR '$USERNAME' is not approved yet. Approve it first: kubectl certificate approve $USERNAME"

echo "==> collecting the signed certificate"
cert_b64="$(kubectl get csr "$USERNAME" -o jsonpath='{.status.certificate}')"
# Approved but empty means the signing controller has not issued it yet.
[ -n "$cert_b64" ] \
  || die "CSR '$USERNAME' is approved but carries no certificate yet -- retry shortly, or check the signer is one this cluster signs"

printf '%s' "$cert_b64" | openssl base64 -d -A > "$CRT"
openssl x509 -in "$CRT" -noout >/dev/null 2>&1 \
  || die "what came back is not a certificate; inspect $CRT"

# ---- the key must belong to that certificate ---------------------------------
# Cheap guard against pointing at the wrong user's key: a mismatch produces a
# kubeconfig that fails its TLS handshake with nothing useful in the message.
key_mod="$(openssl rsa -in "$KEY" -noout -modulus 2>/dev/null)" \
  || die "cannot read $KEY as an RSA private key"
crt_mod="$(openssl x509 -in "$CRT" -noout -modulus)"
[ "$key_mod" = "$crt_mod" ] \
  || die "$KEY does not match the certificate just issued -- wrong key for this user?"

echo "    subject: $(openssl x509 -in "$CRT" -noout -subject | sed 's/^subject=//')"
echo "    expires: $(openssl x509 -in "$CRT" -noout -enddate | sed 's/^notAfter=//')"

# ---- cluster details, defaulting to the current context ----------------------

[ -n "$CLUSTER" ] || CLUSTER="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
[ -n "$SERVER" ]  || SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[ -n "$CLUSTER" ] || die "could not determine the cluster name; pass -c"
[ -n "$SERVER" ]  || die "could not determine the API server URL; pass -s"

if [ -z "$CA" ]; then
  # A kubeconfig may carry the CA inline or as a file path; handle both.
  ca_data="$(kubectl config view --raw --minify \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  if [ -n "$ca_data" ]; then
    CA_TMP="$(mktemp)"
    printf '%s' "$ca_data" | openssl base64 -d -A > "$CA_TMP"
    CA="$CA_TMP"
  else
    CA="$(kubectl config view --minify \
      -o jsonpath='{.clusters[0].cluster.certificate-authority}')"
  fi
fi
[ -n "$CA" ] && [ -f "$CA" ] || die "could not resolve a CA certificate; pass -a"

# ---- assemble ----------------------------------------------------------------

echo "==> writing $OUT"
echo "    cluster: $CLUSTER at $SERVER"
rm -f "$OUT"
( umask 077 && : > "$OUT" )

kubectl config set-cluster "$CLUSTER" \
  --server="$SERVER" --certificate-authority="$CA" --embed-certs=true \
  --kubeconfig="$OUT" >/dev/null

kubectl config set-credentials "$USERNAME" \
  --client-certificate="$CRT" --client-key="$KEY" --embed-certs=true \
  --kubeconfig="$OUT" >/dev/null

kubectl config set-context "$USERNAME@$CLUSTER" \
  --cluster="$CLUSTER" --user="$USERNAME" \
  --kubeconfig="$OUT" >/dev/null

kubectl config use-context "$USERNAME@$CLUSTER" --kubeconfig="$OUT" >/dev/null

cat <<EOF

Certificate: $CRT
Kubeconfig:  $OUT   (mode 0600 -- the private key is embedded in it)

Verify:
  kubectl --kubeconfig=$OUT auth whoami
  kubectl --kubeconfig=$OUT auth can-i --list -n website

If whoami reports the right user but everything is denied, no RoleBinding names
that username -- see README.md step 4.
EOF
