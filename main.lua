local json = require "json"
local Menu = require "menu"

local App = {
    version = "1.1.0",
    chartVersion = "1.1",
    state = "menu",
}

local Layout = {
    baseW = 1000,
    baseH = 700,
    scale = 1,
    ox = 0,
    oy = 0,
}

function Layout.update()
    local sw, sh = love.graphics.getDimensions()
    Layout.scale = math.min(sw / Layout.baseW, sh / Layout.baseH)
    Layout.ox = (sw - Layout.baseW * Layout.scale) * 0.5
    Layout.oy = (sh - Layout.baseH * Layout.scale) * 0.5
end

function Layout.begin()
    love.graphics.push()
    love.graphics.translate(Layout.ox, Layout.oy)
    love.graphics.scale(Layout.scale, Layout.scale)
end

function Layout.finish()
    love.graphics.pop()
end

local Play = {
    chart = { notes = {} },
    activeNotes = {},
    songTime = 0,
    bpm = 120,
    spawnAheadBeats = 4,
    travelDistance = 700,
    startY = -150,
    endY = 550,
    bgmStarted = false,
    endTimer = 0,
    bgm = nil,
    currentSongInfo = {},
    score = 0,
    combo = 0,
    maxCombo = 0,
    hits = 0,
    totalPossibleNotes = 0,
    notesFinished = 0,
    judgment = { text = "", color = {1,1,1}, alpha = 0, scale = 1 },
    hitParticles = {},
    receptorFlashes = {0, 0, 0, 0},
    xPositions = {375, 475, 575, 675},
    beatFlash = 0,
    lastBeat = -1,
}

local keys = { d = 1, f = 2, j = 3, k = 4, l = 4 }

local function autoSpeedForBpm(bpm)
    return bpm / 100
end

local function resetGame()
    Play.score, Play.combo, Play.maxCombo, Play.hits = 0, 0, 0, 0
    Play.activeNotes = {}
    Play.notesFinished = 0
    Play.hitParticles = {}
    Play.receptorFlashes = {0, 0, 0, 0}
    Play.judgment = { text = "", color = {1,1,1}, alpha = 0, scale = 1 }
    Play.bgmStarted = false
    Play.endTimer = 0
    Play.songTime = 0
    Play.beatFlash = 0
    Play.lastBeat = -1
    if Play.bgm then Play.bgm:stop() end
end

local function showJudgment(text, color)
    Play.judgment.text = text
    Play.judgment.color = color
    Play.judgment.alpha = 1
    Play.judgment.scale = 1.5
end

local function buildRuntimeNote(raw)
    local noteSpeed = tonumber(raw.speed) or autoSpeedForBpm(Play.bpm)
    local durationSec = ((raw.duration or 0) * 60) / Play.bpm
    return {
        beat = raw.beat,
        dir = raw.dir,
        durationBeats = raw.duration or 0,
        speed = (100 * noteSpeed * Play.travelDistance) / (Play.spawnAheadBeats * 100),
        y = Play.startY,
        hit = false,
        holdTime = 0,
        holdDuration = durationSec,
    }
end

local function processHit(diff, lane)
    Play.hits = Play.hits + 1
    Play.notesFinished = Play.notesFinished + 1
    Play.combo = Play.combo + 1
    if Play.combo > Play.maxCombo then Play.maxCombo = Play.combo end

    table.insert(Play.hitParticles, { x = Play.xPositions[lane], y = Play.endY, radius = 25, alpha = 1 })

    if diff < 25 then
        Play.score = Play.score + 1000
        showJudgment("PERFECT", {1, 0.8, 0})
    elseif diff < 55 then
        Play.score = Play.score + 500
        showJudgment("GREAT", {0.2, 1, 0.2})
    else
        Play.score = Play.score + 200
        showJudgment("GOOD", {0.2, 0.6, 1})
    end
end

local function hitLane(lane)
    Play.receptorFlashes[lane] = 1
    local hitFound = false

    for i = 1, #Play.activeNotes do
        local n = Play.activeNotes[i]
        if n.dir == lane and not n.hit then
            local diff = math.abs(n.y - Play.endY)
            if diff < 100 then
                n.hit = true
                hitFound = true
                processHit(diff, lane)
                table.remove(Play.activeNotes, i)
                break
            end
        end
    end

    if not hitFound then
        Play.combo = 0
        showJudgment("MISS", {1, 0.2, 0.2})
    end
end

local function returnToMenu()
    if Play.currentSongInfo.filename then
        love.filesystem.unmount("songs/" .. Play.currentSongInfo.filename)
    end
    Play.currentSongInfo = {}
    resetGame()
    Menu.load()
    App.state = "menu"
end

