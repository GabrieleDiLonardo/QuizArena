package it.unipi.dsmt.quizarena.web;

import java.io.IOException;
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
import jakarta.websocket.CloseReason;
import jakarta.websocket.Endpoint;
import jakarta.websocket.EndpointConfig;
import jakarta.websocket.Session;
import jakarta.websocket.server.ServerEndpointConfig;

public final class GameWebSocketEndpoint extends Endpoint {

    private static final long ERLANG_TIMEOUT_MILLIS = 5000;
    private static final int MAX_HOST_NAME_LENGTH = 50;
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Logger LOGGER = Logger.getLogger(
            GameWebSocketEndpoint.class.getName()
    );

    private final ErlangClient client;
    private final String backendNode;
    private final String gatewayName;
    private final Object sendLock = new Object();
    private final Object erlangSessionLock = new Object();
    private final AtomicBoolean closing = new AtomicBoolean();

    private Session webSocketSession;
    private ErlangGameSession erlangSession;
    private volatile String roomPin;
    private volatile Long playerId;     
    private volatile String role;  

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

    private void handleMessage(String text) {
    try {
        JsonNode message = JSON.readTree(text);
        if (!message.isObject()) {
            throw new IllegalArgumentException("Message must be a JSON object");
        }

        String action = requiredText(message, "action");
        switch (action) {
            case "create_room" -> handleCreateRoom(message);
            case "cancel_room" -> handleCancelRoom(message);
            case "list_quizzes" -> handleListQuizzes();
            case "list_rooms" -> handleListRooms();
            case "join" -> handleJoin(message);
            case "rejoin" -> handleRejoin(message);
            case "start_game" -> handleStartGame(message);
            case "next_round" -> handleNextRound(message);
            case "answer" -> handleAnswer(message);
            case "end_game" -> handleEndGame(message);
            default -> sendError("unsupported_action", "Unsupported action: " + action);
        }
        } catch (JsonProcessingException | IllegalArgumentException exception) {
            sendError("invalid_message", exception.getMessage());
        } catch (ErlangServiceException exception) {
            sendError("service_error", exception.getMessage());
        } catch (IOException exception) {
            sendError("backend_unavailable", "Backend unavailable");
        }
    }

private void handleCreateRoom(JsonNode message) throws IOException, ErlangServiceException {
    if (roomPin != null) {
        sendError("room_already_created", "This connection already owns a room");
        return;
    }
    JsonNode quizIdNode = message.path("quizId");
    if (!quizIdNode.isObject()) throw new IllegalArgumentException("Missing quizId");
    QuizId quizId = new QuizId(
            requiredLong(quizIdNode, "timestampMicros"),
            requiredLong(quizIdNode, "uniqueInteger"));
    String hostName = requiredText(message, "hostName").trim();
    if (hostName.length() > 50) throw new IllegalArgumentException("Host name is too long");

    String pin = currentErlangSession().createRoom(quizId, hostName, ERLANG_TIMEOUT_MILLIS);
    roomPin = pin;
    role = "host";
    sendJson(Map.of("type", "room_created", "pin", pin));
}

private void handleCancelRoom(JsonNode message) throws IOException {
    String pin = requiredText(message, "pin");
    currentErlangSession().cancelRoom(pin);
    if (pin.equals(roomPin)) roomPin = null;
    sendJson(Map.of("type", "cancelled", "pin", pin));
}

private void handleListQuizzes() throws IOException, ErlangServiceException {
    // Passa attraverso il client (non la session)
    // Nota: ErlangClient.listQuizzes è il metodo esistente
    // Qui usiamo la session per coerenza
    sendJson(Map.of("type", "error", "code", "not_implemented",
                    "message", "Use /quizzes for now"));
}

private void handleListRooms() throws IOException, ErlangServiceException {
    var rooms = currentErlangSession().listRooms(ERLANG_TIMEOUT_MILLIS);
    sendJson(Map.of("type", "rooms", "rooms", rooms));
}

private void handleJoin(JsonNode message) throws IOException, ErlangServiceException {
    String pin = requiredText(message, "pin");
    String nickname = requiredText(message, "nickname").trim();
    if (nickname.length() > 50) throw new IllegalArgumentException("Nickname too long");
    long pid = currentErlangSession().join(pin, nickname, ERLANG_TIMEOUT_MILLIS);
    this.playerId = pid;
    this.roomPin = pin;
    this.role = "player";
    sendJson(Map.of("type", "joined", "playerId", pid, "pin", pin));
}

private void handleRejoin(JsonNode message) throws IOException, ErlangServiceException {
    String pin = requiredText(message, "pin");
    long pid = requiredLong(message, "playerId");
    currentErlangSession().rejoin(pin, pid, ERLANG_TIMEOUT_MILLIS);
    this.playerId = pid;
    this.roomPin = pin;
    this.role = "player";
    sendJson(Map.of("type", "rejoined", "playerId", pid, "pin", pin));
}

private void handleStartGame(JsonNode message) throws IOException, ErlangServiceException {
    String pin = requiredText(message, "pin");
    currentErlangSession().startGame(pin, ERLANG_TIMEOUT_MILLIS);
    sendJson(Map.of("type", "ok", "action", "start_game"));
}

private void handleNextRound(JsonNode message) throws IOException, ErlangServiceException {
    String pin = requiredText(message, "pin");
    currentErlangSession().nextRound(pin, ERLANG_TIMEOUT_MILLIS);
    sendJson(Map.of("type", "ok", "action", "next_round"));
}

private void handleAnswer(JsonNode message) throws IOException, ErlangServiceException {
    String pin = requiredText(message, "pin");
    long pid = requiredLong(message, "playerId");
    long round = requiredLong(message, "round");
    String answer = requiredText(message, "answer");
    currentErlangSession().answer(pin, pid, round, answer, ERLANG_TIMEOUT_MILLIS);
    sendJson(Map.of("type", "ok", "action", "answer"));
}

private void handleEndGame(JsonNode message) throws IOException, ErlangServiceException {
    String pin = requiredText(message, "pin");
    currentErlangSession().endGame(pin, ERLANG_TIMEOUT_MILLIS);
    sendJson(Map.of("type", "ok", "action", "end_game"));
}

    private void sendEvent(OtpErlangObject event) {
        try {
            sendJson(Map.of(
                    "type", "event",
                    "event", ErlangTermConverter.toJavaValue(event)
            ));
        } catch (IOException exception) {
            closeForBackendFailure();
        }
    }

    private void sendError(String code, String message) {
        sendJson(Map.of(
                "type", "error",
                "code", code,
                "message", message
        ));
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

        cancelOwnedRoom();
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
        cancelOwnedRoom();
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

    private void cancelOwnedRoom() {
        synchronized (erlangSessionLock) {
            if (roomPin == null) {
                return;
            }
            if (erlangSession != null) {
                erlangSession.cancelRoom(roomPin);
            }
            roomPin = null;
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
    }
}
