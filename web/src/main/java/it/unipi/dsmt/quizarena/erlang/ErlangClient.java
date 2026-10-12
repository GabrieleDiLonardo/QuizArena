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

import it.unipi.dsmt.quizarena.model.QuizDetails;
import it.unipi.dsmt.quizarena.model.QuizDraft;
import it.unipi.dsmt.quizarena.model.QuizId;
import it.unipi.dsmt.quizarena.model.QuizQuestion;
import it.unipi.dsmt.quizarena.model.QuizSummary;
import it.unipi.dsmt.quizarena.model.GameHistoryEntry;

public final class ErlangClient implements AutoCloseable {

    private final OtpNode node;

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
        return new ErlangGameSession(node, remoteNode, gatewayName, listener);
    }

    public boolean isReachable(String remoteNode, long timeoutMillis) {
        if (remoteNode == null || remoteNode.isBlank()) {
            throw new IllegalArgumentException("remoteNode must not be blank");
        }
        if (timeoutMillis <= 0) {
            throw new IllegalArgumentException("timeoutMillis must be positive");
        }
        return node.ping(remoteNode, timeoutMillis);
    }

    public boolean isGatewayReachable(
            String remoteNode,
            String gatewayName,
            long timeoutMillis
    ) {
        try {
            OtpErlangObject result = sendRequest(
                    remoteNode, gatewayName,
                    new OtpErlangAtom("ping"), timeoutMillis);
            return result instanceof OtpErlangTuple resultTuple
                    && resultTuple.arity() == 2
                    && new OtpErlangAtom("ok").equals(resultTuple.elementAt(0))
                    && new OtpErlangAtom("pong").equals(resultTuple.elementAt(1));
        } catch (IOException exception) {
            return false;
        }
    }

    // ---------- Autenticazione ----------

    public void registerUser(
            String remoteNode, String gatewayName,
            String username, String password, long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("register_user"),
                new OtpErlangString(username),
                new OtpErlangString(password)
        });
        OtpErlangObject content = requireOk(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis));
        if (!new OtpErlangAtom("registered").equals(content)) {
            throw new IOException("Unexpected registration result");
        }
    }

    public String authenticateUser(
            String remoteNode, String gatewayName,
            String username, String password, long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("authenticate_user"),
                new OtpErlangString(username),
                new OtpErlangString(password)
        });
        OtpErlangObject content = requireOk(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis));
        return decodeString(content, "username");
    }

    // ---------- Quiz ----------

    public List<QuizSummary> listOwnedQuizzes(
            String remoteNode, String gatewayName, String owner, long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("list_owned_quizzes"),
                new OtpErlangString(owner)
        });
        OtpErlangObject content = requireOk(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis));
        if (!(content instanceof OtpErlangList quizList)) {
            throw new IOException("Expected a list of owned quizzes");
        }
        List<QuizSummary> quizzes = new ArrayList<>(quizList.arity());
        for (OtpErlangObject term : quizList) {
            quizzes.add(decodeQuizSummary(term, true));
        }
        return List.copyOf(quizzes);
    }

    public List<QuizSummary> listBrowsableQuizzes(
            String remoteNode, String gatewayName, String username, long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("list_browsable_quizzes"),
                new OtpErlangString(username)
        });
        OtpErlangObject content = requireOk(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis));
        if (!(content instanceof OtpErlangList quizList)) {
            throw new IOException("Expected a list of browsable quizzes");
        }
        List<QuizSummary> quizzes = new ArrayList<>(quizList.arity());
        for (OtpErlangObject term : quizList) {
            quizzes.add(decodeQuizSummaryFromBrowsable(term));
        }
        return List.copyOf(quizzes);
    }

    public QuizDetails getOwnedQuiz(
            String remoteNode, String gatewayName, String owner,
            QuizId quizId, long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("get_owned_quiz"),
                new OtpErlangString(owner),
                encodeQuizId(quizId)
        });
        return decodeQuizDetails(requireOk(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis)));
    }

    public QuizId createQuiz(
            String remoteNode, String gatewayName, String owner,
            QuizDraft quiz, long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("create_quiz"),
                new OtpErlangString(owner),
                encodeQuizDraft(quiz)
        });
        return decodeQuizId(requireOk(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis)));
    }

    public void updateQuiz(
            String remoteNode, String gatewayName, String owner,
            QuizId quizId, QuizDraft quiz, long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("update_quiz"),
                new OtpErlangString(owner),
                encodeQuizId(quizId),
                encodeQuizDraft(quiz)
        });
        requireOkAtom(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis));
    }

    public void deleteQuiz(
            String remoteNode, String gatewayName, String owner,
            QuizId quizId, long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("delete_quiz"),
                new OtpErlangString(owner),
                encodeQuizId(quizId)
        });
        requireOkAtom(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis));
    }

    // ---------- Storico ----------

    public List<GameHistoryEntry> getHistory(
            String remoteNode, String gatewayName,
            String username, long timeoutMillis
    ) throws IOException, ErlangServiceException {
        OtpErlangTuple request = new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("get_history"),
                new OtpErlangString(username)
        });
        OtpErlangObject content = requireOk(sendRequest(
                remoteNode, gatewayName, request, timeoutMillis));
        if (!(content instanceof OtpErlangList historyList)) {
            throw new IOException("Expected a list of game results");
        }

        List<GameHistoryEntry> history = new ArrayList<>(historyList.arity());
        for (OtpErlangObject term : historyList) {
            history.add(decodeHistoryEntry(term));
        }
        history.sort((left, right) -> Long.compare(
                right.finishedAtMillis(), left.finishedAtMillis()));
        return List.copyOf(history);
    }

    // ---------- Helpers ----------

    private static OtpErlangObject requireOk(OtpErlangObject result)
            throws IOException, ErlangServiceException {
        if (!(result instanceof OtpErlangTuple t) || t.arity() != 2) {
            throw new IOException("Malformed result from Erlang gateway");
        }
        OtpErlangObject status = t.elementAt(0);
        OtpErlangObject content = t.elementAt(1);
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
        if (reason instanceof OtpErlangAtom a) return a.atomValue();
        if (reason instanceof OtpErlangTuple t && t.arity() > 0) {
            return t.elementAt(0).toString();
        }
        return reason.toString();
    }

    private OtpErlangObject sendRequest(
            String remoteNode, String gatewayName,
            OtpErlangObject requestBody, long timeoutMillis
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
                    new OtpErlangObject[]{
                            mailbox.self(), reference, requestBody});
            mailbox.send(gatewayName, remoteNode, requestMessage);
            OtpErlangObject message = mailbox.receive(timeoutMillis);
            if (message == null) {
                throw new IOException("Timed out waiting for the Erlang gateway");
            }
            if (!(message instanceof OtpErlangTuple response) || response.arity() != 2) {
                throw new IOException("Malformed response from Erlang gateway");
            }
            if (!reference.equals(response.elementAt(0))) {
                throw new IOException("Mismatched reference in response");
            }
            return response.elementAt(1);
        } catch (OtpErlangExit | OtpErlangDecodeException exception) {
            throw new IOException("Unable to receive the Erlang response", exception);
        } finally {
            mailbox.close();
        }
    }

    // ---------- Decodifica ----------

    private static QuizSummary decodeQuizSummary(OtpErlangObject term, boolean own)
            throws IOException {
        if (!(term instanceof OtpErlangMap m)) {
            throw new IOException("Expected an Erlang map for a quiz");
        }
        return new QuizSummary(
                decodeQuizId(required(m, "id")),
                decodeString(required(m, "owner"), "owner"),
                decodeString(required(m, "title"), "title"),
                decodeString(required(m, "description"), "description"),
                decodeString(required(m, "visibility"), "visibility"),
                own
        );
    }

    private static QuizSummary decodeQuizSummaryFromBrowsable(OtpErlangObject term)
            throws IOException {
        if (!(term instanceof OtpErlangMap m)) {
            throw new IOException("Expected an Erlang map for a quiz");
        }
        boolean isOwn = decodeBoolean(
                m.get(new OtpErlangAtom("is_own")), "is_own");
        return new QuizSummary(
                decodeQuizId(required(m, "id")),
                decodeString(required(m, "owner"), "owner"),
                decodeString(required(m, "title"), "title"),
                decodeString(required(m, "description"), "description"),
                decodeString(required(m, "visibility"), "visibility"),
                isOwn
        );
    }

    private static QuizDetails decodeQuizDetails(OtpErlangObject term)
            throws IOException {
        if (!(term instanceof OtpErlangMap m)) {
            throw new IOException("Expected an Erlang map for quiz details");
        }
        OtpErlangObject qTerm = required(m, "questions");
        if (!(qTerm instanceof OtpErlangList qList)) {
            throw new IOException("Expected a list of quiz questions");
        }
        List<QuizQuestion> questions = new ArrayList<>(qList.arity());
        for (OtpErlangObject item : qList) {
            questions.add(decodeQuizQuestion(item));
        }
        return new QuizDetails(
                decodeQuizId(required(m, "id")),
                decodeString(required(m, "owner"), "owner"),
                decodeString(required(m, "title"), "title"),
                decodeString(required(m, "description"), "description"),
                decodeString(required(m, "visibility"), "visibility"),
                questions
        );
    }

    private static QuizQuestion decodeQuizQuestion(OtpErlangObject term)
            throws IOException {
        if (!(term instanceof OtpErlangMap m)) {
            throw new IOException("Expected an Erlang map for a question");
        }
        OtpErlangObject aTerm = required(m, "answers");
        if (!(aTerm instanceof OtpErlangList aList)) {
            throw new IOException("Expected a list of answers");
        }
        List<String> answers = new ArrayList<>(aList.arity());
        for (OtpErlangObject a : aList) {
            answers.add(decodeString(a, "answer"));
        }
        return new QuizQuestion(
                decodeString(required(m, "text"), "question text"),
                answers,
                decodeString(required(m, "correct"), "correct answer"),
                decodeLong(required(m, "time_limit"), "time limit")
        );
    }

    private static GameHistoryEntry decodeHistoryEntry(OtpErlangObject term)
            throws IOException {
        if (!(term instanceof OtpErlangMap history)) {
            throw new IOException("Malformed game history entry");
        }
        return new GameHistoryEntry(
                decodeString(required(history, "session_id"), "session id"),
                decodeString(required(history, "quiz_title"), "quiz title"),
                decodeBoolean(required(history, "hosted"), "hosted"),
                decodeLong(required(history, "participant_count"),
                        "participant count"),
                decodeOptionalLong(required(history, "score"), "score"),
                decodeOptionalLong(required(history, "rank"), "rank"),
                decodeLong(required(history, "finished_at"), "finished at")
        );
    }

    // ---------- Encode ----------

    private static OtpErlangTuple encodeQuizId(QuizId quizId) {
        return new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangLong(quizId.timestampMicros()),
                new OtpErlangLong(quizId.uniqueInteger())
        });
    }

    private static OtpErlangMap encodeQuizDraft(QuizDraft quiz) {
        OtpErlangObject[] questions = quiz.questions().stream()
                .map(ErlangClient::encodeQuizQuestion)
                .toArray(OtpErlangObject[]::new);
        return new OtpErlangMap(
                new OtpErlangObject[]{
                        new OtpErlangAtom("title"),
                        new OtpErlangAtom("description"),
                        new OtpErlangAtom("visibility"),
                        new OtpErlangAtom("questions")
                },
                new OtpErlangObject[]{
                        new OtpErlangString(quiz.title()),
                        new OtpErlangString(quiz.description()),
                        new OtpErlangAtom(quiz.visibility()),
                        new OtpErlangList(questions)
                }
        );
    }

    private static OtpErlangMap encodeQuizQuestion(QuizQuestion question) {
        OtpErlangObject[] answers = question.answers().stream()
                .map(OtpErlangString::new)
                .toArray(OtpErlangObject[]::new);
        return new OtpErlangMap(
                new OtpErlangObject[]{
                        new OtpErlangAtom("text"),
                        new OtpErlangAtom("answers"),
                        new OtpErlangAtom("correct"),
                        new OtpErlangAtom("time_limit")
                },
                new OtpErlangObject[]{
                        new OtpErlangString(question.text()),
                        new OtpErlangList(answers),
                        new OtpErlangString(question.correct()),
                        new OtpErlangLong(question.timeLimitMillis())
                }
        );
    }

    // ---------- Primitivi ----------

    private static OtpErlangObject required(OtpErlangMap m, String key)
            throws IOException {
        OtpErlangObject value = m.get(new OtpErlangAtom(key));
        if (value == null) {
            throw new IOException("Missing field: " + key);
        }
        return value;
    }

    private static QuizId decodeQuizId(OtpErlangObject term) throws IOException {
        if (!(term instanceof OtpErlangTuple t) || t.arity() != 2
                || !(t.elementAt(0) instanceof OtpErlangLong ts)
                || !(t.elementAt(1) instanceof OtpErlangLong u)) {
            throw new IOException("Malformed quiz id");
        }
        return new QuizId(ts.longValue(), u.longValue());
    }

    private static String decodeString(OtpErlangObject term, String field)
        throws IOException {
            if (term instanceof OtpErlangAtom a) {
                return a.atomValue();
            }
            if (term instanceof OtpErlangString s) {
                return s.stringValue();
            }
            if (term instanceof OtpErlangList l) {
                try {
                    return l.stringValue();
                } catch (OtpErlangException e) {
                    throw new IOException("Field is not a string: " + field, e);
                }
            }
        throw new IOException("Field is not a string: " + field);
    }

    private static long decodeLong(OtpErlangObject term, String field)
            throws IOException {
        if (term instanceof OtpErlangLong v) return v.longValue();
        throw new IOException("Field is not an integer: " + field);
    }

    private static Long decodeOptionalLong(OtpErlangObject term, String field)
            throws IOException {
        if (new OtpErlangAtom("undefined").equals(term)) return null;
        return decodeLong(term, field);
    }

    private static boolean decodeBoolean(OtpErlangObject term, String field)
            throws IOException {
        if (term instanceof OtpErlangAtom a) {
            return switch (a.atomValue()) {
                case "true" -> true;
                case "false" -> false;
                default -> throw new IOException(
                        "Field is not a boolean: " + field);
            };
        }
        throw new IOException("Field is not a boolean: " + field);
    }

    @Override
    public void close() {
        node.close();
    }
}
