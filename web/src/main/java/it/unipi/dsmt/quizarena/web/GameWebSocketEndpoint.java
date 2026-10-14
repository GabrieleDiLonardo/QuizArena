package it.unipi.dsmt.quizarena.web;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.logging.Level;
import java.util.logging.Logger;

import com.ericsson.otp.erlang.OtpErlangAtom;
import com.ericsson.otp.erlang.OtpErlangObject;
import com.ericsson.otp.erlang.OtpErlangPid;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import it.unipi.dsmt.quizarena.erlang.ErlangClient;
import it.unipi.dsmt.quizarena.erlang.ErlangGameSession;
import it.unipi.dsmt.quizarena.erlang.ErlangServiceException;
import it.unipi.dsmt.quizarena.erlang.ErlangTermConverter;
import it.unipi.dsmt.quizarena.model.QuizId;
import it.unipi.dsmt.quizarena.model.QuizSummary;
import jakarta.websocket.CloseReason;
import jakarta.websocket.Endpoint;
import jakarta.websocket.EndpointConfig;
import jakarta.websocket.HandshakeResponse;
import jakarta.websocket.Session;
import jakarta.websocket.server.HandshakeRequest;
import jakarta.websocket.server.ServerEndpointConfig;
import jakarta.servlet.http.HttpSession;

public final class GameWebSocketEndpoint extends Endpoint {

    private static final long ERLANG_TIMEOUT_MILLIS = 5000;
    private static final String AUTHENTICATED_USERNAME_PROPERTY =
            GameWebSocketEndpoint.class.getName() + ".authenticatedUsername";
    private static final String HTTP_SESSION_PROPERTY =
            GameWebSocketEndpoint.class.getName() + ".httpSession";
    private static final ObjectMapper JSON = new ObjectMapper();
    // Tempo concesso al cluster per ripristinare una stanza il cui nodo e'
    // caduto: elezione del leader (alcuni secondi) piu' riavvio della room.
    private static final long ROOM_RECOVERY_TIMEOUT_MILLIS = 20000;
    private static final ScheduledExecutorService RECOVERY_WATCHDOG =
            Executors.newSingleThreadScheduledExecutor(task -> {
                Thread thread = new Thread(task, "quizarena-room-recovery");
                thread.setDaemon(true);
                return thread;
            });
    private static final Logger LOGGER = Logger.getLogger(
            GameWebSocketEndpoint.class.getName()
    );

    private final ErlangClient client;
    private final Object sendLock = new Object();
    private final Object erlangSessionLock = new Object();
    private final Object stateReplayLock = new Object();
    private final AtomicBoolean closing = new AtomicBoolean();
    private final List<Object> queuedEvents = new ArrayList<>();

    private Session webSocketSession;
    private ErlangGameSession erlangSession;
    private volatile String roomPin;
    private volatile String role;
    private String authenticatedUsername;
    private HttpSession httpSession;
    private boolean stateReplayInProgress;
    private volatile String pendingTimeProbe;
    private volatile long pendingTimeProbeStartedNanos;
    private volatile long measuredRoundTripMillis;
    private volatile ScheduledFuture<?> recoveryWatchdog;

    private GameWebSocketEndpoint(ErlangClient client) {
        this.client = Objects.requireNonNull(client);
    }

    public static ServerEndpointConfig configuration(ErlangClient client) {
        return ServerEndpointConfig.Builder
                .create(GameWebSocketEndpoint.class, "/game")
                .configurator(new Configurator(client))
                .build();
    }

