'use strict';

// ===== Costanti =====
const MAX_QUESTIONS = 50;
const MIN_ANSWERS = 2;
const MAX_ANSWERS = 6;
const MIN_TIME = 1000;
const MAX_TIME = 300000;
const DEFAULT_TIME = 30000;

// ===== Stato =====
let quizzes = [];
let editingQuizId = null;
let currentVisibility = 'public';

// ===== Riferimenti DOM =====
const quizListEl = document.getElementById('quizList');
const editorSection = document.getElementById('editorSection');
const editorTitle = document.getElementById('editorTitle');
const quizForm = document.getElementById('quizForm');
const titleInput = document.getElementById('titleInput');
const descriptionInput = document.getElementById('descriptionInput');
const questionsContainer = document.getElementById('questionsContainer');
const alertBox = document.getElementById('alertBox');
const visibilityToggle = document.getElementById('quizVisibilityToggle');
const visibilityHint = document.getElementById('quizVisibilityHint');

// ===== Pulsanti =====
document.getElementById('newQuizBtn').onclick = () => openEditor(null);
document.getElementById('refreshBtn').onclick = loadQuizzes;
document.getElementById('addQuestionBtn').onclick = () => addQuestion();
document.getElementById('cancelEditBtn').onclick = () => closeEditor();
quizForm.onsubmit = (e) => { e.preventDefault(); saveQuiz(); };

// Toggle visibilità — clicca per invertire
visibilityToggle.addEventListener('click', (e) => {
    e.preventDefault();
    e.stopPropagation();
    const next = currentVisibility === 'public' ? 'private' : 'public';
    console.log('[authoring] toggle visibility →', next);
    setVisibility(next);
});

// ===== Visibilità =====
function setVisibility(value) {
    if (value !== 'public' && value !== 'private') {
        value = 'public';
    }
    currentVisibility = value;
    visibilityToggle.dataset.visibility = value;
    visibilityToggle.textContent = value === 'public' ? 'Pubblica' : 'Privata';

    if (value === 'private') {
        visibilityToggle.classList.add('is-private');
        visibilityToggle.classList.remove('is-public');
        visibilityHint.textContent = '🔒 Solo tu potrai usarlo';
    } else {
        visibilityToggle.classList.add('is-public');
        visibilityToggle.classList.remove('is-private');
        visibilityHint.textContent = '🌐 Chiunque potrà usarlo per creare partite';
    }

    console.log('[authoring] visibility set to', value);
}

// Inizializza a public
setVisibility('public');

// ===== Alert =====
function showAlert(message, type = 'error') {
    alertBox.textContent = message;
    alertBox.className = 'alert alert-' + type;
    alertBox.hidden = false;
    setTimeout(() => { alertBox.hidden = true; }, 4000);
}

// ===== API =====
async function apiFetch(url, options = {}) {
    const resp = await fetch(url, {
        headers: { 'Content-Type': 'application/json' },
        ...options
    });
    if (resp.status === 401) {
        window.location.href = 'login';
        throw new Error('Sessione scaduta');
    }
    const body = await resp.json().catch(() => ({}));
    if (!resp.ok) {
        throw new Error(body.error || ('HTTP ' + resp.status));
    }
    return body;
}

async function loadQuizzes() {
    quizListEl.textContent = 'Caricamento...';
    try {
        quizzes = await apiFetch('api/quizzes');
        renderQuizList();
    } catch (e) {
        quizListEl.textContent = 'Errore: ' + e.message;
    }
}

async function loadQuizDetail(quizId) {
    const url = `api/quizzes/${quizId.timestampMicros}/${quizId.uniqueInteger}`;
    return apiFetch(url);
}

async function createQuiz(draft) {
    return apiFetch('api/quizzes', {
        method: 'POST',
        body: JSON.stringify(draft)
    });
}

async function updateQuiz(quizId, draft) {
    const url = `api/quizzes/${quizId.timestampMicros}/${quizId.uniqueInteger}`;
    return apiFetch(url, {
        method: 'PUT',
        body: JSON.stringify(draft)
    });
}

async function deleteQuiz(quizId) {
    const url = `api/quizzes/${quizId.timestampMicros}/${quizId.uniqueInteger}`;
    return apiFetch(url, { method: 'DELETE' });
}

