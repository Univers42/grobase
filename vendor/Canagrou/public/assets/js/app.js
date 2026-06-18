/**
 * CAMAGRU — Main JavaScript
 * Vanilla ES6+ — No frameworks.
 * Handles: AJAX helpers, flash messages, CSRF.
 */

'use strict';

const App = {
    /** Get CSRF token from meta tag */
    csrfToken() {
        const meta = document.querySelector('meta[name="csrf-token"]');
        return meta ? meta.getAttribute('content') : '';
    },

    /**
     * Escape HTML entities to prevent XSS in dynamic content.
     * @param {string} str
     * @returns {string}
     */
    escapeHtml(str) {
        if (typeof str !== 'string') return String(str ?? '');
        const map = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' };
        return str.replace(/[&<>"']/g, c => map[c]);
    },

    /**
     * Fetch wrapper with CSRF and JSON handling.
     * @param {string} url
     * @param {object} options
     * @returns {Promise<object>}
     */
    async request(url, options = {}) {
        const defaults = {
            headers: {
                'X-CSRF-TOKEN': this.csrfToken(),
                'X-Requested-With': 'XMLHttpRequest',
                'Accept': 'application/json',
            },
        };

        if (options.body && !(options.body instanceof FormData)) {
            defaults.headers['Content-Type'] = 'application/json';
            options.body = JSON.stringify(options.body);
        }

        const config = {
            ...defaults,
            ...options,
            headers: { ...defaults.headers, ...(options.headers || {}) },
        };

        const response = await fetch(url, config);
        const data = await response.json();

        if (!response.ok) {
            throw { status: response.status, ...data };
        }

        return data;
    },

    /**
     * POST request shorthand.
     */
    async post(url, body = {}) {
        // If body is FormData, add CSRF token to it
        if (body instanceof FormData) {
            body.append('_csrf', this.csrfToken());
            return this.request(url, { method: 'POST', body });
        }
        return this.request(url, {
            method: 'POST',
            body: { _csrf: this.csrfToken(), ...body },
        });
    },

    /**
     * DELETE request shorthand (via POST with _method override).
     */
    async delete(url) {
        const formData = new FormData();
        formData.append('_csrf', this.csrfToken());
        formData.append('_method', 'DELETE');
        return this.request(url, { method: 'POST', body: formData });
    },

    /**
     * Auto-dismiss flash messages after 5 seconds.
     */
    initFlashMessages() {
        document.querySelectorAll('[role="alert"]').forEach(el => {
            setTimeout(() => {
                el.style.transition = 'opacity 0.3s, transform 0.3s';
                el.style.opacity = '0';
                el.style.transform = 'translateY(-10px)';
                setTimeout(() => el.remove(), 300);
            }, 5000);
        });
    },

    /**
     * Initialize the application.
     */
    init() {
        this.initFlashMessages();
    }
};

// Boot
document.addEventListener('DOMContentLoaded', () => App.init());
