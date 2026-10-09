package it.unipi.dsmt.quizarena.web;

import java.io.IOException;
import java.util.List;

import it.unipi.dsmt.quizarena.erlang.ErlangClient;
import it.unipi.dsmt.quizarena.erlang.ErlangContextListener;
import it.unipi.dsmt.quizarena.erlang.ErlangServiceException;
import it.unipi.dsmt.quizarena.model.QuizSummary;
import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

@WebServlet(name = "quizListServlet", value = "/quizzes")
public final class QuizListServlet extends HttpServlet {

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
        String owner = AuthenticationSession.username(session);
        if (owner == null) {
            response.sendError(
                    HttpServletResponse.SC_UNAUTHORIZED,
                    "Authentication required"
            );
            return;
        }

        try {
            List<QuizSummary> quizzes = client.listOwnedQuizzes(
                    backendNode,
                    gatewayName,
                    owner,
                    ERLANG_TIMEOUT_MILLIS
            );
            request.setAttribute("quizzes", quizzes);
        } catch (IOException | ErlangServiceException exception) {
            getServletContext().log("Unable to list quizzes", exception);
            response.setStatus(HttpServletResponse.SC_BAD_GATEWAY);
            request.setAttribute(
                    "quizError",
                    "The quiz service is temporarily unavailable."
            );
        }

        request.getRequestDispatcher("/WEB-INF/views/quizzes.jsp")
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
