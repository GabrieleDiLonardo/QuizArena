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
import com.ericsson.otp.erlang.OtpErlangString;
import com.ericsson.otp.erlang.OtpErlangTuple;
import com.ericsson.otp.erlang.OtpMbox;
import com.ericsson.otp.erlang.OtpNode;

import it.unipi.dsmt.quizarena.model.QuizId;
import it.unipi.dsmt.quizarena.model.QuizDetails;
import it.unipi.dsmt.quizarena.model.QuizDraft;
import it.unipi.dsmt.quizarena.model.QuizQuestion;
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

    // Registra un account tramite il servizio di autenticazione Erlang
    public void registerUser(
            String remoteNode,
            String gatewayName,
            String username,
            String password,
            long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(
                new OtpErlangObject[] {
                    new OtpErlangAtom("register_user"),
                    new OtpErlangString(username),
                    new OtpErlangString(password)
                }
        );
        OtpErlangObject content = requireOk(sendRequest(
                remoteNode,
                gatewayName,
                request,
                timeoutMillis
        ));

        if (!new OtpErlangAtom("registered").equals(content)) {
            throw new IOException("Unexpected registration result from Erlang");
        }
    }

    // Verifica le credenziali e restituisce lo username riconosciuto da Erlang
    public String authenticateUser(
            String remoteNode,
            String gatewayName,
            String username,
            String password,
            long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(
                new OtpErlangObject[] {
                    new OtpErlangAtom("authenticate_user"),
                    new OtpErlangString(username),
                    new OtpErlangString(password)
                }
        );
        OtpErlangObject content = requireOk(sendRequest(
                remoteNode,
                gatewayName,
                request,
                timeoutMillis
        ));

        return decodeString(content, "username");
    }

    public List<QuizSummary> listOwnedQuizzes(
            String remoteNode,
            String gatewayName,
            String owner,
            long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(
                new OtpErlangObject[] {
                    new OtpErlangAtom("list_owned_quizzes"),
                    new OtpErlangString(owner)
                }
        );
        OtpErlangObject content = requireOk(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis));
        if (!(content instanceof OtpErlangList quizList)) {
            throw new IOException("Expected a list of owned quizzes");
        }

        List<QuizSummary> quizzes = new ArrayList<>(quizList.arity());
        for (OtpErlangObject quizTerm : quizList) {
            quizzes.add(decodeQuizSummary(quizTerm));
        }
        return List.copyOf(quizzes);
    }

    public QuizDetails getOwnedQuiz(
            String remoteNode,
            String gatewayName,
            String owner,
            QuizId quizId,
            long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(
                new OtpErlangObject[] {
                    new OtpErlangAtom("get_owned_quiz"),
                    new OtpErlangString(owner),
                    encodeQuizId(quizId)
                }
        );
        return decodeQuizDetails(requireOk(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis)));
    }

    public QuizId createQuiz(
            String remoteNode,
            String gatewayName,
            String owner,
            QuizDraft quiz,
            long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(
                new OtpErlangObject[] {
                    new OtpErlangAtom("create_quiz"),
                    new OtpErlangString(owner),
                    encodeQuizDraft(quiz)
                }
        );
        return decodeQuizId(requireOk(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis)));
    }

    public void updateQuiz(
            String remoteNode,
            String gatewayName,
            String owner,
            QuizId quizId,
            QuizDraft quiz,
            long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(
                new OtpErlangObject[] {
                    new OtpErlangAtom("update_quiz"),
                    new OtpErlangString(owner),
                    encodeQuizId(quizId),
                    encodeQuizDraft(quiz)
                }
        );
        requireOkAtom(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis));
    }

    public void deleteQuiz(
            String remoteNode,
            String gatewayName,
            String owner,
            QuizId quizId,
            long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(
                new OtpErlangObject[] {
                    new OtpErlangAtom("delete_quiz"),
                    new OtpErlangString(owner),
                    encodeQuizId(quizId)
                }
        );
        requireOkAtom(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis));
    }

    private static OtpErlangObject requireOk(
            OtpErlangObject result
    ) throws IOException, ErlangServiceException {
        if (!(result instanceof OtpErlangTuple resultTuple)
                || resultTuple.arity() != 2) {
            throw new IOException("Malformed result from Erlang gateway");
        }

        OtpErlangObject status = resultTuple.elementAt(0);
        OtpErlangObject content = resultTuple.elementAt(1);

        if (new OtpErlangAtom("error").equals(status)) {
            throw new ErlangServiceException(decodeReason(content));
        }
        if (!new OtpErlangAtom("ok").equals(status)) {
            throw new IOException("Unknown result status from Erlang gateway");
        }

        return content;
    }

    private static void requireOkAtom(OtpErlangObject result)
            throws IOException, ErlangServiceException {
        OtpErlangObject content = requireOk(result);
        if (!new OtpErlangAtom("ok").equals(content)) {
            throw new IOException("Expected ok from Erlang gateway");
        }
    }

    private static String decodeReason(OtpErlangObject reason) {
        if (reason instanceof OtpErlangAtom reasonAtom) {
            return reasonAtom.atomValue();
        }
        return reason.toString();
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

    private static QuizDetails decodeQuizDetails(
            OtpErlangObject quizTerm
    ) throws IOException {
        if (!(quizTerm instanceof OtpErlangMap quizMap)) {
            throw new IOException("Expected an Erlang map for quiz details");
        }
        OtpErlangObject questionTerm = requiredMapValue(
                quizMap, "questions");
        if (!(questionTerm instanceof OtpErlangList questionList)) {
            throw new IOException("Expected a list of quiz questions");
        }

        List<QuizQuestion> questions = new ArrayList<>(questionList.arity());
        for (OtpErlangObject item : questionList) {
            questions.add(decodeQuizQuestion(item));
        }
        return new QuizDetails(
                decodeQuizId(requiredMapValue(quizMap, "id")),
                decodeString(requiredMapValue(quizMap, "owner"), "owner"),
                decodeString(requiredMapValue(quizMap, "title"), "title"),
                decodeString(requiredMapValue(
                        quizMap, "description"), "description"),
                questions
        );
    }

    private static QuizQuestion decodeQuizQuestion(
            OtpErlangObject questionTerm
    ) throws IOException {
        if (!(questionTerm instanceof OtpErlangMap questionMap)) {
            throw new IOException("Expected an Erlang map for a question");
        }
        OtpErlangObject answerTerm = requiredMapValue(
                questionMap, "answers");
        if (!(answerTerm instanceof OtpErlangList answerList)) {
            throw new IOException("Expected a list of answers");
        }
        List<String> answers = new ArrayList<>(answerList.arity());
        for (OtpErlangObject answer : answerList) {
            answers.add(decodeString(answer, "answer"));
        }
        return new QuizQuestion(
                decodeString(requiredMapValue(
                        questionMap, "text"), "question text"),
                answers,
                decodeString(requiredMapValue(
                        questionMap, "correct"), "correct answer"),
                decodeLong(requiredMapValue(
                        questionMap, "time_limit"), "time limit")
        );
    }

    private static OtpErlangTuple encodeQuizId(QuizId quizId) {
        return new OtpErlangTuple(new OtpErlangObject[] {
            new OtpErlangLong(quizId.timestampMicros()),
            new OtpErlangLong(quizId.uniqueInteger())
        });
    }

    private static OtpErlangMap encodeQuizDraft(QuizDraft quiz) {
        OtpErlangObject[] questions = quiz.questions().stream()
                .map(ErlangClient::encodeQuizQuestion)
                .toArray(OtpErlangObject[]::new);
        return new OtpErlangMap(
                new OtpErlangObject[] {
                    new OtpErlangAtom("title"),
                    new OtpErlangAtom("description"),
                    new OtpErlangAtom("questions")
                },
                new OtpErlangObject[] {
                    new OtpErlangString(quiz.title()),
                    new OtpErlangString(quiz.description()),
                    new OtpErlangList(questions)
                }
        );
    }

    private static OtpErlangMap encodeQuizQuestion(QuizQuestion question) {
        OtpErlangObject[] answers = question.answers().stream()
                .map(OtpErlangString::new)
                .toArray(OtpErlangObject[]::new);
        return new OtpErlangMap(
                new OtpErlangObject[] {
                    new OtpErlangAtom("text"),
                    new OtpErlangAtom("answers"),
                    new OtpErlangAtom("correct"),
                    new OtpErlangAtom("time_limit")
                },
                new OtpErlangObject[] {
                    new OtpErlangString(question.text()),
                    new OtpErlangList(answers),
                    new OtpErlangString(question.correct()),
                    new OtpErlangLong(question.timeLimitMillis())
                }
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
        if (stringTerm instanceof OtpErlangString value) {
            return value.stringValue();
        }
        if (stringTerm instanceof OtpErlangList value) {
            try {
                return value.stringValue();
            } catch (OtpErlangException exception) {
                throw new IOException(
                        "Erlang field is not a string: " + fieldName,
                        exception
                );
            }
        }

        throw new IOException("Erlang field is not a string: " + fieldName);
    }

    private static long decodeLong(
            OtpErlangObject term,
            String fieldName
    ) throws IOException {
        if (term instanceof OtpErlangLong value) {
            return value.longValue();
        }
        throw new IOException("Erlang field is not an integer: " + fieldName);
    }

    // Chiude il nodo JInterface e libera le risorse associate
    @Override
    public void close() {
        node.close();
    }
}
