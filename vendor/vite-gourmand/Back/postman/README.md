# Postman Collections

This directory contains Postman collections for testing the Vite Gourmand API independently from the frontend.

## 🔄 Workflow: Design in UI, Run via CLI

```
┌─────────────────────────────────────────────────────────────────────┐
│                     POSTMAN WORKFLOW (Official CLI)                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   POSTMAN UI (Design/Debug)                                         │
│   ─────────────────────────                                         │
│   • Create/edit tests visually                                      │
│   • Debug with console output                                        │
│   • Changes sync automatically to Cloud                             │
│            │                                                         │
│            ▼                                                         │
│   ┌────────────────────────────────────────────────────────┐       │
│   │              POSTMAN CLOUD (Auto-Sync)                  │       │
│   │   Collections, Environments, Test Results               │       │
│   └───────────────────────┬────────────────────────────────┘       │
│                           │                                          │
│                           ▼                                          │
│   ┌────────────────────────────────────────────────────────┐       │
│   │              POSTMAN CLI (Official)                     │       │
│   │   postman collection run <collection-id>                │       │
│   └───────────────────────┬────────────────────────────────┘       │
│                           │                                          │
│                           ▼                                          │
│   ┌────────────────────────────────────────────────────────┐       │
│   │   CI/CD Pipeline (GitHub Actions, GitLab CI, etc.)     │       │
│   │   Results pushed back to Postman Cloud!                 │       │
│   └────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────┘
```

## 📁 Local Collections (Backup/Reference)

| File              | Description                                                  |
| ----------------- | ------------------------------------------------------------ |
| `auth.json`       | Authentication endpoints (register, login, refresh, profile) |
| `orders.json`     | Order lifecycle management (create, status updates, queries) |
| `admin.json`      | Admin operations (user management, review moderation, stats) |
| `env.docker.json` | Environment variables for local/Docker runs                  |

---

## 🚀 Quick Start with Postman CLI (Recommended)

### Step 1: Install Postman CLI

```bash
# Using our script
./scripts/postman-cli.sh install

# Or manually (Linux)
curl -o- "https://dl-cli.pstmn.io/install/linux64.sh" | sh

# Verify
postman --version
```

### Step 2: Login to Postman

```bash
./scripts/postman-cli.sh login
# Opens browser for authentication
```

### Step 3: Create/Edit Tests in Postman UI

1. Open [Postman App](https://www.postman.com/downloads/) or [Web](https://go.postman.co)
2. Create a new Collection or import from `backend/postman/*.json`
3. Add requests and tests visually
4. **Changes sync automatically!**

### Step 4: Get Collection ID

1. Open your collection in Postman
2. Click **Info** tab (ℹ️ icon)
3. Copy the **Collection ID** (UUID format)

### Step 5: Run from CLI

```bash
# Run collection (results sync to Postman Cloud!)
./scripts/postman-cli.sh run YOUR_COLLECTION_ID

# Or directly with postman command
postman collection run YOUR_COLLECTION_ID

# With environment
postman collection run YOUR_COLLECTION_ID -e YOUR_ENV_ID

# Run local file (for offline/backup)
./scripts/postman-cli.sh run-local backend/postman/auth.json
```

---

## 🛠️ Makefile Commands

```bash
make postman-install   # Install Postman CLI
make postman-login     # Login to Postman (browser)
make postman-list      # List your cloud collections
make postman-run ID=x  # Run collection by ID
make postman-local     # Run local auth.json file
```

---

## ☁️ CI/CD Integration (GitHub Actions)

```yaml
# .github/workflows/api-tests.yml
name: API Tests

on: [push, pull_request]

jobs:
  postman-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Postman CLI
        run: curl -o- "https://dl-cli.pstmn.io/install/linux64.sh" | sh

      - name: Login with API Key
        run: postman login --with-api-key ${{ secrets.POSTMAN_API_KEY }}

      - name: Start API
        run: |
          docker compose up -d
          sleep 15

      - name: Run Collection
        run: |
          postman collection run ${{ secrets.POSTMAN_COLLECTION_ID }} \
            --global-var "baseUrl=http://localhost:3000/api"

      # Results automatically sync to Postman Cloud!
```

### Setting Up CI/CD

1. **Get API Key**: [Postman Settings → API Keys](https://go.postman.co/settings/me/api-keys)
2. **Add to GitHub Secrets**:
   - `POSTMAN_API_KEY`: Your API key
   - `POSTMAN_COLLECTION_ID`: Collection UUID
3. **Push and watch results in Postman Cloud!**

---

## 🔑 Test Credentials

After running `npm run seed` or `npm run seed:test`:

| Role    | Email                   | Password    |
| ------- | ----------------------- | ----------- |
| Admin   | admin@vitegourmand.fr   | Admin123!   |
| Manager | manager@vitegourmand.fr | Manager123! |
| Client  | alice.dupont@email.fr   | Client123!  |

---

## 📊 View Results in Postman

After running via CLI:

1. Open Postman
2. Go to **History** or **Runs** tab
3. See all test results with timing, assertions, and failures
4. Share reports with team!

---

## 🆚 Postman CLI vs Newman

| Feature          | Postman CLI (New) | Newman (Legacy) |
| ---------------- | ----------------- | --------------- |
| Official Support | ✅ Active         | ⚠️ Maintenance  |
| Cloud Sync       | ✅ Automatic      | ❌ Manual       |
| Results in UI    | ✅ Yes            | ❌ No           |
| Dependencies     | ✅ None           | ⚠️ npm packages |
| Security Updates | ✅ Regular        | ⚠️ Deprecated   |

**Recommendation**: Use Postman CLI for all new projects!
