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
let currentUsername = null;
let currentRound = null;
let answered = false;
let timerInterval = null;
let roundDeadline = 0;
let roundStartedAt = 0;
let rejoinPending = false;
// Eventi della stanza consegnati nell'ordine della room (vedi ws-client.js).
const events = new EventSequencer(ws, handleEvent);
// Dopo la caduta di un nodo la stanza puo' impiegare qualche secondo per
// essere ripristinata altrove: il rientro viene ritentato.
const REJOIN_RETRY_MS = 1000;
const MAX_REJOIN_ATTEMPTS = 20;
let rejoinAttempts = 0;

// ===== Precompila il PIN dall'URL (da lobby.html?pin=XXX) =====
(function prefillPin() {
    const params = new URLSearchParams(location.search);
    const pin = params.get('pin');
    if (pin) {
        document.getElementById('pinInput').value = pin;
        document.getElementById('joinBtn').focus();
    }
})();

// ===== Handlers pulsanti =====
document.getElementById('joinBtn').onclick = () => {
    const pin = document.getElementById('pinInput').value.trim();
    if (!pin) {
        alert('Inserisci il PIN');
        return;
    }
    events.reset(0);
    ws.send({action: 'join', pin: pin});
};

function sendRejoin(pin) {
    rejoinPending = true;
    events.reset(0);
    ws.send({action: 'rejoin', pin: pin});
}

// ===== Gestione messaggi dal server =====
function handleMessage(msg) {
    log('← ' + JSON.stringify(msg));

    if (msg.type === 'connected') {
        const savedPin = localStorage.getItem('qa_pin');
        if (savedPin) {
            rejoinAttempts = 0;
            sendRejoin(savedPin);
        }
        return;
    }

    if (msg.type === 'joined') {
        currentPin = msg.pin;
        currentUsername = msg.username;
        localStorage.setItem('qa_pin', msg.pin);
        document.getElementById('step1').style.display = 'none';
        document.getElementById('step2').style.display = 'block';
        document.getElementById('statusMsg').textContent =
            `Connesso come ${msg.username}`;
        return;
    }
    if (msg.type === 'rejoined') {
        rejoinPending = false;
        rejoinAttempts = 0;
        events.reset(msg.state.seq || 0);
        showHostNotice('');
        currentPin = msg.pin;
        currentUsername = msg.state.username;
        localStorage.setItem('qa_pin', msg.pin);
        restorePlayerState(msg.state);
        return;
    }
    if (msg.type === 'ok') return;
    if (msg.type === 'error') {
        if (rejoinPending) {
            rejoinPending = false;
            const savedPin = localStorage.getItem('qa_pin');
            if (msg.code === 'room_not_found' && savedPin
                    && rejoinAttempts < MAX_REJOIN_ATTEMPTS) {
                rejoinAttempts++;
                showHostNotice('Partita in ripristino su un altro server…');
                setTimeout(() => sendRejoin(savedPin), REJOIN_RETRY_MS);
                return;
            }
            showHostNotice('');
            currentPin = null;
            localStorage.removeItem('qa_pin');
        }
        alert('Errore: ' + msg.message);
        return;
    }
    if (msg.type === 'room_recovering') {
        showHostNotice('Il server della partita non risponde: ripristino in corso…');
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
        // Gli eventi persi non sono piu' disponibili: si riparte dallo stato.
        location.reload();
    }
}

// ===== Gestione eventi di gioco =====
function handleEvent(ev) {
    if (ev.type === 'player_joined') {
        log(`Entrato: ${ev.username}`);
    } else if (ev.type === 'player_disconnected') {
        log(`Uscito: ${ev.username}`);
    } else if (ev.type === 'player_rejoined') {
        log(`Rientrato: ${ev.username}`);
    } else if (ev.type === 'host_disconnected') {
        showHostNotice('L\'host si è disconnesso: attendi fino a '
            + Math.round(ev.grace_ms / 1000) + 's che rientri…');
    } else if (ev.type === 'host_rejoined' || ev.type === 'room_recovered') {
        showHostNotice('');
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
    } else if (ev.type === 'game_cancelled') {
        stopTimer();
        currentPin = null;
        localStorage.removeItem('qa_pin');
        document.getElementById('step2').style.display = 'none';
        document.getElementById('step3').style.display = 'none';
        document.getElementById('step4').style.display = 'none';
        document.getElementById('step1').style.display = 'block';
        alert('Partita cancellata: ' +
            (ev.reason || 'motivo sconosciuto'));
    }
}

