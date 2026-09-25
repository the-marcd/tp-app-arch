#!/usr/bin/env bash
#
# Generate a client key and x509 certificate signing request for a cluster user,
# then submit it to the API server as a CertificateSigningRequest.
#
# The identity comes from the CSR subject, not from the CertificateSigningRequest
# object: CN becomes the username Kubernetes authenticates as, and each O becomes
# a group. spec.username/spec.groups on the object describe whoever *submitted*
# it and have no bearing on the identity issued.
#
# Nothing here grants any access. The certificate only authenticates; RBAC is a
# separate step -- see README.md.
#
# Usage:
#   ./create-user-csr.sh <username> [-g group]... [-e seconds] [-o dir] [-n] [-h]
#
#   -g  group to embed as an O in the subject; repeatable
#   -e  requested certificate lifetime in seconds (default 7776000 = 90 days,
#       minimum 600 -- the API rejects anything lower)
#   -o  output directory (default ./<username>)
#   -n  write the manifest but do not submit it
set -euo pipefail

SIGNER="kubernetes.io/kube-apiserver-client"
EXPIRATION=7776000
# Not GROUPS: bash reserves that name for the current user's group IDs and an
# assignment to it silently does not stick.
SUBJECT_GROUPS=()
OUTDIR=""
SUBMIT=1

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit "${1:-0}"; }

[ $# -ge 1 ] || usage 1
case "$1" in -h|--help) usage 0 ;; -*) die "first argument must be the username" ;; esac
USERNAME="$1"; shift

while getopts ':g:e:o:nh' opt; do
  case "$opt" in
    g) SUBJECT_GROUPS+=("$OPTARG") ;;
    e) EXPIRATION="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    n) SUBMIT=0 ;;
    h) usage 0 ;;
    :) die "-$OPTARG requires a value" ;;
    \?) die "unknown option -$OPTARG" ;;
  esac
done

# CN lands in an x509 subject and becomes an RBAC subject name; keep it boring.
[[ "$USERNAME" =~ ^[a-zA-Z0-9._@-]+$ ]] \
  || die "username may only contain letters, digits, and . _ @ -"
[[ "$EXPIRATION" =~ ^[0-9]+$ ]] && [ "$EXPIRATION" -ge 600 ] \
  || die "expiration must be an integer >= 600 (the API server's minimum)"

OUTDIR="${OUTDIR:-./$USERNAME}"
KEY="$OUTDIR/$USERNAME.key"
CSR="$OUTDIR/$USERNAME.csr"
MANIFEST="$OUTDIR/$USERNAME-csr.yaml"

command -v openssl >/dev/null || die "openssl not found"
[ "$SUBMIT" -eq 0 ] || command -v kubectl >/dev/null || die "kubectl not found (use -n to skip submission)"

mkdir -p "$OUTDIR"
[ -e "$KEY" ] && die "$KEY already exists -- refusing to overwrite a private key"

# Build the subject: /CN=<user> plus one /O= per group.
SUBJECT="/CN=$USERNAME"
for g in ${SUBJECT_GROUPS+"${SUBJECT_GROUPS[@]}"}; do
  [[ "$g" =~ ^[a-zA-Z0-9._:@-]+$ ]] || die "group '$g' has characters that do not belong in an x509 O"
  SUBJECT="$SUBJECT/O=$g"
done

echo "==> generating a 2048-bit RSA key"
( umask 077 && openssl genrsa -out "$KEY" 2048 2>/dev/null )

echo "==> generating the certificate signing request"
echo "    subject: $SUBJECT"
openssl req -new -key "$KEY" -out "$CSR" -subj "$SUBJECT"

# openssl base64 -A rather than `base64 -w0`: -w0 is GNU-only, and the field
# must be a single unwrapped line.
REQUEST_B64="$(openssl base64 -A -in "$CSR")"

echo "==> writing $MANIFEST"
{
  echo "apiVersion: certificates.k8s.io/v1"
  echo "kind: CertificateSigningRequest"
  echo "metadata:"
  echo "  name: $USERNAME"
  echo "spec:"
  echo "  # The PEM CERTIFICATE REQUEST block, base64-encoded as the API requires."
  echo "  request: $REQUEST_B64"
  echo "  # This signer issues client certificates for authenticating to the API"
  echo "  # server. It is never auto-approved -- approval is always manual."
  echo "  signerName: $SIGNER"
  echo "  expirationSeconds: $EXPIRATION"
  echo "  usages:"
  echo "    - client auth"
} > "$MANIFEST"

if [ "$SUBMIT" -eq 0 ]; then
  echo
  echo "Not submitted (-n). To submit:"
  echo "  kubectl apply -f $MANIFEST"
else
  if kubectl get csr "$USERNAME" >/dev/null 2>&1; then
    die "a CertificateSigningRequest named '$USERNAME' already exists; delete it first: kubectl delete csr $USERNAME"
  fi
  echo "==> submitting"
  kubectl apply -f "$MANIFEST"
fi

cat <<EOF

Key:      $KEY   (never leaves this machine; it is not in the request)
CSR:      $CSR
Manifest: $MANIFEST

Next: approve it, then collect the signed certificate.
  kubectl certificate approve $USERNAME
  kubectl get csr $USERNAME -o jsonpath='{.status.certificate}' | base64 -d > $OUTDIR/$USERNAME.crt

The certificate authenticates but authorises nothing. Bind a role to it before
it can do anything -- see README.md.
EOF
