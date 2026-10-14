package it.unipi.dsmt.quizarena.web;

import java.util.Collection;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.logging.Logger;

// Token di login revocati con il logout, noti a questo Tomcat.
// L'elenco e' mantenuto dal cluster Erlang (tabella Mnesia replicata) e
// arriva qui in push: alla iscrizione l'elenco completo, poi ogni nuova
// revoca, anche se il logout e' stato ricevuto da un altro Tomcat. Alla
// revoca vengono chiuse le sessioni HTTP e le WebSocket aperte con quel
// token su questo Tomcat.
public final class TokenRevocations {

    private static final Logger LOGGER =
            Logger.getLogger(TokenRevocations.class.getName());
    private static final Set<String> REVOKED = ConcurrentHashMap.newKeySet();

    private TokenRevocations() {
    }

    public static boolean isRevoked(String jti) {
        return jti != null && REVOKED.contains(jti);
    }

    // Elenco completo, ricevuto a ogni (re)iscrizione al cluster: copre le
    // revoche eventualmente perse mentre l'iscrizione non era attiva.
    public static void replaceAll(Collection<String> jtis) {
        REVOKED.addAll(jtis);
        REVOKED.retainAll(Set.copyOf(jtis));
        jtis.forEach(TokenRevocations::closeEverything);
    }

    public static void revoke(String jti) {
        if (REVOKED.add(jti)) {
            LOGGER.info("Login token revoked");
        }
        closeEverything(jti);
    }

    private static void closeEverything(String jti) {
        AuthenticationSession.invalidateSessions(jti);
        GameWebSocketEndpoint.closeConnections(jti);
    }
}
