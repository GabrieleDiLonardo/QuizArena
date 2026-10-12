package it.unipi.dsmt.quizarena.model;

import java.time.Instant;

public record GameHistoryEntry(
        String sessionId,
        String quizTitle,
        boolean hosted,
        long participantCount,
        Long score,
        Long rank,
        long finishedAtMillis
) {

    public String finishedAtIso() {
        return Instant.ofEpochMilli(finishedAtMillis).toString();
    }
}
