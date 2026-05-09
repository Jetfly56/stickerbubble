/**
 * StickerBubble API — accounts (user-id), multi-device tokens, JWT auth.
 * Password reset / recovery only via recovery code generated on a signed-in device.
 */
const express = require("express");
const cors = require("cors");
const path = require("path");
const crypto = require("crypto");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const { Pool } = require("pg");

const app = express();
const PORT = Number(process.env.PORT) || 3000;
const JWT_SECRET = process.env.JWT_SECRET;
const BCRYPT_ROUNDS = 12;
const RECOVERY_TTL_MIN = 20;

if (!JWT_SECRET || String(JWT_SECRET).length < 32) {
  console.error(
    "FATAL: Set JWT_SECRET (min 32 chars), e.g. openssl rand -base64 32 — add in Railway service Variables."
  );
  process.exit(1);
}

app.use(cors());
app.use(express.json({ limit: "12mb" }));
app.use(express.static(path.join(__dirname, "..", "public")));

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_URL?.includes("localhost") ? false : { rejectUnauthorized: false },
});

function normalizeUserId(s) {
  const t = (s || "").trim();
  if (t.length < 2 || t.length > 64) return null;
  if (!/^[a-zA-Z0-9._-]+$/.test(t)) return null;
  return t;
}

function normalizeDeviceToken(s) {
  const t = (s || "").trim();
  if (t.length < 8 || t.length > 128) return null;
  if (!/^[a-zA-Z0-9._-]+$/.test(t)) return null;
  return t;
}

function hashRecoveryCode(code) {
  return crypto.createHash("sha256").update(String(code).trim() + "\0" + JWT_SECRET).digest("hex");
}

function signToken(accountId, userId, deviceToken) {
  return jwt.sign({ aid: accountId, uid: userId, dit: deviceToken }, JWT_SECRET, { expiresIn: "30d" });
}

