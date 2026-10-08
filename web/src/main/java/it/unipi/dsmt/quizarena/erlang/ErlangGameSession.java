package it.unipi.dsmt.quizarena.erlang;

import java.io.IOException;
import java.util.Objects;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

import com.ericsson.otp.erlang.OtpErlangAtom;
import com.ericsson.otp.erlang.OtpErlangDecodeException;
import com.ericsson.otp.erlang.OtpErlangException;
import com.ericsson.otp.erlang.OtpErlangExit;
import com.ericsson.otp.erlang.OtpErlangList;
import com.ericsson.otp.erlang.OtpErlangLong;
import com.ericsson.otp.erlang.OtpErlangObject;
import com.ericsson.otp.erlang.OtpErlangRef;
import com.ericsson.otp.erlang.OtpErlangString;
import com.ericsson.otp.erlang.OtpErlangTuple;
import com.ericsson.otp.erlang.OtpMbox;
import com.ericsson.otp.erlang.OtpNode;

import it.unipi.dsmt.quizarena.model.QuizId;

public class ErlangGameSession implements AutoCloseable {

    public interface Listener {

        void onEvent(OtpErlangObject event);

        void onFailure(IOException exception);
    }

    private static final OtpErlangAtom EVENT = new OtpErlangAtom("event");
    private static final AtomicLong SESSION_COUNTER = new AtomicLong();

    private OtpNode node;
    private OtpMbox mailbox;
    private String remoteNode;
    private String gatewayName;
    private Listener listener;
    private ConcurrentHashMap<
            OtpErlangRef,
            CompletableFuture<OtpErlangObject>
    > pendingRequests = new ConcurrentHashMap<>();
    private AtomicBoolean open = new AtomicBoolean(true);
    private Thread receiverThread;

    ErlangGameSession(
            OtpNode node,
            String remoteNode,
            String gatewayName,
            Listener listener
    ) {
        this.node = Objects.requireNonNull(node, "node must not be null");
        this.remoteNode = requireText(remoteNode, "remoteNode");
        this.gatewayName = requireText(gatewayName, "gatewayName");
        this.listener = Objects.requireNonNull(
                listener,
                "listener must not be null"
        );
        this.mailbox = node.createMbox();
        this.receiverThread = new Thread(
                this::receiveLoop,
                "quizarena-erlang-game-"
                        + SESSION_COUNTER.incrementAndGet()
        );
        receiverThread.setDaemon(true);
        receiverThread.start();
    }

    // ---------- API pubblica ----------

    public String createRoom(
            QuizId quizId,
            String hostName,
            long timeoutMillis
    ) throws IOException, ErlangServiceException {
        Objects.requireNonNull(quizId, "quizId must not be null");
        requireText(hostName, "hostName");

        OtpErlangTuple erlangQuizId = new OtpErlangTuple(
                new OtpErlangObject[] {
                    new OtpErlangLong(quizId.timestampMicros()),
                    new OtpErlangLong(quizId.uniqueInteger())
                }
        );
        OtpErlangTuple request = new OtpErlangTuple(
                new OtpErlangObject[] {
                    new OtpErlangAtom("create_room"),
                    erlangQuizId,
                    new OtpErlangString(hostName)
                }
        );

        OtpErlangObject result = sendRequest(request, timeoutMillis);
        return decodeStringResult(result, "room PIN");
    }

    public void cancelRoom(String pin) {
        requireText(pin, "pin");
        if (!open.get()) {
            return;
        }

        OtpErlangRef reference = node.createRef();
        OtpErlangTuple request = new OtpErlangTuple(
                new OtpErlangObject[] {
                    new OtpErlangAtom("cancel_room"),
                    new OtpErlangString(pin)
                }
        );
        OtpErlangTuple requestMessage = new OtpErlangTuple(
                new OtpErlangObject[] {
                    mailbox.self(),
                    reference,
                    request
                }
        );
        mailbox.send(gatewayName, remoteNode, requestMessage);
    }

