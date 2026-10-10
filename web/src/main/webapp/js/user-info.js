'use strict';

(function () {
    const nameEls = document.querySelectorAll('[data-current-user]');
    const badgeEls = document.querySelectorAll('[data-user-badge]');
    if (nameEls.length === 0 && badgeEls.length === 0) return;

    // Ricava il context path dalla URL corrente.
    // Es. /quizarena/host.html → /quizarena
    const contextPath = (function () {
        const path = window.location.pathname;
        const lastSlash = path.lastIndexOf('/');
        return lastSlash > 0 ? path.substring(0, lastSlash) : '';
    })();

    fetch(contextPath + '/api/me', { cache: 'no-store' })
        .then(function (resp) {
            if (resp.status === 401) {
                return { authenticated: false };
            }
            if (!resp.ok) {
                throw new Error('HTTP ' + resp.status);
            }
            return resp.json();
        })
        .then(function (data) {
            if (data.authenticated && data.username) {
                nameEls.forEach(function (el) {
                    el.textContent = data.username;
                });
            } else {
                badgeEls.forEach(function (el) {
                    el.style.display = 'none';
                });
            }
        })
        .catch(function () {
            badgeEls.forEach(function (el) {
                el.style.display = 'none';
            });
        });
})();