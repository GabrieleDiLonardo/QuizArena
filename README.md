# QuizArena

Piattaforma distribuita di quiz in tempo reale.
Progetto per il corso di *Distributed Systems and Middleware Technologies* (AA 2025-2026).

## Cosa è implementato

- **Autenticazione**: registrazione con PBKDF2-SHA256, login/logout con sessione HTTP, filtro su pagine protette.
- **Quiz**: CRUD completo dal browser, visibilità pubblica/privata, owner check lato server.
- **Partita**: PIN univoco, stanze pubbliche/private, lobby con auto-refresh, round con timer, punteggio per tempo, classifica per round e finale.
- **Riconnessione**: rejoin automatico del player con state replay, monitoraggio disconnessioni.
- **Storico**: partite giocate e condotte come host, con titolo del quiz, data, partecipanti, posizione finale e punteggio.
- **Distribuzione**: core Erlang/OTP + Mnesia, web tier Tomcat + WebSocket, bridge Jinterface.

## Stack

Erlang/OTP + Mnesia · Tomcat 10 · Jakarta Servlet 6 · WebSocket · Jinterface · Maven · rebar3

## Test

```
rebar3 eunit --module=quizarena_room_tests
```

Gli scenari (partita completa, uscite e rientri di host e giocatori,
periodo di grazia dell'host, creazione concorrente di stanze, pulizia
delle sessioni orfane) passano dal gateway come farebbe il web tier e
usano una directory Mnesia temporanea, senza toccare i dati locali.
 

## Problemi
✅ Cleanup Mnesia incompleto in quizarena_db:cancel_session/1 e finish_session/2

✅ cancel_session/1 non cancella {session_pins, Pin}. Il PIN resta “occupato” per sempre, quindi una futura open_session con lo stesso PIN può restituire pin_taken.

✅ finish_session/2 non cancella né session_pins né session_questions. Questo lascia dati in Mnesia e può causare memory leak / collisioni PIN nel tempo.

✅ abort_session/1 invece fa il cleanup corretto. Sarebbe da allineare anche cancel_session/1 e finish_session/2.

✅ session_questions non vengono eliminate a fine partita
✅ In room_gen_server:finish_game/1 si chiama quizarena_db:finish_session/2, ma quel metodo non elimina session_questions. Dopo molte partite la tabella cresce inutilmente. Andrebbero cancellate come in cancel_session/1.



Hardcoded node Erlang
In quizarena_app.erl:

erlang
Nodes = ['erlang2@erlang2', 'erlang3@erlang3'],
Funziona nel tuo ambiente, ma è poco configurabile. Valuta se spostarlo in configurazione o variabile d’ambiente.

✅ list_owned_quizzes / list_browsable_quizzes nel gateway non usano safe_call
In quizarena_gateway.erl:

erlang
Result = quizarena_db:list_quizzes_by_owner(Owner),
JavaPid ! {Ref, Result},
✅ Se quizarena_db solleva un’eccezione imprevista, il gen_server del gateway può crashare. Sarebbe più robusto avvolgerle in safe_call, come fai per altre operazioni.




✅ Visibilità non valida in handleCreateRoom
✅ In GameWebSocketEndpoint.java, se arriva una visibility testuale ma diversa da public/private, viene silenziosamente ignorata e si usa public. Meglio restituire un errore esplicito.
