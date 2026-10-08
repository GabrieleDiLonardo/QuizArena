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
let currentPlayerId = null;
let currentRound = null;
let answered = false;
let timerInterval = null;
let roundDeadline = 0;

// ===== Precompila il PIN dall'URL (da lobby.html?pin=XXX) =====
(function prefillPin() {
    const params = new URLSearchParams(location.search);
    const pin = params.get('pin');
    if (pin) {
        document.getElementById('pinInput').value = pin;
        document.getElementById('nickInput').focus();
    }
})();

// ===== Handlers pulsanti =====
document.getElementById('joinBtn').onclick = () => {
    const pin = document.getElementById('pinInput').value.trim();
    const nick = document.getElementById('nickInput').value.trim();
    if (!pin || !nick) {
        alert('Inserisci PIN e nickname');
        return;
    }
    localStorage.setItem('qa_nickname', nick);  
    ws.send({action: 'join', pin: pin, nickname: nick});
};

// ===== Gestione messaggi dal server =====
function handleMessage(msg) {
    log('← ' + JSON.stringify(msg));

    if (msg.type === 'connected') return;

    if (msg.type === 'joined') {
        currentPin = msg.pin;
        currentPlayerId = msg.playerId;
        localStorage.setItem('qa_pin', msg.pin);
        localStorage.setItem('qa_playerId', String(msg.playerId));
        document.getElementById('step1').style.display = 'none';
        document.getElementById('step2').style.display = 'block';
        document.getElementById('statusMsg').textContent =
            `Connesso come player #${msg.playerId}`;
        return;
    }
    if (msg.type === 'ok') return;
    if (msg.type === 'error') {
        alert('Errore: ' + msg.message);
        return;
    }
    if (msg.type === 'event') {
        handleEvent(msg.event);
    }
}

// ===== Gestione eventi di gioco =====
function handleEvent(ev) {
    if (ev.type === 'player_joined') {
        log(`Entrato: ${ev.nickname}`);
    } else if (ev.type === 'player_disconnected') {
        log(`Uscito: ${ev.nickname}`);
    } else if (ev.type === 'game_started') {
        document.getElementById('step2').style.display = 'none';
        document.getElementById('statusMsg').textContent = 'Partita iniziata!';
    } else if (ev.type === 'round_started') {
        showRound(ev);
    } else if (ev.type === 'round_closed') {
        stopTimer();
        showResults(ev);
    } else if (ev.type === 'game_finished') {
        stopTimer();
        showFinal(ev);
    }
}

// ===== Round =====
function showRound(ev) {
    stopTimer();

    currentRound = ev.round;
    answered = false;

    document.getElementById('step2').style.display = 'none';
    document.getElementById('step3').style.display = 'block';
    document.getElementById('step4').style.display = 'none';
    document.getElementById('roundTitle').textContent = `Round ${ev.round}`;
    document.getElementById('questionText').textContent = ev.question.text;
    document.getElementById('leaderboard').innerHTML = '';

    const box = document.getElementById('answersBox');
    box.innerHTML = '';
    ev.question.answers.forEach(a => {
        const btn = document.createElement('button');
        btn.className = 'answer-btn';
        btn.textContent = a;
        btn.onclick = () => submitAnswer(a, btn);
        box.appendChild(btn);
    });

    // Timer basato su timestamp assoluto (no drift)
    roundDeadline = Date.now() + ev.question.time_limit;
    timerInterval = setInterval(updateTimer, 100);
    updateTimer();
}

function updateTimer() {
    const remaining = Math.max(0, roundDeadline - Date.now());
    const timerEl = document.getElementById('timerDisplay');
    if (remaining <= 0) {
        timerEl.textContent = 'Tempo scaduto';
        stopTimer();
        return;
    }
    timerEl.textContent = `Tempo: ${(remaining / 1000).toFixed(1)}s`;
}

function stopTimer() {
    if (timerInterval !== null) {
        clearInterval(timerInterval);
        timerInterval = null;
    }
}

function submitAnswer(answer, btn) {
    if (answered) return;
    answered = true;
    stopTimer();
    document.querySelectorAll('.answer-btn').forEach(b => {
        b.classList.remove('selected');
        b.disabled = true;
    });
    btn.classList.add('selected');
    ws.send({
        action: 'answer',
        playerId: currentPlayerId,
        round: currentRound,
        answer: answer
    });
}

// ===== Risultati =====
function showResults(ev) {
    document.getElementById('step3').style.display = 'none';
    document.getElementById('step4').style.display = 'block';
    document.getElementById('resultTitle').textContent = `Round ${ev.round} chiuso`;
    document.getElementById('correctAnswer').textContent =
        `Risposta corretta: ${ev.correct}`;

    // Trova il proprio punteggio
    const myNickname = localStorage.getItem('qa_nickname');
    const yourScoreEl = document.getElementById('yourScore');
    if (myNickname) {
        const row = ev.leaderboard.find(([name]) => name === myNickname);
        if (row) {
            yourScoreEl.textContent = `Il tuo punteggio: ${row[1]}`;
        } else {
            yourScoreEl.textContent = '';
        }
    } else {
        yourScoreEl.textContent = '';
    }

    renderLeaderboard(ev.leaderboard);
}

function showFinal(ev) {
    document.getElementById('step3').style.display = 'none';
    document.getElementById('step4').style.display = 'block';
    document.getElementById('resultTitle').textContent = 'Partita terminata!';
    document.getElementById('correctAnswer').textContent = '';
    document.getElementById('yourScore').textContent = '';
    renderLeaderboard(ev.final_leaderboard);
    localStorage.removeItem('qa_pin');
    localStorage.removeItem('qa_playerId');
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