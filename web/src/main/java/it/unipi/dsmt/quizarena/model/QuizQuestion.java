package it.unipi.dsmt.quizarena.model;

import java.util.List;

public record QuizQuestion(
        String text,
        List<String> answers,
        String correct,
        long timeLimitMillis
) {
    public QuizQuestion {
        answers = List.copyOf(answers);
    }
}
