package it.unipi.dsmt.quizarena.erlang;

public final class ErlangServiceException extends Exception {

    private final String reason;

    public ErlangServiceException(String reason) {
        super("Erlang service error: " + reason);
        this.reason = reason;
    }

    public String getReason() {
        return reason;
    }
}
