/* tailwind.config.js — compiled to a STATIC public/tailwind.css (see build-css.sh)
 * instead of the runtime CDN, so styling works even when cdn.tailwindcss.com is
 * blocked by CSP/network. Mirrors the palette that used to live inline in
 * index.html. `content` scans the literal class strings in the JS (el(..,{class}))
 * and the services/ layer. */
module.exports = {
  content: ['./index.html', './src/**/*.{js,html}', '../services/**/*.js'],
  safelist: [
    // dynamically-composed kinds (toast colors, etc.) the scanner can't infer
    'bg-ig-text', 'bg-emerald-600', 'bg-ig-red', 'text-white',
  ],
  theme: {
    extend: {
      colors: {
        ig: {
          blue: '#7c3aed',
          dkblue: '#6d28d9',
          red: '#f43f5e',
          bg: '#f7f7fb',
          border: '#ececf3',
          text: '#1a1a2e',
          muted: '#8a8aa3',
          card: '#ffffff',
        },
        brand: { start: '#7c3aed', mid: '#ec4899', end: '#f59e0b' },
      },
      borderRadius: { '2xl': '1rem', '3xl': '1.5rem' },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'BlinkMacSystemFont', '"Segoe UI"', 'Roboto', 'sans-serif'],
      },
    },
  },
};
