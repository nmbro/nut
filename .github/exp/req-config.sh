#!/bin/sh
# Does "openssl req -new -subj ..." work with a minimal -config file, also
# where the system openssl.cnf is missing? (NetBSD 11.0's vmactions image has
# no /etc/openssl/openssl.cnf; OPENSSL_CONF=/nonexistent mimics that here.)
set -u
openssl version
d=$(mktemp -d); cd "$d" || exit 1
printf 'nit\n' > .pwfile
cat > server.req.conf <<'EOF'
[ req ]
distinguished_name = dn
prompt = no

[ dn ]
EOF
SUBJ="/CN=NIT data server/OU=Test/O=NIT/ST=StateOfChaos/C=US"
try() { # try <label> [env assignment] -- openssl req args...
  label=$1; shift
  if env "$@" -newkey rsa:2048 -passout file:.pwfile -keyout k.pem -out r.pem -subj "$SUBJ" >o.txt 2>&1; then
    echo "$label: OK, $(openssl req -in r.pem -noout -subject 2>&1)"
  else
    echo "$label: FAILED: $(grep -v '^\.' o.txt | tr '\n' ' ' | cut -c1-200)"
  fi
  rm -f k.pem r.pem
}
try "system config, no -config      " openssl req -new -nodes
try "no system config, no -config   " OPENSSL_CONF=/nonexistent openssl req -new -nodes
try "no system config, -config      " OPENSSL_CONF=/nonexistent openssl req -new -nodes -config server.req.conf
try "system config, -config         " openssl req -new -nodes -config server.req.conf
