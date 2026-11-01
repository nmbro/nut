#!/bin/sh
# Which minimal -config makes "openssl req -new -subj ..." work everywhere,
# also where the system openssl.cnf is missing? (NetBSD 11.0's vmactions image
# has no /etc/openssl/openssl.cnf; OPENSSL_CONF=/nonexistent mimics that.)
set -u
openssl version
d=$(mktemp -d); cd "$d" || exit 1
printf 'nit\n' > .pwfile
printf '[ req ]\ndistinguished_name = dn\nprompt = no\n\n[ dn ]\n' > a-prompt-no-empty-dn.conf
printf '[ req ]\ndistinguished_name = dn\n\n[ dn ]\n' > b-empty-dn.conf
printf '[ req ]\ndistinguished_name = dn\nprompt = no\n\n[ dn ]\ncommonName = placeholder\n' > c-prompt-no-cn.conf
SUBJ="/CN=NIT data server/OU=Test/O=NIT/ST=StateOfChaos/C=US"
for c in *.conf; do
  for env in "" "OPENSSL_CONF=/nonexistent"; do
    if env $env openssl req -new -nodes -config "$c" -newkey rsa:2048 -passout file:.pwfile \
         -keyout k.pem -out r.pem -subj "$SUBJ" >o.txt 2>&1 </dev/null; then
      s=$(env $env openssl req -config "$c" -in r.pem -noout -subject 2>/dev/null)
      echo "$c ${env:-system-config}: OK, $s"
    else
      echo "$c ${env:-system-config}: FAILED: $(grep -iE 'error|problem' o.txt | tr '\n' ' ' | cut -c1-160)"
    fi
    rm -f k.pem r.pem
  done
done
