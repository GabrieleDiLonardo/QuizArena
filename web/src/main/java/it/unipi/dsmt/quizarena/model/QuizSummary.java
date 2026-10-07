package it.unipi.dsmt.quizarena.model;

public record QuizSummary(
        QuizId id,
        String owner,
        String title,
        String description
) {
}
