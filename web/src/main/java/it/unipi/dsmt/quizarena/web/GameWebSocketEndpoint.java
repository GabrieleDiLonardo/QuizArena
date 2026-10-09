package it.unipi.dsmt.quizarena.web;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.logging.Level;
import java.util.logging.Logger;

import com.ericsson.otp.erlang.OtpErlangObject;
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
    private static final Logger LOGGER = Logger.getLogger(
            GameWebSocketEndpoint.class.getName()
    );

    private final ErlangClient client;
    private final String backendNode;
    private final String gatewayName;
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

    private GameWebSocketEndpoint(
            ErlangClient client,
            String backendNode,
            String gatewayName
    ) {
        this.client = Objects.requireNonNull(client);
        this.backendNode = Objects.requireNonNull(backendNode);
        this.gatewayName = Objects.requireNonNull(gatewayName);
    }

    public static ServerEndpointConfig configuration(
            ErlangClient client,
            String backendNode,
            String gatewayName
    ) {
        return ServerEndpointConfig.Builder
                .create(GameWebSocketEndpoint.class, "/game")
                .configurator(new Configurator(
                        client,
                        backendNode,
                        gatewayName
                ))
                .build();
    }

    @Override
    public void onOpen(Session session, EndpointConfig config) {
        webSocketSession = session;
        Object handshakeSession = config.getUserProperties().get(
                HTTP_SESSION_PROPERTY);
        Object username = config.getUserProperties().get(
                AUTHENTICATED_USERNAME_PROPERTY);
        if (!(handshakeSession instanceof HttpSession valueSession)
                || !(username instanceof String value)
                || value.isBlank()
                || !value.equals(AuthenticationSession.username(
                        valueSession))) {
            closeUnauthenticated(session);
            return;
        }
        httpSession = valueSession;
        authenticatedUsername = value;

        if (!AuthenticationSession.registerWebSocket(
                httpSession, session)) {
            closeUnauthenticated(session);
            return;
        }

        ErlangGameSession openedSession = client.openGameSession(
                backendNode,
                gatewayName,
                new ErlangGameSession.Listener() {
                    @Override
                    public void onEvent(OtpErlangObject event) {
                        sendEvent(event);
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
                case "start_game" -> handleStartGame();
                case "next_round" -> handleNextRound();
                case "answer" -> handleAnswer(message);
                case "end_game" -> handleEndGame();
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
        String pin = currentErlangSession().createRoom(
                quizId, authenticatedUsername, ERLANG_TIMEOUT_MILLIS);
        roomPin = pin;
        role = "host";
        sendJson(Map.of("type", "room_created", "pin", pin));
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
                backendNode,
                gatewayName,
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
        currentErlangSession().answer(
                roomPin, round, answer, ERLANG_TIMEOUT_MILLIS);
        sendJson(Map.of("type", "ok", "action", "answer"));
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
        try {
            Object converted = ErlangTermConverter.toJavaValue(event);
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

    private void releaseRoomAssociation() {
        synchronized (erlangSessionLock) {
            if (roomPin == null) {
                return;
            }
            if (erlangSession != null) {
                if ("host".equals(role)) {
                    erlangSession.cancelRoom(roomPin);
                } else if ("player".equals(role)) {
                    erlangSession.disconnectPlayer(roomPin);
                }
            }
            roomPin = null;
            role = null;
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
        private final String backendNode;
        private final String gatewayName;

        private Configurator(
                ErlangClient client,
                String backendNode,
                String gatewayName
        ) {
            this.client = client;
            this.backendNode = backendNode;
            this.gatewayName = gatewayName;
        }

        @Override
        public <T> T getEndpointInstance(Class<T> endpointClass)
                throws InstantiationException {
            return endpointClass.cast(new GameWebSocketEndpoint(
                    client,
                    backendNode,
                    gatewayName
            ));
        }

        @Override
        public void modifyHandshake(
                ServerEndpointConfig endpointConfig,
                HandshakeRequest request,
                HandshakeResponse response
        ) {
            Object session = request.getHttpSession();
            String username = session instanceof HttpSession httpSession
                    ? AuthenticationSession.username(httpSession)
                    : null;

            if (username == null) {
                endpointConfig.getUserProperties().remove(
                        AUTHENTICATED_USERNAME_PROPERTY);
                endpointConfig.getUserProperties().remove(
                        HTTP_SESSION_PROPERTY);
            } else {
                endpointConfig.getUserProperties().put(
                        AUTHENTICATED_USERNAME_PROPERTY, username);
                endpointConfig.getUserProperties().put(
                        HTTP_SESSION_PROPERTY, session);
            }
        }
    }
}
