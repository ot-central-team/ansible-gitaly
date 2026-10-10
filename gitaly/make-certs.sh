#!/usr/bin/env bash
# Run from a protected LOCAL directory, not the repo or an EC2 VM.
# bash /path/to/gitaly/make-certs.sh init-ca
# bash /path/to/gitaly/make-certs.sh issue batch-01 praefect-lab.tyagi.fun
set -euo pipefail
umask 077

fail() { printf '%s\n' "$*" >&2; exit 1; }
command -v openssl >/dev/null || fail 'OpenSSL is required.'

case "${1:-}" in
  init-ca)
    [[ $# -eq 1 ]] || fail 'Usage: make-certs.sh init-ca'
    [[ ! -e ca ]] || fail 'ca already exists; keep it for renewals. Refusing overwrite.'
    mkdir -m 700 ca
    # Interactive encrypted key: retain its passphrase in your password manager.
    openssl genpkey -algorithm RSA -aes-256-cbc -pkeyopt rsa_keygen_bits:3072 -out ca/ca.key
    openssl req -x509 -new -sha256 -days 1095 -key ca/ca.key -out ca/ca.crt \
      -subj '/CN=Gitaly Lab Root CA' \
      -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -addext 'subjectKeyIdentifier=hash'
    printf 'CA created. Keep ca/ca.key offline; distribute only ca/ca.crt.\n'
    ;;
  issue)
    [[ $# -eq 3 ]] || fail 'Usage: make-certs.sh issue NEW_BATCH_DIRECTORY PUBLIC_DNS_NAME'
    batch=$2
    endpoint=$3
    [[ "$batch" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || fail 'Use a simple new batch directory name.'
    [[ "$endpoint" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || fail 'Invalid DNS hostname.'
    [[ -f ca/ca.key && -f ca/ca.crt ]] || fail 'Initialize the CA first, or restore the SAME existing CA.'
    [[ ! -e "$batch" ]] || fail 'Batch exists; refusing overwrite.'
    openssl x509 -in ca/ca.crt -checkend 7776000 -noout || fail 'CA has less than 90 days left. Plan a CA rollover.'
    mkdir -m 700 "$batch"
    for role in praefect gitaly; do
      for number in 1 2 3; do
        node="$role-$number"
        sans="DNS:$node.gitaly-lab.internal"
        [[ "$role" != praefect ]] || sans="$sans,DNS:$endpoint"
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$batch/$node.key"
        openssl req -new -key "$batch/$node.key" -out "$batch/$node.csr" \
          -subj "/CN=$node.gitaly-lab.internal"
        printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
          'keyUsage=critical,digitalSignature,keyEncipherment' \
          'extendedKeyUsage=serverAuth' "subjectAltName=$sans" > "$batch/$node.ext"
        # Each signing operation prompts for the CA passphrase (six prompts).
        openssl x509 -req -sha256 -days 90 -in "$batch/$node.csr" \
          -CA ca/ca.crt -CAkey ca/ca.key -set_serial "0x$(openssl rand -hex 16)" \
          -extfile "$batch/$node.ext" -out "$batch/$node.crt"
        openssl verify -CAfile ca/ca.crt "$batch/$node.crt"
        openssl x509 -in "$batch/$node.crt" -noout -checkhost "$node.gitaly-lab.internal"
        if [[ "$role" == praefect ]]; then
          openssl x509 -in "$batch/$node.crt" -noout -checkhost "$endpoint"
        fi
      done
    done
    printf 'Issued six 90-day certificates in %s. Schedule renewal at day 60.\n' "$batch"
    ;;
  *) fail 'Usage: make-certs.sh init-ca | issue NEW_BATCH_DIRECTORY PUBLIC_DNS_NAME' ;;
esac