    @Override
    public void onOpen(Session session, EndpointConfig config) {
        webSocketSession = session;
        Object handshakeSession = config.getUserProperties().get(
                HTTP_SESSION_PROPERTY);
        Object username = config.getUserProperties().get(
                AUTHENTICATED_USERNAME_PROPERTY);
        if (!(username instanceof String value) || value.isBlank()) {
            closeUnauthenticated(session);
            return;
        }
        authenticatedUsername = value;

        // La sessione HTTP locale esiste solo se l'utente e' passato da
        // questo Tomcat: serve a chiudere le WebSocket al logout.
        if (handshakeSession instanceof HttpSession valueSession
                && value.equals(AuthenticationSession.username(valueSession))
                && AuthenticationSession.registerWebSocket(
                        valueSession, session)) {
            httpSession = valueSession;
        }

        ErlangGameSession openedSession = client.openGameSession(
                new ErlangGameSession.Listener() {
                    @Override
                    public void onEvent(OtpErlangObject event) {
                        sendEvent(event);
                    }

                    @Override
                    public void onLinkExit(
                            OtpErlangPid pid,
                            OtpErlangObject reason
                    ) {
                        handleRoomExit(reason);
                    }

                    @Override
                    public void onFailure(IOException exception) {
                        LOGGER.log(
                                Level.WARNING,
                                "Erlang game session failed",
                                exception
                        );
                        closeForBackendFailure();
                    }
                }
        );

        synchronized (erlangSessionLock) {
            if (closing.get()) {
                openedSession.close();
                return;
            }
            erlangSession = openedSession;
        }

        session.addMessageHandler(String.class, this::handleMessage);
        sendJson(Map.of("type", "connected"));
        issueTimeProbe();
    }

    private void closeUnauthenticated(Session session) {
        closing.set(true);
        try {
            session.close(new CloseReason(
                    CloseReason.CloseCodes.VIOLATED_POLICY,
                    "Authentication required"
            ));
        } catch (IOException exception) {
            LOGGER.log(Level.FINE,
                    "Unable to close unauthenticated WebSocket", exception);
        }
    }

    private void handleMessage(String text) {
        try {
            JsonNode message = JSON.readTree(text);
            if (!message.isObject()) {
                throw new IllegalArgumentException("Message must be a JSON object");
            }

            String action = requiredText(message, "action");
            switch (action) {
                case "create_room" -> handleCreateRoom(message);
                case "cancel_room" -> handleCancelRoom();
                case "list_rooms" -> handleListRooms();
                case "join" -> handleJoin(message);
                case "rejoin" -> handleRejoin(message);
                case "host_rejoin" -> handleHostRejoin(message);
                case "start_game" -> handleStartGame();
                case "next_round" -> handleNextRound();
                case "answer" -> handleAnswer(message);
                case "time_probe_reply" -> handleTimeProbeReply(message);
                case "end_game" -> handleEndGame();
                case "list_browsable_quizzes" -> handleListBrowsableQuizzes();
                case "list_owned_quizzes" -> handleListOwnedQuizzes();
                default -> sendError("unsupported_action",
                        "Unsupported action: " + action);
            }
        } catch (JsonProcessingException | IllegalArgumentException exception) {
            sendError("invalid_message", exception.getMessage());
        } catch (ErlangServiceException exception) {
            sendError(exception.getReason(),
                    serviceErrorMessage(exception));
        } catch (IOException exception) {
            sendError("backend_unavailable", "Backend unavailable");
        }
    }

    // ---------- Handlers ----------

    private void handleCreateRoom(JsonNode message)
        throws IOException, ErlangServiceException {
    if (roomPin != null) {
        sendError("room_already_created",
                "This connection already owns a room");
        return;
    }
    JsonNode quizIdNode = message.path("quizId");
    if (!quizIdNode.isObject()) {
        throw new IllegalArgumentException("Missing quizId");
    }
    QuizId quizId = new QuizId(
            requiredLong(quizIdNode, "timestampMicros"),
            requiredLong(quizIdNode, "uniqueInteger"));

    String visibility = "public";
    JsonNode visibilityNode = message.get("visibility");
    if (visibilityNode != null && !visibilityNode.isNull()) {
        if (!visibilityNode.isTextual()) {
            sendError("invalid_request",
                    "Visibility must be public or private");
            return;
        }
        String candidate = visibilityNode.asText();
        if (!"public".equals(candidate) && !"private".equals(candidate)) {
            sendError("invalid_request",
                    "Visibility must be public or private");
            return;
        }
        visibility = candidate;
    }

    String pin = currentErlangSession().createRoom(
            quizId,
            authenticatedUsername,
            visibility,
            ERLANG_TIMEOUT_MILLIS
    );
    roomPin = pin;
    role = "host";
    sendJson(Map.of(
            "type", "room_created",
            "pin", pin,
            "visibility", visibility
    ));
    }

