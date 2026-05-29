const path = require('path');
const fs = require('fs');
const Fastify = require('fastify');
const sqlite3 = require('sqlite3').verbose();

const util = require('util');
const { pipeline } = require('stream');
const pump = util.promisify(pipeline);
const multipart = require('@fastify/multipart');
const fastifyStatic = require('@fastify/static');

const app = Fastify({ logger: true });
const PORT = 8080;
const HOST = '0.0.0.0';

// ✅ CORRECCIÓN: Límite expandido a 50MB para soportar archivos .lrg pesados sin corromperlos
app.register(multipart, {
    limits: {
        fileSize: 50 * 1024 * 1024
    }
});

app.register(fastifyStatic, {
    root: path.join(__dirname, 'public'),
    prefix: '/',
});

const dbPath = path.join(__dirname, 'songs.db');
const songsDir = path.join(__dirname, 'songs');

if (!fs.existsSync(songsDir)) {
    fs.mkdirSync(songsDir, { recursive: true });
}

const db = new sqlite3.Database(dbPath);

const exportToJSON = () => {
    db.all('SELECT title, artist, bpm, filename, size FROM songs ORDER BY created_at DESC', [], (err, rows) => {
        if (!err) {
            const jsonPath = path.join(__dirname, 'public', 'songs.json');
            fs.writeFileSync(jsonPath, JSON.stringify(rows, null, 2));
            app.log.info("¡Archivo songs.json actualizado con éxito!");
        } else {
            app.log.error("Error al exportar a JSON: ", err);
        }
    });
};

// ✅ CORRECCIÓN: exportToJSON se ejecuta estrictamente DESPUÉS de que db.run termine
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
  `, (err) => {
        if (!err) {
            exportToJSON();
        }
    });
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

    // Enviar tamaño exacto para ayudar a la estabilidad de la descarga en Lua
    const stat = fs.statSync(filePath);
    reply.header('Content-Length', stat.size);

    reply.header('Content-Type', 'application/octet-stream');
    reply.header('Content-Disposition', `attachment; filename="${safeName}"`);
    return reply.send(fs.createReadStream(filePath));
});

app.post('/api/upload', async (request, reply) => {
    const data = await request.file();

    if (!data) {
        return reply.code(400).send({ error: 'No se envió ningún archivo' });
    }

    const title = data.fields.title ? data.fields.title.value : 'Sin título';
    const artist = data.fields.artist ? data.fields.artist.value : 'Desconocido';
    const bpm = data.fields.bpm ? parseInt(data.fields.bpm.value, 10) : 0;

    const safeName = path.basename(data.filename);
    const filePath = path.join(songsDir, safeName);

    try {
        await pump(data.file, fs.createWriteStream(filePath));
        const size = fs.statSync(filePath).size;

        return await new Promise((resolve, reject) => {
            db.run(
                'INSERT INTO songs (filename, title, artist, bpm, size) VALUES (?, ?, ?, ?, ?)',
                [safeName, title, artist, bpm, size],
                function(err) {
                    if (err) {
                        if (err.message.includes('UNIQUE')) {
                            resolve(reply.code(409).send({ error: 'Una canción con este nombre de archivo ya existe.' }));
                        } else {
                            resolve(reply.code(500).send({ error: 'Error al registrar en la base de datos.' }));
                        }
                    } else {
                        // ✅ CORRECCIÓN CLAVE: Regenerar el JSON inmediatamente tras el éxito del INSERT
                        exportToJSON();

                        resolve(reply.send({
                            success: true,
                            message: 'Canción subida y registrada correctamente',
                            song: { id: this.lastID, filename: safeName, title, artist, bpm, size }
                        }));
                    }
                }
            );
        });
    } catch (err) {
        app.log.error(err);
        return reply.code(500).send({ error: 'Error al procesar el archivo' });
    }
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
