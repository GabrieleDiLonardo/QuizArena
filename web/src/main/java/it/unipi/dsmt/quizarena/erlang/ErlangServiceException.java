package it.unipi.dsmt.quizarena.erlang;

public final class ErlangServiceException extends Exception {

    private final String reason;

    public ErlangServiceException(String reason, String detail) {
        super("Erlang service error: " + detail);
        this.reason = reason;
    }

    public String getReason() {
        return reason;
    }
}
