'use strict';

document.querySelectorAll('[data-finished-at-millis]').forEach((element) => {
    const timestamp = Number(element.dataset.finishedAtMillis);
    if (!Number.isFinite(timestamp)) return;

    const date = new Date(timestamp);
    if (Number.isNaN(date.getTime())) return;

    element.textContent = new Intl.DateTimeFormat('it-IT', {
        dateStyle: 'medium',
        timeStyle: 'short'
    }).format(date);
});
