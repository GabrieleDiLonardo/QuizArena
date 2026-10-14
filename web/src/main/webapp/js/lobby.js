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
                <div class="room-pin">${escapeHtml(pin)}</div>
                <div class="room-title">${escapeHtml(r.quiz_title || '')}</div>
                <div class="room-meta">
                    <span>Host: <strong>${escapeHtml(r.host || '')}</strong></span>
                    <span>Stato: <strong>${status}</strong></span>
                    <span>Giocatori: <strong>${players}</strong></span>
                    <span>Domande: <strong>${questions}</strong></span>
                </div>
                ${canJoin
                    ? `<a class="btn" href="play.html?pin=${encodeURIComponent(pin)}">Entra</a>`
                    : `<span class="btn disabled">Partita in corso</span>`}
            </div>
        `;
    }).join('');
}

function escapeHtml(s) {
    if (s == null) return '';
    return String(s).replace(/[&<>"']/g, c => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
}

// Auto-refresh ogni 5 secondi
setInterval(() => {
    if (ws.connected) ws.send({action: 'list_rooms'});
}, 5000);