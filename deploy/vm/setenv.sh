# /usr/share/tomcat10/bin/setenv.sh
# Unico per tutte e 3 le VM: auto-rileva l'IP locale.

export JAVA_HOME=/opt/java-25

LOCAL_IP=$(hostname -I | tr ' ' '\n' | grep -m1 -E '^10\.' | tr -d '[:space:]')
if [ -z "$LOCAL_IP" ]; then
    echo "WARN: IP locale 10.x.x.x non trovato in setenv.sh" >&2
fi

export QUIZARENA_ERLANG_NODE="quizarena_web@${LOCAL_IP}"
export QUIZARENA_COOKIE=quizarena_demo_cookie
export QUIZARENA_BACKEND_NODES="quizarena@${LOCAL_IP},quizarena@10.2.1.3,quizarena@10.2.1.4,quizarena@10.2.1.5"
export QUIZARENA_AUTH_SECRET=quizarena-demo-secret-change-me
export QUIZARENA_GATEWAY_NAME=quizarena_gateway
export QUIZARENA_CLUSTER_NODES=quizarena@10.2.1.3,quizarena@10.2.1.4,quizarena@10.2.1.5