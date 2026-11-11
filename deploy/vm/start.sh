#!/bin/bash
# =============================================================================
# start.sh - Start the QuizArena Erlang node on this VM.
#
# Build with "rebar3 release" (default profile) -> _build/default/rel/quizarena.
# Auto-detects the local IP, generates vm.args, patches sys.config, creates
# the Mnesia dir, starts the node, verifies via erl -name (no eval, no hosts).
#
# Usage:
#   ./start.sh                          # auto-detect IP (primo 10.x.x.x)
#   LOCAL_IP=10.2.1.3 ./start.sh        # override IP
#
# Idempotent: safe to re-run (stops the previous instance first).
# =============================================================================

set -eu

# ---- Configuration (identica su tutte e 3 le VM) ----
CLUSTER_NODES="quizarena@10.2.1.3,quizarena@10.2.1.4,quizarena@10.2.1.5"
ERLANG_COOKIE="quizarena_demo_cookie"
REL_DIR="/opt/quizarena/_build/default/rel/quizarena"
LOG_FILE="/var/log/quizarena-erlang.log"

# ---- Rilevamento IP locale ----
LOCAL_IP="${LOCAL_IP:-$(hostname -I | tr ' ' '\n' | grep -m1 -E '^10\.' | tr -d '[:space:]')}"
if [ -z "${LOCAL_IP:-}" ]; then
    echo "ERROR: impossibile rilevare l'IP locale (nessun 10.x.x.x)."
    echo "Override: LOCAL_IP=10.2.1.3 $0"
    exit 1
fi
NODE_NAME_FULL="quizarena@$LOCAL_IP"
IFACE_BODY=$(echo "$LOCAL_IP" | tr '.' ',')
IFACE_TUPLE="{$IFACE_BODY}"

# ---- Rilevamento versione release ----
if [ ! -d "$REL_DIR/releases" ]; then
    echo "ERROR: $REL_DIR/releases non trovato."
    echo "Compila prima: cd /opt/quizarena && rebar3 release"
    exit 1
fi
VERS=$(ls "$REL_DIR/releases/" | grep -m1 -E '^[0-9]+\.[0-9]+' || true)
if [ -z "$VERS" ]; then
    echo "ERROR: nessuna release in $REL_DIR/releases/"
    exit 1
fi
REL_VERS_DIR="$REL_DIR/releases/$VERS"

echo "=== QuizArena start ==="
echo "Local IP:  $LOCAL_IP"
echo "Node name: $NODE_NAME_FULL"
echo "Release:   $VERS"

# ---- Template canonico (idempotente) ----
for f in /opt/quizarena/config/vm.args.src "$REL_VERS_DIR/vm.args.src"; do
    cat > "$f" <<'EOF'
-name ${NODE_NAME}
-setcookie ${ERLANG_COOKIE}
-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100
-kernel inet_dist_use_interface ${NODE_IFACE}
+K true
EOF
done

# ---- Genera vm.args ----
export NODE_NAME="$NODE_NAME_FULL"
export ERLANG_COOKIE
export NODE_IFACE="$IFACE_TUPLE"

envsubst < "$REL_VERS_DIR/vm.args.src" > "$REL_VERS_DIR/vm.args"
echo "--- vm.args ---"
sed 's/^/  /' "$REL_VERS_DIR/vm.args"
echo "---"

# ---- Patch sys.config con cluster_nodes ----
NODES_ATOMS=$(echo "$CLUSTER_NODES" | tr ',' '\n' | sed "s/.*/'&'/" | paste -sd, -)
for f in /opt/quizarena/config/sys.config "$REL_VERS_DIR/sys.config"; do
    if [ -f "$f" ]; then
        sed -i -E "s/\{cluster_nodes,\s*\[[^]]*\]\}/{cluster_nodes, [$NODES_ATOMS]}/" "$f"
    fi
done
echo "--- cluster_nodes in sys.config ---"
grep "cluster_nodes" "$REL_VERS_DIR/sys.config" || true
echo "---"

# ---- Ferma istanza precedente ----
if pgrep -f "quizarena.*foreground" > /dev/null 2>&1; then
    echo "Fermo l'istanza Erlang precedente..."
    pkill -f "quizarena.*foreground" || true
    sleep 2
fi

# ---- Prepara directory ----
echo "Preparo le directory..."
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$REL_DIR/data/mnesia"

# ---- Avvia il nodo ----
echo "Avvio del nodo..."
nohup "$REL_DIR/bin/quizarena" foreground > "$LOG_FILE" 2>&1 &

# ---- Attesa: processo vivo + registrato in epmd ----
echo "Attendo che il nodo sia registrato in epmd (max 20s)..."
READY=0
for i in $(seq 1 20); do
    sleep 1
    if pgrep -f "quizarena.*foreground" > /dev/null 2>&1 \
       && epmd -names 2>/dev/null | grep -q "^name quizarena at port"; then
        READY=1
        echo "Nodo pronto (registrato in epmd)."
        break
    fi
done

if [ "$READY" -eq 0 ]; then
    echo "ERROR: nodo non pronto dopo 20s."
    echo "--- pgrep ---"
    pgrep -af "quizarena.*foreground" || echo "(nessun processo)"
    echo "--- epmd -names ---"
    epmd -names 2>/dev/null || echo "(epmd non risponde)"
    echo "--- ultime 40 righe di $LOG_FILE ---"
    tail -40 "$LOG_FILE" 2>/dev/null || true
    exit 1
fi

# ---- Stato del cluster via erl -name ----
echo "=== Stato del cluster ==="
erl -name "check_$$@$LOCAL_IP" -setcookie "$ERLANG_COOKIE" -noshell -eval "
    N = list_to_atom(\"quizarena@$LOCAL_IP\"),
    io:format(\"node():           ~p~n\", [N]),
    case net_adm:ping(N) of
        pong ->
            io:format(\"ping:             pong~n\"),
            io:format(\"nodes():          ~p~n\", [rpc:call(N, erlang, nodes, [])]),
            io:format(\"running_db_nodes: ~p~n\", [rpc:call(N, mnesia, system_info, [running_db_nodes])]),
            io:format(\"leader:           ~p~n\", [rpc:call(N, quizarena_election, leader, [])]);
        pang ->
            io:format(\"ping:             pang (nodo non raggiungibile)~n\")
    end,
    halt()." 2>/dev/null || echo "(verifica via erl non disponibile)"
echo "=== Fine ==="