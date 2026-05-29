os.execute("export SDL_AUDIODRIVER=alsa")

local json = require "json"

-- ============================================================
--  Editor state
--  CAMBIOS: se añade `offset` (nuevo campo obligatorio del
--  manifest, leído en main.lua como currentSongInfo.offset).
-- ============================================================
local editor = {
    state        = "menu",
    bpm          = 144,
    offset       = 0,          -- NEW: timing offset en ms (manifest.offset)
    notes        = {},
    scroll       = 0,
    snap         = 0.25,
    spacing      = 40,
    song         = nil,
    songName     = "",
    songData     = nil,
    chartTitle   = "My_Awesome_Chart",
    artist       = "Unknown Artist",
    serverUrl    = "http://localhost:3000",
    keyBindings  = { "d", "f", "j", "k" },
    previousState = "menu",
    statusMessage = "",
    focus        = nil
}

local keys = {}

local CHART_VERSION = "1.0"
local DEFAULT_DIFFICULTY = "hard"
local SETTINGS_FILE = "settings.json"
local DEFAULT_SETTINGS = {
    serverUrl = "http://localhost:3000",
    keyBindings = { "d", "f", "j", "k" }
}
local settings = {
    serverUrl = DEFAULT_SETTINGS.serverUrl,
    keyBindings = { "d", "f", "j", "k" }
}
local settingsFields = {
    { focus = "serverUrl", label = "Server URL:" },
    { focus = "key1", label = "Lane 1 key:" },
    { focus = "key2", label = "Lane 2 key:" },
    { focus = "key3", label = "Lane 3 key:" },
    { focus = "key4", label = "Lane 4 key:" }
}

local function copyDefaultKeyBindings()
    return {
        DEFAULT_SETTINGS.keyBindings[1],
        DEFAULT_SETTINGS.keyBindings[2],
        DEFAULT_SETTINGS.keyBindings[3],
        DEFAULT_SETTINGS.keyBindings[4]
    }
end

local function normalizeKey(value, fallback)
    if type(value) ~= "string" or value == "" then return fallback end
    return value:sub(1, 1):lower()
end

local function rebuildKeyMap()
    keys = {}
    for lane = 1, 4 do
        local key = normalizeKey(settings.keyBindings[lane], DEFAULT_SETTINGS.keyBindings[lane])
        settings.keyBindings[lane] = key
        keys[key] = lane
    end
end

local function applySettings()
    if type(settings.serverUrl) ~= "string" or settings.serverUrl == "" then
        settings.serverUrl = DEFAULT_SETTINGS.serverUrl
    end
    if type(settings.keyBindings) ~= "table" then
        settings.keyBindings = copyDefaultKeyBindings()
    end
    for lane = 1, 4 do
        settings.keyBindings[lane] = normalizeKey(settings.keyBindings[lane], DEFAULT_SETTINGS.keyBindings[lane])
    end

    editor.serverUrl = settings.serverUrl
    editor.keyBindings = settings.keyBindings
    rebuildKeyMap()
end

local function loadSettings()
    settings = {
        serverUrl = DEFAULT_SETTINGS.serverUrl,
        keyBindings = copyDefaultKeyBindings()
    }

    if love.filesystem.getInfo(SETTINGS_FILE) then
        local data = love.filesystem.read(SETTINGS_FILE)
        local ok, decoded = pcall(json.decode, json, data)
        if ok and type(decoded) == "table" then
            if type(decoded.serverUrl) == "string" then
                settings.serverUrl = decoded.serverUrl
            end
            if type(decoded.keyBindings) == "table" then
                for lane = 1, 4 do
                    settings.keyBindings[lane] = decoded.keyBindings[lane] or settings.keyBindings[lane]
                end
            end
        end
    end

    applySettings()
end

local function saveSettings()
    applySettings()
    if love.filesystem.write(SETTINGS_FILE, json:encode(settings)) then
        editor.statusMessage = "Configuración guardada en " .. SETTINGS_FILE
    else
        editor.statusMessage = "Error guardando " .. SETTINGS_FILE
    end
end

local function openSettings()
    editor.previousState = editor.state
    editor.state = "settings"
    editor.focus = nil
end

local function closeSettings()
    editor.state = editor.previousState or "menu"
    editor.focus = nil
end

local function copyNote(note)
    local copied = {}
    if type(note) == "table" then
        for key, value in pairs(note) do
            copied[key] = value
        end
    end
    return copied
end

