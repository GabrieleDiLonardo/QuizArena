// Connessione WebSocket al server di gioco.
// Se la connessione cade (Tomcat o macchina non piu' raggiungibile) viene
// ristabilita automaticamente con attese crescenti: Nginx la instrada su un
// Tomcat ancora attivo e la pagina, ricevuto di nuovo "connected", rientra
// nella stanza.
class QuizWsClient {
    static MIN_RETRY_MS = 500;
    static MAX_RETRY_MS = 5000;
    // Chiusura per autenticazione mancante (CloseCodes.VIOLATED_POLICY).
    static POLICY_VIOLATION = 1008;

    constructor(onMessage) {
        this.onMessage = onMessage;
        this.ws = null;
        this.connected = false;
        this.retryDelay = QuizWsClient.MIN_RETRY_MS;
        this.banner = null;
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
            this.retryDelay = QuizWsClient.MIN_RETRY_MS;
            this.showBanner(false);
        };
        this.ws.onmessage = (e) => {
            try {
                const msg = JSON.parse(e.data);
                if (msg.type === 'time_probe' && msg.nonce) {
                    this.send({action: 'time_probe_reply', nonce: msg.nonce});
                    return;
                }
                this.emit(msg);
            } catch (err) {
                console.error('Bad JSON:', e.data);
            }
        };
        this.ws.onclose = (e) => {
            const wasConnected = this.connected;
            this.connected = false;
            if (e.code === QuizWsClient.POLICY_VIOLATION) {
                // Sessione scaduta o logout: si torna alla pagina di login.
                location.href = contextPath + '/';
                return;
            }
            if (wasConnected) {
                this.emit({type: 'disconnected'});
            }
            this.showBanner(true);
            setTimeout(() => this.connect(), this.retryDelay);
            this.retryDelay = Math.min(this.retryDelay * 2,
                QuizWsClient.MAX_RETRY_MS);
        };
        this.ws.onerror = (err) => {
            console.error('[WS] error', err);
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

    showBanner(visible) {
        if (!this.banner) {
            this.banner = document.createElement('div');
            this.banner.textContent = 'Connessione persa: riconnessione in corso…';
            this.banner.style.cssText = 'position:fixed;top:0;left:0;right:0;'
                + 'padding:8px;text-align:center;background:#fff6e0;'
                + 'border-bottom:1px solid #f0c36d;color:#7a5a00;z-index:1000';
            document.body.appendChild(this.banner);
        }
        this.banner.style.display = visible ? 'block' : 'none';
    }
}
