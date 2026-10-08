const log = (msg) => {
    const el = document.getElementById('log');
    el.innerHTML += `<div>${new Date().toLocaleTimeString()} — ${msg}</div>`;
    el.scrollTop = el.scrollHeight;
};

const ws = new QuizWsClient(handleMessage);
ws.connect();

document.getElementById('refreshBtn').onclick = () => {
    ws.send({action: 'list_rooms'});
};

function handleMessage(msg) {
    log('← ' + JSON.stringify(msg));

    if (msg.type === 'connected') {
        ws.send({action: 'list_rooms'});
        return;
    }
    if (msg.type === 'rooms') {
        renderRooms(msg.rooms);
        return;
    }
    if (msg.type === 'error') {
        document.getElementById('roomsList').textContent = 'Errore: ' + msg.message;
    }
}

function renderRooms(rooms) {
    const el = document.getElementById('roomsList');
    if (!rooms || rooms.length === 0) {
        el.innerHTML = '<p>Nessuna stanza aperta al momento.</p>';
        return;
    }
    el.innerHTML = rooms.map(r => {
        const pin = r.pin;
        const status = r.status || 'unknown';
        const players = r.num_players != null ? r.num_players : 0;
        const questions = r.num_questions != null ? r.num_questions : 0;
        const canJoin = status === 'waiting';
        return `
            <div class="room-card">
                <div class="room-pin">${pin}</div>
                <div class="room-meta">
                    <span>Stato: <strong>${status}</strong></span>
                    <span>Giocatori: <strong>${players}</strong></span>
                    <span>Domande: <strong>${questions}</strong></span>
                </div>
                ${canJoin
                    ? `<a class="btn" href="play.html?pin=${pin}">Entra</a>`
                    : `<span class="btn disabled">Partita in corso</span>`}
            </div>
        `;
    }).join('');
}

// Auto-refresh ogni 5 secondi
setInterval(() => {
    if (ws.connected) ws.send({action: 'list_rooms'});
}, 5000);