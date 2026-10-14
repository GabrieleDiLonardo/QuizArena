# QuizArena

Piattaforma distribuita di quiz in tempo reale.
Progetto per il corso di *Distributed Systems and Middleware Technologies* (AA 2025-2026).

## Cosa è implementato

- **Autenticazione**: registrazione con PBKDF2-SHA256, login/logout con sessione HTTP e cookie firmato (HMAC) valido su ogni Tomcat, filtro su pagine protette.
- **Quiz**: CRUD completo dal browser, visibilità pubblica/privata, owner check lato server.
- **Partita**: PIN univoco, stanze pubbliche/private, lobby, round con timer, classifica per round e finale. Una risposta corretta vale da 1000 punti (istantanea) a 500 (alla scadenza).
- **Riconnessione**: rejoin automatico del player con state replay, monitoraggio disconnessioni.
- **Tempi di risposta**: tempo misurato dal client e verificato dal server con l'RTT stimato da più sonde (Cristian, minimo dei campioni); margine di 500 ms sulla scadenza per le risposte in viaggio; tempi sospetti segnalati all'host.
- **Ordine degli eventi**: numerazione dalla room (unico sequencer) e hold-back queue nel client, con recupero degli eventi mancanti (`events_since`).
- **Lobby in push**: la lista delle stanze arriva al browser quando cambia (eventi Mnesia), senza polling.
- **Storico**: partite giocate e condotte come host, con titolo del quiz, data, partecipanti, posizione finale e punteggio.
- **Distribuzione**: core Erlang/OTP + Mnesia, web tier Tomcat + WebSocket, bridge Jinterface.

## Stack

Erlang/OTP + Mnesia · Tomcat 10 · Jakarta Servlet 6 · WebSocket · Jinterface · Maven · rebar3

## Deploy distribuito

Tre macchine (nodo Erlang + Tomcat) e Nginx come ingresso unico: vedi
[deploy/README.md](deploy/README.md). In locale:

```
docker compose -f deploy/docker-compose.yml up -d --build
```

## Test

```
rebar3 eunit
```

- `quizarena_room_tests`: partita completa, uscite e rientri di host e
  giocatori, periodo di grazia dell'host, creazione concorrente di stanze,
  pulizia delle sessioni orfane, controllo dei tempi di risposta, recupero
  degli eventi mancanti, lobby in push. Passano dal gateway come farebbe il
  web tier.
- `quizarena_cluster_tests`: tre nodi Erlang reali (modulo `peer`): bootstrap
  di Mnesia in qualunque ordine, rientro di un nodo caduto, elezione Bully,
  ripristino di una partita dopo la caduta del nodo che la ospita.

Usano directory Mnesia temporanee, senza toccare i dati locali.
