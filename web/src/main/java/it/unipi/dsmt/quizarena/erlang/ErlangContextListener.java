package it.unipi.dsmt.quizarena.erlang;

import java.io.IOException;

import jakarta.servlet.ServletContext;
import jakarta.servlet.ServletContextEvent;
import jakarta.servlet.ServletContextListener;

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

        try {
            client = new ErlangClient(nodeName, cookie);
            context.setAttribute(CLIENT_ATTRIBUTE, client);

            boolean reachable = client.isReachable(backendNode, 2000);
            context.log(
                    "Erlang node " + client.getNodeName()
                    + ", backend reachable: " + reachable
            );
        } catch (IOException exception) {
            throw new IllegalStateException(
                    "Unable to initialize the Java Erlang node",
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
}
