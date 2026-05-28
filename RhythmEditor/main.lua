os.execute("export SDL_AUDIODRIVER=alsa")

local json = require "json"

local editor = {
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
    statusMessage = "",
    focus = nil 
}

local keys = { d = 1, f = 2, j = 3, k = 4 }

function love.load()
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
    if editor.state == "menu" then
        local filename = file:getFilename()
        if filename:match("%.ogg$") or filename:match("%.mp3$") then
            editor.song = love.audio.newSource(file, "stream")
            editor.songName = filename:match("([^/\\]+)$") or "audio.ogg"
            editor.songData = file:read("data")
            editor.state = "edit"
            editor.statusMessage = "Loaded: " .. editor.songName
        end
    end
end

function exportLRG()
    if not editor.songData then return end
    love.filesystem.write(editor.songName, editor.songData)

    local exportChart = { bpm = editor.bpm, notes = {} }
    local beats = {}
    for b, _ in pairs(editor.notes) do table.insert(beats, b) end
    table.sort(beats)
    for _, b in ipairs(beats) do
        for lane, active in ipairs(editor.notes[b]) do
            if active then table.insert(exportChart.notes, {beat = b, dir = lane}) end
        end
    end
    love.filesystem.write("chart.json", json:encode(exportChart))

    local manifest = {
        version = "1.0",
        title = editor.chartTitle,
        bpm = editor.bpm,
        difficulties = { hard = "chart.json" },
        artist = editor.artist,
        audio = editor.songName
    }
    love.filesystem.write("manifest.json", json:encode(manifest))

    local saveDir = love.filesystem.getSaveDirectory()
    local packageName = editor.chartTitle:gsub("%s+", "_") .. ".lrg"
    local cmd = string.format('cd "%s" && zip -j "%s" chart.json manifest.json "%s"', saveDir, packageName, editor.songName)
    os.execute(cmd)
    editor.statusMessage = "Exported: " .. packageName
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
                editor.notes[beat][lane] = not editor.notes[beat][lane]
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
                editor.notes[snappedBeat][lane] = true
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