local function chartPathFromManifest(manifest)
    if type(manifest.difficulties) ~= "table" then return nil end
    return manifest.difficulties[DEFAULT_DIFFICULTY] or manifest.difficulties.hard
end

local function setEditorNote(beat, lane, noteData)
    if type(beat) ~= "number" or type(lane) ~= "number" then return end
    if lane < 1 or lane > 4 then return end

    local note = copyNote(noteData)
    note.beat = beat
    note.dir = lane

    editor.notes[beat] = editor.notes[beat] or {false, false, false, false}
    editor.notes[beat][lane] = note
end

local function toggleEditorNote(beat, lane)
    editor.notes[beat] = editor.notes[beat] or {false, false, false, false}
    if editor.notes[beat][lane] then
        editor.notes[beat][lane] = false
    else
        editor.notes[beat][lane] = { beat = beat, dir = lane }
    end
end

local function buildExportNote(beat, lane, noteData)
    local note = type(noteData) == "table" and copyNote(noteData) or {}
    note.beat = tonumber(note.beat) or beat
    note.dir = tonumber(note.dir) or lane
    return note
end

function love.load()
    love.window.setTitle("LRG Chart Editor")
    love.window.setMode(1000, 700, {resizable = true})
    love.keyboard.setKeyRepeat(true)
    loadSettings()
end

-- ============================================================
--  Text input  — CAMBIO MÍNIMO: añade rama para "offset"
-- ============================================================
function love.textinput(t)
    if editor.state == "settings" then
        if editor.focus == "serverUrl" then
            settings.serverUrl = settings.serverUrl .. t
        elseif editor.focus and editor.focus:match("^key%d$") then
            local lane = tonumber(editor.focus:sub(4, 4))
            if lane then
                settings.keyBindings[lane] = t:sub(1, 1):lower()
            end
        end
    elseif editor.state == "edit" then
        if editor.focus == "title" then
            editor.chartTitle = editor.chartTitle .. t
        elseif editor.focus == "bpm" then
            if tonumber(t) or t == "." then
                local currentStr = tostring(editor.bpm)
                if currentStr == "0" then currentStr = "" end
                editor.bpm = tonumber(currentStr .. t) or editor.bpm
            end
        elseif editor.focus == "artist" then
            editor.artist = editor.artist .. t
        elseif editor.focus == "offset" then          -- NEW
            if tonumber(t) or t == "-" then
                local currentStr = tostring(editor.offset)
                if currentStr == "0" then currentStr = "" end
                editor.offset = tonumber(currentStr .. t) or editor.offset
            end
        end
    end
end

-- ============================================================
--  File drop — TAREA 1 + TAREA 2:
--    · Audio (.ogg / .mp3): comportamiento original intacto.
--    · .lrg:  monta el archivo con love.filesystem.mount,
--             lee manifest.json y chart.json (nuevo formato),
--             y carga todos los campos incluido `offset`.
-- ============================================================
function love.filedropped(file)
    if editor.state ~= "menu" then return end

    local filename = file:getFilename()

    -- ── Cargar un .lrg existente para edición ────────────────
    if filename:match("%.lrg$") then
        loadLRG(file)
        return
    end

    -- ── Cargar audio para crear un chart nuevo ───────────────
    if filename:match("%.ogg$") or filename:match("%.mp3$") then
        if editor.song and editor.song:isPlaying() then
            editor.song:stop()
        end
        editor.song      = love.audio.newSource(file, "stream")
        editor.songName  = filename:match("([^/\\]+)$") or "audio.ogg"
        editor.songData  = file:read("data")
        editor.state     = "edit"
        editor.statusMessage = "Cargado: " .. editor.songName
    end
end

