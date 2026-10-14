package it.unipi.dsmt.quizarena.web;

import java.io.IOException;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import jakarta.servlet.http.HttpServletRequest;
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
    private static final String TOKEN_ATTRIBUTE =
            AuthenticationSession.class.getName() + ".token";

    // Sessioni di questo Tomcat per token di login: alla revoca del token
    // (logout, anche ricevuto da un altro Tomcat) vengono invalidate.
    private static final ConcurrentHashMap<String, Set<HttpSession>>
            SESSIONS_BY_TOKEN = new ConcurrentHashMap<>();

    private AuthenticationSession() {
    }

    public static String username(HttpSession session) {
        if (session == null) {
            return null;
        }

        try {
            Object value = session.getAttribute(USERNAME_ATTRIBUTE);
            if (value instanceof String username && !username.isBlank()
                    && !TokenRevocations.isRevoked(jti(session))) {
                return username;
            }
        } catch (IllegalStateException exception) {
            // La sessione e' stata invalidata mentre veniva controllata.
        }

        return null;
    }

    // Utente autenticato della richiesta. Se questo Tomcat non ha una
    // sessione per l'utente (login fatto su un altro nodo del cluster) ma il
    // cookie firmato e' valido, la sessione locale viene ricreata.
    public static String username(HttpServletRequest request) {
        String username = username(request.getSession(false));
        if (username != null) {
            return username;
        }
        AuthToken.Verified fromCookie = AuthToken.from(request);
        if (fromCookie == null) {
            return null;
        }
        bind(request.getSession(true), fromCookie);
        return fromCookie.username();
    }

    // Login della sessione: utente e token che lo autentica.
    public static void bind(HttpSession session, AuthToken.Verified token) {
        session.setAttribute(USERNAME_ATTRIBUTE, token.username());
        session.setAttribute(TOKEN_ATTRIBUTE, new TokenBinding(token));
    }

    // Token che autentica la sessione, oppure quello del cookie.
    public static AuthToken.Verified token(HttpServletRequest request) {
        HttpSession session = request.getSession(false);
        if (session != null) {
            try {
                if (session.getAttribute(TOKEN_ATTRIBUTE)
                        instanceof TokenBinding binding) {
                    return binding.token;
                }
            } catch (IllegalStateException exception) {
                // Sessione gia' invalidata.
            }
        }
        return AuthToken.from(request);
    }

    public static String jti(HttpSession session) {
        if (session == null) {
            return null;
        }
        try {
            return session.getAttribute(TOKEN_ATTRIBUTE)
                    instanceof TokenBinding binding
                    ? binding.token.jti()
                    : null;
        } catch (IllegalStateException exception) {
            return null;
        }
    }

    public static void invalidateSessions(String jti) {
        Set<HttpSession> sessions = SESSIONS_BY_TOKEN.remove(jti);
        if (sessions == null) {
            return;
        }
        for (HttpSession session : sessions) {
            try {
                session.invalidate();
            } catch (IllegalStateException exception) {
                // Gia' invalidata.
            }
        }
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

    // Registra la sessione per token finche' resta associata al login.
    private static final class TokenBinding
            implements HttpSessionBindingListener {

        private final AuthToken.Verified token;

        private TokenBinding(AuthToken.Verified token) {
            this.token = token;
        }

        @Override
        public void valueBound(HttpSessionBindingEvent event) {
            SESSIONS_BY_TOKEN
                    .computeIfAbsent(token.jti(),
                            key -> ConcurrentHashMap.newKeySet())
                    .add(event.getSession());
        }

        @Override
        public void valueUnbound(HttpSessionBindingEvent event) {
            SESSIONS_BY_TOKEN.computeIfPresent(token.jti(), (key, sessions) -> {
                sessions.remove(event.getSession());
                return sessions.isEmpty() ? null : sessions;
            });
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
