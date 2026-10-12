<%@ page contentType="text/html;charset=UTF-8" language="java" %>
<%@ page session="false" %>
<%@ page import="java.util.List" %>
<%@ page import="it.unipi.dsmt.quizarena.model.GameHistoryEntry" %>

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
    List<GameHistoryEntry> history =
            (List<GameHistoryEntry>) request.getAttribute("history");
    String historyError = (String) request.getAttribute("historyError");
%>

<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Storico partite - QuizArena</title>
    <link rel="stylesheet" href="<%= request.getContextPath() %>/css/common.css">
    <link rel="stylesheet" href="<%= request.getContextPath() %>/css/history.css">
</head>
<body>
    <main class="container">
        <header class="page-topbar">
            <a href="<%= request.getContextPath() %>/" class="btn-back">← Home</a>
            <span class="user-badge" data-user-badge>
                👤 <span class="user-name" data-current-user>…</span>
            </span>
        </header>

        <h1>Storico partite</h1>
        <p class="history-intro">Le partite che hai giocato o condotto come host.</p>

        <% if (historyError != null) { %>
            <p class="alert alert-error" role="alert">
                <%= escapeHtml(historyError) %>
            </p>
        <% } else if (history == null || history.isEmpty()) { %>
            <section class="empty-history">
                <h2>Nessuna partita completata</h2>
                <p>Quando terminerai una partita, il risultato apparirà qui.</p>
                <a class="btn" href="<%= request.getContextPath() %>/lobby.html">
                    Vai alla lobby
                </a>
            </section>
        <% } else { %>
            <div class="history-table-wrapper">
                <table class="history-table">
                    <thead>
                        <tr>
                            <th scope="col">Quiz e partita</th>
                            <th scope="col">Ruolo</th>
                            <th scope="col">Data</th>
                            <th scope="col">Partecipanti</th>
                            <th scope="col">Posizione</th>
                            <th scope="col">Punteggio</th>
                        </tr>
                    </thead>
                    <tbody>
                        <% for (GameHistoryEntry entry : history) { %>
                            <tr>
                                <td>
                                    <strong class="quiz-title"><%= escapeHtml(entry.quizTitle()) %></strong>
                                    <span class="session-id"><%= escapeHtml(entry.sessionId()) %></span>
                                </td>
                                <td>
                                    <% if (entry.hosted() && entry.score() != null) { %>
                                        Host e giocatore
                                    <% } else if (entry.hosted()) { %>
                                        Host
                                    <% } else { %>
                                        Giocatore
                                    <% } %>
                                </td>
                                <td>
                                    <time datetime="<%= escapeHtml(entry.finishedAtIso()) %>"
                                          data-finished-at-millis="<%= entry.finishedAtMillis() %>">
                                        <%= escapeHtml(entry.finishedAtIso()) %>
                                    </time>
                                </td>
                                <td><%= entry.participantCount() %></td>
                                <td class="rank">
                                    <%= entry.rank() == null ? "—" : "#" + entry.rank() %>
                                </td>
                                <td class="score">
                                    <%= entry.score() == null ? "—" : entry.score() %>
                                </td>
                            </tr>
                        <% } %>
                    </tbody>
                </table>
            </div>
        <% } %>
    </main>

    <script src="<%= request.getContextPath() %>/js/user-info.js"></script>
    <script src="<%= request.getContextPath() %>/js/history.js"></script>
</body>
</html>