    private void handleCancelRoom()
            throws IOException, ErlangServiceException {
        if (roomPin == null) {
            sendError("room_not_created", "No room to cancel");
            return;
        }
        if (!"host".equals(role)) {
            sendError("not_host",
                    "Solo l'host puo' annullare la stanza");
            return;
        }
        currentErlangSession().cancelRoom(
                roomPin, ERLANG_TIMEOUT_MILLIS);
        String cancelledPin = roomPin;
        roomPin = null;
        role = null;
        sendJson(Map.of("type", "cancelled", "pin", cancelledPin));
    }

    private void handleListRooms() throws IOException, ErlangServiceException {
        var rooms = currentErlangSession().listRooms(ERLANG_TIMEOUT_MILLIS);
        sendJson(Map.of("type", "rooms", "rooms", rooms));
    }
    private void handleListOwnedQuizzes()
        throws IOException, ErlangServiceException {
            List<QuizSummary> quizzes = client.listOwnedQuizzes(
                    authenticatedUsername,
                    ERLANG_TIMEOUT_MILLIS);
            List<Map<String, Object>> out = new ArrayList<>();
            for (QuizSummary q : quizzes) {
                Map<String, Object> idMap = new HashMap<>();
                idMap.put("timestampMicros", q.id().timestampMicros());
                idMap.put("uniqueInteger", q.id().uniqueInteger());
                Map<String, Object> item = new HashMap<>();
                item.put("id", idMap);
                item.put("owner", q.owner());
                item.put("title", q.title());
                item.put("description", q.description());
                item.put("visibility", q.visibility());
                item.put("isOwn", true);
                out.add(item);
        }
    sendJson(Map.of("type", "quizzes", "quizzes", out));
}

    private void handleJoin(JsonNode message)
            throws IOException, ErlangServiceException {
        if (roomPin != null) {
            sendError("connection_already_associated",
                    "This connection is already associated with a room");
            return;
        }
        String pin = requiredText(message, "pin");
        currentErlangSession().join(
                pin,
                authenticatedUsername,
                ERLANG_TIMEOUT_MILLIS
        );
        this.roomPin = pin;
        this.role = "player";
        sendJson(Map.of("type", "joined",
                "username", authenticatedUsername, "pin", pin));
    }

    private void handleRejoin(JsonNode message)
            throws IOException, ErlangServiceException {
        if (roomPin != null) {
            sendError("connection_already_associated",
                    "This connection is already associated with a room");
            return;
        }
        String pin = requiredText(message, "pin");
        beginStateReplay();
        try {
            ErlangGameSession session = currentErlangSession();
            session.rejoin(
                    pin, authenticatedUsername, ERLANG_TIMEOUT_MILLIS);
            this.roomPin = pin;
            this.role = "player";
            Object playerState = session.getPlayerState(
                    pin,
                    authenticatedUsername,
                    ERLANG_TIMEOUT_MILLIS
            );
            sendJson(Map.of(
                    "type", "rejoined",
                    "pin", pin,
                    "state", playerState
            ));
            finishStateReplay(sequenceOf(playerState));
        } catch (IOException | ErlangServiceException exception) {
            releaseRoomAssociation();
            abortStateReplay();
            throw exception;
        }
    }

    private void handleHostRejoin(JsonNode message)
            throws IOException, ErlangServiceException {
        if (roomPin != null) {
            sendError("connection_already_associated",
                    "This connection is already associated with a room");
            return;
        }
        String pin = requiredText(message, "pin");
        beginStateReplay();
        try {
            Object hostState = currentErlangSession().hostRejoin(
                    pin, authenticatedUsername, ERLANG_TIMEOUT_MILLIS);
            this.roomPin = pin;
            this.role = "host";
            sendJson(Map.of(
                    "type", "host_rejoined",
                    "pin", pin,
                    "state", hostState
            ));
            finishStateReplay(sequenceOf(hostState));
        } catch (IOException | ErlangServiceException exception) {
            abortStateReplay();
            throw exception;
        }
    }

