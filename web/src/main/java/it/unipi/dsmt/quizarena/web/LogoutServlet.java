package it.unipi.dsmt.quizarena.web;

import java.io.IOException;

import it.unipi.dsmt.quizarena.erlang.ErlangClient;
import it.unipi.dsmt.quizarena.erlang.ErlangContextListener;
import it.unipi.dsmt.quizarena.erlang.ErlangServiceException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

@WebServlet(name = "logoutServlet", value = "/logout")
public final class LogoutServlet extends HttpServlet {

    private static final long ERLANG_TIMEOUT_MILLIS = 5000;

    // Il logout revoca il token di login su tutto il cluster: la revoca e'
    // registrata in Mnesia prima di rispondere, e ogni Tomcat chiude le
    // sessioni e le WebSocket aperte con quel token (TokenRevocations).
    @Override
    protected void doPost(
            HttpServletRequest request,
            HttpServletResponse response
    ) throws IOException {
        AuthToken.Verified token = AuthenticationSession.token(request);
        if (token != null) {
            revokeInCluster(token);
            TokenRevocations.revoke(token.jti());
        }

        HttpSession session = request.getSession(false);
        if (session != null) {
            try {
                session.invalidate();
            } catch (IllegalStateException exception) {
                // Gia' invalidata dalla revoca.
            }
        }
        response.addCookie(AuthToken.expiredCookie(request.getContextPath()));

        response.sendRedirect(response.encodeRedirectURL(
                request.getContextPath() + "/"));
    }

    private void revokeInCluster(AuthToken.Verified token) {
        Object attribute = getServletContext().getAttribute(
                ErlangContextListener.CLIENT_ATTRIBUTE);
        if (!(attribute instanceof ErlangClient client)) {
            return;
        }
        try {
            client.revokeToken(token.jti(), token.expiresAtMillis(),
                    ERLANG_TIMEOUT_MILLIS);
        } catch (IOException | ErlangServiceException exception) {
            // Senza backend la revoca resta locale: il cookie viene comunque
            // cancellato dal browser e la sessione di questo Tomcat chiusa.
            getServletContext().log("Unable to revoke login token", exception);
        }
    }
}
