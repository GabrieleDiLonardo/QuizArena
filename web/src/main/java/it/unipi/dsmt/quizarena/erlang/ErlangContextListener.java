package it.unipi.dsmt.quizarena.erlang;

import java.io.IOException;
import java.util.Arrays;
import java.util.List;

import it.unipi.dsmt.quizarena.web.AuthToken;
import it.unipi.dsmt.quizarena.web.GameWebSocketEndpoint;
import jakarta.servlet.ServletContext;
import jakarta.servlet.ServletContextEvent;
import jakarta.servlet.ServletContextListener;
import jakarta.websocket.DeploymentException;
import jakarta.websocket.server.ServerContainer;

public final class ErlangContextListener implements ServletContextListener {

    public static final String CLIENT_ATTRIBUTE = ErlangClient.class.getName();

    private ErlangClient client;

    // Crea il nodo Java quando Tomcat avvia la web application.
    // Ogni impostazione puo' essere fornita da una variabile d'ambiente
    // (usata nel deploy su piu' macchine) oppure dal file web.xml.
    @Override
    public void contextInitialized(ServletContextEvent event) {
        ServletContext context = event.getServletContext();

        String nodeName = requireSetting(
                context, "QUIZARENA_ERLANG_NODE", "erlangNodeName");
        String cookie = requireSetting(
                context, "QUIZARENA_COOKIE", "erlangCookie");
        List<String> backendNodes = Arrays.stream(requireSetting(
                        context, "QUIZARENA_BACKEND_NODES", "erlangBackendNode")
                        .split(","))
                .map(String::trim)
                .filter(value -> !value.isEmpty())
                .toList();
        String gatewayName = requireSetting(
                context, "QUIZARENA_GATEWAY_NAME", "erlangGatewayName");
        AuthToken.configure(System.getenv("QUIZARENA_AUTH_SECRET"));

        try {
            client = new ErlangClient(
                    nodeName, cookie, backendNodes, gatewayName);
            context.setAttribute(CLIENT_ATTRIBUTE, client);

            boolean gatewayReachable = client.isGatewayReachable(2000);
            context.log(
                    "Erlang node " + client.getNodeName()
                    + ", backends " + client.getBackends()
                    + ", gateway reachable: " + gatewayReachable
            );

            registerGameWebSocket(context);
        } catch (IOException | DeploymentException | RuntimeException exception) {
            if (client != null) {
                client.close();
                client = null;
            }
            context.removeAttribute(CLIENT_ATTRIBUTE);
            throw new IllegalStateException(
                    "Unable to initialize the QuizArena web application",
                    exception
            );
        }
    }

    // Chiude il nodo Java quando Tomcat arresta la web application.
    @Override
    public void contextDestroyed(ServletContextEvent event) {
        if (client != null) {
            client.close();
            client = null;
        }
    }

    // Legge un'impostazione obbligatoria: prima dall'ambiente, poi da web.xml.
    private static String requireSetting(
            ServletContext context,
            String environmentName,
            String parameterName
    ) {
        String value = System.getenv(environmentName);
        if (value == null || value.isBlank()) {
            value = context.getInitParameter(parameterName);
        }

        if (value == null || value.isBlank()) {
            throw new IllegalStateException(
                    "Missing setting: " + environmentName
                    + " / context parameter " + parameterName
            );
        }

        return value.trim();
    }

    private void registerGameWebSocket(ServletContext context)
            throws DeploymentException {
        Object attribute = context.getAttribute(
                ServerContainer.class.getName()
        );
        if (!(attribute instanceof ServerContainer serverContainer)) {
            throw new IllegalStateException(
                    "Jakarta WebSocket server container is not available"
            );
        }

        serverContainer.addEndpoint(
                GameWebSocketEndpoint.configuration(client));
    }
}
