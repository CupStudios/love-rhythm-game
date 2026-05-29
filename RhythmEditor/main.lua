os.execute("export SDL_AUDIODRIVER=alsa")

local json = require "json"

local editor

local LRG_FORMAT_VERSION = "2.0"
local LRG_DIRS = {
    songs = "songs",
    extracted = "extracted_songs",
    editorExports = "lrg_editor_exports"
}

local function pathJoin(...)
    local parts = {...}
    local clean = {}
    for _, part in ipairs(parts) do
        if part and part ~= "" then
            table.insert(clean, tostring(part):gsub("^/+", ""):gsub("/+$", ""))
        end
    end
    return table.concat(clean, "/")
end

local function safeName(value, fallback)
    local cleaned = tostring(value or fallback or "chart"):gsub("%s+", "_"):gsub("[^%w_%-]", "")
    if cleaned == "" then return fallback or "chart" end
    return cleaned
end

local function safeFileName(value, fallback)
    local cleaned = tostring(value or fallback or "file"):gsub("%s+", "_"):gsub("[^%w_%-%.]", "")
    if cleaned == "" then return fallback or "file" end
    return cleaned
end

local function ensureLRGDirectories()
    for _, dir in pairs(LRG_DIRS) do
        love.filesystem.createDirectory(dir)
    end
end

local function decodeJson(data)
    if not data then return nil end
    local ok, decoded = pcall(json.decode, json, data)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

local function readJson(path)
    return decodeJson(love.filesystem.read(path))
end

local function writeJson(path, payload)
    return love.filesystem.write(path, json:encode(payload))
end

local function normalizeNote(note)
    if type(note) ~= "table" then return nil end
    local beat = tonumber(note.beat)
    local dir = tonumber(note.dir or note.lane)
    if not beat or not dir then return nil end

    local duration = tonumber(note.duration or note.holdDuration or note.length or note.holdLength) or 0
    local noteType = note.type or note.kind
    if not noteType then
        noteType = duration > 0 and "hold" or "tap"
    end

    local normalized = {
        beat = beat,
        dir = dir,
        type = noteType,
        duration = duration,
        hold = note.hold == true or noteType == "hold" or duration > 0
    }
    normalized.endBeat = tonumber(note.endBeat) or (duration > 0 and beat + duration or beat)

    return normalized
end

local function setEditorNote(note)
    local normalized = normalizeNote(note)
    if not normalized or normalized.dir < 1 or normalized.dir > 4 then return end
    editor.notes[normalized.beat] = editor.notes[normalized.beat] or {false, false, false, false}
    editor.notes[normalized.beat][normalized.dir] = normalized
end

local function buildExportChart()
    local exportChart = {
        version = LRG_FORMAT_VERSION,
        bpm = editor.bpm,
        offset = editor.offset,
        lanes = 4,
        notes = {}
    }

    local beats = {}
    for b, _ in pairs(editor.notes) do table.insert(beats, b) end
    table.sort(beats)

    for _, b in ipairs(beats) do
        for lane, note in ipairs(editor.notes[b]) do
            if note then
                local normalized = normalizeNote(type(note) == "table" and note or { beat = b, dir = lane })
                if normalized then
                    normalized.beat = b
                    normalized.dir = lane
                    table.insert(exportChart.notes, normalized)
                end
            end
        end
    end

    return exportChart
end