    private void handleStartGame()
            throws IOException, ErlangServiceException {
        if (roomPin == null) {
            sendError("room_not_created",
                    "Create a room before starting the game");
            return;
        }
        currentErlangSession().startGame(roomPin, ERLANG_TIMEOUT_MILLIS);
        sendJson(Map.of("type", "ok", "action", "start_game"));
    }

    private void handleNextRound()
            throws IOException, ErlangServiceException {
        if (roomPin == null) {
            sendError("room_not_created",
                    "Create a room before starting a round");
            return;
        }
        currentErlangSession().nextRound(roomPin, ERLANG_TIMEOUT_MILLIS);
        sendJson(Map.of("type", "ok", "action", "next_round"));
    }

    private void handleAnswer(JsonNode message)
            throws IOException, ErlangServiceException {
        if (roomPin == null || !"player".equals(role)) {
            sendError("room_not_created",
                    "Join a room before answering");
            return;
        }
        long round = requiredLong(message, "round");
        String answer = requiredText(message, "answer");
        long clientElapsedMillis = requiredLong(message,
                "clientElapsedMillis");
        if (clientElapsedMillis < 0) {
            throw new IllegalArgumentException(
                    "clientElapsedMillis must not be negative");
        }
        currentErlangSession().answer(
                roomPin, round, answer, clientElapsedMillis,
                measuredRoundTripMillis, ERLANG_TIMEOUT_MILLIS);
        sendJson(Map.of("type", "ok", "action", "answer"));
    }

    private void handleTimeProbeReply(JsonNode message) {
        String nonce = requiredText(message, "nonce");
        if (!nonce.equals(pendingTimeProbe)) {
            return;
        }
        measuredRoundTripMillis = Math.max(0,
                (System.nanoTime() - pendingTimeProbeStartedNanos)
                        / 1_000_000L);
        pendingTimeProbe = null;
    }

    private void handleEndGame()
            throws IOException, ErlangServiceException {
        if (roomPin == null) {
            sendError("room_not_created", "No room to end");
            return;
        }
        currentErlangSession().endGame(roomPin, ERLANG_TIMEOUT_MILLIS);
        sendJson(Map.of("type", "ok", "action", "end_game"));
    }

    // ---------- Internals ----------

    private void sendEvent(OtpErlangObject event) {
        // Un evento dalla room indica che e' viva (eventualmente ripristinata).
        cancelRecoveryWatchdog();
        try {
            Object converted = ErlangTermConverter.toJavaValue(event);
            if (converted instanceof Map<?, ?> map
                    && ("game_finished".equals(map.get("type"))
                        || "game_cancelled".equals(map.get("type")))) {
                // La partita e' conclusa: la connessione puo' entrare in
                // un'altra stanza senza notificare quella chiusa.
                clearRoomAssociation();
            }
            synchronized (stateReplayLock) {
                if (stateReplayInProgress) {
                    queuedEvents.add(converted);
                } else {
                    sendConvertedEvent(converted);
                }
            }
        } catch (IOException exception) {
            closeForBackendFailure();
        }
    }

    private void beginStateReplay() {
        synchronized (stateReplayLock) {
            stateReplayInProgress = true;
            queuedEvents.clear();
        }
    }

    private void finishStateReplay(long snapshotSequence) {
        synchronized (stateReplayLock) {
            for (Object event : queuedEvents) {
                if (sequenceOf(event) > snapshotSequence) {
                    sendConvertedEvent(event);
                }
            }
            queuedEvents.clear();
            stateReplayInProgress = false;
        }
    }

    private void abortStateReplay() {
        synchronized (stateReplayLock) {
            queuedEvents.clear();
            stateReplayInProgress = false;
        }
    }

    private void sendConvertedEvent(Object event) {
        sendJson(Map.of("type", "event", "event", event));
        if (event instanceof Map<?, ?> map
                && "round_started".equals(map.get("type"))) {
            issueTimeProbe();
        }
    }

