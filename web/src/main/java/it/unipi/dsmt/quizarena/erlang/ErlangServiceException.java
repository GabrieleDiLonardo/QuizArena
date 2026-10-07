package it.unipi.dsmt.quizarena.erlang;

public final class ErlangServiceException extends Exception {

    public ErlangServiceException(String reason) {
        super("Erlang service error: " + reason);
    }
}
