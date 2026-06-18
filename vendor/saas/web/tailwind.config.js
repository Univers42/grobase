/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        canvas: '#0a0a0f',
        surface: '#12121a',
        'surface-2': '#16161f',
        line: 'rgba(255,255,255,0.08)',
        'line-strong': 'rgba(255,255,255,0.14)',
        ink: '#ECECF3',
        muted: '#8A8AA3',
        accent: '#6F4FF0',
        'accent-fg': '#FFFFFF',
        'accent-soft': 'rgba(111,79,240,0.16)',
        cyan: '#39E5C8',
        danger: '#FF6B6B',
        success: '#3ED598',
        warn: '#FFB454',
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'Segoe UI', 'Roboto', 'sans-serif'],
        display: ['"Instrument Serif"', 'Georgia', 'serif'],
      },
      borderRadius: { '2xl': '1.25rem', '3xl': '1.75rem' },
      letterSpacing: { tightest: '-0.04em' },
      lineHeight: { tightest: '1.05' },
      boxShadow: {
        glass: '0 1px 0 0 rgba(255,255,255,0.05) inset, 0 20px 60px -20px rgba(0,0,0,0.7)',
        glow: '0 0 0 1px rgba(124,92,255,0.35), 0 8px 40px -8px rgba(124,92,255,0.4)',
      },
      backdropBlur: { glass: '18px' },
      keyframes: {
        drift: {
          '0%,100%': { transform: 'translate3d(0,0,0) scale(1)' },
          '50%': { transform: 'translate3d(2%,-3%,0) scale(1.08)' },
        },
        rise: { from: { opacity: '0', transform: 'translateY(14px)' }, to: { opacity: '1', transform: 'translateY(0)' } },
        spin: { to: { transform: 'rotate(360deg)' } },
      },
      animation: {
        drift: 'drift 22s ease-in-out infinite',
        'drift-slow': 'drift 34s ease-in-out infinite',
        rise: 'rise 0.6s cubic-bezier(0.16,1,0.3,1) both',
        spin: 'spin 0.7s linear infinite',
      },
    },
  },
  plugins: [],
};