    private void issueTimeProbe() {
        String nonce = UUID.randomUUID().toString();
        pendingTimeProbeStartedNanos = System.nanoTime();
        pendingTimeProbe = nonce;
        sendJson(Map.of("type", "time_probe", "nonce", nonce));
    }

    private static long sequenceOf(Object value) {
        if (value instanceof Map<?, ?> map
                && map.get("seq") instanceof Number sequence) {
            return sequence.longValue();
        }
        return -1;
    }

    private void sendError(String code, String message) {
        sendJson(Map.of(
                "type", "error",
                "code", code,
                "message", message
        ));
    }

    private static String serviceErrorMessage(
            ErlangServiceException exception
    ) {
        return switch (exception.getReason()) {
            case "not_owner" ->
                    "Il quiz non appartiene all'utente autenticato";
            case "not_host" ->
                    "Solo l'host puo' eseguire questa operazione";
            default -> exception.getMessage();
        };
    }

    private void sendJson(Object message) {
        try {
            String json = JSON.writeValueAsString(message);
            synchronized (sendLock) {
                if (webSocketSession != null
                        && webSocketSession.isOpen()) {
                    webSocketSession.getBasicRemote().sendText(json);
                }
            }
        } catch (IOException exception) {
            closeForBackendFailure();
        }
    }

    private void closeForBackendFailure() {
        if (!closing.compareAndSet(false, true)) {
            return;
        }

        releaseRoomAssociation();
        closeErlangSession();
        if (webSocketSession != null && webSocketSession.isOpen()) {
            try {
                webSocketSession.close(new CloseReason(
                        CloseReason.CloseCodes.UNEXPECTED_CONDITION,
                        "Backend communication failure"
                ));
            } catch (IOException exception) {
                // La connessione è già in chiusura.
            }
        }
    }

    @Override
    public void onClose(Session session, CloseReason closeReason) {
        closing.set(true);
        cancelRecoveryWatchdog();
        AuthenticationSession.unregisterWebSocket(httpSession, session);
        releaseRoomAssociation();
        closeErlangSession();
    }

    @Override
    public void onError(Session session, Throwable throwable) {
        LOGGER.log(Level.WARNING, "WebSocket game session failed", throwable);
        closeForBackendFailure();
    }

    private void closeErlangSession() {
        ErlangGameSession sessionToClose;
        synchronized (erlangSessionLock) {
            sessionToClose = erlangSession;
            erlangSession = null;
        }
        if (sessionToClose != null) {
            sessionToClose.close();
        }
    }

    // Chiusura della connessione: la room viene avvisata, ma la partita
    // prosegue. Un host disconnesso ha un periodo di grazia per rientrare;
    // l'annullamento avviene solo con l'azione esplicita cancel_room.
    private void releaseRoomAssociation() {
        synchronized (erlangSessionLock) {
            if (roomPin == null) {
                return;
            }
            if (erlangSession != null) {
                erlangSession.disconnect(roomPin);
            }
            roomPin = null;
            role = null;
        }
    }

    private void clearRoomAssociation() {
        synchronized (erlangSessionLock) {
            roomPin = null;
            role = null;
        }
    }

    // Un'uscita "normal" della room segue sempre game_finished o
    // game_cancelled, gia' inoltrati al client. Qualsiasi altro motivo
    // indica la perdita del nodo Erlang che la ospitava (o un suo crash):
    // il leader del cluster la ripristina altrove e la nuova room si
    // ri-collega a questa stessa mailbox. Se entro il timeout non arriva
    // alcun evento, la stanza e' considerata persa.
    private void handleRoomExit(OtpErlangObject reason) {
        if (new OtpErlangAtom("normal").equals(reason)) {
            return;
        }
        LOGGER.log(Level.WARNING, "Game room terminated: {0}", reason);
        sendJson(Map.of("type", "room_recovering"));
        cancelRecoveryWatchdog();
        recoveryWatchdog = RECOVERY_WATCHDOG.schedule(
                this::roomRecoveryFailed,
                ROOM_RECOVERY_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS);
    }

