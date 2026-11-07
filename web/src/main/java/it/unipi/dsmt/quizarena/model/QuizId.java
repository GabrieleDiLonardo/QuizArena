package it.unipi.dsmt.quizarena.model;

import java.util.regex.Pattern;

import com.fasterxml.jackson.annotation.JsonValue;

// Identificativo di un quiz: un UUID generato dal core Erlang. In JSON
// viene scritto come semplice stringa.
public record QuizId(String value) {

    private static final Pattern UUID_PATTERN = Pattern.compile(
            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");

    public QuizId {
        if (value == null || !UUID_PATTERN.matcher(value).matches()) {
            throw new IllegalArgumentException("ID del quiz non valido");
        }
    }

    @JsonValue
    public String value() {
        return value;
    }
}
