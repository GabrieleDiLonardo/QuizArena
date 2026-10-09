package it.unipi.dsmt.quizarena.web;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import it.unipi.dsmt.quizarena.erlang.ErlangClient;
import it.unipi.dsmt.quizarena.erlang.ErlangContextListener;
import it.unipi.dsmt.quizarena.erlang.ErlangServiceException;
import it.unipi.dsmt.quizarena.model.QuizDraft;
import it.unipi.dsmt.quizarena.model.QuizId;
import it.unipi.dsmt.quizarena.model.QuizQuestion;
import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@WebServlet(
        name = "quizApiServlet",
        urlPatterns = {"/api/quizzes", "/api/quizzes/*"}
)
public final class QuizApiServlet extends HttpServlet {

    private static final long ERLANG_TIMEOUT_MILLIS = 5000;
    private static final int MAX_TITLE_LENGTH = 100;
    private static final int MAX_DESCRIPTION_LENGTH = 1000;
    private static final int MAX_QUESTION_LENGTH = 500;
    private static final int MAX_ANSWER_LENGTH = 200;
    private static final int MAX_QUESTIONS = 50;
    private static final int MAX_ANSWERS = 6;
    private static final long MIN_TIME_LIMIT_MILLIS = 1000;
    private static final long MAX_TIME_LIMIT_MILLIS = 300000;
    private static final ObjectMapper JSON = new ObjectMapper();

    private String backendNode;
    private String gatewayName;

    @Override
    public void init() throws ServletException {
        backendNode = requireInitParameter("erlangBackendNode");
        gatewayName = requireInitParameter("erlangGatewayName");
    }

    @Override
    protected void doGet(
            HttpServletRequest request,
            HttpServletResponse response
    ) throws IOException {
        String owner = authenticatedUsername(request, response);
        if (owner == null) {
            return;
        }

        try {
            QuizId quizId = optionalQuizId(request);
            if (quizId == null) {
                writeJson(response, HttpServletResponse.SC_OK,
                        requireClient().listOwnedQuizzes(
                                backendNode,
                                gatewayName,
                                owner,
                                ERLANG_TIMEOUT_MILLIS
                        ));
            } else {
                writeJson(response, HttpServletResponse.SC_OK,
                        requireClient().getOwnedQuiz(
                                backendNode,
                                gatewayName,
                                owner,
                                quizId,
                                ERLANG_TIMEOUT_MILLIS
                        ));
            }
        } catch (IllegalArgumentException exception) {
            writeError(response, HttpServletResponse.SC_BAD_REQUEST,
                    exception.getMessage());
        } catch (ErlangServiceException exception) {
            handleServiceError(response, exception);
        } catch (IOException exception) {
            backendUnavailable(response, exception);
        }
    }

    @Override
    protected void doPost(
            HttpServletRequest request,
            HttpServletResponse response
    ) throws IOException {
        String owner = authenticatedUsername(request, response);
        if (owner == null) {
            return;
        }

        try {
            requireCollectionPath(request);
            QuizDraft quiz = readQuizDraft(request);
            QuizId quizId = requireClient().createQuiz(
                    backendNode,
                    gatewayName,
                    owner,
                    quiz,
                    ERLANG_TIMEOUT_MILLIS
            );
            writeJson(response, HttpServletResponse.SC_CREATED,
                    Map.of("id", quizId));
        } catch (IllegalArgumentException exception) {
            writeError(response, HttpServletResponse.SC_BAD_REQUEST,
                    exception.getMessage());
        } catch (ErlangServiceException exception) {
            handleServiceError(response, exception);
        } catch (IOException exception) {
            backendUnavailable(response, exception);
        }
    }

    @Override
    protected void doPut(
            HttpServletRequest request,
            HttpServletResponse response
    ) throws IOException {
        String owner = authenticatedUsername(request, response);
        if (owner == null) {
            return;
        }

        try {
            QuizId quizId = requiredQuizId(request);
            QuizDraft quiz = readQuizDraft(request);
            requireClient().updateQuiz(
                    backendNode,
                    gatewayName,
                    owner,
                    quizId,
                    quiz,
                    ERLANG_TIMEOUT_MILLIS
            );
            writeJson(response, HttpServletResponse.SC_OK,
                    Map.of("status", "updated"));
        } catch (IllegalArgumentException exception) {
            writeError(response, HttpServletResponse.SC_BAD_REQUEST,
                    exception.getMessage());
        } catch (ErlangServiceException exception) {
            handleServiceError(response, exception);
        } catch (IOException exception) {
            backendUnavailable(response, exception);
        }
    }

