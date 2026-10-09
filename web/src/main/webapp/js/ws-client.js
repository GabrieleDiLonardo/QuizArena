class QuizWsClient {
    constructor(onMessage) {
        this.onMessage = onMessage;
        this.ws = null;
        this.connected = false;
    }

    connect() {
        const proto = location.protocol === 'https:' ? 'wss' : 'ws';
        // L'endpoint è registrato come "/game" (relativo al context path)
        // Esempio: pagina /quizarena/play.html → ws://host/quizarena/game
        const contextPath = location.pathname.replace(/\/[^/]*$/, '');
        const url = `${proto}://${location.host}${contextPath}/game`;

        console.log('[WS] connecting to', url);
        this.ws = new WebSocket(url);

        this.ws.onopen = () => {
            this.connected = true;
        };
        this.ws.onmessage = (e) => {
            try {
                const msg = JSON.parse(e.data);
                this.emit(msg);
            } catch (err) {
                console.error('Bad JSON:', e.data);
            }
        };
        this.ws.onclose = () => {
            this.connected = false;
            this.emit({type: 'disconnected'});
        };
        this.ws.onerror = (err) => {
            console.error('[WS] error', err);
            this.emit({type: 'ws_error'});
        };
    }

    send(obj) {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify(obj));
        } else {
            console.warn('WS not open, cannot send', obj);
        }
    }

    emit(msg) {
        if (this.onMessage) this.onMessage(msg);
    }
}
