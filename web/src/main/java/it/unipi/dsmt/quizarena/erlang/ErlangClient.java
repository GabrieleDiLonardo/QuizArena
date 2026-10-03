package it.unipi.dsmt.quizarena.erlang;

import java.io.IOException;

import com.ericsson.otp.erlang.OtpNode;

public final class ErlangClient implements AutoCloseable {

    private final OtpNode node;

    // Crea un nodo Java JInterface con il nome e il cookie specificati.
    public ErlangClient(String nodeName, String cookie) throws IOException {
        if (nodeName == null || nodeName.isBlank()) {
            throw new IllegalArgumentException("nodeName must not be blank");
        }
        if (cookie == null || cookie.isBlank()) {
            throw new IllegalArgumentException("cookie must not be blank");
        }

        this.node = new OtpNode(nodeName, cookie);
    }

    public String getNodeName() {
        return node.node();
    }

    // Verifica entro il timeout se il nodo Erlang remoto è raggiungibile.
    public boolean isReachable(String remoteNode, long timeoutMillis) {
        if (remoteNode == null || remoteNode.isBlank()) {
            throw new IllegalArgumentException("remoteNode must not be blank");
        }
        if (timeoutMillis <= 0) {
            throw new IllegalArgumentException("timeoutMillis must be positive");
        }

        return node.ping(remoteNode, timeoutMillis);
    }

    // Chiude il nodo JInterface e libera le risorse associate.
    @Override
    public void close() {
        node.close();
    }
}
