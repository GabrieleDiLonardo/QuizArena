'use strict';

(function () {
    const nameEls = document.querySelectorAll('[data-current-user]');
    const badgeEls = document.querySelectorAll('[data-user-badge]');
    const authenticatedEls = document.querySelectorAll('[data-authenticated-only]');
    const guestEls = document.querySelectorAll('[data-guest-only]');
    if (nameEls.length === 0 && badgeEls.length === 0 &&
            authenticatedEls.length === 0 && guestEls.length === 0) return;

    function showAuthenticationState(authenticated) {
        authenticatedEls.forEach(function (el) {
            el.hidden = !authenticated;
        });
        guestEls.forEach(function (el) {
            el.hidden = authenticated;
        });
        badgeEls.forEach(function (el) {
            el.hidden = !authenticated;
        });
    }

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
                showAuthenticationState(true);
            } else {
                showAuthenticationState(false);
            }
        })
        .catch(function () {
            showAuthenticationState(false);
        });
})();