local function startGame(filename)
    resetGame()
    if not filename then return end

    local archivePath = "songs/" .. filename
    if not love.filesystem.mount(archivePath, "loaded_song") then return end

    local manifestData = love.filesystem.read("loaded_song/manifest.json")
    if not manifestData then love.filesystem.unmount(archivePath); return end

    local okManifest, manifest = pcall(json.decode, json, manifestData)
    if not okManifest or not manifest then love.filesystem.unmount(archivePath); return end

    Play.currentSongInfo = manifest
    Play.currentSongInfo.filename = filename

    if Play.currentSongInfo.audio then
        local okAudio, source = pcall(love.audio.newSource, "loaded_song/" .. Play.currentSongInfo.audio, "stream")
        Play.bgm = okAudio and source or nil
        if Play.bgm then Play.bgm:setVolume(0.8) end
    end

    local chartPath = Play.currentSongInfo.difficulties and Play.currentSongInfo.difficulties.hard
    if not chartPath then love.filesystem.unmount(archivePath); return end

    local chartData = love.filesystem.read("loaded_song/" .. chartPath)
    if not chartData then love.filesystem.unmount(archivePath); return end

    local okChart, decodedChart = pcall(json.decode, json, chartData)
    if not okChart or type(decodedChart) ~= "table" or type(decodedChart.notes) ~= "table" then
        love.filesystem.unmount(archivePath)
        return
    end

    Play.chart = decodedChart
    Play.bpm = tonumber(Play.currentSongInfo.bpm) or 120
    Play.totalPossibleNotes = #Play.chart.notes

    local delaySeconds = (Play.spawnAheadBeats * 60) / Play.bpm
    Play.songTime = -delaySeconds
    App.state = "play"
end

function love.load()
    love.filesystem.createDirectory("songs")
    love.window.setTitle("Rhythm Game v" .. App.version)
    love.window.setMode(1000, 700, {resizable = true})
    Layout.update()
    Menu.setLayout(Layout)
    Menu.load()
end

function love.resize()
    Layout.update()
end

function love.keypressed(key)
    if App.state == "menu" then
        if key == "escape" then love.event.quit() end
        return
    end
    if key == "escape" then returnToMenu(); return end
    local lane = keys[key]
    if lane then hitLane(lane) end
end

function love.mousepressed(x, y, button)
    if App.state == "menu" then
        Menu.mousepressed((x - Layout.ox) / Layout.scale, (y - Layout.oy) / Layout.scale, button, startGame)
    end
end

function love.wheelmoved(x, y)
    if App.state == "menu" then Menu.wheelmoved(x, y) end
end

function love.update(dt)
    if App.state == "menu" then Menu.update(dt); return end

    if not Play.bgmStarted then
        Play.songTime = Play.songTime + dt
        if Play.songTime >= 0 then
            if Play.bgm then Play.bgm:play() end
            Play.bgmStarted = true
        end
    else
        if Play.bgm and Play.bgm:isPlaying() then
            Play.songTime = Play.bgm:tell()
        else
            Play.songTime = Play.songTime + dt
            if Play.notesFinished >= Play.totalPossibleNotes and #Play.activeNotes == 0 then
                Play.endTimer = Play.endTimer + dt
                if Play.endTimer > 1.5 then returnToMenu() end
            end
        end
    end

    local currentBeat = Play.songTime * (Play.bpm / 60)
    local beatInt = math.floor(currentBeat)
    if beatInt > Play.lastBeat then Play.lastBeat = beatInt; Play.beatFlash = 0.35 end
    Play.beatFlash = math.max(0, Play.beatFlash - dt * 2.5)

    for i = #Play.chart.notes, 1, -1 do
        local n = Play.chart.notes[i]
        if currentBeat >= n.beat - Play.spawnAheadBeats then
            table.insert(Play.activeNotes, buildRuntimeNote(n))
            table.remove(Play.chart.notes, i)
        end
    end

    for i = #Play.activeNotes, 1, -1 do
        local n = Play.activeNotes[i]
        n.y = n.y + n.speed * dt
        if n.y > Play.endY + 60 then
            Play.notesFinished = Play.notesFinished + 1
            table.remove(Play.activeNotes, i)
            Play.combo = 0
            showJudgment("MISS", {1, 0.2, 0.2})
        end
    end

    if Play.judgment.alpha > 0 then
        Play.judgment.alpha = Play.judgment.alpha - dt
        if Play.judgment.scale > 1 then Play.judgment.scale = Play.judgment.scale - dt * 3 end
    end
end

function love.draw()
    if App.state == "menu" then
        Layout.begin(); Menu.draw(); Layout.finish(); return
    end

    Layout.begin()
    local bg = 0.05 + Play.beatFlash
    love.graphics.setColor(bg, bg, bg + 0.03)
    love.graphics.rectangle("fill", 0, 0, Layout.baseW, Layout.baseH)

    love.graphics.setColor(1,1,1)
    love.graphics.print("v" .. App.version .. " | Chart " .. App.chartVersion, 20, 20)
    love.graphics.print("Score: " .. Play.score, 20, 45)
    love.graphics.print("Combo: " .. Play.combo, 20, 70)

    for i, x in ipairs(Play.xPositions) do
        love.graphics.setColor(1,1,1,0.2)
        love.graphics.circle("line", x, Play.endY, 25)
        if Play.receptorFlashes[i] > 0 then
            love.graphics.setColor(1,1,1,Play.receptorFlashes[i] * 0.5)
            love.graphics.circle("fill", x, Play.endY, 25)
        end
    end

    for _, n in ipairs(Play.activeNotes) do
        if n.holdDuration > 0 then
            local holdPixels = n.speed * n.holdDuration
            love.graphics.setColor(1, 0.4, 0.4, 0.25)
            love.graphics.rectangle("fill", Play.xPositions[n.dir] - 12, n.y - holdPixels, 24, holdPixels)
        end
        love.graphics.setColor(1, 0.4, 0.4)
        love.graphics.circle("fill", Play.xPositions[n.dir], n.y, 25)
    end

    if Play.judgment.alpha > 0 then
        local c = Play.judgment.color
        love.graphics.setColor(c[1], c[2], c[3], Play.judgment.alpha)
        love.graphics.printf(Play.judgment.text, 0, 310, Layout.baseW, "center")
    end

    Layout.finish()
end