// ===== Render lista =====
function renderQuizList() {
    if (!quizzes || quizzes.length === 0) {
        quizListEl.innerHTML =
            '<p>Nessun quiz ancora. Clicca "+ Nuovo quiz" per crearne uno.</p>';
        return;
    }
    quizListEl.innerHTML = quizzes.map((q, i) => `
        <div class="quiz-card">
            <div class="quiz-card-header">
                <h3>${escapeHtml(q.title)}</h3>
                ${visibilityBadge(q.visibility)}
            </div>
            <p>${escapeHtml(q.description || '')}</p>
            <div class="quiz-actions">
                <button data-action="edit" data-index="${i}">Modifica</button>
                <button data-action="delete" data-index="${i}"
                        class="btn-danger">Elimina</button>
            </div>
        </div>
    `).join('');

    quizListEl.querySelectorAll('button').forEach(btn => {
        const idx = parseInt(btn.dataset.index, 10);
        if (btn.dataset.action === 'edit') {
            btn.onclick = () => openEditorForEdit(quizzes[idx].id);
        } else if (btn.dataset.action === 'delete') {
            btn.onclick = () => confirmDelete(quizzes[idx]);
        }
    });
}

function visibilityBadge(visibility) {
    if (visibility === 'private') {
        return '<span class="badge badge-private">🔒 Privato</span>';
    }
    return '<span class="badge badge-public">🌐 Pubblico</span>';
}

// ===== Editor =====
function openEditor(quizDetail) {
    editingQuizId = quizDetail ? quizDetail.id : null;
    editorTitle.textContent = quizDetail ? 'Modifica quiz' : 'Nuovo quiz';

    titleInput.value = quizDetail ? quizDetail.title : '';
    descriptionInput.value = quizDetail ? quizDetail.description : '';

    // Imposta la visibilità: se quizDetail esiste, usa la sua; altrimenti public
    const initialVisibility = quizDetail
        ? (quizDetail.visibility || 'public')
        : 'public';
    console.log('[authoring] openEditor, quizDetail.visibility =',
                quizDetail ? quizDetail.visibility : 'new');
    setVisibility(initialVisibility);

    questionsContainer.innerHTML = '';
    if (quizDetail && quizDetail.questions.length > 0) {
        quizDetail.questions.forEach(q => addQuestion(q));
    } else {
        addQuestion();
    }

    editorSection.hidden = false;
    quizListEl.parentElement.style.display = 'none';
    window.scrollTo({ top: 0, behavior: 'smooth' });
}

async function openEditorForEdit(quizId) {
    try {
        const detail = await loadQuizDetail(quizId);
        openEditor(detail);
    } catch (e) {
        showAlert('Impossibile caricare il quiz: ' + e.message);
    }
}

function closeEditor() {
    editorSection.hidden = true;
    quizListEl.parentElement.style.display = 'block';
    editingQuizId = null;
    quizForm.reset();
    setVisibility('public');
}

// ===== Editor domande =====
function addQuestion(q = null) {
    const count = questionsContainer.querySelectorAll('.question-editor').length;
    if (count >= MAX_QUESTIONS) {
        showAlert('Massimo ' + MAX_QUESTIONS + ' domande');
        return;
    }

    const el = document.createElement('div');
    el.className = 'question-editor';
    const answers = q ? q.answers : ['', ''];
    const correct = q ? q.correct : null;
    const timeLimit = q ? (q.timeLimitMillis || DEFAULT_TIME) : DEFAULT_TIME;

    el.innerHTML = `
        <div class="question-header">
            <strong>Domanda</strong>
            <button type="button" class="btn-danger remove-question">
                Rimuovi domanda
            </button>
        </div>
        <label>Testo</label>
        <input type="text" class="q-text" maxlength="500"
               value="${escapeHtmlAttr(q ? q.text : '')}" required>

        <label>Risposte
            <span class="hint">(clicca il cerchio per la corretta,
            riclicca per deselezionare)</span>
        </label>
        <div class="answers-list"></div>
        <button type="button" class="btn-secondary add-answer">
            + Aggiungi risposta
        </button>

        <label>Tempo limite (ms)</label>
        <input type="number" class="q-time" min="${MIN_TIME}" max="${MAX_TIME}"
               value="${timeLimit}" required>
    `;

    const list = el.querySelector('.answers-list');
    answers.forEach(a => {
        const isCorrect = correct !== null && correct !== '' && a === correct;
        list.appendChild(createAnswerRow(a, isCorrect, el));
    });

    el.querySelector('.remove-question').onclick = () => el.remove();
    el.querySelector('.add-answer').onclick = () => addAnswer(el);

    questionsContainer.appendChild(el);
}

function createAnswerRow(value, isCorrect, questionEl) {
    const row = document.createElement('div');
    row.className = 'answer-row';
    if (isCorrect) row.classList.add('is-correct');

    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.className = 'correct-toggle';
    toggle.title = 'Clicca per segnare come corretta';
    toggle.textContent = '✓';
    applyToggleStyle(toggle, isCorrect);

    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'answer-input';
    input.maxLength = 200;
    input.placeholder = 'Testo della risposta';
    input.value = value;
    input.required = true;

    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'remove-answer';
    remove.title = 'Rimuovi questa risposta';
    remove.textContent = '×';

    row.appendChild(toggle);
    row.appendChild(input);
    row.appendChild(remove);

    toggle.onclick = () => toggleCorrect(row, questionEl);
    remove.onclick = () => {
        if (questionEl.querySelectorAll('.answer-row').length <= MIN_ANSWERS) {
            showAlert('Servono almeno ' + MIN_ANSWERS + ' risposte');
            return;
        }
        row.remove();
    };

    return row;
}

