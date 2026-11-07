package it.unipi.dsmt.quizarena.web;

import java.io.IOException;

import it.unipi.dsmt.quizarena.erlang.ErlangClient;
import it.unipi.dsmt.quizarena.erlang.ErlangContextListener;
import jakarta.servlet.ServletContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

// Funzioni comuni ai servlet.
final class WebSupport {

    private WebSupport() {
    }

    // Client Erlang creato all'avvio da ErlangContextListener, o null.
    static ErlangClient erlangClient(ServletContext context) {
        Object attribute = context.getAttribute(
                ErlangContextListener.CLIENT_ATTRIBUTE);
        return attribute instanceof ErlangClient client ? client : null;
    }

    // Come erlangClient, ma se manca risponde 503 e restituisce null.
    static ErlangClient requireClient(
            ServletContext context, HttpServletResponse response
    ) throws IOException {
        ErlangClient client = erlangClient(context);
        if (client == null) {
            response.sendError(
                    HttpServletResponse.SC_SERVICE_UNAVAILABLE,
                    "Erlang client is not available");
        }
        return client;
    }

    static String parameter(HttpServletRequest request, String name) {
        String value = request.getParameter(name);
        return value == null ? "" : value;
    }
}