async function authMiddleware(req, res, next) {
  try {
    const h = req.headers.authorization;
    if (!h || typeof h !== "string" || !h.startsWith("Bearer ")) {
      return res.status(401).json({ error: "auth_required" });
    }
    const raw = h.slice(7).trim();
    let payload;
    try {
      payload = jwt.verify(raw, JWT_SECRET);
    } catch {
      return res.status(401).json({ error: "invalid_token" });
    }
    const aid = payload.aid;
    const dit = payload.dit;
    if (!aid || !dit) return res.status(401).json({ error: "invalid_token" });
    const { rows } = await pool.query(
      `SELECT a.id, a.user_id, a.display_name
       FROM sb_devices d
       JOIN sb_accounts a ON a.id = d.account_id
       WHERE d.account_id = $1 AND d.device_token = $2`,
      [aid, String(dit)]
    );
    if (!rows.length) return res.status(401).json({ error: "device_revoked" });
    req.accountId = rows[0].id;
    req.userId = rows[0].user_id;
    req.displayName = rows[0].display_name;
    req.deviceToken = String(dit);
    next();
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
}

async function initDb() {
  await pool.query(`CREATE EXTENSION IF NOT EXISTS pgcrypto`);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS sb_accounts (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      display_name TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS sb_devices (
      id SERIAL PRIMARY KEY,
      account_id UUID NOT NULL REFERENCES sb_accounts(id) ON DELETE CASCADE,
      device_token TEXT NOT NULL UNIQUE,
      label TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await pool.query(`CREATE INDEX IF NOT EXISTS idx_sb_devices_account ON sb_devices(account_id)`);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS sb_contacts (
      id SERIAL PRIMARY KEY,
      owner_account_id UUID NOT NULL REFERENCES sb_accounts(id) ON DELETE CASCADE,
      peer_user_id TEXT NOT NULL,
      display_name TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE (owner_account_id, peer_user_id)
    );
  `);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS sb_messages (
      id BIGSERIAL PRIMARY KEY,
      sender_account_id UUID NOT NULL REFERENCES sb_accounts(id) ON DELETE CASCADE,
      recipient_account_id UUID NOT NULL REFERENCES sb_accounts(id) ON DELETE CASCADE,
      sender_device_token TEXT,
      sticker_url TEXT,
      body TEXT,
      sender_display_name TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await pool.query(
    `CREATE INDEX IF NOT EXISTS idx_sb_messages_recipient ON sb_messages(recipient_account_id, id)`
  );

  await pool.query(`
    CREATE TABLE IF NOT EXISTS sb_recovery_codes (
      id BIGSERIAL PRIMARY KEY,
      account_id UUID NOT NULL REFERENCES sb_accounts(id) ON DELETE CASCADE,
      code_hash TEXT NOT NULL,
      expires_at TIMESTAMPTZ NOT NULL,
      used_at TIMESTAMPTZ
    );
  `);
}

// --- Auth ---

app.post("/api/auth/register", async (req, res) => {
  const { user_id, password, display_name, device_token, device_label } = req.body || {};
  const uid = normalizeUserId(user_id);
  const dit = normalizeDeviceToken(device_token);
  const pw = (password || "").toString();
  if (!uid || !dit) return res.status(400).json({ error: "invalid_user_id_or_device_token" });
  if (pw.length < 8) return res.status(400).json({ error: "password_min_8_chars" });
  const disp = (display_name || "").toString().trim().slice(0, 120);
  try {
    const hash = await bcrypt.hash(pw, BCRYPT_ROUNDS);
    const { rows } = await pool.query(
      `INSERT INTO sb_accounts (user_id, password_hash, display_name) VALUES ($1, $2, $3) RETURNING id, user_id, display_name`,
      [uid, hash, disp]
    );
    const acc = rows[0];
    await pool.query(
      `INSERT INTO sb_devices (account_id, device_token, label) VALUES ($1, $2, $3)
       ON CONFLICT (device_token) DO UPDATE SET account_id = EXCLUDED.account_id, label = EXCLUDED.label, last_seen_at = NOW()`,
      [acc.id, dit, (device_label || "").toString().trim().slice(0, 80)]
    );
    const token = signToken(acc.id, acc.user_id, dit);
    res.status(201).json({ token, account: { user_id: acc.user_id, display_name: acc.display_name } });
  } catch (e) {
    if (e.code === "23505") return res.status(409).json({ error: "user_id_taken" });
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

app.post("/api/auth/login", async (req, res) => {
  const { user_id, password, device_token, device_label } = req.body || {};
  const uid = normalizeUserId(user_id);
  const dit = normalizeDeviceToken(device_token);
  const pw = (password || "").toString();
  if (!uid || !dit) return res.status(400).json({ error: "invalid_user_id_or_device_token" });
  try {
    const { rows } = await pool.query(`SELECT id, user_id, password_hash, display_name FROM sb_accounts WHERE user_id = $1`, [uid]);
    if (!rows.length) return res.status(401).json({ error: "invalid_credentials" });
    const row = rows[0];
    const ok = await bcrypt.compare(pw, row.password_hash);
    if (!ok) return res.status(401).json({ error: "invalid_credentials" });
    await pool.query(
      `INSERT INTO sb_devices (account_id, device_token, label) VALUES ($1, $2, $3)
       ON CONFLICT (device_token) DO UPDATE SET account_id = EXCLUDED.account_id, label = EXCLUDED.label, last_seen_at = NOW()`,
      [row.id, dit, (device_label || "").toString().trim().slice(0, 80)]
    );
    const token = signToken(row.id, row.user_id, dit);
    res.json({ token, account: { user_id: row.user_id, display_name: row.display_name } });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

app.post("/api/auth/change-password", authMiddleware, async (req, res) => {
  const { old_password, new_password } = req.body || {};
  const oldPw = (old_password || "").toString();
  const newPw = (new_password || "").toString();
  if (newPw.length < 8) return res.status(400).json({ error: "password_min_8_chars" });
  try {
    const { rows } = await pool.query(`SELECT password_hash FROM sb_accounts WHERE id = $1`, [req.accountId]);
    if (!rows.length) return res.status(404).json({ error: "not_found" });
    const ok = await bcrypt.compare(oldPw, rows[0].password_hash);
    if (!ok) return res.status(401).json({ error: "invalid_old_password" });
    const hash = await bcrypt.hash(newPw, BCRYPT_ROUNDS);
    await pool.query(`UPDATE sb_accounts SET password_hash = $1 WHERE id = $2`, [hash, req.accountId]);
    res.json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

/** Only from a signed-in device: returns a one-time code for use on another device (forgot password / new install). */
app.post("/api/auth/recovery-code", authMiddleware, async (req, res) => {
  const code = crypto.randomBytes(9).toString("base64url").slice(0, 14);
  const codeHash = hashRecoveryCode(code);
  const expires = new Date(Date.now() + RECOVERY_TTL_MIN * 60 * 1000);
  try {
    await pool.query(`UPDATE sb_recovery_codes SET used_at = NOW() WHERE account_id = $1 AND used_at IS NULL`, [
      req.accountId,
    ]);
    await pool.query(`INSERT INTO sb_recovery_codes (account_id, code_hash, expires_at) VALUES ($1, $2, $3)`, [
      req.accountId,
      codeHash,
      expires,
    ]);
    res.json({ code, expires_at: expires.toISOString() });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

/** Use recovery code from another signed-in device — not available without the code. */
app.post("/api/auth/recover", async (req, res) => {
  const { user_id, code, new_password, device_token, device_label } = req.body || {};
  const uid = normalizeUserId(user_id);
  const dit = normalizeDeviceToken(device_token);
  const newPw = (new_password || "").toString();
  const rawCode = (code || "").toString().trim();
  if (!uid || !dit || !rawCode) return res.status(400).json({ error: "user_id_code_device_required" });
  if (newPw.length < 8) return res.status(400).json({ error: "password_min_8_chars" });
  const codeHash = hashRecoveryCode(rawCode);
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const acc = await client.query(`SELECT id FROM sb_accounts WHERE user_id = $1 FOR UPDATE`, [uid]);
    if (!acc.rows.length) {
      await client.query("ROLLBACK");
      return res.status(404).json({ error: "unknown_user" });
    }
    const accountId = acc.rows[0].id;
    const rc = await client.query(
      `SELECT id FROM sb_recovery_codes
       WHERE account_id = $1 AND code_hash = $2 AND used_at IS NULL AND expires_at > NOW()
       ORDER BY id DESC LIMIT 1 FOR UPDATE`,
      [accountId, codeHash]
    );
    if (!rc.rows.length) {
      await client.query("ROLLBACK");
      return res.status(400).json({ error: "invalid_or_expired_code" });
    }
    await client.query(`UPDATE sb_recovery_codes SET used_at = NOW() WHERE id = $1`, [rc.rows[0].id]);
    const hash = await bcrypt.hash(newPw, BCRYPT_ROUNDS);
    await client.query(`UPDATE sb_accounts SET password_hash = $1 WHERE id = $2`, [hash, accountId]);
    await client.query(
      `INSERT INTO sb_devices (account_id, device_token, label) VALUES ($1, $2, $3)
       ON CONFLICT (device_token) DO UPDATE SET account_id = EXCLUDED.account_id, label = EXCLUDED.label, last_seen_at = NOW()`,
      [accountId, dit, (device_label || "").toString().trim().slice(0, 80)]
    );
    const { rows: urows } = await client.query(`SELECT user_id, display_name FROM sb_accounts WHERE id = $1`, [accountId]);
    await client.query("COMMIT");
    const token = signToken(accountId, urows[0].user_id, dit);
    res.json({ token, account: { user_id: urows[0].user_id, display_name: urows[0].display_name } });
  } catch (e) {
    await client.query("ROLLBACK").catch(() => {});
    console.error(e);
    res.status(500).json({ error: "db_error" });
  } finally {
    client.release();
  }
});

app.get("/api/me", authMiddleware, async (req, res) => {
  try {
    const { rows: devs } = await pool.query(
      `SELECT device_token, label, created_at, last_seen_at FROM sb_devices WHERE account_id = $1 ORDER BY last_seen_at DESC`,
      [req.accountId]
    );
    res.json({
      user_id: req.userId,
      display_name: req.displayName,
      devices: devs.map((d) => ({
        device_token: d.device_token,
        label: d.label,
        created_at: d.created_at,
        last_seen_at: d.last_seen_at,
      })),
    });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

app.patch("/api/me", authMiddleware, async (req, res) => {
  const { display_name } = req.body || {};
  const disp = (display_name != null ? String(display_name) : "").trim().slice(0, 120);
  try {
    const { rows } = await pool.query(`UPDATE sb_accounts SET display_name = $1 WHERE id = $2 RETURNING user_id, display_name`, [
      disp,
      req.accountId,
    ]);
    res.json({ account: { user_id: rows[0].user_id, display_name: rows[0].display_name } });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

// --- Contacts (by peer user-id) ---

app.get("/api/contacts", authMiddleware, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT id, peer_user_id, display_name, created_at FROM sb_contacts WHERE owner_account_id = $1 ORDER BY display_name ASC`,
      [req.accountId]
    );
    res.json({ contacts: rows });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

app.post("/api/contacts", authMiddleware, async (req, res) => {
  const { peer_user_id, display_name } = req.body || {};
  const peer = normalizeUserId(peer_user_id);
  if (!peer) return res.status(400).json({ error: "invalid_peer_user_id" });
  if (peer === req.userId) return res.status(400).json({ error: "cannot_add_self" });
  const name = (display_name || "").toString().trim().slice(0, 120) || peer;
  try {
    const { rows } = await pool.query(
      `INSERT INTO sb_contacts (owner_account_id, peer_user_id, display_name) VALUES ($1, $2, $3)
       ON CONFLICT (owner_account_id, peer_user_id) DO UPDATE SET display_name = EXCLUDED.display_name
       RETURNING id, peer_user_id, display_name, created_at`,
      [req.accountId, peer, name]
    );
    res.status(201).json({ contact: rows[0] });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

app.delete("/api/contacts/:id", authMiddleware, async (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isFinite(id)) return res.status(400).json({ error: "invalid id" });
  try {
    const r = await pool.query(`DELETE FROM sb_contacts WHERE id = $1 AND owner_account_id = $2 RETURNING id`, [id, req.accountId]);
    if (r.rowCount === 0) return res.status(404).json({ error: "not_found" });
    res.json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

// --- Messages ---

app.post("/api/messages", authMiddleware, async (req, res) => {
  const { recipient_user_id, sticker_url, body, media_base64, media_content_type, sender_display_name } = req.body || {};
  const recipHandle = normalizeUserId(recipient_user_id);
  if (!recipHandle) return res.status(400).json({ error: "invalid_recipient_user_id" });
  if (recipHandle === req.userId) return res.status(400).json({ error: "cannot_message_self" });

  let senderLabel =
    sender_display_name != null && String(sender_display_name).trim() !== ""
      ? String(sender_display_name).trim().slice(0, 120)
      : null;
  if (!senderLabel && req.displayName) {
    const t = String(req.displayName).trim();
    senderLabel = t.length === 0 ? null : t.slice(0, 120);
  }

  let url = sticker_url ? String(sticker_url).trim() : null;
  const textBody = body != null && String(body).trim() !== "" ? String(body) : null;

  try {
    const recip = await pool.query(`SELECT id FROM sb_accounts WHERE user_id = $1`, [recipHandle]);
    if (!recip.rows.length) return res.status(404).json({ error: "recipient_not_registered" });
    const recipientId = recip.rows[0].id;

    if (media_base64 && typeof media_base64 === "string" && media_base64.length > 0) {
      const buf = Buffer.from(media_base64, "base64");
      if (buf.length > 8 * 1024 * 1024) return res.status(400).json({ error: "media_too_large_max_8mb" });
      const ct = (media_content_type || "application/octet-stream").toString().slice(0, 120);
      const { rows } = await pool.query(
        `INSERT INTO sb_messages (sender_account_id, recipient_account_id, sender_device_token, sticker_url, body, sender_display_name)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, created_at`,
        [
          req.accountId,
          recipientId,
          req.deviceToken,
          `data:${ct};base64,${buf.toString("base64")}`,
          textBody,
          senderLabel,
        ]
      );
      return res.status(201).json({ message: rows[0] });
    }

    if (!url && !textBody) return res.status(400).json({ error: "sticker_url_body_or_media_required" });

    const { rows } = await pool.query(
      `INSERT INTO sb_messages (sender_account_id, recipient_account_id, sender_device_token, sticker_url, body, sender_display_name)
       VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, created_at`,
      [req.accountId, recipientId, req.deviceToken, url, textBody, senderLabel]
    );
    res.status(201).json({ message: rows[0] });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "db_error" });
  }
});

app.get("/api/messages/inbox", authMiddleware, async (req, res) => {
  const afterId = req.query.after_id != null ? Number(req.query.after_id) : 0;
  if (!Number.isFinite(afterId) || afterId < 0) return res.status(400).json({ error: "after_id_invalid" });
  try {
    const { rows } = await pool.query(
      `SELECT m.id, sender.user_id AS sender_user_id, m.sticker_url, m.body, m.sender_display_name, m.created_at
       FROM sb_messages m
       JOIN sb_accounts sender ON sender.id = m.sender_account_id
       WHERE m.recipient_account_id = $1 AND m.id > $2
       ORDER BY m.id ASC LIMIT 100`,
      [req.accountId, afterId]
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
      "DATABASE_URL is not set. On Railway: add Postgres and reference DATABASE_URL on this service. Redeploy."
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
