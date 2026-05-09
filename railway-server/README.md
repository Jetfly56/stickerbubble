# StickerBubble Railway server

Node + Express + Postgres. The Mac app (**StickerBubble**) polls `GET /api/messages/inbox` while running and includes **Account & sync…** for server URL, device ID, contacts, and inbox triage — no browser required. The `public/index.html` page is **optional** if you prefer triage in a tab.

## Deploy on Railway

1. Create a **New Project** → **Deploy from GitHub** (or empty repo + push this `railway-server` folder as root or monorepo subpath).
2. Add **PostgreSQL** (New → Database → Postgres). Railway injects `DATABASE_URL` into the service.
3. Set the **root directory** to `railway-server` if your repo contains the whole StickerBubble project.
4. **Start command**: `npm start` (default).
5. After deploy, copy the **public URL** into StickerBubble → **Account & sync…**. You can still open `/` in a browser if you want the web UI.

### Environment

| Variable         | Required | Notes                          |
|-----------------|----------|--------------------------------|
| `DATABASE_URL`  | Yes      | Provided by Railway Postgres   |
| `PORT`          | No       | Railway sets automatically     |

## API (used by Mac app and web UI)

- `GET /api/contacts?device_id=` — list contacts for this device.
- `POST /api/contacts` — body `{ owner_device_id, peer_device_id, display_name }`.
- `DELETE /api/contacts/:id?device_id=` — remove if owned by device.
- `POST /api/messages` — body `{ sender_device_id, recipient_device_id, sticker_url?, body?, media_base64?, media_content_type? }`.
- `GET /api/messages/inbox?device_id=&after_id=` — poll new rows where `recipient_device_id` matches.

## Local run

```bash
cd railway-server
npm install
export DATABASE_URL="postgres://user:pass@localhost:5432/stickerbubble"
npm start
```

Open `http://localhost:3000`.
