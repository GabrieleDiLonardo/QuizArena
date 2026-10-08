"use strict";

const gameCreation = document.getElementById("game-creation");
const hostNameInput = document.getElementById("host-name");
const createRoomButtons = document.querySelectorAll(".create-room");
const gameStatus = document.getElementById("game-status");
const gameError = document.getElementById("game-error");
const gameResult = document.getElementById("game-result");
const roomPin = document.getElementById("room-pin");
const startGameButton = document.getElementById("start-game");

let connected = false;
let requestPending = false;
let roomCreated = false;
let gameStarted = false;

function updateButtons() {
    createRoomButtons.forEach((button) => {
        button.disabled = !connected || requestPending || roomCreated;
    });
    startGameButton.disabled = !connected
        || requestPending
        || !roomCreated
        || gameStarted;
}

function showError(message) {
    gameError.textContent = message;
    gameError.hidden = false;
}

const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
const socket = new WebSocket(
    `${protocol}//${window.location.host}${gameCreation.dataset.contextPath}/game`
);

socket.addEventListener("message", (event) => {
    let message;
    try {
        message = JSON.parse(event.data);
    } catch (exception) {
        showError("Risposta non valida ricevuta dal server.");
        return;
    }

    if (message.type === "connected") {
        connected = true;
        gameStatus.textContent = "Collegamento al server riuscito.";
        updateButtons();
        return;
    }

    if (message.type === "room_created") {
        requestPending = false;
        roomCreated = true;
        hostNameInput.disabled = true;
        roomPin.textContent = message.pin;
        gameResult.hidden = false;
        startGameButton.hidden = false;
        gameError.hidden = true;
        gameStatus.textContent = "Partita creata.";
        updateButtons();
        return;
    }

    if (message.type === "event"
            && message.event?.type === "game_started") {
        requestPending = false;
        gameStarted = true;
        startGameButton.hidden = true;
        gameError.hidden = true;
        gameStatus.textContent = "Partita avviata.";
        updateButtons();
        return;
    }

    if (message.type === "game_start_accepted") {
        requestPending = false;
        updateButtons();
        return;
    }

    if (message.type === "error") {
        requestPending = false;
        showError(message.message || "Impossibile creare la partita.");
        gameStatus.textContent = "Richiesta non completata.";
        updateButtons();
    }
});

socket.addEventListener("error", () => {
    connected = false;
    requestPending = false;
    showError("Errore di collegamento al server.");
    gameStatus.textContent = "Collegamento al server non disponibile.";
    updateButtons();
});

socket.addEventListener("close", () => {
    connected = false;
    requestPending = false;
    gameStatus.textContent = "Collegamento al server chiuso.";
    updateButtons();
});

createRoomButtons.forEach((button) => {
    button.addEventListener("click", () => {
        if (!connected || socket.readyState !== WebSocket.OPEN) {
            showError("Il collegamento al server non è disponibile.");
            return;
        }

        const hostName = hostNameInput.value.trim();
        if (hostName === "") {
            showError("Inserisci il nome dell'host.");
            hostNameInput.focus();
            return;
        }

        requestPending = true;
        gameError.hidden = true;
        gameResult.hidden = true;
        gameStatus.textContent = "Creazione della partita...";
        updateButtons();

        try {
            socket.send(JSON.stringify({
                action: "create_room",
                quizId: {
                    timestampMicros: button.dataset.timestampMicros,
                    uniqueInteger: button.dataset.uniqueInteger
                },
                hostName
            }));
        } catch (exception) {
            requestPending = false;
            showError("Impossibile inviare la richiesta al server.");
            updateButtons();
        }
    });
});

startGameButton.addEventListener("click", () => {
    if (!connected || socket.readyState !== WebSocket.OPEN) {
        showError("Il collegamento al server non è disponibile.");
        return;
    }

    requestPending = true;
    gameError.hidden = true;
    gameStatus.textContent = "Avvio della partita...";
    updateButtons();

    try {
        socket.send(JSON.stringify({action: "start_game"}));
    } catch (exception) {
        requestPending = false;
        showError("Impossibile inviare la richiesta al server.");
        updateButtons();
    }
});
