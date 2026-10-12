package it.unipi.dsmt.quizarena.web;

import java.io.IOException;
import java.util.List;

import it.unipi.dsmt.quizarena.erlang.ErlangClient;
import it.unipi.dsmt.quizarena.erlang.ErlangContextListener;
import it.unipi.dsmt.quizarena.erlang.ErlangServiceException;
import it.unipi.dsmt.quizarena.model.GameHistoryEntry;
import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

@WebServlet(name = "historyServlet", value = "/history")
public final class HistoryServlet extends HttpServlet {

    private static final long ERLANG_TIMEOUT_MILLIS = 2000;

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
        Object clientAttribute = getServletContext().getAttribute(
                ErlangContextListener.CLIENT_ATTRIBUTE
        );
        if (!(clientAttribute instanceof ErlangClient client)) {
            response.sendError(
                    HttpServletResponse.SC_SERVICE_UNAVAILABLE,
                    "Erlang client is not available"
            );
            return;
        }

        HttpSession session = request.getSession(false);
        String username = AuthenticationSession.username(session);
        if (username == null) {
            response.sendError(
                    HttpServletResponse.SC_UNAUTHORIZED,
                    "Authentication required"
            );
            return;
        }

        try {
            List<GameHistoryEntry> history = client.getHistory(
                    backendNode,
                    gatewayName,
                    username,
                    ERLANG_TIMEOUT_MILLIS
            );
            request.setAttribute("history", history);
        } catch (IOException | ErlangServiceException exception) {
            getServletContext().log("Unable to load game history", exception);
            response.setStatus(HttpServletResponse.SC_BAD_GATEWAY);
            request.setAttribute(
                    "historyError",
                    "Lo storico non è momentaneamente disponibile."
            );
        }

        request.getRequestDispatcher("/WEB-INF/views/history.jsp")
                .forward(request, response);
    }

    private String requireInitParameter(String name) throws ServletException {
        String value = getServletContext().getInitParameter(name);
        if (value == null || value.isBlank()) {
            throw new ServletException("Missing context parameter: " + name);
        }
        return value;
    }
}
