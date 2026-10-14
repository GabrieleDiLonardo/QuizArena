'use strict';

// ===== Log helper =====
const log = (msg) => {
    const el = document.getElementById('log');
    if (!el) return;
    el.innerHTML += `<div>${new Date().toLocaleTimeString()} — ${msg}</div>`;
    el.scrollTop = el.scrollHeight;
};

// ===== WebSocket =====
const ws = new QuizWsClient(handleMessage);
ws.connect();

// ===== Stato =====
let currentPin = null;
let players = [];
let roomVisibility = 'public';
let cancelPending = false;
let hostRejoinPending = false;
const HOST_PIN_KEY = 'qa_host_pin';
// Vedi play.js: eventi in ordine (hold-back queue) e rientro ritentato
// durante il ripristino della stanza su un altro nodo.
const events = new EventSequencer(ws, handleEvent);
const REJOIN_RETRY_MS = 1000;
const MAX_REJOIN_ATTEMPTS = 20;
let rejoinAttempts = 0;

function sendHostRejoin(pin) {
    hostRejoinPending = true;
    events.reset(0);
    ws.send({action: 'host_rejoin', pin: pin});
}

// ===== Toggle visibilità stanza =====
const visibilityToggle = document.getElementById('visibilityToggle');
const visibilityHint = document.getElementById('visibilityHint');

function setVisibility(value) {
    roomVisibility = value;
    visibilityToggle.dataset.visibility = value;
    visibilityToggle.textContent = value === 'public' ? 'Pubblica' : 'Privata';
    visibilityToggle.classList.toggle('is-private', value === 'private');
    visibilityToggle.classList.toggle('is-public', value === 'public');
    visibilityHint.textContent = value === 'public'
        ? 'Visibile nella lobby'
        : 'Non visibile nella lobby';
}
visibilityToggle.onclick = () => {
    setVisibility(roomVisibility === 'public' ? 'private' : 'public');
};
setVisibility('public');

// ===== Handlers =====
document.getElementById('startBtn').onclick = () => {
    ws.send({action: 'start_game'});
};
document.getElementById('nextBtn').onclick = () => {
    ws.send({action: 'next_round'});
};
document.getElementById('endBtn').onclick = () => {
    if (confirm('Terminare la partita?')) {
        ws.send({action: 'end_game'});
    }
};
document.querySelectorAll('.cancel-room-btn').forEach(btn => {
    btn.onclick = () => {
        if (confirm('Annullare la stanza? La partita non verrà salvata nello storico.')) {
            cancelPending = true;
            document.querySelectorAll('.cancel-room-btn').forEach(button => {
                button.disabled = true;
            });
            ws.send({action: 'cancel_room'});
        }
    };
});

// ===== Messaggi dal server =====
function handleMessage(msg) {
    log('← ' + JSON.stringify(msg));

    if (msg.type === 'connected') {
        const savedPin = localStorage.getItem(HOST_PIN_KEY);
        if (savedPin) {
            // Pagina ricaricata o connessione persa: riprende la stanza.
            rejoinAttempts = 0;
            sendHostRejoin(savedPin);
        }
        loadMyQuizzes();
        loadBrowsableQuizzes();
        return;
    }
    if (msg.type === 'host_rejoined') {
        hostRejoinPending = false;
        rejoinAttempts = 0;
        events.reset(msg.state.seq || 0);
        restoreHostState(msg.state);
        return;
    }
    if (msg.type === 'quizzes') {
        renderMyQuizzes(msg.quizzes);
        return;
    }
    if (msg.type === 'browsable_quizzes') {
        renderPublicQuizzes(msg.quizzes);
        return;
    }
    if (msg.type === 'room_created') {
        events.reset(0);
        showWaitingRoom(msg.pin, msg.visibility);
        return;
    }
    if (msg.type === 'error') {
        if (hostRejoinPending) {
            hostRejoinPending = false;
            const savedPin = localStorage.getItem(HOST_PIN_KEY);
            if (msg.code === 'room_not_found' && savedPin
                    && rejoinAttempts < MAX_REJOIN_ATTEMPTS) {
                rejoinAttempts++;
                setTimeout(() => sendHostRejoin(savedPin), REJOIN_RETRY_MS);
                return;
            }
            // La stanza non esiste piu': si riparte da zero.
            forgetRoom();
            return;
        }
        if (cancelPending) {
            cancelPending = false;
            document.querySelectorAll('.cancel-room-btn').forEach(button => {
                button.disabled = false;
            });
        }
        alert('Errore: ' + msg.message);
        return;
    }
    if (msg.type === 'ok') {
        return;
    }
    if (msg.type === 'cancelled') {
        forgetRoom();
        alert('Stanza annullata.');
        location.reload();
        return;
    }
    if (msg.type === 'room_recovering') {
        log('Server della partita non raggiungibile: ripristino in corso…');
        return;
    }
    if (msg.type === 'event') {
        events.receive(msg.event);
        return;
    }
    if (msg.type === 'events') {
        events.receiveMissing(msg.events);
        return;
    }
    if (msg.type === 'resync_required') {
        location.reload();
    }
}

