Automations in a project like building webpages save time, reduce errors and streamline development.
1. Project setup automation
- `create-react-app` for frontend, `express-generator` for Nodes.js backend, or `django-admin startproject` for Django
- Automate environment setup with scripts (e.g., `npm install`, `pip install -r requirements.txt`)

2. Code Formatting & Linting
- Automate code style checks using tools like ESLint (Javascript), Black (python) or Prettier.
- Set up pre-commit hooks with Husky or lint-staged to run checks before code is comitted

3. Testing Automation
- Write unit and integratino tests (Jest, Mocha, Pytest, etc).
- Automate test runs with CI tools (Github Actios, GitLab CI, etc.)

4. Build & Deployment Automation
- Automate builds (Webpack, Parcel, etc.)
- Automate deployments using CI/CD pipelines (Github actions, Azure DevOps etc)

5. Database Migrations
- Automate schema changes with migration tools (sequelize for node.js, alembic fro python, Django migrations)

6. Documentatioin Generation
- Automate API docs (Swagger/OpenAPI, Sphinx for python)

## Docker as a solution of automatization

- Standardizes environments: Ensure our app runs the same everywhere (dev, test, prod)
- Automates setup: install dependencies, runs services (like databases), and starts our app with one command
- Works wellw with CI/CD tools support Docker
