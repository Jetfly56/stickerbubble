# StickerBubble Railway server

Node + Express + Postgres. The Mac app (**StickerBubble**) polls `GET /api/messages/inbox` while running and includes **Account & sync…** for server URL, device ID, contacts, and inbox triage — no browser required. The `public/index.html` page is **optional** if you prefer triage in a tab.

## Deploy on Railway

1. Create a **New Project** → **Deploy from GitHub** (or empty repo + push this `railway-server` folder as root or monorepo subpath).
2. Add **PostgreSQL** to the **same project** (New → Database → Postgres).
3. **Wire `DATABASE_URL` into the Node service** (this step is easy to miss — without it the app tries `localhost:5432` and crashes):
   - Open your **API / web** service (the one running `node src/index.js`), not only the Postgres card.
   - **Variables** → **+ New Variable** → **Variable Reference** (or “Reference” depending on UI).
   - Select the **Postgres** service → variable **`DATABASE_URL`** → add.
   - Redeploy (or wait for auto-deploy). You should **not** see `ECONNREFUSED 127.0.0.1:5432` once this is set.
4. Set the **root directory** to `railway-server` if your repo contains the whole StickerBubble project.
5. **Start command**: `npm start` (default).
6. After deploy, copy the **public URL** into StickerBubble → **Account & sync…**. You can still open `/` in a browser if you want the web UI.

### Environment

| Variable         | Required | Notes                          |
|-----------------|----------|--------------------------------|
| `DATABASE_URL`  | Yes      | Provided by Railway Postgres   |
| `PORT`          | No       | Railway sets automatically     |

## API (used by Mac app and web UI)

- `GET /api/contacts?device_id=` — list contacts for this device.
- `POST /api/contacts` — body `{ owner_device_id, peer_device_id, display_name }`.
- `DELETE /api/contacts/:id?device_id=` — remove if owned by device.
- `POST /api/messages` — body `{ sender_device_id, recipient_device_id, sticker_url?, body?, media_base64?, media_content_type?, sender_display_name? }` (optional short name shown to the recipient).
- `GET /api/messages/inbox?device_id=&after_id=` — poll new rows where `recipient_device_id` matches (includes `sender_display_name` when present).

## Local run

```bash
cd railway-server
npm install
export DATABASE_URL="postgres://user:pass@localhost:5432/stickerbubble"
npm start
```

Open `http://localhost:3000`.