-- ============================================================
--  loadLRG(file)  — TAREA 1 (nuevo)
--  Usa exclusivamente funciones del sistema LRG:
--    love.filesystem.mount / unmount / getDirectoryItems /
--    getInfo / read / write / createDirectory
-- ============================================================
function loadLRG(file)
    local filepath   = file:getFilename()
    local mountPoint = "temp_editor_load"

    if not love.filesystem.mount(filepath, mountPoint) then
        editor.statusMessage = "Error: no se pudo montar el .lrg"
        return
    end

    -- Detecta posible subcarpeta wrapper dentro del ZIP
    local items = love.filesystem.getDirectoryItems(mountPoint)
    local base  = mountPoint .. "/"
    if #items == 1 then
        local info = love.filesystem.getInfo(mountPoint .. "/" .. items[1])
        if info and info.type == "directory" then
            base = mountPoint .. "/" .. items[1] .. "/"
        end
    end

    -- ── Leer manifest.json ────────────────────────────────────
    local manifestData = love.filesystem.read(base .. "manifest.json")
    if not manifestData then
        love.filesystem.unmount(filepath)
        editor.statusMessage = "Error: manifest.json no encontrado"
        return
    end
    local okM, manifest = pcall(json.decode, json, manifestData)
    if not okM or type(manifest) ~= "table" then
        love.filesystem.unmount(filepath)
        editor.statusMessage = "Error: manifest.json inválido"
        return
    end

    -- ── Leer chart (dificultad hard) ─────────────────────────
    local chartFile = chartPathFromManifest(manifest)
    if not chartFile then
        love.filesystem.unmount(filepath)
        editor.statusMessage = "Error: sin dificultad en manifest"
        return
    end
    local chartData = love.filesystem.read(base .. chartFile)
    if not chartData then
        love.filesystem.unmount(filepath)
        editor.statusMessage = "Error: archivo de chart no encontrado"
        return
    end
    local okC, chartDecoded = pcall(json.decode, json, chartData)
    if not okC or type(chartDecoded) ~= "table" then
        love.filesystem.unmount(filepath)
        editor.statusMessage = "Error: JSON del chart inválido"
        return
    end

    -- ── Leer audio antes de desmontar ────────────────────────
    local audioFile    = manifest.audio
    local audioDataRaw = nil
    local songSource   = nil

    if audioFile then
        audioDataRaw = love.filesystem.read(base .. audioFile)
        if audioDataRaw then
            -- Escribe en save dir para poder hacer stream tras unmount
            love.filesystem.write("_editor_tmp_" .. audioFile, audioDataRaw)
        end
    end

    love.filesystem.unmount(filepath)

    -- Carga el audio desde la copia temporal en save dir
    if audioFile and audioDataRaw then
        local okA, src = pcall(love.audio.newSource, "_editor_tmp_" .. audioFile, "stream")
        if okA and src then songSource = src end
    end

    -- Detiene la pista anterior si hay una
    if editor.song and editor.song:isPlaying() then editor.song:stop() end

    -- ── Poblar el estado del editor ──────────────────────────
    editor.chartTitle = manifest.title  or "Untitled"
    editor.artist     = manifest.artist or "Unknown Artist"
    editor.bpm        = tonumber(manifest.bpm) or tonumber(chartDecoded.bpm) or 144
    editor.offset     = tonumber(manifest.offset) or tonumber(chartDecoded.offset) or 0   -- TAREA 2: leer offset
    editor.songName   = audioFile or "audio.ogg"
    editor.song       = songSource
    editor.songData   = audioDataRaw
    editor.notes      = {}
    editor.scroll     = 0

    -- Reconstruir tabla de notas desde el chart preservando propiedades
    -- nuevas del formato (por ejemplo holds) sin alterar el editor visual.
    for _, note in ipairs(chartDecoded.notes or {}) do
        if type(note) == "table" then
            local b = tonumber(note.beat)
            local lane = tonumber(note.dir)
            setEditorNote(b, lane, note)
        end
    end

    editor.state = "edit"
    editor.statusMessage = "Cargado: " .. (manifest.title or filepath)
end