// ===== Avvisi sull'host =====
function showHostNotice(text) {
    let el = document.getElementById('hostNotice');
    if (!el) {
        el = document.createElement('p');
        el.id = 'hostNotice';
        el.className = 'host-notice';
        const anchor = document.getElementById('step1');
        anchor.parentNode.insertBefore(el, anchor);
    }
    el.textContent = text;
    el.style.display = text ? 'block' : 'none';
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

    // Il clock monotono locale misura il tempo di risposta senza dipendere
    // dall'orologio di calendario del dispositivo.
    const remainingTime = ev.remaining_time ?? ev.question.time_limit;
    const alreadyElapsed = ev.question.time_limit - remainingTime;
    roundStartedAt = performance.now() - alreadyElapsed;
    roundDeadline = performance.now() + remainingTime;
    timerInterval = setInterval(updateTimer, 100);
    updateTimer();
}

function updateTimer() {
    const remaining = Math.max(0, roundDeadline - performance.now());
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
        round: currentRound,
        answer: answer,
        clientElapsedMillis: Math.max(0,
            Math.round(performance.now() - roundStartedAt))
    });
}

// ===== Risultati =====
function showResults(ev) {
    document.getElementById('step3').style.display = 'none';
    document.getElementById('step4').style.display = 'block';
    document.getElementById('resultTitle').textContent = `Round ${ev.round} chiuso`;
    document.getElementById('correctAnswer').textContent =
        `Risposta corretta: ${ev.correct}`;

    const yourScoreEl = document.getElementById('yourScore');
    const ownScore = ev.leaderboard.find(([name]) =>
        name === currentUsername);
    yourScoreEl.textContent = ownScore
        ? `Il tuo punteggio: ${ownScore[1]}`
        : '';

    renderLeaderboard(ev.leaderboard);
}

function showFinal(ev) {
    document.getElementById('step3').style.display = 'none';
    document.getElementById('step4').style.display = 'block';
    document.getElementById('resultTitle').textContent = 'Partita terminata!';
    document.getElementById('correctAnswer').textContent = '';
    document.getElementById('yourScore').textContent = '';
    renderLeaderboard(ev.final_leaderboard);
    currentPin = null;
    localStorage.removeItem('qa_pin');
}

function restorePlayerState(state) {
    if (state && state.host_connected === false) {
        showHostNotice('L\'host è disconnesso: attendi che rientri…');
    }
    document.getElementById('step1').style.display = 'none';
    document.getElementById('step2').style.display = 'none';
    document.getElementById('step3').style.display = 'none';
    document.getElementById('step4').style.display = 'none';

    if (!state || state.status === 'waiting') {
        document.getElementById('step2').style.display = 'block';
        document.getElementById('statusMsg').textContent =
            'Riconnesso. In attesa dell’host...';
        return;
    }
    if (state.status === 'playing') {
        document.getElementById('step2').style.display = 'block';
        document.getElementById('statusMsg').textContent =
            'Riconnesso. In attesa del prossimo round...';
        return;
    }
    if (state.status === 'round_open') {
        showRound({
            round: state.current_round,
            question: state.question,
            remaining_time: state.remaining_time
        });
        if (state.answered) {
            answered = true;
            stopTimer();
            document.querySelectorAll('.answer-btn').forEach(button => {
                button.disabled = true;
            });
            document.getElementById('timerDisplay').textContent =
                'Risposta già inviata. Attendi la chiusura del round.';
        }
        return;
    }
    if (state.status === 'round_closed') {
        showResults({
            round: state.current_round,
            correct: state.correct,
            leaderboard: state.leaderboard
        });
    }
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