local function loadChart(chartData, manifest)
    if type(chartData) ~= "table" or type(chartData.notes) ~= "table" then
        editor.statusMessage = "Invalid chart data"
        return false
    end

    editor.notes = {}
    editor.bpm = tonumber(chartData.bpm or manifest and manifest.bpm) or editor.bpm
    editor.offset = tonumber(chartData.offset or manifest and manifest.offset) or 0

    for _, note in ipairs(chartData.notes) do
        setEditorNote(note)
    end

    if type(manifest) == "table" then
        editor.chartTitle = manifest.title or editor.chartTitle
        editor.artist = manifest.artist or editor.artist
        editor.songName = manifest.audio or editor.songName
    end

    editor.state = "edit"
    editor.statusMessage = string.format("Loaded chart: %d notes", #chartData.notes)
    return true
end

local function loadChartJson(path)
    local chartData = readJson(path)
    return loadChart(chartData)
end

local function loadChartJsonData(data)
    return loadChart(decodeJson(data))
end

local function loadLRGPackage(path)
    ensureLRGDirectories()

    local packageName = safeName(path:match("([^/\\]+)%.lrg$") or "package", "package")
    local mountPoint = "editor_mount_" .. packageName

    if not love.filesystem.mount(path, mountPoint) then
        editor.statusMessage = "Could not mount LRG package"
        return false
    end

    local items = love.filesystem.getDirectoryItems(mountPoint)
    local sourceSubfolder = ""
    if #items == 1 then
        local info = love.filesystem.getInfo(pathJoin(mountPoint, items[1]))
        if info and info.type == "directory" then
            sourceSubfolder = items[1]
        end
    end

    local basePath = sourceSubfolder ~= "" and pathJoin(mountPoint, sourceSubfolder) or mountPoint
    local manifest = readJson(pathJoin(basePath, "manifest.json"))
    if not manifest then
        love.filesystem.unmount(path)
        editor.statusMessage = "LRG package missing manifest.json"
        return false
    end

    local chartPath = manifest.difficulties and (manifest.difficulties.hard or manifest.difficulties.normal or manifest.difficulties.easy)
    if not chartPath then chartPath = "chart.json" end

    local chartData = readJson(pathJoin(basePath, chartPath))
    if not chartData then
        love.filesystem.unmount(path)
        editor.statusMessage = "LRG package missing chart"
        return false
    end

    if manifest.audio then
        local audioData = love.filesystem.read(pathJoin(basePath, manifest.audio))
        if audioData then
            editor.songData = love.data.newByteData(audioData)
            editor.songName = manifest.audio
            local ok, source = pcall(love.audio.newSource, editor.songData, "stream")
            if ok then editor.song = source end
        end
    end

    love.filesystem.unmount(path)
    return loadChart(chartData, manifest)
end

editor = {
    state = "menu",
    bpm = 144,
    notes = {},
    scroll = 0,
    snap = 0.25,
    spacing = 40,
    song = nil,
    songName = "",
    songData = nil,
    chartTitle = "My_Awesome_Chart",
    artist = "Unknown Artist",
    offset = 0,
    statusMessage = "",
    focus = nil 
}

local keys = { d = 1, f = 2, j = 3, k = 4 }

function love.load()
    ensureLRGDirectories()
    love.window.setTitle("LRG Chart Editor")
    love.window.setMode(1000, 700, {resizable = true})
    love.keyboard.setKeyRepeat(true)
end

function love.textinput(t)
    if editor.state == "edit" then
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
        end
    end
end

function love.filedropped(file)
    local filename = file:getFilename()
    local lowerName = filename:lower()

    if lowerName:match("%.lrg$") then
        loadLRGPackage(filename)
    elseif lowerName:match("%.json$") then
        loadChartJsonData(file:read())
    elseif lowerName:match("%.ogg$") or lowerName:match("%.mp3$") then
        editor.song = love.audio.newSource(file, "stream")
        editor.songName = filename:match("([^/\\]+)$") or "audio.ogg"
        editor.songData = file:read("data")
        editor.state = "edit"
        editor.statusMessage = "Loaded: " .. editor.songName
    end
end

function exportLRG()
    if not editor.songData then
        editor.statusMessage = "Load audio before exporting"
        return
    end

    ensureLRGDirectories()

    local packageBase = safeName(editor.chartTitle, "chart")
    local exportDir = pathJoin(LRG_DIRS.editorExports, packageBase)
    love.filesystem.createDirectory(exportDir)

    local audioName = safeFileName(editor.songName, "audio.ogg")
    if not audioName:match("%.%w+$") then
        audioName = audioName .. ".ogg"
    end

    love.filesystem.write(pathJoin(exportDir, audioName), editor.songData)

    local exportChart = buildExportChart()
    writeJson(pathJoin(exportDir, "chart.json"), exportChart)

    local manifest = {
        version = LRG_FORMAT_VERSION,
        format = "LRG",
        title = editor.chartTitle,
        artist = editor.artist,
        bpm = editor.bpm,
        offset = editor.offset,
        lanes = 4,
        difficulties = { hard = "chart.json" },
        audio = audioName
    }
    writeJson(pathJoin(exportDir, "manifest.json"), manifest)

    local saveDir = love.filesystem.getSaveDirectory()
    local packageName = packageBase .. ".lrg"
    local packagePath = pathJoin(LRG_DIRS.songs, packageName)
    love.filesystem.remove(packagePath)

    local exportPath = pathJoin(saveDir, exportDir)
    local outputPath = pathJoin(saveDir, packagePath)
    local cmd = string.format('cd "%s" && zip -j "%s" chart.json manifest.json "%s"', exportPath, outputPath, audioName)
    os.execute(cmd)
    editor.statusMessage = "Exported: " .. packagePath
end

function love.mousepressed(x, y, button)
    local sw, sh = love.graphics.getDimensions()
    if editor.state == "edit" and button == 1 then
        local panelX = sw - 300
        editor.focus = nil

        -- Click detection updated to match the new draw coordinates
        -- Title: Y 100-125
        if x > panelX + 20 and x < sw - 20 and y > 100 and y < 125 then
            editor.focus = "title"
        -- BPM: Y 160-185
        elseif x > panelX + 20 and x < sw - 20 and y > 160 and y < 185 then
            editor.focus = "bpm"
        -- Artist: Y 220-245
        elseif x > panelX + 20 and x < sw - 20 and y > 220 and y < 245 then
            editor.focus = "artist"
        end

        -- Grid interaction
        local startX = (sw * 0.35) - 120
        if x >= startX and x <= startX + 240 then
            local lane = math.floor((x - startX) / 60) + 1
            local beat = math.floor(-(y - (sh - 100) + editor.scroll) / editor.spacing) * editor.snap
            if beat >= 0 then
                editor.notes[beat] = editor.notes[beat] or {false, false, false, false}
                editor.notes[beat][lane] = editor.notes[beat][lane] and false or { beat = beat, dir = lane, type = "tap", duration = 0, hold = false, endBeat = beat }
            end
        end

        -- Export button updated to match bottom anchor (sh - 80)
        if x > panelX + 50 and x < panelX + 250 and y > sh - 80 and y < sh - 30 then
            exportLRG()
        end
    end
end

function love.keypressed(key)
    if editor.state ~= "edit" then return end

    if key == "backspace" then
        if editor.focus == "title" then
            editor.chartTitle = editor.chartTitle:sub(1, -2)
        elseif editor.focus == "bpm" then
            local s = tostring(editor.bpm):sub(1, -2)
            editor.bpm = tonumber(s) or 0
        elseif editor.focus == "artist" then
            editor.artist = editor.artist:sub(1, -2)
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
            local currentBeat = editor.song:isPlaying() and (editor.song:tell() * (editor.bpm / 60)) or (editor.scroll / (editor.spacing / editor.snap))
            local snappedBeat = math.floor((currentBeat / editor.snap) + 0.5) * editor.snap
            if snappedBeat >= 0 then
                editor.notes[snappedBeat] = editor.notes[snappedBeat] or {false, false, false, false}
                editor.notes[snappedBeat][lane] = { beat = snappedBeat, dir = lane, type = "tap", duration = 0, hold = false, endBeat = snappedBeat }
            end
        end
    end
end

function love.update(dt)
    if editor.state == "edit" and editor.song and editor.song:isPlaying() then
        editor.scroll = (editor.song:tell() * (editor.bpm / 60)) * (editor.spacing / editor.snap)
    end
end

function love.draw()
    local sw, sh = love.graphics.getDimensions()
    if editor.state == "menu" then
        love.graphics.clear(0.1, 0.1, 0.15)
        love.graphics.printf("Drag & Drop audio to start", 0, sh/2, sw, "center")
        return
    end

    love.graphics.clear(0.05, 0.05, 0.05)
    local startX, bottomY = (sw * 0.35) - 120, sh - 100

    -- Grid
    for i = math.max(0, math.floor((bottomY + editor.scroll - sh) / editor.spacing)), math.ceil((bottomY + editor.scroll) / editor.spacing) do
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

    -- Right Info Panel
    local panelX = sw - 300
    love.graphics.setColor(0.1, 0.1, 0.15)
    love.graphics.rectangle("fill", panelX, 0, 300, sh)
    
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("CHART DETAILS", panelX + 20, 30)

    -- Fields (Higher up to avoid collision)
    love.graphics.setColor(0.7, 0.7, 1)
    love.graphics.print("Chart Title:", panelX + 20, 80)
    love.graphics.setColor(editor.focus == "title" and {1,1,1} or {0.5,0.5,0.5})
    love.graphics.rectangle("line", panelX + 20, 100, 260, 25)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(editor.chartTitle .. (editor.focus == "title" and "|" or ""), panelX + 25, 105)

    love.graphics.setColor(0.7, 0.7, 1)
    love.graphics.print("BPM:", panelX + 20, 140)
    love.graphics.setColor(editor.focus == "bpm" and {1,1,1} or {0.5,0.5,0.5})
    love.graphics.rectangle("line", panelX + 20, 160, 260, 25)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(tostring(editor.bpm) .. (editor.focus == "bpm" and "|" or ""), panelX + 25, 165)

    love.graphics.setColor(0.7, 0.7, 1)
    love.graphics.print("Artist:", panelX + 20, 200)
    love.graphics.setColor(editor.focus == "artist" and {1,1,1} or {0.5,0.5,0.5})
    love.graphics.rectangle("line", panelX + 20, 220, 260, 25)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(editor.artist .. (editor.focus == "artist" and "|" or ""), panelX + 25, 225)

    -- Bottom Anchored UI
    if editor.statusMessage ~= "" then
        love.graphics.setColor(0.4, 1, 0.4)
        love.graphics.printf(editor.statusMessage, panelX + 20, sh - 140, 260, "center")
    end

    love.graphics.setColor(0.2, 0.6, 0.2)
    love.graphics.rectangle("fill", panelX + 50, sh - 80, 200, 50, 5)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("Export to .lrg", panelX + 50, sh - 65, 200, "center")
end