    @Override
    protected void doDelete(
            HttpServletRequest request,
            HttpServletResponse response
    ) throws IOException {
        String owner = authenticatedUsername(request, response);
        if (owner == null) {
            return;
        }

        try {
            QuizId quizId = requiredQuizId(request);
            requireClient().deleteQuiz(
                    backendNode,
                    gatewayName,
                    owner,
                    quizId,
                    ERLANG_TIMEOUT_MILLIS
            );
            writeJson(response, HttpServletResponse.SC_OK,
                    Map.of("status", "deleted"));
        } catch (IllegalArgumentException exception) {
            writeError(response, HttpServletResponse.SC_BAD_REQUEST,
                    exception.getMessage());
        } catch (ErlangServiceException exception) {
            handleServiceError(response, exception);
        } catch (IOException exception) {
            backendUnavailable(response, exception);
        }
    }

    private QuizDraft readQuizDraft(HttpServletRequest request) {
        final JsonNode root;
        try {
            root = JSON.readTree(request.getInputStream());
        } catch (JsonProcessingException exception) {
            throw new IllegalArgumentException("JSON non valido");
        } catch (IOException exception) {
            throw new IllegalArgumentException(
                    "Impossibile leggere il JSON");
        }

        if (root == null || !root.isObject()) {
            throw new IllegalArgumentException(
                    "Il corpo deve essere un oggetto JSON");
        }
        if (root.has("owner")) {
            throw new IllegalArgumentException(
                    "Il proprietario deriva dalla sessione autenticata");
        }

        String title = requiredText(root, "title").trim();
        if (title.length() > MAX_TITLE_LENGTH) {
            throw new IllegalArgumentException("Titolo troppo lungo");
        }
        String description = optionalText(root, "description").trim();
        if (description.length() > MAX_DESCRIPTION_LENGTH) {
            throw new IllegalArgumentException("Descrizione troppo lunga");
        }

        JsonNode questionNodes = root.get("questions");
        if (questionNodes == null || !questionNodes.isArray()
                || questionNodes.isEmpty()
                || questionNodes.size() > MAX_QUESTIONS) {
            throw new IllegalArgumentException(
                    "Servono da 1 a " + MAX_QUESTIONS + " domande");
        }

        List<QuizQuestion> questions = new ArrayList<>();
        for (JsonNode questionNode : questionNodes) {
            questions.add(readQuestion(questionNode));
        }
        return new QuizDraft(title, description, questions);
    }

    private QuizQuestion readQuestion(JsonNode question) {
        if (!question.isObject()) {
            throw new IllegalArgumentException(
                    "Ogni domanda deve essere un oggetto JSON");
        }
        String text = requiredText(question, "text").trim();
        if (text.length() > MAX_QUESTION_LENGTH) {
            throw new IllegalArgumentException("Domanda troppo lunga");
        }

        JsonNode answerNodes = question.get("answers");
        if (answerNodes == null || !answerNodes.isArray()
                || answerNodes.size() < 2
                || answerNodes.size() > MAX_ANSWERS) {
            throw new IllegalArgumentException(
                    "Ogni domanda deve avere da 2 a "
                            + MAX_ANSWERS + " risposte");
        }
        List<String> answers = new ArrayList<>();
        Set<String> uniqueAnswers = new HashSet<>();
        for (JsonNode answerNode : answerNodes) {
            if (!answerNode.isTextual()) {
                throw new IllegalArgumentException(
                        "Ogni risposta deve essere testuale");
            }
            String answer = answerNode.asText().trim();
            if (answer.isEmpty() || answer.length() > MAX_ANSWER_LENGTH
                    || !uniqueAnswers.add(answer)) {
                throw new IllegalArgumentException(
                        "Le risposte devono essere non vuote e diverse");
            }
            answers.add(answer);
        }

        String correct = requiredText(question, "correct").trim();
        if (!answers.contains(correct)) {
            throw new IllegalArgumentException(
                    "La risposta corretta deve essere tra le risposte");
        }
        long timeLimit = optionalLong(
                question, "timeLimitMillis", 60000);
        if (timeLimit < MIN_TIME_LIMIT_MILLIS
                || timeLimit > MAX_TIME_LIMIT_MILLIS) {
            throw new IllegalArgumentException(
                    "Tempo limite non valido");
        }
        return new QuizQuestion(text, answers, correct, timeLimit);
    }