-- ============================================================
--  exportLRG()  — TAREA 1 + TAREA 2
--  TAREA 1: usa love.filesystem.createDirectory / write / getInfo
--           en lugar de llamadas de shell directas para gestión
--           de archivos. El zip final sigue usando os.execute
--           porque LÖVE no tiene API nativa de creación de ZIP
--           (PhysFS solo monta, no crea), con fallback informativo.
--  TAREA 2: el manifest ahora incluye el campo `offset`
--           (obligatorio para compatibilidad con startGame()).
-- ============================================================
function exportLRG()
    if not editor.songData then return end

    local packageBase = editor.chartTitle:gsub("[%s%W]+", "_")
    local packageName = packageBase .. ".lrg"

    -- Crea subcarpeta organizada dentro del save dir
    love.filesystem.createDirectory("exports")
    local outDir = "exports/" .. packageBase
    love.filesystem.createDirectory(outDir)

    -- Escribe el archivo de audio
    love.filesystem.write(outDir .. "/" .. editor.songName, editor.songData)

    -- ── Construye y escribe chart.json ───────────────────────
    local exportChart = { version = CHART_VERSION, bpm = editor.bpm, offset = editor.offset, notes = {} }
    local beats = {}
    for b, _ in pairs(editor.notes) do table.insert(beats, b) end
    table.sort(beats)
    for _, b in ipairs(beats) do
        for lane, active in ipairs(editor.notes[b]) do
            if active then
                table.insert(exportChart.notes, buildExportNote(b, lane, active))
            end
        end
    end
    love.filesystem.write(outDir .. "/chart.json", json:encode(exportChart))

    -- ── Construye y escribe manifest.json (TAREA 2) ──────────
    --    Campos obligatorios nuevos: `offset`
    local manifest = {
        version      = "1.0",
        title        = editor.chartTitle,
        artist       = editor.artist,
        bpm          = editor.bpm,
        offset       = editor.offset,          -- NEW: campo obligatorio
        audio        = editor.songName,
        difficulties = { hard = "chart.json" }
    }
    love.filesystem.write(outDir .. "/manifest.json", json:encode(manifest))

    -- ── Empaqueta en .lrg (ZIP) ──────────────────────────────
    local saveDir  = love.filesystem.getSaveDirectory()
    local srcDir   = saveDir .. "/" .. outDir
    local destFile = saveDir .. "/" .. packageName
    local cmd = string.format(
        'cd "%s" && zip -j "%s" chart.json manifest.json "%s"',
        srcDir, destFile, editor.songName
    )
    local result = os.execute(cmd)

    if result then
        editor.statusMessage = "Exportado: " .. packageName
    else
        -- Fallback: los archivos quedaron en exports/<nombre>/
        editor.statusMessage = "Sin zip. Archivos en: exports/" .. packageBase
    end
end

-- ============================================================
--  Mouse input — CAMBIO MÍNIMO: añade detección del campo
--  "offset" (Y 280-305) manteniendo todo lo demás intacto.
-- ============================================================
function love.mousepressed(x, y, button)
    local sw, sh = love.graphics.getDimensions()
    if button ~= 1 then return end

    if editor.state == "menu" then
        if x > sw / 2 - 100 and x < sw / 2 + 100 and y > sh / 2 + 70 and y < sh / 2 + 115 then
            openSettings()
        end
        return
    end

    if editor.state == "settings" then
        local panelW, panelH = 520, 470
        local panelX, panelY = (sw - panelW) / 2, (sh - panelH) / 2
        editor.focus = nil
        for i, field in ipairs(settingsFields) do
            local fieldY = panelY + 80 + ((i - 1) * 60)
            if x > panelX + 30 and x < panelX + panelW - 30 and y > fieldY + 22 and y < fieldY + 50 then
                editor.focus = field.focus
            end
        end
        if x > panelX + 80 and x < panelX + 240 and y > panelY + panelH - 70 and y < panelY + panelH - 25 then
            saveSettings()
        elseif x > panelX + 280 and x < panelX + 440 and y > panelY + panelH - 70 and y < panelY + panelH - 25 then
            closeSettings()
        end
        return
    end

    if editor.state == "edit" then
        local panelX = sw - 300
        editor.focus = nil

        if x > panelX + 20 and x < sw - 20 then
            if     y > 100 and y < 125 then editor.focus = "title"
            elseif y > 160 and y < 185 then editor.focus = "bpm"
            elseif y > 220 and y < 245 then editor.focus = "artist"
            elseif y > 280 and y < 305 then editor.focus = "offset"  -- NEW
            end
        end

        -- Grid interaction (sin cambios)
        local startX = (sw * 0.35) - 120
        if x >= startX and x <= startX + 240 then
            local lane = math.floor((x - startX) / 60) + 1
            local beat = math.floor(-(y - (sh - 100) + editor.scroll) / editor.spacing) * editor.snap
            if beat >= 0 then
                toggleEditorNote(beat, lane)
            end
        end

        -- Settings button
        if x > panelX + 50 and x < panelX + 250 and y > sh - 140 and y < sh - 95 then
            openSettings()
            return
        end

        -- Export button (sin cambios de posición)
        if x > panelX + 50 and x < panelX + 250 and y > sh - 80 and y < sh - 30 then
            exportLRG()
        end
    end
end

