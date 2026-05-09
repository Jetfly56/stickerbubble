# StickerBubble Railway server

Node + Express + Postgres. The Mac app (**StickerBubble**) uses **user IDs** and **passwords**; each install gets a **device token** so one account can sign in on multiple Macs. JWT auth is required for contacts, send, and inbox.

## Deploy on Railway

1. Create a **New Project** → **Deploy from GitHub** (or push this `railway-server` folder).
2. Add **PostgreSQL** to the **same project**.
3. On the **Node** service → **Variables**:
   - Reference **`DATABASE_URL`** from Postgres.
   - Add **`JWT_SECRET`**: at least **32 characters** (e.g. run `openssl rand -base64 32` locally and paste). The server will not start without it.
4. Set **root directory** to `railway-server` if the repo is the monorepo root.
5. **Start command**: `npm start`.
6. Copy the **public URL** into the Mac app → **Account & sync…**.

The bundled `public/index.html` is optional; full sign-in and recovery are in the Mac app.

### Environment

| Variable         | Required | Notes                                      |
|-----------------|----------|--------------------------------------------|
| `DATABASE_URL`  | Yes      | From Railway Postgres                      |
| `JWT_SECRET`      | Yes      | Min 32 chars; signs session tokens         |
| `PORT`          | No       | Set by Railway                             |

## Auth & recovery

- **Register / login** with `user_id` + `password`. Each client sends a stable **`device_token`** (opaque string); the server binds many devices to one account.
- **Forgot password**: there is **no email reset**. A user on a **signed-in** Mac generates a **recovery code** (`POST /api/auth/recovery-code` with Bearer token). On the other Mac, use **`POST /api/auth/recover`** with `user_id`, `code`, `new_password`, and this Mac’s `device_token`.
- **Change password** (signed in): `POST /api/auth/change-password` with old and new password.

## API summary (Bearer `Authorization` except register/login/recover)

| Method | Path | Notes |
|--------|------|--------|
| POST | `/api/auth/register` | `user_id`, `password`, `device_token`, optional `display_name`, `device_label` |
| POST | `/api/auth/login` | `user_id`, `password`, `device_token`, optional `device_label` |
| POST | `/api/auth/change-password` | Bearer; `old_password`, `new_password` |
| POST | `/api/auth/recovery-code` | Bearer; returns `{ code, expires_at }` once |
| POST | `/api/auth/recover` | `user_id`, `code`, `new_password`, `device_token` |
| GET | `/api/me` | Bearer; profile + devices |
| PATCH | `/api/me` | Bearer; `{ display_name }` |
| GET | `/api/contacts` | Bearer |
| POST | `/api/contacts` | Bearer; `{ peer_user_id, display_name }` |
| DELETE | `/api/contacts/:id` | Bearer |
| POST | `/api/messages` | Bearer; `{ recipient_user_id, sticker_url?, body?, media_base64?, media_content_type?, sender_display_name? }` |
| GET | `/api/messages/inbox?after_id=` | Bearer |

## Local run

```bash
cd railway-server
npm install
export DATABASE_URL="postgres://user:pass@localhost:5432/stickerbubble"
export JWT_SECRET="$(openssl rand -base64 32)"
npm start
```

Open `http://localhost:3000`.

### Database note

v2 uses new tables prefixed with `sb_`. Older `contacts` / `messages` tables from v1 are no longer used by the API; you may drop them manually after migrating users.

### If Railway shows **502**

The edge returns 502 when **Node never listens** (crash on boot) or the container is unhealthy. Open **Deploy logs** on the service and look for `FATAL:` or `StickerBubble failed to start:`.

| Log / symptom | Fix |
|----------------|-----|
| `FATAL: Set JWT_SECRET` | Add variable **`JWT_SECRET`** (32+ characters). Trim accidental spaces/newlines if you pasted from a doc. |
| `DATABASE_URL is not set` | Reference Postgres **`DATABASE_URL`** on this same service. |
| Postgres error about `gen_random_uuid` | Upgrade Postgres to **13+** on Railway (older versions lack built-in `gen_random_uuid`). |
| `Cannot find module` | Confirm deploy **root directory** is `railway-server` and `npm install` ran (check build logs). |