// ===== Stanza =====
function showWaitingRoom(pin, visibility) {
    currentPin = pin;
    localStorage.setItem(HOST_PIN_KEY, pin);
    document.getElementById('step1').style.display = 'none';
    document.getElementById('step2').style.display = 'block';
    document.getElementById('pinDisplay').textContent = pin;
    document.getElementById('visibilityInfo').textContent =
        visibility === 'private'
            ? '⚠ Stanza privata — non visibile in lobby'
            : '✓ Stanza pubblica — visibile in lobby';
}

function forgetRoom() {
    currentPin = null;
    localStorage.removeItem(HOST_PIN_KEY);
}

function showGameScreen() {
    document.getElementById('step1').style.display = 'none';
    document.getElementById('step2').style.display = 'none';
    document.getElementById('step3').style.display = 'block';
    document.getElementById('startBtn').disabled = true;
}

// Ricostruisce la schermata a partire dallo stato inviato dalla room.
function restoreHostState(state) {
    players = state.players || [];
    updatePlayerList();
    if (state.status === 'waiting') {
        showWaitingRoom(state.pin, state.visibility);
        return;
    }
    currentPin = state.pin;
    showGameScreen();
    document.getElementById('questionText').textContent = '';
    document.getElementById('correctAnswer').textContent = '';
    if (state.status === 'playing') {
        document.getElementById('roundInfo').textContent =
            'Partita avviata. Premi "Prossimo round" per iniziare.';
        document.getElementById('nextBtn').style.display = 'inline-block';
    } else if (state.status === 'round_open') {
        showRound({round: state.current_round, question: state.question});
    } else if (state.status === 'round_closed') {
        showResults({
            round: state.current_round,
            correct: state.correct,
            leaderboard: state.leaderboard,
            has_next_round: state.has_next_round
        });
    }
}

// ===== Caricamento liste quiz =====
function loadMyQuizzes() {
    document.getElementById('myQuizList').innerHTML = 'Caricamento...';
    ws.send({action: 'list_owned_quizzes'});
}
function loadBrowsableQuizzes() {
    document.getElementById('publicQuizList').innerHTML = 'Caricamento...';
    ws.send({action: 'list_browsable_quizzes'});
}

function renderMyQuizzes(quizzes) {
    const el = document.getElementById('myQuizList');
    if (!quizzes || quizzes.length === 0) {
        el.innerHTML =
            '<p>Nessun quiz. Creane uno dalla pagina <a href="authoring.html">I miei quiz</a>.</p>';
        return;
    }
    el.innerHTML = quizzes.map((q, i) => renderQuizCard(q, i, 'my')).join('');
    bindQuizButtons(el, quizzes);
}

function renderPublicQuizzes(quizzes) {
    const el = document.getElementById('publicQuizList');
    // Filtra solo quelli NON miei
    const others = (quizzes || []).filter(q => !q.isOwn);
    if (others.length === 0) {
        el.innerHTML = '<p>Nessun quiz pubblico di altri utenti.</p>';
        return;
    }
    el.innerHTML = others.map((q, i) => renderQuizCard(q, i, 'public')).join('');
    bindQuizButtons(el, others);
}

function renderQuizCard(q, index, kind) {
    const badge = q.visibility === 'private'
        ? '<span class="badge badge-private">🔒 Privato</span>'
        : '<span class="badge badge-public">🌐 Pubblico</span>';
    const ownerLine = kind === 'public'
        ? `<p class="quiz-owner">di ${escapeHtml(q.owner)}</p>`
        : '';
    return `
        <div class="quiz-card">
            <div class="quiz-card-header">
                <h3>${escapeHtml(q.title)}</h3>
                ${badge}
            </div>
            <p>${escapeHtml(q.description || '')}</p>
            ${ownerLine}
            <button class="quiz-select-btn" data-index="${index}">Crea stanza</button>
        </div>
    `;
}

function bindQuizButtons(container, quizzes) {
    container.querySelectorAll('.quiz-select-btn').forEach(btn => {
        btn.onclick = () => {
            const idx = parseInt(btn.getAttribute('data-index'), 10);
            createRoomWithQuiz(quizzes[idx]);
        };
    });
}

