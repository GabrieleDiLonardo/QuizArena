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
import jakarta.servlet.http.HttpSession;

@WebServlet(name = "loginServlet", value = "/login")
public final class LoginServlet extends HttpServlet {

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
        if ("true".equals(request.getParameter("registered"))) {
            request.setAttribute(
                    "loginMessage",
                    "Registrazione completata. Ora puoi accedere.");
        } else if ("true".equals(request.getParameter("loggedOut"))) {
            request.setAttribute(
                    "loginMessage",
                    "Logout completato.");
        }
        request.getRequestDispatcher("/WEB-INF/views/login.jsp")
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

        ErlangClient client = requireClient(response);
        if (client == null) {
            return;
        }

        try {
            String authenticatedUsername = client.authenticateUser(
                    backendNode,
                    gatewayName,
                    username,
                    password,
                    ERLANG_TIMEOUT_MILLIS
            );

            HttpSession session = request.getSession(true);
            request.changeSessionId();
            session.setAttribute(
                    AuthenticationSession.USERNAME_ATTRIBUTE,
                    authenticatedUsername
            );
            response.sendRedirect(response.encodeRedirectURL(
                    request.getContextPath() + "/lobby.html"));
        } catch (ErlangServiceException exception) {
            if ("invalid_credentials".equals(exception.getReason())) {
                showError(request, response,
                        HttpServletResponse.SC_UNAUTHORIZED,
                        "Username o password non corretti.");
            } else {
                getServletContext().log("Login service error", exception);
                showError(request, response,
                        HttpServletResponse.SC_BAD_GATEWAY,
                        "Il servizio di autenticazione non e' disponibile.");
            }
        } catch (IOException exception) {
            getServletContext().log("Unable to authenticate user", exception);
            showError(request, response,
                    HttpServletResponse.SC_BAD_GATEWAY,
                    "Il servizio di autenticazione non e' disponibile.");
        }
    }

    private void showError(
            HttpServletRequest request,
            HttpServletResponse response,
            int status,
            String message
    ) throws ServletException, IOException {
        response.setStatus(status);
        request.setAttribute("loginError", message);
        request.getRequestDispatcher("/WEB-INF/views/login.jsp")
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