-- ============================================================
--  Key input — CAMBIO MÍNIMO: añade rama de backspace para
--  "offset". Todo lo demás permanece intacto.
-- ============================================================
function love.keypressed(key)
    if editor.state == "settings" then
        if key == "backspace" then
            if editor.focus == "serverUrl" then
                settings.serverUrl = settings.serverUrl:sub(1, -2)
            elseif editor.focus and editor.focus:match("^key%d$") then
                local lane = tonumber(editor.focus:sub(4, 4))
                if lane then settings.keyBindings[lane] = "" end
            end
        elseif key == "return" then
            if editor.focus then
                editor.focus = nil
            else
                saveSettings()
            end
        elseif key == "escape" then
            closeSettings()
        end
        return
    end

    if editor.state ~= "edit" then return end

    if key == "escape" then
        openSettings()
        return
    elseif key == "backspace" then
        if editor.focus == "title" then
            editor.chartTitle = editor.chartTitle:sub(1, -2)
        elseif editor.focus == "bpm" then
            local s = tostring(editor.bpm):sub(1, -2)
            editor.bpm = tonumber(s) or 0
        elseif editor.focus == "artist" then
            editor.artist = editor.artist:sub(1, -2)
        elseif editor.focus == "offset" then              -- NEW
            local s = tostring(editor.offset):sub(1, -2)
            editor.offset = tonumber(s) or 0
        end
    elseif key == "return" then
        editor.focus = nil
    end

    if key == "space" and not editor.focus then
        if editor.song:isPlaying() then editor.song:pause() else editor.song:play() end
    end

    if not editor.focus then
        local lane = keys[key]
        if lane then
            local currentBeat = editor.song:isPlaying()
                and (editor.song:tell() * (editor.bpm / 60))
                or  (editor.scroll / (editor.spacing / editor.snap))
            local snappedBeat = math.floor((currentBeat / editor.snap) + 0.5) * editor.snap
            if snappedBeat >= 0 then
                setEditorNote(snappedBeat, lane, { beat = snappedBeat, dir = lane })
            end
        end
    end
end

-- ============================================================
--  Update — sin cambios
-- ============================================================
function love.update(dt)
    if editor.state == "edit" and editor.song and editor.song:isPlaying() then
        editor.scroll = (editor.song:tell() * (editor.bpm / 60)) * (editor.spacing / editor.snap)
    end
end