    private void roomRecoveryFailed() {
        recoveryWatchdog = null;
        clearRoomAssociation();
        sendError("room_failed", "La stanza non e' piu' disponibile");
    }

    private void cancelRecoveryWatchdog() {
        ScheduledFuture<?> watchdog = recoveryWatchdog;
        if (watchdog != null) {
            watchdog.cancel(false);
            recoveryWatchdog = null;
        }
    }

    private ErlangGameSession currentErlangSession() throws IOException {
        synchronized (erlangSessionLock) {
            if (erlangSession == null) {
                throw new IOException("Erlang game session is closed");
            }
            return erlangSession;
        }
    }

    private static String requiredText(JsonNode object, String fieldName) {
        JsonNode value = object.get(fieldName);
        if (value == null || !value.isTextual() || value.asText().isBlank()) {
            throw new IllegalArgumentException(
                    "Missing or invalid field: " + fieldName
            );
        }
        return value.asText();
    }

    private static long requiredLong(JsonNode object, String fieldName) {
        JsonNode value = object.get(fieldName);
        if (value != null) {
            if (value.isIntegralNumber() && value.canConvertToLong()) {
                return value.longValue();
            }
            if (value.isTextual()) {
                try {
                    return Long.parseLong(value.asText());
                } catch (NumberFormatException exception) {
                    // L'errore viene uniformato qui sotto.
                }
            }
        }
        throw new IllegalArgumentException(
                "Missing or invalid field: " + fieldName
        );
    }

    private static final class Configurator
            extends ServerEndpointConfig.Configurator {

        private final ErlangClient client;

        private Configurator(ErlangClient client) {
            this.client = client;
        }

        @Override
        public <T> T getEndpointInstance(Class<T> endpointClass)
                throws InstantiationException {
            return endpointClass.cast(new GameWebSocketEndpoint(client));
        }

        @Override
        public void modifyHandshake(
                ServerEndpointConfig endpointConfig,
                HandshakeRequest request,
                HandshakeResponse response
        ) {
            // Prima la sessione locale, poi il cookie firmato: la WebSocket
            // puo' essere instradata su un Tomcat diverso da quello del login.
            Object session = request.getHttpSession();
            String username = session instanceof HttpSession httpSession
                    ? AuthenticationSession.username(httpSession)
                    : null;
            if (username == null) {
                username = AuthToken.usernameFromCookieHeaders(
                        request.getHeaders().get("cookie"));
            }

            if (username == null) {
                endpointConfig.getUserProperties().remove(
                        AUTHENTICATED_USERNAME_PROPERTY);
                endpointConfig.getUserProperties().remove(
                        HTTP_SESSION_PROPERTY);
            } else {
                endpointConfig.getUserProperties().put(
                        AUTHENTICATED_USERNAME_PROPERTY, username);
                if (session != null) {
                    endpointConfig.getUserProperties().put(
                            HTTP_SESSION_PROPERTY, session);
                } else {
                    endpointConfig.getUserProperties().remove(
                            HTTP_SESSION_PROPERTY);
                }
            }
        }
    }

    private void handleListBrowsableQuizzes()
        throws IOException, ErlangServiceException {
    List<QuizSummary> quizzes = client.listBrowsableQuizzes(
            authenticatedUsername,
            ERLANG_TIMEOUT_MILLIS);
    List<Map<String, Object>> out = new ArrayList<>();
    for (QuizSummary q : quizzes) {
        Map<String, Object> idMap = new HashMap<>();
        idMap.put("timestampMicros", q.id().timestampMicros());
        idMap.put("uniqueInteger", q.id().uniqueInteger());
        Map<String, Object> item = new HashMap<>();
        item.put("id", idMap);
        item.put("owner", q.owner());
        item.put("title", q.title());
        item.put("description", q.description());
        item.put("visibility", q.visibility());
        item.put("isOwn", q.isOwn());
        out.add(item);
    }
    sendJson(Map.of("type", "browsable_quizzes", "quizzes", out));
}
}
