#!/bin/bash
# =============================================================================
# lb-test.sh - Verifica il bilanciamento di Nginx sui Tomcat.
#
# Invia N richieste a Nginx e conta quale Tomcat ha risposto, leggendo
# l'intestazione X-Upstream aggiunta da quizarena.conf.
#
# Uso:
#   ./lb-test.sh                       # 30 richieste a http://10.2.1.3
#   ./lb-test.sh 60                    # 60 richieste
#   ./lb-test.sh 30 http://10.2.1.3    # Nginx su un altro indirizzo
# =============================================================================

set -eu

N="${1:-30}"
NGINX="${2:-http://10.2.1.3}"
URL="$NGINX/quizarena/"

echo "Invio $N richieste a $URL"

RESULTS=$(for i in $(seq 1 "$N"); do
    curl -s -o /dev/null -D - "$URL?lbtest=$i" \
        | tr -d '\r' \
        | awk -F': ' 'tolower($1) == "x-upstream" { print $2; found = 1 }
                      END { if (!found) print "(nessuna intestazione)" }'
done)

echo
echo "Richieste per Tomcat:"
echo "$RESULTS" | sort | uniq -c | awk '{ c = $1; $1 = ""; sub(/^ /, "")
                                          printf "  %-22s %3d\n", $0, c }'

if echo "$RESULTS" | grep -q "nessuna intestazione"; then
    echo
    echo "Manca X-Upstream: controllare add_header in quizarena.conf"
    echo "e ricaricare Nginx (nginx -t && systemctl reload nginx)."
fi
