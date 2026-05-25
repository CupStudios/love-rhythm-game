const path = require('path');
const fs = require('fs');
const Fastify = require('fastify');
const sqlite3 = require('sqlite3').verbose();

const app = Fastify({ logger: true });
const PORT = 3000;
const HOST = '0.0.0.0';

const dbPath = path.join(__dirname, 'songs.db');
const songsDir = path.join(__dirname, 'songs');

if (!fs.existsSync(songsDir)) {
  fs.mkdirSync(songsDir, { recursive: true });
}

const db = new sqlite3.Database(dbPath);

db.serialize(() => {
  db.run(`
    CREATE TABLE IF NOT EXISTS songs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      filename TEXT UNIQUE NOT NULL,
      title TEXT NOT NULL,
      artist TEXT,
      bpm INTEGER,
      size INTEGER DEFAULT 0,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
});

app.get('/api/songs', async (_request, reply) => {
  const rows = await new Promise((resolve, reject) => {
    db.all(
      'SELECT title, artist, bpm, filename, size FROM songs ORDER BY created_at DESC',
      [],
      (err, result) => (err ? reject(err) : resolve(result || []))
    );
  });

  return reply.send(rows);
});

app.get('/api/download/:filename', async (request, reply) => {
  const { filename } = request.params;
  const safeName = path.basename(filename);
  const filePath = path.join(songsDir, safeName);

  if (!fs.existsSync(filePath)) {
    return reply.code(404).send({ error: 'Archivo no encontrado' });
  }

  reply.header('Content-Type', 'application/octet-stream');
  reply.header('Content-Disposition', `attachment; filename="${safeName}"`);
  return reply.send(fs.createReadStream(filePath));
});

const start = async () => {
  try {
    await app.listen({ port: PORT, host: HOST });
    app.log.info(`Servidor activo en http://${HOST}:${PORT}`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
};

start();
