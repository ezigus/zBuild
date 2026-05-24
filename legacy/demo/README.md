# Shipwright Demo API

A small Express REST API with **intentional bugs** — designed as a test target for the [Shipwright pipeline](../scripts/sw-pipeline.sh).

## Quick Start

```bash
npm install
npm test        # 2 tests will FAIL (that's on purpose)
npm start       # runs on port 3000
```

## API Endpoints

| Method | Path       | Auth | Description       |
| ------ | ---------- | ---- | ----------------- |
| GET    | /health    | No   | Health check      |
| GET    | /users     | Yes  | List all users    |
| GET    | /users/:id | Yes  | Get user by ID    |
| POST   | /users     | Yes  | Create a new user |

Auth: include `Authorization: Bearer <any-token>` header.

## Intentional Bugs

This project ships with known issues so the Shipwright pipeline can discover, fix, and validate them automatically.

### 1. Wrong HTTP status in auth middleware (Bug)

`src/middleware.js` returns **403 Forbidden** instead of **401 Unauthorized** when the `Authorization` header is missing or malformed. Two tests in `app.test.js` fail because of this.

### 2. Missing rate limiting (Feature)

The API has no rate limiting on any endpoint — a good candidate for a feature-request issue.

## Pre-made GitHub Issues

When using this demo with `shipwright pipeline`, consider creating these issues:

1. **"Fix auth middleware returning wrong HTTP status code"** — _bug_
   The auth middleware returns 403 instead of 401 for unauthenticated requests.

2. **"Add email validation to user creation endpoint"** — _enhancement_
   While Joi validates email format, there's no check for duplicate emails.

3. **"Add rate limiting to API endpoints"** — _feature_
   No rate limiting exists; add express-rate-limit to protect the API.

## Running with Shipwright pipeline

```bash
# From the repo root:
shipwright pipeline --dir demo --issue 1 --base main
```

The pipeline will detect the failing tests, apply self-healing fixes, and open a PR.
