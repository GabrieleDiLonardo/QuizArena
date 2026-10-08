const log = (msg) => {
    const el = document.getElementById('log');
    el.innerHTML += `<div>${new Date().toLocaleTimeString()} — ${msg}</div>`;
    el.scrollTop = el.scrollHeight;
};

const ws = new QuizWsClient(handleMessage);
ws.connect();

let currentPin = null;
let currentPlayerId = null;
let currentRound = null;
let answered = false;

document.getElementById('joinBtn').onclick = () => {
    const pin = document.getElementById('pinInput').value.trim();
    const nick = document.getElementById('nickInput').value.trim();
    if (!pin || !nick) { alert('Inserisci PIN e nickname'); return; }
    ws.send({action: 'join', pin: pin, nickname: nick});
};

function handleMessage(msg) {
    log('← ' + JSON.stringify(msg));

    if (msg.type === 'connected') return;

    if (msg.type === 'joined') {
        currentPin = msg.pin;
        currentPlayerId = msg.playerId;
        // Salva per rejoin
        localStorage.setItem('qa_pin', msg.pin);
        localStorage.setItem('qa_playerId', String(msg.playerId));
        document.getElementById('step1').style.display = 'none';
        document.getElementById('step2').style.display = 'block';
        document.getElementById('statusMsg').textContent =
            `Connesso come player #${msg.playerId}`;
        return;
    }
    if (msg.type === 'error') {
        alert('Errore: ' + msg.message);
        return;
    }
    if (msg.type === 'event') {
        handleEvent(msg.event);
    }
}

function handleEvent(ev) {
    if (ev.type === 'player_joined') {
        log(`Entrato: ${ev.nickname}`);
    } else if (ev.type === 'game_started') {
        document.getElementById('step2').style.display = 'none';
        document.getElementById('statusMsg').textContent = 'Partita iniziata!';
    } else if (ev.type === 'round_started') {
        showRound(ev);
    } else if (ev.type === 'round_closed') {
        showResults(ev);
    } else if (ev.type === 'game_finished') {
        showFinal(ev);
    }
}

function showRound(ev) {
    currentRound = ev.round;
    answered = false;
    document.getElementById('step2').style.display = 'none';
    document.getElementById('step3').style.display = 'block';
    document.getElementById('step4').style.display = 'none';
    document.getElementById('roundTitle').textContent =
        `Round ${ev.round}`;
    document.getElementById('questionText').textContent = ev.question.text;

    const box = document.getElementById('answersBox');
    box.innerHTML = '';
    ev.question.answers.forEach(a => {
        const btn = document.createElement('button');
        btn.className = 'answer-btn';
        btn.textContent = a;
        btn.onclick = () => submitAnswer(a, btn);
        box.appendChild(btn);
    });

    // Timer locale (opzionale)
    let remaining = ev.question.time_limit;
    const timerEl = document.getElementById('timerDisplay');
    const tick = setInterval(() => {
        remaining -= 100;
        timerEl.textContent = `Tempo: ${(remaining / 1000).toFixed(1)}s`;
        if (remaining <= 0) clearInterval(tick);
    }, 100);
}

function submitAnswer(answer, btn) {
    if (answered) return;
    answered = true;
    document.querySelectorAll('.answer-btn').forEach(b => b.classList.remove('selected'));
    btn.classList.add('selected');
    ws.send({
        action: 'answer',
        pin: currentPin,
        playerId: currentPlayerId,
        round: currentRound,
        answer: answer
    });
}

function showResults(ev) {
    document.getElementById('step3').style.display = 'none';
    document.getElementById('step4').style.display = 'block';
    document.getElementById('resultTitle').textContent = `Round ${ev.round}`;
    document.getElementById('correctAnswer').textContent =
        `Risposta corretta: ${ev.correct}`;
    renderLeaderboard(ev.leaderboard);
}

function showFinal(ev) {
    document.getElementById('step4').style.display = 'block';
    document.getElementById('resultTitle').textContent = 'Partita terminata!';
    renderLeaderboard(ev.final_leaderboard);
    localStorage.removeItem('qa_pin');
    localStorage.removeItem('qa_playerId');
}

function renderLeaderboard(lb) {
    document.getElementById('leaderboard').innerHTML =
        lb.map(([name, score]) => `<li>${name} — ${score}</li>`).join('');
}