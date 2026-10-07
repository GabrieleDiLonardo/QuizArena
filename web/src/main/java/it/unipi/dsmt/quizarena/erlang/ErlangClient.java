package it.unipi.dsmt.quizarena.erlang;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

import com.ericsson.otp.erlang.OtpErlangAtom;
import com.ericsson.otp.erlang.OtpErlangDecodeException;
import com.ericsson.otp.erlang.OtpErlangException;
import com.ericsson.otp.erlang.OtpErlangExit;
import com.ericsson.otp.erlang.OtpErlangList;
import com.ericsson.otp.erlang.OtpErlangLong;
import com.ericsson.otp.erlang.OtpErlangMap;
import com.ericsson.otp.erlang.OtpErlangObject;
import com.ericsson.otp.erlang.OtpErlangRef;
import com.ericsson.otp.erlang.OtpErlangTuple;
import com.ericsson.otp.erlang.OtpMbox;
import com.ericsson.otp.erlang.OtpNode;

import it.unipi.dsmt.quizarena.model.QuizId;
import it.unipi.dsmt.quizarena.model.QuizSummary;

public final class ErlangClient implements AutoCloseable {

    private final OtpNode node;

    // Crea un nodo Java JInterface con il nome e il cookie specificati
    public ErlangClient(String nodeName, String cookie) throws IOException {
        if (nodeName == null || nodeName.isBlank()) {
            throw new IllegalArgumentException("nodeName must not be blank");
        }
        if (cookie == null || cookie.isBlank()) {
            throw new IllegalArgumentException("cookie must not be blank");
        }

        this.node = new OtpNode(nodeName, cookie);
    }

    public String getNodeName() {
        return node.node();
    }

    public ErlangGameSession openGameSession(
            String remoteNode,
            String gatewayName,
            ErlangGameSession.Listener listener
    ) {
        return new ErlangGameSession(
                node,
                remoteNode,
                gatewayName,
                listener
        );
    }

    // Verifica entro il timeout se il nodo Erlang remoto è raggiungibile
    public boolean isReachable(String remoteNode, long timeoutMillis) {
        if (remoteNode == null || remoteNode.isBlank()) {
            throw new IllegalArgumentException("remoteNode must not be blank");
        }
        if (timeoutMillis <= 0) {
            throw new IllegalArgumentException("timeoutMillis must be positive");
        }

        return node.ping(remoteNode, timeoutMillis);
    }

    // Verifica il protocollo applicativo scambiando ping/pong con il gateway
    public boolean isGatewayReachable(
            String remoteNode,
            String gatewayName,
            long timeoutMillis
    ) {
        try {
            OtpErlangObject result = sendRequest(
                    remoteNode,
                    gatewayName,
                    new OtpErlangAtom("ping"),
                    timeoutMillis
            );

            return result instanceof OtpErlangTuple resultTuple
                    && resultTuple.arity() == 2
                    && new OtpErlangAtom("ok").equals(
                            resultTuple.elementAt(0)
                    )
                    && new OtpErlangAtom("pong").equals(
                            resultTuple.elementAt(1)
                    );
        } catch (IOException exception) {
            return false;
        }
    }

    // Richiede al gateway l'elenco sintetico dei quiz disponibili
    public List<QuizSummary> listQuizzes(
            String remoteNode,
            String gatewayName,
            long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangObject result = sendRequest(
                remoteNode,
                gatewayName,
                new OtpErlangAtom("list_quizzes"),
                timeoutMillis
        );

        if (!(result instanceof OtpErlangTuple resultTuple)
                || resultTuple.arity() != 2) {
            throw new IOException("Malformed result from Erlang gateway");
        }

        OtpErlangObject status = resultTuple.elementAt(0);
        OtpErlangObject content = resultTuple.elementAt(1);

        if (new OtpErlangAtom("error").equals(status)) {
            throw new ErlangServiceException(content.toString());
        }
        if (!new OtpErlangAtom("ok").equals(status)) {
            throw new IOException("Unknown result status from Erlang gateway");
        }
        if (!(content instanceof OtpErlangList quizList)) {
            throw new IOException("Expected a list of quizzes from Erlang");
        }

        List<QuizSummary> quizzes = new ArrayList<>(quizList.arity());
        for (OtpErlangObject quizTerm : quizList) {
            quizzes.add(decodeQuizSummary(quizTerm));
        }

        return List.copyOf(quizzes);
    }