    public long join(String pin, String nickname, long timeoutMillis)
            throws IOException, ErlangServiceException {
        requireText(pin, "pin");
        requireText(nickname, "nickname");
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[] {
            new OtpErlangAtom("join"),
            new OtpErlangString(pin),
            new OtpErlangString(nickname)
        });
        OtpErlangObject result = sendRequest(request, timeoutMillis);
        return decodeLongResult(result, "playerId");
    }

    public long rejoin(String pin, long playerId, long timeoutMillis)
            throws IOException, ErlangServiceException {
        requireText(pin, "pin");
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[] {
            new OtpErlangAtom("rejoin"),
            new OtpErlangString(pin),
            new OtpErlangLong(playerId)
        });
        OtpErlangObject result = sendRequest(request, timeoutMillis);
        return decodeLongResult(result, "playerId");
    }

    public void startGame(String pin, long timeoutMillis)
            throws IOException, ErlangServiceException {
        requireText(pin, "pin");
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[] {
            new OtpErlangAtom("start_game"),
            new OtpErlangString(pin)
        });
        decodeOkResult(sendRequest(request, timeoutMillis));
    }

    public void nextRound(String pin, long timeoutMillis)
            throws IOException, ErlangServiceException {
        requireText(pin, "pin");
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[] {
            new OtpErlangAtom("next_round"),
            new OtpErlangString(pin)
        });
        decodeOkResult(sendRequest(request, timeoutMillis));
    }

    public void answer(String pin, long playerId, long round, String answer,
                       long timeoutMillis)
            throws IOException, ErlangServiceException {
        requireText(pin, "pin");
        requireText(answer, "answer");
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[] {
            new OtpErlangAtom("answer"),
            new OtpErlangString(pin),
            new OtpErlangLong(playerId),
            new OtpErlangLong(round),
            new OtpErlangString(answer)
        });
        decodeOkResult(sendRequest(request, timeoutMillis));
    }

    public void endGame(String pin, long timeoutMillis)
            throws IOException, ErlangServiceException {
        requireText(pin, "pin");
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[] {
            new OtpErlangAtom("end_game"),
            new OtpErlangString(pin)
        });
        decodeOkResult(sendRequest(request, timeoutMillis));
    }

    public java.util.List<Object> listRooms(long timeoutMillis)
            throws IOException, ErlangServiceException {
        OtpErlangObject result = sendRequest(
                new OtpErlangAtom("list_rooms"), timeoutMillis);
        if (!(result instanceof OtpErlangTuple t) || t.arity() != 2) {
            throw new IOException("Malformed result from list_rooms");
        }
        if (new OtpErlangAtom("error").equals(t.elementAt(0))) {
            throw new ErlangServiceException(t.elementAt(1).toString());
        }
        if (!(t.elementAt(1) instanceof OtpErlangList list)) {
            throw new IOException("Expected a list of rooms");
        }
        java.util.List<Object> out = new java.util.ArrayList<>();
        for (OtpErlangObject item : list) {
            out.add(ErlangTermConverter.toJavaValue(item));
        }
        return out;
    }

    // ---------- Internals ----------

    private OtpErlangObject sendRequest(
            OtpErlangObject requestBody,
            long timeoutMillis
    ) throws IOException {
        Objects.requireNonNull(requestBody, "request must not be null");
        if (timeoutMillis <= 0) {
            throw new IllegalArgumentException("timeoutMillis must be positive");
        }
        if (!open.get()) {
            throw new IOException("Erlang game session is closed");
        }

        OtpErlangRef reference = node.createRef();
        CompletableFuture<OtpErlangObject> response =
                new CompletableFuture<>();
        pendingRequests.put(reference, response);

        try {
            if (!open.get()) {
                throw new IOException("Erlang game session is closed");
            }

            OtpErlangTuple requestMessage = new OtpErlangTuple(
                    new OtpErlangObject[] {
                        mailbox.self(),
                        reference,
                        requestBody
                    }
            );
            mailbox.send(gatewayName, remoteNode, requestMessage);

            return response.get(timeoutMillis, TimeUnit.MILLISECONDS);
        } catch (TimeoutException exception) {
            throw new IOException(
                    "Timed out waiting for the Erlang gateway",
                    exception
            );
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new IOException(
                    "Interrupted while waiting for the Erlang gateway",
                    exception
            );
        } catch (ExecutionException exception) {
            Throwable cause = exception.getCause();
            if (cause instanceof IOException ioException) {
                throw ioException;
            }
            throw new IOException(
                    "Unable to receive the Erlang gateway response",
                    cause
            );
        } finally {
            pendingRequests.remove(reference);
        }
    }

    private void receiveLoop() {
        try {
            while (open.get()) {
                OtpErlangObject message = mailbox.receive(1000);
                if (message != null) {
                    dispatch(message);
                }
            }
        } catch (OtpErlangExit | OtpErlangDecodeException exception) {
            fail(new IOException(
                    "Unable to receive from the Erlang game mailbox",
                    exception
            ));
        } catch (RuntimeException exception) {
            fail(new IOException(
                    "Unexpected Erlang game session failure",
                    exception
            ));
        }
    }

    private void dispatch(OtpErlangObject message) {
        if (!(message instanceof OtpErlangTuple tuple)
                || tuple.arity() != 2) {
            fail(new IOException("Malformed message from Erlang"));
            return;
        }

        OtpErlangObject messageType = tuple.elementAt(0);
        OtpErlangObject content = tuple.elementAt(1);

        if (messageType instanceof OtpErlangRef reference) {
            CompletableFuture<OtpErlangObject> response =
                    pendingRequests.remove(reference);
            if (response != null) {
                response.complete(content);
            }
            return;
        }

        if (EVENT.equals(messageType)) {
            listener.onEvent(content);
            return;
        }

        fail(new IOException("Unknown message type from Erlang"));
    }

    private void fail(IOException exception) {
        if (!open.getAndSet(false)) {
            return;
        }

        mailbox.close();
        pendingRequests.forEach(
                (_Reference, response) ->
                        response.completeExceptionally(exception)
        );
        pendingRequests.clear();
        listener.onFailure(exception);
    }

    // ---------- Decodifica risposte ----------

    private static String decodeStringResult(
            OtpErlangObject result,
            String expectedValue
    ) throws IOException, ErlangServiceException {
        if (!(result instanceof OtpErlangTuple tuple)
                || tuple.arity() != 2) {
            throw new IOException("Malformed result from Erlang gateway");
        }

        OtpErlangObject status = tuple.elementAt(0);
        OtpErlangObject content = tuple.elementAt(1);

        if (new OtpErlangAtom("error").equals(status)) {
            throw new ErlangServiceException(content.toString());
        }
        if (!new OtpErlangAtom("ok").equals(status)) {
            throw new IOException("Unknown result status from Erlang gateway");
        }
        if (content instanceof OtpErlangString value) {
            return value.stringValue();
        }
        if (content instanceof OtpErlangList value) {
            try {
                return value.stringValue();
            } catch (OtpErlangException exception) {
                throw new IOException(
                        "Expected an Erlang string for " + expectedValue,
                        exception
                );
            }
        }

        throw new IOException(
                "Expected an Erlang string for " + expectedValue
        );
    }

    private static long decodeLongResult(OtpErlangObject result, String ctx)
            throws IOException, ErlangServiceException {
        if (!(result instanceof OtpErlangTuple t) || t.arity() != 2) {
            throw new IOException("Malformed result from " + ctx);
        }
        if (new OtpErlangAtom("error").equals(t.elementAt(0))) {
            throw new ErlangServiceException(t.elementAt(1).toString());
        }
        if (!new OtpErlangAtom("ok").equals(t.elementAt(0))) {
            throw new IOException("Unknown status from " + ctx);
        }
        if (!(t.elementAt(1) instanceof OtpErlangLong v)) {
            throw new IOException("Expected long from " + ctx);
        }
        return v.longValue();
    }

    private static void decodeOkResult(OtpErlangObject result)
            throws IOException, ErlangServiceException {
        if (!(result instanceof OtpErlangTuple t) || t.arity() != 2) {
            throw new IOException("Malformed result");
        }
        if (new OtpErlangAtom("error").equals(t.elementAt(0))) {
            throw new ErlangServiceException(t.elementAt(1).toString());
        }
        // {ok, ok} oppure {ok, Value}
    }

    private static void decodeAtomResult(
            OtpErlangObject result,
            String expectedAtom
    ) throws IOException, ErlangServiceException {
        if (!(result instanceof OtpErlangTuple tuple)
                || tuple.arity() != 2) {
            throw new IOException("Malformed result from Erlang gateway");
        }

        OtpErlangObject status = tuple.elementAt(0);
        OtpErlangObject content = tuple.elementAt(1);

        if (new OtpErlangAtom("error").equals(status)) {
            throw new ErlangServiceException(content.toString());
        }
        if (!new OtpErlangAtom("ok").equals(status)
                || !new OtpErlangAtom(expectedAtom).equals(content)) {
            throw new IOException("Unexpected result from Erlang gateway");
        }
    }

    private static String requireText(String value, String name) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(name + " must not be blank");
        }
        return value;
    }

    @Override
    public void close() {
        if (!open.getAndSet(false)) {
            return;
        }

        mailbox.close();
        receiverThread.interrupt();
        IOException exception = new IOException("Erlang game session closed");
        pendingRequests.forEach(
                (_Reference, response) ->
                        response.completeExceptionally(exception)
        );
        pendingRequests.clear();
    }
}