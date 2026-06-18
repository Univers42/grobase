/**
 * CAMAGRU — Auth page JavaScript
 * Password strength indicator + client-side validation.
 */

'use strict';

(function() {
    const passwordInput = document.getElementById('password');
    const confirmInput = document.getElementById('password_confirm');
    const strengthBars = document.querySelectorAll('[data-bar]');

    if (!passwordInput || !strengthBars.length) return;

    /**
     * Calculate password strength score (0-4).
     */
    function getStrength(password) {
        let score = 0;
        if (password.length >= 8) score++;
        if (/[A-Z]/.test(password) && /[a-z]/.test(password)) score++;
        if (/[0-9]/.test(password)) score++;
        if (/[^A-Za-z0-9]/.test(password)) score++;
        return score;
    }

    /**
     * Get color class for strength level.
     */
    function getColor(score, index) {
        if (index >= score) return 'bg-gray-200';
        const colors = ['bg-red-500', 'bg-orange-500', 'bg-amber-500', 'bg-emerald-500'];
        return colors[score - 1] || 'bg-gray-200';
    }

    /**
     * Update visual strength bars.
     */
    function updateStrength() {
        const score = getStrength(passwordInput.value);
        strengthBars.forEach((bar, i) => {
            // Remove all color classes
            bar.className = bar.className.replace(/bg-\S+/g, '');
            bar.classList.add('h-1', 'flex-1', 'rounded-full', 'transition-colors');
            bar.classList.add(getColor(score, i));
        });
    }

    passwordInput.addEventListener('input', updateStrength);

    // Client-side confirm match indicator
    if (confirmInput) {
        confirmInput.addEventListener('input', function() {
            if (this.value === '') {
                this.classList.remove('border-emerald-500', 'border-red-500');
                this.classList.add('border-gray-300');
            } else if (this.value === passwordInput.value) {
                this.classList.remove('border-gray-300', 'border-red-500');
                this.classList.add('border-emerald-500');
            } else {
                this.classList.remove('border-gray-300', 'border-emerald-500');
                this.classList.add('border-red-500');
            }
        });
    }
})();

/**
 * AJAX Auth Forms — Submit login & register forms via AJAX
 * Progressive enhancement: works without JS (normal POST), enhanced with JS.
 */
(function() {
    /**
     * Show an inline error message within the form.
     */
    function showFormError(form, message) {
        // Remove existing error
        const existing = form.querySelector('.ajax-error');
        if (existing) existing.remove();

        const el = document.createElement('div');
        el.className = 'ajax-error bg-red-50 border border-red-200 text-red-600 px-4 py-3 rounded-lg text-sm flex items-center gap-2 mb-4';
        el.innerHTML = `
            <svg class="w-5 h-5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/></svg>
            <span>${App.escapeHtml(message)}</span>
        `;
        form.prepend(el);

        // Auto-dismiss after 6 seconds
        setTimeout(() => {
            el.style.transition = 'opacity 0.3s';
            el.style.opacity = '0';
            setTimeout(() => el.remove(), 300);
        }, 6000);
    }

    /**
     * Show an inline success message.
     */
    function showFormSuccess(form, message) {
        const existing = form.querySelector('.ajax-error, .ajax-success');
        if (existing) existing.remove();

        const el = document.createElement('div');
        el.className = 'ajax-success bg-emerald-50 border border-emerald-200 text-emerald-600 px-4 py-3 rounded-lg text-sm flex items-center gap-2 mb-4';
        el.innerHTML = `
            <svg class="w-5 h-5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/></svg>
            <span>${App.escapeHtml(message)}</span>
        `;
        form.prepend(el);
    }

    /**
     * Enhance a form to submit via AJAX.
     */
    function ajaxifyForm(form) {
        form.addEventListener('submit', async function(e) {
            e.preventDefault();

            const btn = form.querySelector('button[type="submit"]');
            const originalText = btn.textContent;
            btn.disabled = true;
            btn.textContent = 'Loading…';

            // Remove previous error
            const existing = form.querySelector('.ajax-error, .ajax-success');
            if (existing) existing.remove();

            // Collect form data
            const formData = new FormData(form);
            const data = {};
            for (const [key, val] of formData.entries()) {
                if (key !== '_csrf') data[key] = val;
            }

            try {
                const result = await App.post(form.action, data);

                if (result.success) {
                    showFormSuccess(form, result.message || 'Success!');
                    // Redirect after short delay for user to see success
                    if (result.redirect) {
                        setTimeout(() => window.location.href = result.redirect, 600);
                    }
                }
            } catch (err) {
                showFormError(form, err.error || 'An unexpected error occurred.');
            } finally {
                btn.disabled = false;
                btn.textContent = originalText;
            }
        });
    }

    // Enhance login and register forms
    document.querySelectorAll('form[action="/login"], form[action="/register"]').forEach(ajaxifyForm);
})();
