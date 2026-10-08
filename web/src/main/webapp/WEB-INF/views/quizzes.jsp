<%@ page contentType="text/html;charset=UTF-8" language="java" %>
<%@ page session="false" %>
<%@ page import="java.util.List" %>
<%@ page import="it.unipi.dsmt.quizarena.model.QuizSummary" %>

<%!
    private static String escapeHtml(String value) {
        if (value == null) {
            return "";
        }

        return value.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&#39;");
    }
%>

<%
    @SuppressWarnings("unchecked")
    List<QuizSummary> quizzes =
            (List<QuizSummary>) request.getAttribute("quizzes");
    String quizError = (String) request.getAttribute("quizError");
%>

<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <title>Quiz disponibili - QuizArena</title>
</head>
<body>
    <h1>Quiz disponibili</h1>

    <% if (quizError != null) { %>
        <p role="alert"><%= escapeHtml(quizError) %></p>
    <% } else if (quizzes == null || quizzes.isEmpty()) { %>
        <p>Nessun quiz disponibile.</p>
    <% } else { %>
        <section id="game-creation"
                 data-context-path="<%= escapeHtml(request.getContextPath()) %>">
            <p>
                <label for="host-name">Nome dell'host:</label>
                <input id="host-name" name="hostName" maxlength="50"
                       autocomplete="nickname" required>
            </p>

            <ul>
                <% for (QuizSummary quiz : quizzes) { %>
                    <li>
                        <h2><%= escapeHtml(quiz.title()) %></h2>
                        <p>Autore: <%= escapeHtml(quiz.owner()) %></p>
                        <p><%= escapeHtml(quiz.description()) %></p>
                        <button type="button" class="create-room"
                                data-timestamp-micros="<%= quiz.id().timestampMicros() %>"
                                data-unique-integer="<%= quiz.id().uniqueInteger() %>"
                                disabled>
                            Crea partita
                        </button>
                    </li>
                <% } %>
            </ul>

            <p id="game-status" role="status">Collegamento al server...</p>
            <p id="game-error" role="alert" hidden></p>
            <p id="game-result" hidden>
                Partita creata. PIN: <strong id="room-pin"></strong>
            </p>
            <button id="start-game" type="button" hidden>
                Avvia partita
            </button>
        </section>
    <% } %>

    <p><a href="<%= request.getContextPath() %>/">Torna alla home</a></p>

    <% if (quizError == null && quizzes != null && !quizzes.isEmpty()) { %>
        <script src="<%= request.getContextPath() %>/js/quizzes.js"></script>
    <% } %>
</body>
</html>