function createRoomWithQuiz(quiz) {
    ws.send({
        action: 'create_room',
        quizId: {
            timestampMicros: quiz.id.timestampMicros,
            uniqueInteger: quiz.id.uniqueInteger
        },
        visibility: roomVisibility
    });
}

// ===== Eventi di gioco =====
function handleEvent(ev) {
    if (ev.type === 'player_joined' || ev.type === 'player_rejoined') {
        if (!players.includes(ev.username)) players.push(ev.username);
        updatePlayerList();
    } else if (ev.type === 'player_disconnected') {
        players = players.filter(p => p !== ev.username);
        updatePlayerList();
    } else if (ev.type === 'game_started') {
        showGameScreen();
        document.getElementById('roundInfo').textContent =
            'Partita avviata. Premi "Prossimo round" per iniziare.';
        document.getElementById('questionText').textContent = '';
        document.getElementById('correctAnswer').textContent = '';
        document.getElementById('nextBtn').style.display = 'inline-block';
        document.getElementById('nextBtn').textContent = 'Prossimo round';
    } else if (ev.type === 'round_started') {
        showRound(ev);
    } else if (ev.type === 'round_closed') {
        showResults(ev);
    } else if (ev.type === 'game_finished') {
        forgetRoom();
        showFinal(ev);
    } else if (ev.type === 'game_cancelled') {
        forgetRoom();
        alert('Stanza annullata.');
        location.reload();
    }
}

function updatePlayerList() {
    document.getElementById('playerList').innerHTML =
        players.map(p => `<li>${escapeHtml(p)}</li>`).join('');
    document.getElementById('startBtn').disabled = players.length === 0;
}

function showRound(ev) {
    document.getElementById('roundInfo').textContent =
        `Round ${ev.round} in corso — ${ev.question.time_limit / 1000}s`;
    document.getElementById('questionText').textContent = ev.question.text;
    document.getElementById('correctAnswer').textContent = '';
    document.getElementById('nextBtn').style.display = 'none';
}

function showResults(ev) {
    document.getElementById('roundInfo').textContent = ev.has_next_round === false
        ? `Ultimo round (${ev.round}) concluso. Termina la partita per salvare i risultati.`
        : `Round ${ev.round} chiuso`;
    document.getElementById('correctAnswer').textContent =
        `Risposta corretta: ${ev.correct}`;
    renderLeaderboard(ev.leaderboard);
    showSuspicious(ev.suspicious || []);
    const nextBtn = document.getElementById('nextBtn');
    if (ev.has_next_round === false) {
        nextBtn.style.display = 'none';
    } else {
        nextBtn.style.display = 'inline-block';
        nextBtn.textContent = 'Prossimo round';
    }
}

// Giocatori il cui tempo di risposta dichiarato non e' coerente con quello
// misurato dal server: per il punteggio e' stato usato il tempo del server.
function showSuspicious(usernames) {
    let el = document.getElementById('suspiciousInfo');
    if (!el) {
        el = document.createElement('p');
        el.id = 'suspiciousInfo';
        el.className = 'suspicious-info';
        const anchor = document.getElementById('leaderboard');
        anchor.parentNode.insertBefore(el, anchor.nextSibling);
    }
    el.textContent = usernames.length === 0 ? ''
        : '⚠ Tempi di risposta sospetti (usato il tempo del server): '
            + usernames.join(', ');
    el.style.display = usernames.length === 0 ? 'none' : 'block';
}

function showFinal(ev) {
    document.getElementById('roundInfo').textContent = 'Partita terminata';
    document.getElementById('questionText').textContent = '';
    document.getElementById('correctAnswer').textContent = '';
    renderLeaderboard(ev.final_leaderboard);
    document.getElementById('nextBtn').style.display = 'none';
    document.getElementById('endBtn').disabled = true;
    document.querySelectorAll('.cancel-room-btn').forEach(button => {
        button.disabled = true;
    });
}

function renderLeaderboard(lb) {
    const el = document.getElementById('leaderboard');
    if (!lb || lb.length === 0) {
        el.innerHTML = '<li>(nessun punteggio)</li>';
        return;
    }
    el.innerHTML = lb.map(([name, score], i) =>
        `<li><strong>#${i + 1} ${escapeHtml(name)}</strong> — ${score} punti</li>`
    ).join('');
}

// ===== Utility =====
function escapeHtml(s) {
    if (s == null) return '';
    return String(s).replace(/[&<>"']/g, c => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
}
