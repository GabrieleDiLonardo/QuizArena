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

// ===== Stato locale =====
let currentPin = null;
let players = [];

// ===== Handlers pulsanti =====
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

// ===== Gestione messaggi dal server =====
function handleMessage(msg) {
    log('← ' + JSON.stringify(msg));

    if (msg.type === 'connected') {
        loadQuizzes();
        return;
    }
    if (msg.type === 'quizzes') {
        renderQuizzes(msg.quizzes);
        return;
    }
    if (msg.type === 'room_created') {
        currentPin = msg.pin;
        document.getElementById('step1').style.display = 'none';
        document.getElementById('step2').style.display = 'block';
        document.getElementById('pinDisplay').textContent = msg.pin;
        return;
    }
    if (msg.type === 'error') {
        alert('Errore: ' + msg.message);
        return;
    }
    if (msg.type === 'ok') {
        return;
    }
    if (msg.type === 'event') {
        handleEvent(msg.event);
    }
}

// ===== Caricamento e render della lista quiz =====
function loadQuizzes() {
    document.getElementById('quizList').innerHTML = 'Caricamento...';
    ws.send({action: 'list_owned_quizzes'});
}

function renderQuizzes(quizzes) {
    const el = document.getElementById('quizList');
    if (!quizzes || quizzes.length === 0) {
        el.innerHTML = '<p>Nessun quiz disponibile. Contatta un amministratore.</p>';
        return;
    }
    el.innerHTML = quizzes.map((q, i) => `
        <div class="quiz-card">
            <h3>${escapeHtml(q.title)}</h3>
            <p>${escapeHtml(q.description || '')}</p>
            <p class="quiz-owner">di ${escapeHtml(q.owner || 'anonimo')}</p>
            <button class="quiz-select-btn" data-index="${i}">Crea stanza</button>
        </div>
    `).join('');

    document.querySelectorAll('.quiz-select-btn').forEach(btn => {
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
        }
    });
}

// ===== Gestione eventi di gioco =====
function handleEvent(ev) {
    if (ev.type === 'player_joined' || ev.type === 'player_rejoined') {
        if (!players.includes(ev.username)) {
            players.push(ev.username);
        }
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
        alert('Partita cancellata: ' + (ev.reason || 'motivo sconosciuto'));
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
    document.getElementById('roundInfo').textContent = `Round ${ev.round} chiuso`;
    document.getElementById('correctAnswer').textContent =
        `Risposta corretta: ${ev.correct}`;
    renderLeaderboard(ev.leaderboard);
    const nextBtn = document.getElementById('nextBtn');
    nextBtn.style.display = 'inline-block';
    nextBtn.textContent = 'Prossimo round';
}

function showFinal(ev) {
    document.getElementById('roundInfo').textContent = 'Partita terminata';
    document.getElementById('questionText').textContent = '';
    document.getElementById('correctAnswer').textContent = '';
    renderLeaderboard(ev.final_leaderboard);
    document.getElementById('nextBtn').style.display = 'none';
    document.getElementById('endBtn').disabled = true;
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
