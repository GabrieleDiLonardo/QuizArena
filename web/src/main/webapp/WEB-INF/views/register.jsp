<%@ page contentType="text/html;charset=UTF-8" language="java" %>
<%@ page session="false" %>

<%
    String registrationError =
            (String) request.getAttribute("registrationError");
%>

<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Registrazione - QuizArena</title>
    <link rel="stylesheet"
          href="<%= request.getContextPath() %>/css/style.css">
</head>
<body>
    <main class="container auth-form">
        <h1>Crea un account</h1>

        <% if (registrationError != null) { %>
            <p class="error-message" role="alert">
                <%= registrationError %>
            </p>
        <% } %>

        <form method="post"
              action="<%= request.getContextPath() %>/register">
            <label for="username">Username</label>
            <input id="username" name="username" type="text"
                   minlength="3" maxlength="30"
                   pattern="[A-Za-z0-9_]+" autocomplete="username" required>

            <label for="password">Password</label>
            <input id="password" name="password" type="password"
                   minlength="8" maxlength="128"
                   autocomplete="new-password" required>

            <label for="password-confirmation">Conferma password</label>
            <input id="password-confirmation" name="passwordConfirmation"
                   type="password" minlength="8" maxlength="128"
                   autocomplete="new-password" required>

            <button type="submit">Registrati</button>
        </form>

        <p>Hai gia' un account?
            <a href="<%= request.getContextPath() %>/login">Accedi</a>
        </p>
        <p><a href="<%= request.getContextPath() %>/">Torna alla home</a></p>
    </main>
</body>
</html>
