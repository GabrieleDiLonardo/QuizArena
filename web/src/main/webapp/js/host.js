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
        loadMyQuizzes();
        loadBrowsableQuizzes();
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
        currentPin = msg.pin;
        document.getElementById('step1').style.display = 'none';
        document.getElementById('step2').style.display = 'block';
        document.getElementById('pinDisplay').textContent = msg.pin;
        document.getElementById('visibilityInfo').textContent =
            msg.visibility === 'private'
                ? '⚠ Stanza privata — non visibile in lobby'
                : '✓ Stanza pubblica — visibile in lobby';
        return;
    }
    if (msg.type === 'error') {
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
        alert('Stanza annullata.');
        location.reload();
        return;
    }
    if (msg.type === 'event') {
        handleEvent(msg.event);
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
        document.getElementById('step2').style.display = 'none';
        document.getElementById('step3').style.display = 'block';
        document.getElementById('startBtn').disabled = true;
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
        showFinal(ev);
    } else if (ev.type === 'game_cancelled') {
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
    const nextBtn = document.getElementById('nextBtn');
    if (ev.has_next_round === false) {
        nextBtn.style.display = 'none';
    } else {
        nextBtn.style.display = 'inline-block';
        nextBtn.textContent = 'Prossimo round';
    }
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
