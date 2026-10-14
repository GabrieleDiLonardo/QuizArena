#!/bin/sh
# Avvia su questa macchina il nodo Erlang e poi Tomcat.
# Variabili richieste: QUIZARENA_CLUSTER_NODES, ERLANG_COOKIE.
set -eu

HOST="$(hostname -s)"
export NODE_NAME="${NODE_NAME:-quizarena}"
export ERLANG_COOKIE="${ERLANG_COOKIE:?ERLANG_COOKIE mancante}"

# Il nodo Erlang scrive i suoi log sullo stdout del container.
/opt/quizarena/bin/quizarena foreground &

# Tomcat parte subito: finche' il nodo locale non e' pronto (ad esempio
# perche' attende il seed Mnesia) il web tier usa un altro nodo del
# cluster, e torna a quello locale appena risponde.
export QUIZARENA_ERLANG_NODE="quizarena_web@${HOST}"
export QUIZARENA_COOKIE="${ERLANG_COOKIE}"
export QUIZARENA_BACKEND_NODES="${NODE_NAME}@${HOST},${QUIZARENA_CLUSTER_NODES}"

exec catalina.sh run
