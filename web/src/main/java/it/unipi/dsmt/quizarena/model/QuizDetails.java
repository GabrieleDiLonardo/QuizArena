package it.unipi.dsmt.quizarena.model;

import java.util.List;

public record QuizDetails(
        QuizId id,
        String owner,
        String title,
        String description,
        List<QuizQuestion> questions
) {
    public QuizDetails {
        questions = List.copyOf(questions);
    }
}
