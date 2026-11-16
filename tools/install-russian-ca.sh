
#!/usr/bin/env bash
# install-russian-ca.sh
# Download and install Russian CA certificates.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$ROOT_DIR/ms-max/certs"
BASE_URL='https://gu-st.ru/content/lending'

for cmd in curl openssl mktemp; do
  command -v "$cmd" >/dev/null || {
    echo "$cmd is required" >&2
    exit 127
  }
done

mkdir -p "$CERT_DIR"

for name in russian_trusted_root_ca_pem.crt russian_trusted_sub_ca_pem.crt; do
  target="$CERT_DIR/$name"

  if [[ ! -s "$target" ]]; then
    tmp="$(mktemp "$CERT_DIR/.${name}.XXXXXX")"
    trap 'rm -f -- "$tmp"' EXIT

    curl --fail --silent --show-error --location --retry 2 \
      "$BASE_URL/$name" -o "$tmp"

    openssl x509 -in "$tmp" -noout -text | grep -q 'CA:TRUE' || {
      echo "Not a CA certificate: $name" >&2
      exit 65
    }

    mv -f -- "$tmp" "$target"
    trap - EXIT
  fi
done

openssl verify -CAfile "$CERT_DIR/russian_trusted_root_ca_pem.crt" \
  "$CERT_DIR/russian_trusted_sub_ca_pem.crt" >&2

if command -v update-ca-trust >/dev/null; then
  DEST='/etc/ca-certificates/trust-source/anchors'
  UPDATE=(update-ca-trust extract)
elif command -v update-ca-certificates >/dev/null; then
  DEST='/usr/local/share/ca-certificates/russian'
  UPDATE=(update-ca-certificates)
else
  echo 'Unsupported certificate store' >&2
  exit 69
fi

sudo install -d -m 0755 "$DEST"
sudo install -m 0644 "$CERT_DIR"/*.crt "$DEST/"
sudo "${UPDATE[@]}"
