package it.unipi.dsmt.quizarena.web;

import java.io.IOException;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import jakarta.servlet.http.HttpSessionBindingEvent;
import jakarta.servlet.http.HttpSessionBindingListener;
import jakarta.servlet.http.HttpSession;
import jakarta.websocket.CloseReason;
import jakarta.websocket.Session;

public final class AuthenticationSession {

    public static final String USERNAME_ATTRIBUTE =
            AuthenticationSession.class.getName() + ".username";
    private static final String WEB_SOCKETS_ATTRIBUTE =
            AuthenticationSession.class.getName() + ".webSockets";

    private AuthenticationSession() {
    }

    public static String username(HttpSession session) {
        if (session == null) {
            return null;
        }

        try {
            Object value = session.getAttribute(USERNAME_ATTRIBUTE);
            if (value instanceof String username && !username.isBlank()) {
                return username;
            }
        } catch (IllegalStateException exception) {
            // La sessione e' stata invalidata mentre veniva controllata.
        }

        return null;
    }

    public static boolean registerWebSocket(
            HttpSession httpSession,
            Session webSocketSession
    ) {
        if (httpSession == null || username(httpSession) == null) {
            return false;
        }

        try {
            synchronized (httpSession) {
                Object current = httpSession.getAttribute(
                        WEB_SOCKETS_ATTRIBUTE);
                WebSocketRegistry registry;
                if (current instanceof WebSocketRegistry value) {
                    registry = value;
                } else {
                    registry = new WebSocketRegistry();
                    httpSession.setAttribute(
                            WEB_SOCKETS_ATTRIBUTE, registry);
                }
                registry.add(webSocketSession);
            }
            return true;
        } catch (IllegalStateException exception) {
            return false;
        }
    }

    public static void unregisterWebSocket(
            HttpSession httpSession,
            Session webSocketSession
    ) {
        if (httpSession == null) {
            return;
        }

        try {
            Object current = httpSession.getAttribute(
                    WEB_SOCKETS_ATTRIBUTE);
            if (current instanceof WebSocketRegistry registry) {
                registry.remove(webSocketSession);
            }
        } catch (IllegalStateException exception) {
            // La sessione HTTP è già stata invalidata.
        }
    }

    private static final class WebSocketRegistry
            implements HttpSessionBindingListener {

        private final Set<Session> sessions =
                ConcurrentHashMap.newKeySet();

        private void add(Session session) {
            sessions.add(session);
        }

        private void remove(Session session) {
            sessions.remove(session);
        }

        @Override
        public void valueUnbound(HttpSessionBindingEvent event) {
            CloseReason reason = new CloseReason(
                    CloseReason.CloseCodes.VIOLATED_POLICY,
                    "HTTP session ended"
            );
            for (Session session : sessions) {
                if (!session.isOpen()) {
                    continue;
                }
                try {
                    session.close(reason);
                } catch (IOException exception) {
                    // La connessione è già in chiusura.
                }
            }
            sessions.clear();
        }
    }
}
