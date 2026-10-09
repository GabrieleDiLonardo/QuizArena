package it.unipi.dsmt.quizarena.web;

import java.io.IOException;

import it.unipi.dsmt.quizarena.erlang.ErlangClient;
import it.unipi.dsmt.quizarena.erlang.ErlangContextListener;
import it.unipi.dsmt.quizarena.erlang.ErlangServiceException;
import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@WebServlet(name = "registerServlet", value = "/register")
public final class RegisterServlet extends HttpServlet {

    private static final long ERLANG_TIMEOUT_MILLIS = 5000;

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
    ) throws IOException, ServletException {
        request.getRequestDispatcher("/WEB-INF/views/register.jsp")
                .forward(request, response);
    }

    @Override
    protected void doPost(
            HttpServletRequest request,
            HttpServletResponse response
    ) throws IOException, ServletException {
        request.setCharacterEncoding("UTF-8");
        String username = parameter(request, "username").trim();
        String password = parameter(request, "password");
        String passwordConfirmation = parameter(
                request, "passwordConfirmation");

        if (!password.equals(passwordConfirmation)) {
            showError(request, response,
                    HttpServletResponse.SC_BAD_REQUEST,
                    "Le password non coincidono.");
            return;
        }

        ErlangClient client = requireClient(response);
        if (client == null) {
            return;
        }

        try {
            client.registerUser(
                    backendNode,
                    gatewayName,
                    username,
                    password,
                    ERLANG_TIMEOUT_MILLIS
            );
            response.sendRedirect(response.encodeRedirectURL(
                    request.getContextPath() + "/login?registered=true"));
        } catch (ErlangServiceException exception) {
            handleRegistrationError(request, response, exception);
        } catch (IOException exception) {
            getServletContext().log("Unable to register user", exception);
            showError(request, response,
                    HttpServletResponse.SC_BAD_GATEWAY,
                    "Il servizio di autenticazione non e' disponibile.");
        }
    }

    private void handleRegistrationError(
            HttpServletRequest request,
            HttpServletResponse response,
            ErlangServiceException exception
    ) throws ServletException, IOException {
        switch (exception.getReason()) {
            case "username_taken" -> showError(
                    request, response, HttpServletResponse.SC_CONFLICT,
                    "Questo username e' gia' utilizzato.");
            case "invalid_username" -> showError(
                    request, response, HttpServletResponse.SC_BAD_REQUEST,
                    "Lo username deve contenere da 3 a 30 caratteri: "
                    + "lettere, numeri o underscore.");
            case "invalid_password" -> showError(
                    request, response, HttpServletResponse.SC_BAD_REQUEST,
                    "La password deve contenere da 8 a 128 caratteri.");
            default -> {
                getServletContext().log(
                        "Registration service error", exception);
                showError(request, response,
                        HttpServletResponse.SC_BAD_GATEWAY,
                        "Il servizio di autenticazione non e' disponibile.");
            }
        }
    }

    private void showError(
            HttpServletRequest request,
            HttpServletResponse response,
            int status,
            String message
    ) throws ServletException, IOException {
        response.setStatus(status);
        request.setAttribute("registrationError", message);
        request.getRequestDispatcher("/WEB-INF/views/register.jsp")
                .forward(request, response);
    }

    private ErlangClient requireClient(HttpServletResponse response)
            throws IOException {
        Object clientAttribute = getServletContext().getAttribute(
                ErlangContextListener.CLIENT_ATTRIBUTE);
        if (clientAttribute instanceof ErlangClient client) {
            return client;
        }

        response.sendError(
                HttpServletResponse.SC_SERVICE_UNAVAILABLE,
                "Erlang client is not available");
        return null;
    }

    private String requireInitParameter(String name) throws ServletException {
        String value = getServletContext().getInitParameter(name);
        if (value == null || value.isBlank()) {
            throw new ServletException("Missing context parameter: " + name);
        }
        return value;
    }

    private static String parameter(
            HttpServletRequest request,
            String name
    ) {
        String value = request.getParameter(name);
        return value == null ? "" : value;
    }
}
