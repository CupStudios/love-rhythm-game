const path = require('path');
const fs = require('fs');
const Fastify = require('fastify');
const sqlite3 = require('sqlite3').verbose();

const util = require('util');
const {
    pipeline
} = require('stream');
const pump = util.promisify(pipeline);
const multipart = require('@fastify/multipart');
const fastifyStatic = require('@fastify/static');

const app = Fastify({
    logger: true
});
const PORT = 8080;
const HOST = '0.0.0.0';

app.register(multipart, {
  limits: {
    fileSize: 50 * 1024 * 1024 // 50 MB
  }
});

app.register(fastifyStatic, {
    root: path.join(__dirname, 'public'),
    prefix: '/', // Esto permite que busques directamente http://ip:puerto/upload.html
});

const exportToJSON = () => {
    db.all('SELECT title, artist, bpm, filename, size FROM songs ORDER BY created_at DESC', [], (err, rows) => {
        if (!err) {
            // Guarda el archivo songs.json en la carpeta 'public' para que sea accesible por el navegador/juego
            const jsonPath = path.join(__dirname, 'public', 'songs.json');
            fs.writeFileSync(jsonPath, JSON.stringify(rows, null, 2));
        }
    });
};

const dbPath = path.join(__dirname, 'songs.db');
const songsDir = path.join(__dirname, 'songs');

if (!fs.existsSync(songsDir)) {
    fs.mkdirSync(songsDir, {
        recursive: true
    });
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
    exportToJSON();
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
    const {
        filename
    } = request.params;
    const safeName = path.basename(filename);
    const filePath = path.join(songsDir, safeName);

    if (!fs.existsSync(filePath)) {
        return reply.code(404).send({
            error: 'Archivo no encontrado'
        });
    }

    reply.header('Content-Type', 'application/octet-stream');
    reply.header('Content-Disposition', `attachment; filename="${safeName}"`);
    return reply.send(fs.createReadStream(filePath));
});

const start = async () => {
    try {
        await app.listen({
            port: PORT,
            host: HOST
        });
        app.log.info(`Servidor activo en http://${HOST}:${PORT}`);
    } catch (err) {
        app.log.error(err);
        process.exit(1);
    }
};

app.post('/api/upload', async (request, reply) => {
    const data = await request.file();

    if (!data) {
        return reply.code(400).send({
            error: 'No se envió ningún archivo'
        });
    }

    // Extraer metadatos (si no se envían, se asignan valores por defecto)
    const title = data.fields.title ? data.fields.title.value : 'Sin título';
    const artist = data.fields.artist ? data.fields.artist.value : 'Desconocido';
    const bpm = data.fields.bpm ? parseInt(data.fields.bpm.value, 10) : 0;

    const safeName = path.basename(data.filename);
    const filePath = path.join(songsDir, safeName);

    try {
        // 1. Guardar el archivo físicamente en la carpeta 'songs'
        await pump(data.file, fs.createWriteStream(filePath));

        // 2. Obtener el peso del archivo recién creado
        const size = fs.statSync(filePath).size;

        // 3. Registrar en la base de datos SQLite
        return await new Promise((resolve, reject) => {
            db.run(
                'INSERT INTO songs (filename, title, artist, bpm, size) VALUES (?, ?, ?, ?, ?)',
                [safeName, title, artist, bpm, size],
                function(err) {
                    if (err) {
                        // Si el filename ya existe (por la restricción UNIQUE)
                        if (err.message.includes('UNIQUE')) {
                            resolve(reply.code(409).send({
                                error: 'Una canción con este nombre de archivo ya existe.'
                            }));
                        } else {
                            resolve(reply.code(500).send({
                                error: 'Error al registrar en la base de datos.'
                            }));
                        }
                    } else {
                        resolve(reply.send({
                            success: true,
                            message: 'Canción subida y registrada correctamente',
                            song: {
                                id: this.lastID,
                                filename: safeName,
                                title,
                                artist,
                                bpm,
                                size
                            }
                        }));
                    }
                }
            );
        });
    } catch (err) {
        app.log.error(err);
        return reply.code(500).send({
            error: 'Error al procesar el archivo'
        });
    }
});

start();
