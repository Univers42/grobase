# Deployment Guide

This guide covers deploying Music Room to production.

## Prerequisites

- Docker & Docker Compose
- Domain name with SSL certificate
- MongoDB Atlas (or self-hosted)
- SMTP credentials for email sending

## Environment Configuration

### Production Environment Variables

```bash
# Server
NODE_ENV=production
PORT=3000

# Database
MONGODB_URI=mongodb+srv://<user>:<pass>@<cluster>/music-room

# JWT
JWT_SECRET=<generate-with: openssl rand -hex 64>
JWT_EXPIRATION=15m
JWT_REFRESH_SECRET=<generate-with: openssl rand -hex 64>
JWT_REFRESH_EXPIRATION=7d

# OAuth
GOOGLE_CLIENT_ID=<from-google-console>
GOOGLE_CLIENT_SECRET=<from-google-console>
GOOGLE_CALLBACK_URL=https://api.yourdomain.com/auth/google/callback
FACEBOOK_APP_ID=<from-facebook-developers>
FACEBOOK_APP_SECRET=<from-facebook-developers>
FACEBOOK_CALLBACK_URL=https://api.yourdomain.com/auth/facebook/callback

# CORS
CORS_ORIGINS=https://yourdomain.com,https://www.yourdomain.com
FRONTEND_URL=https://yourdomain.com

# Rate Limiting
THROTTLE_TTL=60000
THROTTLE_LIMIT=30

# SMTP
SMTP_HOST=smtp.yourdomain.com
SMTP_PORT=587
SMTP_USER=noreply@yourdomain.com
SMTP_PASS=<smtp-password>

# MQTT (optional, for IoT)
MQTT_BROKER_URL=mqtt://mqtt.yourdomain.com:1883
MQTT_USERNAME=<mqtt-user>
MQTT_PASSWORD=<mqtt-pass>
```

## Docker Deployment

### Build and Run

```bash
# Build images
docker-compose -f docker-compose.yml build

# Start services
docker-compose up -d

# Check logs
docker-compose logs -f api
```

### With Reverse Proxy (nginx)

```nginx
server {
    listen 443 ssl http2;
    server_name api.yourdomain.com;

    ssl_certificate /etc/ssl/certs/yourdomain.pem;
    ssl_certificate_key /etc/ssl/private/yourdomain.key;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Database Setup

### MongoDB Atlas

1. Create a cluster at [mongodb.com](https://www.mongodb.com/atlas)
2. Create a database user
3. Whitelist your server IP
4. Get connection string for `MONGODB_URI`

### Create Indexes

The Mongoose schemas auto-create indexes, but for production you may want to verify:

```javascript
// In MongoDB shell
db.users.createIndex({ email: 1 }, { unique: true });
db.events.createIndex({ "location": "2dsphere" });
db.request_logs.createIndex({ createdAt: 1 }, { expireAfterSeconds: 2592000 });
```

### Seed Initial Data

```bash
cd back
npx ts-node -r tsconfig-paths/register src/scripts/seed-all.sh
```

## Mobile App Deployment

### Expo Build

```bash
cd front

# Build for iOS
eas build --platform ios

# Build for Android
eas build --platform android

# Submit to stores
eas submit --platform ios
eas submit --platform android
```

### Web Deployment

```bash
cd front
npx expo export --platform web
# Deploy dist/ to any static hosting (Vercel, Netlify, S3)
```

## Monitoring

### Health Check

```bash
curl https://api.yourdomain.com/health
```

### Logs

Request logs are stored in MongoDB with 30-day TTL. Access via admin API:

```bash
curl -H "Authorization: Bearer <admin-token>" \
  https://api.yourdomain.com/admin/logs?limit=100
```

## Security Checklist

- [ ] Strong JWT secrets (64+ hex characters)
- [ ] CORS configured for specific origins
- [ ] Rate limiting enabled
- [ ] HTTPS only
- [ ] MongoDB authentication enabled
- [ ] Environment variables not committed
- [ ] Regular dependency audits (`npm audit`)
- [ ] Helmet CSP headers configured