    // Invia una richiesta al gateway e restituisce il Result di {Ref, Result}
    private OtpErlangObject sendRequest(
            String remoteNode,
            String gatewayName,
            OtpErlangObject requestBody,
            long timeoutMillis
    ) throws IOException {
        if (remoteNode == null || remoteNode.isBlank()) {
            throw new IllegalArgumentException("remoteNode must not be blank");
        }
        if (gatewayName == null || gatewayName.isBlank()) {
            throw new IllegalArgumentException("gatewayName must not be blank");
        }
        if (requestBody == null) {
            throw new IllegalArgumentException("request must not be null");
        }
        if (timeoutMillis <= 0) {
            throw new IllegalArgumentException("timeoutMillis must be positive");
        }

        OtpMbox mailbox = node.createMbox();

        try {
            OtpErlangRef reference = node.createRef();
            OtpErlangTuple requestMessage = new OtpErlangTuple(
                    new OtpErlangObject[] {
                        mailbox.self(),
                        reference,
                        requestBody
                    }
            );

            mailbox.send(gatewayName, remoteNode, requestMessage);
            OtpErlangObject message = mailbox.receive(timeoutMillis);

            if (message == null) {
                throw new IOException(
                        "Timed out waiting for the Erlang gateway"
                );
            }

            if (!(message instanceof OtpErlangTuple response)
                    || response.arity() != 2) {
                throw new IOException("Malformed response from Erlang gateway");
            }

            if (!reference.equals(response.elementAt(0))) {
                throw new IOException(
                        "Mismatched reference in Erlang gateway response"
                );
            }

            return response.elementAt(1);
        } catch (OtpErlangExit | OtpErlangDecodeException exception) {
            throw new IOException(
                    "Unable to receive the Erlang gateway response",
                    exception
            );
        } finally {
            mailbox.close();
        }
    }

    private static QuizSummary decodeQuizSummary(
            OtpErlangObject quizTerm
    ) throws IOException {
        if (!(quizTerm instanceof OtpErlangMap quizMap)) {
            throw new IOException("Expected an Erlang map for a quiz");
        }

        return new QuizSummary(
                decodeQuizId(requiredMapValue(quizMap, "id")),
                decodeString(requiredMapValue(quizMap, "owner"), "owner"),
                decodeString(requiredMapValue(quizMap, "title"), "title"),
                decodeString(
                        requiredMapValue(quizMap, "description"),
                        "description"
                )
        );
    }

    private static OtpErlangObject requiredMapValue(
            OtpErlangMap map,
            String key
    ) throws IOException {
        OtpErlangObject value = map.get(new OtpErlangAtom(key));

        if (value == null) {
            throw new IOException("Missing quiz field: " + key);
        }

        return value;
    }

    private static QuizId decodeQuizId(
            OtpErlangObject idTerm
    ) throws IOException {
        if (!(idTerm instanceof OtpErlangTuple idTuple)
                || idTuple.arity() != 2
                || !(idTuple.elementAt(0) instanceof OtpErlangLong timestamp)
                || !(idTuple.elementAt(1) instanceof OtpErlangLong unique)) {
            throw new IOException("Malformed quiz id from Erlang");
        }

        return new QuizId(timestamp.longValue(), unique.longValue());
    }

    private static String decodeString(
            OtpErlangObject stringTerm,
            String fieldName
    ) throws IOException {
        if (stringTerm instanceof com.ericsson.otp.erlang.OtpErlangString value) {
            return value.stringValue();
        }
        if (stringTerm instanceof OtpErlangList value) {
            try {
                return value.stringValue();
            } catch (OtpErlangException exception) {
                throw new IOException(
                        "Quiz field is not a string: " + fieldName,
                        exception
                );
            }
        }

        throw new IOException("Quiz field is not a string: " + fieldName);
    }

    // Chiude il nodo JInterface e libera le risorse associate
    @Override
    public void close() {
        node.close();
    }
}
