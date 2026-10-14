# Immagine di una "VM" QuizArena: nodo Erlang (release OTP) + Tomcat.

# --- Backend Erlang ---
FROM erlang:28 AS erlang-build
WORKDIR /build
COPY rebar.config rebar.lock ./
RUN rebar3 get-deps && rebar3 compile --deps_only
COPY config ./config
COPY src ./src
RUN rebar3 release

# --- Web tier ---
FROM maven:3.9-eclipse-temurin-21 AS web-build
WORKDIR /build
COPY web/pom.xml ./
COPY web/src ./src
RUN mvn -q -B package -DskipTests

# --- Runtime ---
FROM tomcat:10.1-jdk21-temurin
RUN rm -rf /usr/local/tomcat/webapps/*
COPY --from=erlang-build /build/_build/default/rel/quizarena /opt/quizarena
COPY --from=web-build /build/target/quizarena.war /usr/local/tomcat/webapps/quizarena.war
COPY deploy/entrypoint.sh /usr/local/bin/quizarena-entrypoint
RUN chmod +x /usr/local/bin/quizarena-entrypoint
# Valori usati sia dall'entrypoint sia dai comandi di amministrazione
# (docker exec ... /opt/quizarena/bin/quizarena eval/remote_console).
ENV NODE_NAME=quizarena
EXPOSE 8080 4369 9100
ENTRYPOINT ["/usr/local/bin/quizarena-entrypoint"]
