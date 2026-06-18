// ============================================================
// Savanna Park Zoo — BaaS Application Configuration
// Root config consumed by the mini-baas runtime.
// ============================================================

module.exports = {
  appId: 'app2',
  name: 'Savanna Park Zoo',

  databases: {
    mongo: {
      uri: process.env.MONGO_URI || 'mongodb://localhost:27017',
      db: 'zoo_app',
      schemas: './mongo/schemas',
      seeds: './mongo/seeds',
      triggers: './mongo/triggers',
    },
    postgres: {
      uri:
        process.env.POSTGRES_URI ||
        'postgresql://localhost:5432/zoo_app',
      migrations: './postgres/migrations',
      seeds: './postgres/seeds',
      triggers: './postgres/triggers',
    },
  },

  auth: {
    jwtSecret: process.env.JWT_SECRET || 'dev-secret-change-in-production',
    roles: ['admin', 'zookeeper', 'vet', 'reception', 'visitor'],
    sessionTtl: '7d',
    publicRole: 'visitor',
  },

  rules: './rules',
  relations: './relations',

  storage: {
    provider: 'local',
    basePath: process.env.STORAGE_PATH || './storage/app2',
    publicUrl:
      process.env.STORAGE_PUBLIC_URL ||
      'http://localhost:3000/storage/app2',
  },

  realtime: {
    enabled: true,
    adapter: 'websocket',
    port: 3001,
  },

  api: {
    port: 3000,
    cors: {
      origins: [
        'http://localhost:5173', // Vite dev server
        process.env.FRONTEND_URL,
      ].filter(Boolean),
    },
  },
};
