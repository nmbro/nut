#!/bin/sh
# Which root CA extension layout do both LibreSSL and OpenSSL accept for NIT's
# self-signed CA, and does a server certificate signed by it (with NIT's
# server.v3.ext, minus DNS:::1) verify? Prints one line per variant.
set -u
openssl version
d=$(mktemp -d); cd "$d" || exit 1
openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -new -nodes -newkey rsa:2048 -keyout srv.key -out srv.csr -subj "/CN=NIT data server" 2>/dev/null
cat > srv.ext <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = localhost6
DNS.3 = nut-server-1.localdomain
DNS.4 = 127.0.0.1
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = 127.1.2.3
EOF
ca() { # ca <name> <extension lines...>
  n=$1; shift
  { printf '[ req ]\ndistinguished_name = dn\nx509_extensions = extensions\nprompt = no\n\n'
    printf '[ dn ]\ncommonName = NUT Mock Root CA/OU=Test/O=NIT/ST=StateOfChaos/C=US\n\n[ extensions ]\n'
    for l in "$@"; do echo "$l"; done; } > "$n.conf"
  if ! openssl req -x509 -new -nodes -key ca.key -sha256 -days 2 -out "$n.pem" -config "$n.conf" 2>"$n.err"; then
    echo "$n: CA not created: $(grep -o 'name=[^,]*' "$n.err" | head -1)"; return
  fi
  aki=$(openssl x509 -in "$n.pem" -noout -text | grep -A1 'Authority Key Identifier' | tail -1 | tr -s ' ')
  if ! openssl x509 -req -in srv.csr -CA "$n.pem" -CAkey ca.key -CAcreateserial -days 2 -sha256 \
       -extfile srv.ext -out "$n-srv.pem" 2>"$n.err2"; then
    echo "$n: CA ok (AKI:$aki), server not signed: $(head -c 200 "$n.err2")"; return
  fi
  echo "$n: CA ok (AKI:${aki:- none}); server $(openssl verify -CAfile "$n.pem" "$n-srv.pem" 2>&1 | tail -1)"
}
ca current 'authorityKeyIdentifier=keyid:always,issuer' 'basicConstraints=critical,CA:TRUE' \
  'keyUsage=critical,digitalSignature,cRLSign,keyCertSign' 'subjectKeyIdentifier=hash'
ca skid-first 'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid:always,issuer' \
  'basicConstraints=critical,CA:TRUE' 'keyUsage=critical,digitalSignature,cRLSign,keyCertSign'
ca skid-first-keyid 'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid:always' \
  'basicConstraints=critical,CA:TRUE' 'keyUsage=critical,digitalSignature,cRLSign,keyCertSign'
ca no-aki 'basicConstraints=critical,CA:TRUE' 'keyUsage=critical,digitalSignature,cRLSign,keyCertSign' \
  'subjectKeyIdentifier=hash'