-- ============================================================
--  Draw — CAMBIO MÍNIMO: añade campo "Offset (ms)" en el panel
--  después de "Artist". Toda la lógica de grid, notas y botón
--  de exportación permanece exactamente igual.
-- ============================================================
function love.draw()
    local sw, sh = love.graphics.getDimensions()
    if editor.state == "menu" then
        love.graphics.clear(0.1, 0.1, 0.15)
        love.graphics.printf("Arrastra un .ogg/.mp3 para crear\no un .lrg para editar", 0, sh/2 - 20, sw, "center")
        love.graphics.setColor(0.2, 0.4, 0.7)
        love.graphics.rectangle("fill", sw / 2 - 100, sh / 2 + 70, 200, 45, 5)
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("Configuración", sw / 2 - 100, sh / 2 + 84, 200, "center")
        return
    elseif editor.state == "settings" then
        love.graphics.clear(0.08, 0.08, 0.12)
        local panelW, panelH = 520, 470
        local panelX, panelY = (sw - panelW) / 2, (sh - panelH) / 2

        love.graphics.setColor(0.12, 0.12, 0.18)
        love.graphics.rectangle("fill", panelX, panelY, panelW, panelH, 8)
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("CONFIGURACIÓN", panelX, panelY + 25, panelW, "center")

        for i, field in ipairs(settingsFields) do
            local fieldY = panelY + 80 + ((i - 1) * 60)
            local value = settings.serverUrl
            if field.focus ~= "serverUrl" then
                value = settings.keyBindings[i - 1] or ""
            end

            love.graphics.setColor(0.7, 0.7, 1)
            love.graphics.print(field.label, panelX + 30, fieldY)
            love.graphics.setColor(editor.focus == field.focus and {1, 1, 1} or {0.5, 0.5, 0.5})
            love.graphics.rectangle("line", panelX + 30, fieldY + 22, panelW - 60, 28)
            love.graphics.setColor(1, 1, 1)
            love.graphics.print(value .. (editor.focus == field.focus and "|" or ""), panelX + 36, fieldY + 28)
        end

        if editor.statusMessage ~= "" then
            love.graphics.setColor(0.4, 1, 0.4)
            love.graphics.printf(editor.statusMessage, panelX + 30, panelY + panelH - 105, panelW - 60, "center")
        end

        love.graphics.setColor(0.2, 0.6, 0.2)
        love.graphics.rectangle("fill", panelX + 80, panelY + panelH - 70, 160, 45, 5)
        love.graphics.setColor(0.5, 0.2, 0.2)
        love.graphics.rectangle("fill", panelX + 280, panelY + panelH - 70, 160, 45, 5)
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("Guardar", panelX + 80, panelY + panelH - 56, 160, "center")
        love.graphics.printf("Volver", panelX + 280, panelY + panelH - 56, 160, "center")
        return
    end

    love.graphics.clear(0.05, 0.05, 0.05)
    local startX, bottomY = (sw * 0.35) - 120, sh - 100

    -- Grid (sin cambios)
    for i = math.max(0, math.floor((bottomY + editor.scroll - sh) / editor.spacing)),
             math.ceil((bottomY + editor.scroll) / editor.spacing) do
        local y = bottomY - (i * editor.spacing) + editor.scroll
        love.graphics.setColor(0.3, 0.3, 0.3)
        love.graphics.line(startX, y, startX + 240, y)
    end
    for beat, lanes in pairs(editor.notes) do
        local y = bottomY - (beat / editor.snap * editor.spacing) + editor.scroll
        for lane, active in ipairs(lanes) do
            if active then
                love.graphics.setColor(1, 0.4, 0.4)
                love.graphics.circle("fill", startX + (lane-1)*60 + 30, y, 20)
            end
        end
    end
    love.graphics.setColor(1, 1, 0)
    love.graphics.line(startX - 20, bottomY, startX + 260, bottomY)

    -- Right Info Panel (sin cambios estructurales)
    local panelX = sw - 300
    love.graphics.setColor(0.1, 0.1, 0.15)
    love.graphics.rectangle("fill", panelX, 0, 300, sh)

    love.graphics.setColor(1, 1, 1)
    love.graphics.print("CHART DETAILS", panelX + 20, 30)

    -- Campo: Title
    love.graphics.setColor(0.7, 0.7, 1)
    love.graphics.print("Chart Title:", panelX + 20, 80)
    love.graphics.setColor(editor.focus == "title" and {1,1,1} or {0.5,0.5,0.5})
    love.graphics.rectangle("line", panelX + 20, 100, 260, 25)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(editor.chartTitle .. (editor.focus == "title" and "|" or ""), panelX + 25, 105)

    -- Campo: BPM
    love.graphics.setColor(0.7, 0.7, 1)
    love.graphics.print("BPM:", panelX + 20, 140)
    love.graphics.setColor(editor.focus == "bpm" and {1,1,1} or {0.5,0.5,0.5})
    love.graphics.rectangle("line", panelX + 20, 160, 260, 25)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(tostring(editor.bpm) .. (editor.focus == "bpm" and "|" or ""), panelX + 25, 165)

    -- Campo: Artist
    love.graphics.setColor(0.7, 0.7, 1)
    love.graphics.print("Artist:", panelX + 20, 200)
    love.graphics.setColor(editor.focus == "artist" and {1,1,1} or {0.5,0.5,0.5})
    love.graphics.rectangle("line", panelX + 20, 220, 260, 25)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(editor.artist .. (editor.focus == "artist" and "|" or ""), panelX + 25, 225)

    -- Campo: Offset (ms) — NUEVO, necesario para manifest.offset
    love.graphics.setColor(0.7, 0.7, 1)
    love.graphics.print("Offset (ms):", panelX + 20, 260)
    love.graphics.setColor(editor.focus == "offset" and {1,1,1} or {0.5,0.5,0.5})
    love.graphics.rectangle("line", panelX + 20, 280, 260, 25)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(tostring(editor.offset) .. (editor.focus == "offset" and "|" or ""), panelX + 25, 285)

    -- UI anclada al fondo
    if editor.statusMessage ~= "" then
        love.graphics.setColor(0.4, 1, 0.4)
        love.graphics.printf(editor.statusMessage, panelX + 20, sh - 190, 260, "center")
    end

    love.graphics.setColor(0.2, 0.4, 0.7)
    love.graphics.rectangle("fill", panelX + 50, sh - 140, 200, 45, 5)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("Configuración", panelX + 50, sh - 127, 200, "center")

    love.graphics.setColor(0.2, 0.6, 0.2)
    love.graphics.rectangle("fill", panelX + 50, sh - 80, 200, 50, 5)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("Export to .lrg", panelX + 50, sh - 65, 200, "center")
end
