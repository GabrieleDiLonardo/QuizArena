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
        <ul>
            <% for (QuizSummary quiz : quizzes) { %>
                <li>
                    <h2><%= escapeHtml(quiz.title()) %></h2>
                    <p>Autore: <%= escapeHtml(quiz.owner()) %></p>
                    <p><%= escapeHtml(quiz.description()) %></p>
                </li>
            <% } %>
        </ul>
    <% } %>

    <p><a href="<%= request.getContextPath() %>/">Torna alla home</a></p>
</body>
</html>