function applyToggleStyle(toggle, isCorrect) {
    Object.assign(toggle.style, {
        width: '40px', height: '40px', minWidth: '40px',
        padding: '0', margin: '0', borderRadius: '50%',
        background: isCorrect ? '#4caf50' : 'white',
        color: isCorrect ? 'white' : 'transparent',
        border: '2px solid ' + (isCorrect ? '#4caf50' : '#bbb'),
        fontSize: '22px', fontWeight: 'bold', cursor: 'pointer',
        flexShrink: '0', display: 'flex',
        alignItems: 'center', justifyContent: 'center',
        transition: 'all 0.15s'
    });
}

function toggleCorrect(row, questionEl) {
    const wasCorrect = row.classList.contains('is-correct');
    questionEl.querySelectorAll('.answer-row').forEach(r => {
        r.classList.remove('is-correct');
        const t = r.querySelector('.correct-toggle');
        if (t) applyToggleStyle(t, false);
    });
    if (!wasCorrect) {
        row.classList.add('is-correct');
        applyToggleStyle(row.querySelector('.correct-toggle'), true);
    }
}

function addAnswer(questionEl) {
    const list = questionEl.querySelector('.answers-list');
    if (list.querySelectorAll('.answer-row').length >= MAX_ANSWERS) {
        showAlert('Massimo ' + MAX_ANSWERS + ' risposte');
        return;
    }
    const row = createAnswerRow('', false, questionEl);
    list.appendChild(row);
    row.querySelector('.answer-input').focus();
}

// ===== Salvataggio =====
async function saveQuiz() {
    try {
        const draft = buildDraftFromForm();
        console.log('[authoring] saving draft:', JSON.stringify(draft));

        if (editingQuizId) {
            await updateQuiz(editingQuizId, draft);
            showAlert('Quiz aggiornato', 'success');
        } else {
            await createQuiz(draft);
            showAlert('Quiz creato', 'success');
        }
        closeEditor();
        await loadQuizzes();
    } catch (e) {
        console.error('[authoring] save error:', e);
        showAlert('Errore: ' + e.message);
    }
}

function buildDraftFromForm() {
    const title = titleInput.value.trim();
    if (!title) throw new Error('Titolo obbligatorio');

    const questionEls = questionsContainer.querySelectorAll('.question-editor');
    if (questionEls.length === 0) throw new Error('Serve almeno una domanda');

    const questions = [];
    questionEls.forEach(qEl => {
        const text = qEl.querySelector('.q-text').value.trim();
        if (!text) throw new Error('Testo domanda obbligatorio');

        const rows = qEl.querySelectorAll('.answer-row');
        const answers = [];
        let correct = null;

        rows.forEach(row => {
            const value = row.querySelector('.answer-input').value.trim();
            if (!value) return;
            answers.push(value);
            if (row.classList.contains('is-correct')) correct = value;
        });

        if (answers.length < MIN_ANSWERS) {
            throw new Error('Ogni domanda deve avere almeno ' + MIN_ANSWERS + ' risposte');
        }
        const unique = new Set(answers);
        if (unique.size !== answers.length) {
            throw new Error('Le risposte devono essere diverse tra loro');
        }
        if (!correct) {
            throw new Error('Indica la risposta corretta con il cerchio verde');
        }

        const timeLimit = parseInt(qEl.querySelector('.q-time').value, 10);
        if (isNaN(timeLimit) || timeLimit < MIN_TIME || timeLimit > MAX_TIME) {
            throw new Error('Tempo limite non valido');
        }

        questions.push({
            text: text,
            answers: answers,
            correct: correct,
            timeLimitMillis: timeLimit
        });
    });

    return {
        title,
        description: descriptionInput.value.trim(),
        visibility: currentVisibility,
        questions
    };
}

// ===== Cancellazione =====
async function confirmDelete(quiz) {
    if (!confirm(`Eliminare il quiz "${quiz.title}"?`)) return;
    try {
        await deleteQuiz(quiz.id);
        showAlert('Quiz eliminato', 'success');
        await loadQuizzes();
    } catch (e) {
        showAlert('Errore: ' + e.message);
    }
}

// ===== Utility =====
function escapeHtml(s) {
    if (s == null) return '';
    return String(s).replace(/[&<>"']/g, c => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
}
function escapeHtmlAttr(s) { return escapeHtml(s); }

// ===== Init =====
loadQuizzes();