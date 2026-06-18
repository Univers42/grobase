import * as Joi from 'joi';

export const configValidationSchema = Joi.object({
  // Server
  PORT: Joi.number().default(3000),
  NODE_ENV: Joi.string()
    .valid('development', 'production', 'test', 'staging')
    .default('development'),

  // MongoDB
  MONGODB_URI: Joi.string().required().uri({ scheme: ['mongodb', 'mongodb+srv'] }),

  // JWT
  JWT_SECRET: Joi.string().required().min(32),
  JWT_REFRESH_SECRET: Joi.string().required().min(32),
  JWT_EXPIRATION: Joi.string().default('15m'),
  JWT_REFRESH_EXPIRATION: Joi.string().default('7d'),

  // OAuth - Google
  GOOGLE_CLIENT_ID: Joi.string().optional(),
  GOOGLE_CLIENT_SECRET: Joi.string().optional(),
  GOOGLE_CALLBACK_URL: Joi.string().uri().optional(),

  // OAuth - Facebook
  FACEBOOK_APP_ID: Joi.string().optional(),
  FACEBOOK_APP_SECRET: Joi.string().optional(),
  FACEBOOK_CALLBACK_URL: Joi.string().uri().optional(),

  // Deezer
  DEEZER_APP_ID: Joi.string().optional(),
  DEEZER_APP_SECRET: Joi.string().optional(),

  // SMTP
  SMTP_HOST: Joi.string().optional(),
  SMTP_PORT: Joi.number().default(587),
  SMTP_USER: Joi.string().optional(),
  SMTP_PASS: Joi.string().optional(),
  SMTP_FROM: Joi.string().email().optional(),

  // Frontend
  FRONTEND_URL: Joi.string().uri().default('http://localhost:8081'),

  // Rate Limiting
  THROTTLE_TTL: Joi.number().default(60000),
  THROTTLE_LIMIT: Joi.number().default(100),

  // MQTT / IoT
  MQTT_BROKER_URL: Joi.string().uri().optional(),
  MQTT_USERNAME: Joi.string().optional(),
  MQTT_PASSWORD: Joi.string().optional(),
});
