'use strict';

// Funzioni condivise dalle pagine.

// Rende sicuro un testo da inserire in HTML (contenuto o attributo).
function escapeHtml(s) {
    if (s == null) return '';
    return String(s).replace(/[&<>"']/g, c => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
}
