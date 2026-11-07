package it.unipi.dsmt.quizarena.erlang;

import java.io.IOException;

import com.ericsson.otp.erlang.OtpErlangAtom;
import com.ericsson.otp.erlang.OtpErlangObject;
import com.ericsson.otp.erlang.OtpErlangTuple;

// Decodifica, in un solo punto, delle risposte del gateway Erlang:
// {ok, Valore} oppure {error, Motivo}.
final class ErlangReplies {

    private static final OtpErlangAtom OK = new OtpErlangAtom("ok");
    private static final OtpErlangAtom ERROR = new OtpErlangAtom("error");

    private ErlangReplies() {
    }

    // Restituisce Valore; {error, Motivo} diventa ErlangServiceException.
    static OtpErlangObject requireOk(OtpErlangObject result)
            throws IOException, ErlangServiceException {
        if (!(result instanceof OtpErlangTuple tuple) || tuple.arity() != 2) {
            throw new IOException("Malformed result from Erlang gateway");
        }
        OtpErlangObject status = tuple.elementAt(0);
        OtpErlangObject content = tuple.elementAt(1);
        if (ERROR.equals(status)) {
            throw new ErlangServiceException(reasonTag(content),
                    content.toString());
        }
        if (!OK.equals(status)) {
            throw new IOException("Unknown result status from Erlang gateway");
        }
        return content;
    }

    static void requireOkAtom(OtpErlangObject result)
            throws IOException, ErlangServiceException {
        if (!OK.equals(requireOk(result))) {
            throw new IOException("Expected {ok, ok} from Erlang gateway");
        }
    }

    private static String reasonTag(OtpErlangObject reason) {
        if (reason instanceof OtpErlangAtom atom) {
            return atom.atomValue();
        }
        if (reason instanceof OtpErlangTuple tuple && tuple.arity() > 0
                && tuple.elementAt(0) instanceof OtpErlangAtom tag) {
            return tag.atomValue();
        }
        return reason.toString();
    }
}
