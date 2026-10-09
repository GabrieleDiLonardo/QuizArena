<%@ page contentType="text/html;charset=UTF-8" language="java" %>
<%@ page session="false" %>

<%
    String loginMessage = (String) request.getAttribute("loginMessage");
    String loginError = (String) request.getAttribute("loginError");
%>

<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Accesso - QuizArena</title>
    <link rel="stylesheet"
          href="<%= request.getContextPath() %>/css/style.css">
</head>
<body>
    <main class="container auth-form">
        <h1>Accedi</h1>

        <% if (loginMessage != null) { %>
            <p class="success-message" role="status"><%= loginMessage %></p>
        <% } %>
        <% if (loginError != null) { %>
            <p class="error-message" role="alert"><%= loginError %></p>
        <% } %>

        <form method="post" action="<%= request.getContextPath() %>/login">
            <label for="username">Username</label>
            <input id="username" name="username" type="text"
                   maxlength="30" autocomplete="username" required>

            <label for="password">Password</label>
            <input id="password" name="password" type="password"
                   maxlength="128" autocomplete="current-password" required>

            <button type="submit">Accedi</button>
        </form>

        <p>Non hai un account?
            <a href="<%= request.getContextPath() %>/register">Registrati</a>
        </p>
        <p><a href="<%= request.getContextPath() %>/">Torna alla home</a></p>
    </main>
</body>
</html>
