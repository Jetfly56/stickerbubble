/**
 * StickerBubble API — deploy on Railway with Postgres plugin (DATABASE_URL).
 * Serves REST + static / for managing contacts; Mac app polls /api/messages/inbox.
 */
const express = require("express");
const cors = require("cors");
const path = require("path");
const { Pool } = require("pg");

const app = express();
const PORT = Number(process.env.PORT) || 3000;

app.use(cors());
app.use(express.json({ limit: "12mb" }));
app.use(express.static(path.join(__dirname, "..", "public")));

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_URL?.includes("localhost") ? false : { rejectUnauthorized: false },
});

async function initDb() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS contacts (
      id SERIAL PRIMARY KEY,
      owner_device_id TEXT NOT NULL,
      peer_device_id TEXT NOT NULL,
      display_name TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE (owner_device_id, peer_device_id)
    );
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS messages (
      id BIGSERIAL PRIMARY KEY,
      sender_device_id TEXT NOT NULL,
      recipient_device_id TEXT NOT NULL,
      sticker_url TEXT,
      body TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await pool.query(
    `ALTER TABLE messages ADD COLUMN IF NOT EXISTS sender_display_name TEXT`
  );
  await pool.query(`CREATE INDEX IF NOT EXISTS idx_messages_recipient ON messages (recipient_device_id, id);`);
}

/** Contacts for a device (owner = device). */
app.get("/api/contacts", async (req, res) => {
  const deviceId = req.query.device_id;
  if (!deviceId || typeof deviceId !== "string") {
    return res.status(400).json({ error: "device_id query required" });
  }
  try {
    const { rows } = await pool.query(
      `SELECT id, peer_device_id, display_name, created_at FROM contacts WHERE owner_device_id = $1 ORDER BY display_name ASC`,
      [deviceId.trim()]
    );
    res.json({ contacts: rows });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

app.post("/api/contacts", async (req, res) => {
  const { owner_device_id, peer_device_id, display_name } = req.body || {};
  if (!owner_device_id || !peer_device_id) {
    return res.status(400).json({ error: "owner_device_id and peer_device_id required" });
  }
  const name = (display_name || "").toString().trim() || "Contact";
  try {
    const { rows } = await pool.query(
      `INSERT INTO contacts (owner_device_id, peer_device_id, display_name)
       VALUES ($1, $2, $3)
       ON CONFLICT (owner_device_id, peer_device_id) DO UPDATE SET display_name = EXCLUDED.display_name
       RETURNING id, peer_device_id, display_name, created_at`,
      [owner_device_id.trim(), peer_device_id.trim(), name]
    );
    res.status(201).json({ contact: rows[0] });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

app.delete("/api/contacts/:id", async (req, res) => {
  const id = Number(req.params.id);
  const deviceId = req.query.device_id;
  if (!Number.isFinite(id) || !deviceId) {
    return res.status(400).json({ error: "invalid id or device_id" });
  }
  try {
    const r = await pool.query(`DELETE FROM contacts WHERE id = $1 AND owner_device_id = $2 RETURNING id`, [id, String(deviceId).trim()]);
    if (r.rowCount === 0) return res.status(404).json({ error: "not_found" });
    res.json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

/** Send a sticker (URL), plain text, or tiny base64 image. */
app.post("/api/messages", async (req, res) => {
  const {
    sender_device_id,
    recipient_device_id,
    sticker_url,
    body,
    media_base64,
    media_content_type,
    sender_display_name,
  } = req.body || {};
  if (!sender_device_id || !recipient_device_id) {
    return res.status(400).json({ error: "sender_device_id and recipient_device_id required" });
  }
  const senderLabel =
    sender_display_name != null && String(sender_display_name).trim() !== ""
      ? String(sender_display_name).trim().slice(0, 120)
      : null;
  let url = sticker_url ? String(sticker_url).trim() : null;
  const textBody = body != null && String(body).trim() !== "" ? String(body) : null;

  if (media_base64 && typeof media_base64 === "string" && media_base64.length > 0) {
    try {
      const buf = Buffer.from(media_base64, "base64");
      if (buf.length > 8 * 1024 * 1024) {
        return res.status(400).json({ error: "media_too_large_max_8mb" });
      }
      const ct = (media_content_type || "application/octet-stream").toString().slice(0, 120);
      const { rows } = await pool.query(
        `INSERT INTO messages (sender_device_id, recipient_device_id, sticker_url, body, sender_display_name)
         VALUES ($1, $2, $3, $4, $5) RETURNING id, created_at`,
        [
          String(sender_device_id).trim(),
          String(recipient_device_id).trim(),
          `data:${ct};base64,${buf.toString("base64")}`,
          textBody,
          senderLabel,
        ]
      );
      return res.status(201).json({ message: rows[0] });
    } catch (e) {
      console.error(e);
      return res.status(500).json({ error: "db_error" });
    }
  }

  if (!url && !textBody) {
    return res.status(400).json({ error: "sticker_url, body, or media_base64 required" });
  }

  try {
    const { rows } = await pool.query(
      `INSERT INTO messages (sender_device_id, recipient_device_id, sticker_url, body, sender_display_name)
       VALUES ($1, $2, $3, $4, $5) RETURNING id, created_at`,
      [String(sender_device_id).trim(), String(recipient_device_id).trim(), url, textBody, senderLabel]
    );
    res.status(201).json({ message: rows[0] });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

/** Poll inbox for a device (recipient = this device). */
app.get("/api/messages/inbox", async (req, res) => {
  const deviceId = req.query.device_id;
  const afterId = req.query.after_id != null ? Number(req.query.after_id) : 0;
  if (!deviceId) return res.status(400).json({ error: "device_id required" });
  if (!Number.isFinite(afterId) || afterId < 0) {
    return res.status(400).json({ error: "after_id must be a non-negative number" });
  }
  try {
    const { rows } = await pool.query(
      `SELECT id, sender_device_id, recipient_device_id, sticker_url, body, sender_display_name, created_at
       FROM messages WHERE recipient_device_id = $1 AND id > $2 ORDER BY id ASC LIMIT 100`,
      [String(deviceId).trim(), afterId]
    );
    res.json({ messages: rows });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

app.get("/health", (_req, res) => {
  res.json({ ok: true });
});

async function main() {
  if (!process.env.DATABASE_URL || !String(process.env.DATABASE_URL).trim()) {
    console.error(
      "DATABASE_URL is not set. On Railway: add a Postgres service to this project, then on THIS service open Variables → New variable → Variable reference → choose Postgres → DATABASE_URL. Redeploy."
    );
    process.exit(1);
  }
  await initDb();
  app.listen(PORT, () => console.log(`StickerBubble server listening on ${PORT}`));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
