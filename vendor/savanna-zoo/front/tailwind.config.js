/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      colors: {
        forest:  { DEFAULT: '#1a3a2a', light: '#2c6e49', pale: '#4a9e6f' },
        sand:    { DEFAULT: '#e8d5a3', light: '#f0e4c4', dark: '#c9b67e' },
        amber:   { DEFAULT: '#c4702a', light: '#e09048', dark: '#9e5a20' },
        ivory:   { DEFAULT: '#faf7f0', warm: '#f5f0e3' },
        charcoal:{ DEFAULT: '#1c1c1e', light: '#2c2c2e' },
      },
      fontFamily: {
        display: ['"Cormorant Garamond"', 'Georgia', 'serif'],
        body:    ['"DM Sans"', 'system-ui', 'sans-serif'],
      },
      backgroundImage: {
        'hero-gradient':
          'linear-gradient(135deg, rgba(26,58,42,0.92) 0%, rgba(26,58,42,0.6) 50%, rgba(196,112,42,0.4) 100%)',
        'card-gradient':
          'linear-gradient(180deg, transparent 0%, rgba(26,58,42,0.85) 100%)',
      },
      animation: {
        'fade-in':    'fadeIn 0.6s ease-out',
        'slide-up':   'slideUp 0.5s ease-out',
        'pulse-slow': 'pulse 3s ease-in-out infinite',
      },
      keyframes: {
        fadeIn:  { from: { opacity: '0' },                              to: { opacity: '1' } },
        slideUp: { from: { opacity: '0', transform: 'translateY(20px)' }, to: { opacity: '1', transform: 'translateY(0)' } },
      },
    },
  },
  plugins: [],
};