    private QuizId optionalQuizId(HttpServletRequest request) {
        String path = request.getPathInfo();
        if (path == null || path.isBlank() || "/".equals(path)) {
            return null;
        }
        return parseQuizId(path);
    }

    private QuizId requiredQuizId(HttpServletRequest request) {
        QuizId quizId = optionalQuizId(request);
        if (quizId == null) {
            throw new IllegalArgumentException("ID del quiz mancante");
        }
        return quizId;
    }

    private QuizId parseQuizId(String path) {
        String[] components = path.substring(1).split("/");
        if (components.length != 2) {
            throw new IllegalArgumentException("ID del quiz non valido");
        }
        try {
            long timestamp = Long.parseLong(components[0]);
            long unique = Long.parseLong(components[1]);
            if (timestamp <= 0 || unique <= 0) {
                throw new NumberFormatException();
            }
            return new QuizId(timestamp, unique);
        } catch (NumberFormatException exception) {
            throw new IllegalArgumentException("ID del quiz non valido");
        }
    }

    private void requireCollectionPath(HttpServletRequest request) {
        if (optionalQuizId(request) != null) {
            throw new IllegalArgumentException(
                    "La creazione non accetta un ID nel percorso");
        }
    }

    private String authenticatedUsername(
            HttpServletRequest request,
            HttpServletResponse response
    ) throws IOException {
        String username = AuthenticationSession.username(
                request.getSession(false));
        if (username == null) {
            writeError(response, HttpServletResponse.SC_UNAUTHORIZED,
                    "Autenticazione richiesta");
        }
        return username;
    }

    private ErlangClient requireClient() throws IOException {
        Object value = getServletContext().getAttribute(
                ErlangContextListener.CLIENT_ATTRIBUTE);
        if (value instanceof ErlangClient client) {
            return client;
        }
        throw new IOException("Erlang client is not available");
    }

    private void handleServiceError(
            HttpServletResponse response,
            ErlangServiceException exception
    ) throws IOException {
        switch (exception.getReason()) {
            case "not_found" -> writeError(
                    response, HttpServletResponse.SC_NOT_FOUND,
                    "Quiz non trovato");
            case "not_owner" -> writeError(
                    response, HttpServletResponse.SC_FORBIDDEN,
                    "Non sei il proprietario del quiz");
            default -> writeError(
                    response, HttpServletResponse.SC_BAD_GATEWAY,
                    "Servizio quiz non disponibile");
        }
    }

    private void backendUnavailable(
            HttpServletResponse response,
            IOException exception
    ) throws IOException {
        getServletContext().log("Quiz API backend failure", exception);
        writeError(response, HttpServletResponse.SC_BAD_GATEWAY,
                "Backend non disponibile");
    }

    private static String requiredText(JsonNode object, String field) {
        JsonNode value = object.get(field);
        if (value == null || !value.isTextual()
                || value.asText().isBlank()) {
            throw new IllegalArgumentException(
                    "Campo mancante o non valido: " + field);
        }
        return value.asText();
    }

    private static String optionalText(JsonNode object, String field) {
        JsonNode value = object.get(field);
        if (value == null || value.isNull()) {
            return "";
        }
        if (!value.isTextual()) {
            throw new IllegalArgumentException(
                    "Campo non valido: " + field);
        }
        return value.asText();
    }

    private static long optionalLong(
            JsonNode object,
            String field,
            long defaultValue
    ) {
        JsonNode value = object.get(field);
        if (value == null || value.isNull()) {
            return defaultValue;
        }
        if (!value.isIntegralNumber() || !value.canConvertToLong()) {
            throw new IllegalArgumentException(
                    "Campo non valido: " + field);
        }
        return value.longValue();
    }

    private static void writeError(
            HttpServletResponse response,
            int status,
            String message
    ) throws IOException {
        writeJson(response, status, Map.of("error", message));
    }

    private static void writeJson(
            HttpServletResponse response,
            int status,
            Object body
    ) throws IOException {
        response.setStatus(status);
        response.setContentType("application/json");
        response.setCharacterEncoding("UTF-8");
        JSON.writeValue(response.getWriter(), body);
    }

    private String requireInitParameter(String name) throws ServletException {
        String value = getServletContext().getInitParameter(name);
        if (value == null || value.isBlank()) {
            throw new ServletException("Missing context parameter: " + name);
        }
        return value;
    }
}
