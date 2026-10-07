package it.unipi.dsmt.quizarena.erlang;

import java.io.IOException;

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
    @Override
    public void contextInitialized(ServletContextEvent event) {
        ServletContext context = event.getServletContext();

        String nodeName = requireInitParameter(
                context,
                "erlangNodeName"
        );
        String cookie = requireInitParameter(
                context,
                "erlangCookie"
        );
        String backendNode = requireInitParameter(
                context,
                "erlangBackendNode"
        );
        String gatewayName = requireInitParameter(
                context,
                "erlangGatewayName"
        );

        try {
            client = new ErlangClient(nodeName, cookie);
            context.setAttribute(CLIENT_ATTRIBUTE, client);

            boolean backendReachable = client.isReachable(backendNode, 2000);
            context.log(
                    "Erlang node " + client.getNodeName()
                    + ", backend reachable: " + backendReachable
            );

            boolean gatewayReachable = backendReachable
                    && client.isGatewayReachable(
                            backendNode,
                            gatewayName,
                            2000
                    );
            context.log(
                    "Erlang gateway " + gatewayName
                    + " reachable: " + gatewayReachable
            );

            registerGameWebSocket(
                    context,
                    backendNode,
                    gatewayName
            );
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

    // Legge un parametro obbligatorio dal file web.xml.
    private static String requireInitParameter(
            ServletContext context,
            String name
    ) {
        String value = context.getInitParameter(name);

        if (value == null || value.isBlank()) {
            throw new IllegalStateException(
                    "Missing context parameter: " + name
            );
        }

        return value;
    }

    private void registerGameWebSocket(
            ServletContext context,
            String backendNode,
            String gatewayName
    ) throws DeploymentException {
        Object attribute = context.getAttribute(
                ServerContainer.class.getName()
        );
        if (!(attribute instanceof ServerContainer serverContainer)) {
            throw new IllegalStateException(
                    "Jakarta WebSocket server container is not available"
            );
        }

        serverContainer.addEndpoint(GameWebSocketEndpoint.configuration(
                client,
                backendNode,
                gatewayName
        ));
    }
}
