module.exports = {
  testEnvironment: 'jsdom',
  setupFiles: ['./test/setup.js'],
  transform: {
    '^.+\\.jsx?$': 'babel-jest',
  },
  moduleNameMapper: {
    '\\.(css|less|scss|sass)$': 'identity-obj-proxy',
  },
  transformIgnorePatterns: [
    '/node_modules/(?!(socket.io-client)/)',
  ],
  collectCoverageFrom: [
    'src/**/*.{js,jsx}',
    '!src/client/index.js',
    '!src/server/index.js',
    '!src/client/store.js',
    '!src/client/middleware/socket.js',
    '!src/client/hooks/useGameEngine.js',
    '!**/node_modules/**',
  ],
  coverageThreshold: {
    global: {
      statements: 70,
      branches: 50,
      functions: 70,
      lines: 70,
    },
  },
  testMatch: [
    '<rootDir>/test/**/*.test.{js,jsx}',
  ],
};
