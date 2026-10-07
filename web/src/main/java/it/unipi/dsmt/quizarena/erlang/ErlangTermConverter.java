package it.unipi.dsmt.quizarena.erlang;

import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.ericsson.otp.erlang.OtpErlangAtom;
import com.ericsson.otp.erlang.OtpErlangDouble;
import com.ericsson.otp.erlang.OtpErlangException;
import com.ericsson.otp.erlang.OtpErlangList;
import com.ericsson.otp.erlang.OtpErlangLong;
import com.ericsson.otp.erlang.OtpErlangMap;
import com.ericsson.otp.erlang.OtpErlangObject;
import com.ericsson.otp.erlang.OtpErlangString;
import com.ericsson.otp.erlang.OtpErlangTuple;

public final class ErlangTermConverter {

    private ErlangTermConverter() {
    }

    public static Object toJavaValue(OtpErlangObject term)
            throws IOException {
        if (term instanceof OtpErlangString value) {
            return value.stringValue();
        }
        if (term instanceof OtpErlangAtom value) {
            return switch (value.atomValue()) {
                case "true" -> true;
                case "false" -> false;
                default -> value.atomValue();
            };
        }
        if (term instanceof OtpErlangLong value) {
            return value.bigIntegerValue();
        }
        if (term instanceof OtpErlangDouble value) {
            return value.doubleValue();
        }
        if (term instanceof OtpErlangMap value) {
            Map<String, Object> result = new LinkedHashMap<>();
            for (Map.Entry<OtpErlangObject, OtpErlangObject> entry
                    : value.entrySet()) {
                result.put(
                        mapKey(entry.getKey()),
                        toJavaValue(entry.getValue())
                );
            }
            return result;
        }
        if (term instanceof OtpErlangList value) {
            if (value.arity() > 0) {
                try {
                    return value.stringValue();
                } catch (OtpErlangException exception) {
                    // Non è una stringa Erlang: viene convertita come lista.
                }
            }

            List<Object> result = new ArrayList<>(value.arity());
            for (OtpErlangObject element : value) {
                result.add(toJavaValue(element));
            }
            return result;
        }
        if (term instanceof OtpErlangTuple value) {
            List<Object> result = new ArrayList<>(value.arity());
            for (OtpErlangObject element : value.elements()) {
                result.add(toJavaValue(element));
            }
            return result;
        }

        return term.toString();
    }

    private static String mapKey(OtpErlangObject key) {
        if (key instanceof OtpErlangAtom atom) {
            return atom.atomValue();
        }
        if (key instanceof OtpErlangString string) {
            return string.stringValue();
        }
        return key.toString();
    }
}
