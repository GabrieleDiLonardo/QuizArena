const log = (msg) => {
    const el = document.getElementById('log');
    el.innerHTML += `<div>${new Date().toLocaleTimeString()} — ${msg}</div>`;
    el.scrollTop = el.scrollHeight;
};

const ws = new QuizWsClient(handleMessage);
ws.connect();

let currentPin = null;
let players = [];

function loadQuizzes() {
    document.getElementById('quizList').innerHTML =
        '<p>Vai su <a href="quizzes">Quiz disponibili</a> per vedere gli ID dei quiz.</p>' +
        '<p>Poi incolla l\'ID nel formato <code>[timestampMicros,uniqueInteger]</code>:</p>' +
        '<input id="quizIdInput" placeholder="es. [1790872455166200,1160]">' +
        '<button onclick="createRoom()">Crea stanza</button>';
}

function createRoom() {
    const raw = document.getElementById('quizIdInput').value.trim();
    const parts = raw.replace(/[\[\]]/g, '').split(',').map(s => s.trim());
    if (parts.length !== 2) {
        alert('Formato ID non valido. Usa [timestamp,unique]');
        return;
    }
    const quizId = {
        timestampMicros: parseInt(parts[0]),
        uniqueInteger: parseInt(parts[1])
    };
    ws.send({
        action: 'create_room',
        quizId: quizId,
        hostName: 'host'
    });
}

document.getElementById('startBtn').onclick = () => {
    ws.send({action: 'start_game', pin: currentPin});
};

document.getElementById('nextBtn').onclick = () => {
    ws.send({action: 'next_round', pin: currentPin});
};

document.getElementById('endBtn').onclick = () => {
    if (confirm('Terminare la partita?')) {
        ws.send({action: 'end_game', pin: currentPin});
    }
};

function handleMessage(msg) {
    log('← ' + JSON.stringify(msg));

    if (msg.type === 'connected') {
        loadQuizzes();
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

function handleEvent(ev) {
    if (ev.type === 'player_joined') {
        if (!players.includes(ev.nickname)) {
            players.push(ev.nickname);
        }
        updatePlayerList();
    } else if (ev.type === 'player_disconnected') {
        players = players.filter(p => p !== ev.nickname);
        updatePlayerList();
    } else if (ev.type === 'game_started') {
        document.getElementById('step2').style.display = 'none';
        document.getElementById('step3').style.display = 'block';
        document.getElementById('startBtn').disabled = true;
        document.getElementById('roundInfo').textContent = 'Partita avviata. Premi "Prossimo round" per iniziare.';
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
        alert('Partita cancellata');
        location.reload();
    }
}

function updatePlayerList() {
    document.getElementById('playerList').innerHTML =
        players.map(p => `<li>${p}</li>`).join('');
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
    if (!lb || lb.length === 0) {
        document.getElementById('leaderboard').innerHTML = '<li>(nessun punteggio)</li>';
        return;
    }
    document.getElementById('leaderboard').innerHTML =
        lb.map(([name, score]) => `<li><strong>${name}</strong> — ${score} punti</li>`).join('');
}