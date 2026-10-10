package it.unipi.dsmt.quizarena.model;

import java.util.List;

public record QuizDraft(
        String title,
        String description,
        String visibility,
        List<QuizQuestion> questions
) {
    public QuizDraft {
        questions = List.copyOf(questions);
    }
}