local json = require "json"
local Menu = require "menu"

local VIRTUAL_WIDTH = 1280
local VIRTUAL_HEIGHT = 720

local function getVirtualScale()
    local sw, sh = love.graphics.getDimensions()
    return sw / VIRTUAL_WIDTH, sh / VIRTUAL_HEIGHT
end

local settings = {
    repositoryUrl = "https://easy-planes-remain.loca.lt/",
    eyeCandy = true,
    framerateCap = 60
}

local function loadSettings()
    local data = love.filesystem.read("settings.json")
    if not data then return end

    local ok, decoded = pcall(json.decode, json, data)
    if not ok or type(decoded) ~= "table" then return end

    if type(decoded.repositoryUrl) == "string" and decoded.repositoryUrl ~= "" then
        settings.repositoryUrl = decoded.repositoryUrl
    end
    if type(decoded.eyeCandy) == "boolean" then
        settings.eyeCandy = decoded.eyeCandy
    end
    if type(decoded.framerateCap) == "number" then
        settings.framerateCap = decoded.framerateCap
    end
end

local function saveSettings()
    local payload = json.encode(json, settings)
    if payload then
        love.filesystem.write("settings.json", payload)
    end
end

local gameState = "menu" -- "menu", "play", "pause", "results"

local loadedChart = { notes = {} }
local chart = { notes = {} }
local activeNotes = {}
local songTime = 0
local bpm = 120
local spawnAheadBeats = 4
local travelDistance = 700
local startY, endY = 0, 0
local bgmStarted = false
local endTimer = 0

local score, combo, maxCombo, hits, totalPossibleNotes = 0, 0, 0, 0, 0
local judgments = { marvelous = 0, perfect = 0, great = 0, good = 0, miss = 0 }
local finalResults = nil
local notesFinished = 0

local judgment = { text = "", alpha = 0, scale = 1 }
local hitParticles = {}
local receptorFlashes = {0, 0, 0, 0}
local xPositions = {}

local bgm
local currentSongInfo = {}
local keys = { d = 1, f = 2, j = 3, k = 4, l = 4 }

local beatFlash = 0
local lastBeat = -1
local globalOffsetMs = 0
local currentSongOffsetMs = 0
local timingWindows = { marvelous = 18, perfect = 35, great = 60, good = 90 }

local pauseButtons = {
    continue = { x = 0, y = 0, w = 320, h = 60, text = "Continuar" },
    restart = { x = 0, y = 0, w = 320, h = 60, text = "Reiniciar" },
    exit = { x = 0, y = 0, w = 320, h = 60, text = "Salir" }
}

local function layoutPauseButtons()
    local sw, sh = love.graphics.getDimensions()
    local centerX = (sw - pauseButtons.continue.w) / 2
    local startYPos = (sh / 2) - 110
    pauseButtons.continue.x, pauseButtons.continue.y = centerX, startYPos
    pauseButtons.restart.x, pauseButtons.restart.y = centerX, startYPos + 80
    pauseButtons.exit.x, pauseButtons.exit.y = centerX, startYPos + 160
end

local function pointInRect(x, y, r)
    return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

local function resolvePointerToPixels(x, y)
    local sw, sh = love.graphics.getDimensions()
    local px, py = x, y
    if px >= 0 and px <= 1 and py >= 0 and py <= 1 then
        px, py = px * sw, py * sh
    end
    return px, py, sw, sh
end

local function pauseGame()
    if gameState ~= "play" then return end
    if bgm and bgm:isPlaying() then bgm:pause() end
    gameState = "pause"
end

local function resumeGame()
    if gameState ~= "pause" then return end
    if bgm and not bgm:isPlaying() then bgm:play() end
    gameState = "play"
end

function resetGame()
    score, combo, maxCombo, hits = 0, 0, 0, 0
    judgments = { marvelous = 0, perfect = 0, great = 0, good = 0, miss = 0 }
    activeNotes = {}
    chart = { notes = {} }
    notesFinished = 0
    totalPossibleNotes = 0
    hitParticles = {}
    receptorFlashes = {0, 0, 0, 0}
    judgment = { text = "", alpha = 0, scale = 1 }
    bgmStarted = false
    endTimer = 0
    finalResults = nil
    if bgm then bgm:stop() end
end

function startGame(songData)
    resetGame()
    if not songData or type(songData) ~= "table" then return end

    local folder = songData.folderPath
    local manifestData = love.filesystem.read(folder .. "/manifest.json")
    if not manifestData then return end

    local okManifest, decodedManifest = pcall(json.decode, json, manifestData)
    if not okManifest or not decodedManifest then return end

    currentSongInfo = decodedManifest
    currentSongInfo.filename = songData.filename
    currentSongInfo.folderPath = folder

    if currentSongInfo.audio then
        local audioPath = folder .. "/" .. currentSongInfo.audio
        local okAudio, source = pcall(love.audio.newSource, audioPath, "stream")
        if okAudio and source then
            bgm = source
            bgm:setVolume(0.8)
        else
            bgm = nil
        end
    end

    if not currentSongInfo.difficulties or not currentSongInfo.difficulties.hard then return end

    local chartData = love.filesystem.read(folder .. "/" .. currentSongInfo.difficulties.hard)
    if not chartData then return end

    local okChart, decodedChart = pcall(json.decode, json, chartData)
    if not okChart or type(decodedChart) ~= "table" or type(decodedChart.notes) ~= "table" then return end

    loadedChart = decodedChart
    chart = { notes = {} }
    for _, note in ipairs(loadedChart.notes) do table.insert(chart.notes, note) end
    bpm = tonumber(currentSongInfo.bpm) or 120
    totalPossibleNotes = #loadedChart.notes
    currentSongOffsetMs = currentSongInfo.offset or 0

    local delaySeconds = (spawnAheadBeats * 60) / bpm
    songTime = -delaySeconds
    gameState = "play"
end

function returnToMenu()
    currentSongInfo = {}
    resetGame()
    Menu.load()
    gameState = "menu"
end

local function gradeFromAccuracy(accuracy)
    if accuracy >= 99 then return "S" end
    if accuracy >= 95 then return "A" end
    if accuracy >= 90 then return "B" end
    if accuracy >= 80 then return "C" end
    return "D"
end

local function showResults()
    local weightedHitScore = (judgments.marvelous * 1.0) + (judgments.perfect * 0.95) + (judgments.great * 0.75) + (judgments.good * 0.5)
    local accuracy = totalPossibleNotes > 0 and (weightedHitScore / totalPossibleNotes) * 100 or 0
    finalResults = { score = score, maxCombo = maxCombo, accuracy = accuracy, grade = gradeFromAccuracy(accuracy) }
    gameState = "results"
end

function love.load()
    love.filesystem.createDirectory("songs")
    love.window.setTitle("Rhythm Game")
    love.window.setMode(1000, 700, {resizable = true})

    startY = VIRTUAL_HEIGHT / 2 - 500
    endY = VIRTUAL_HEIGHT / 2 + 200
    xPositions = {VIRTUAL_WIDTH / 2 - 125, VIRTUAL_WIDTH / 2 - 25, VIRTUAL_WIDTH / 2 + 75, VIRTUAL_WIDTH / 2 + 175}

    love.filesystem.mount(love.filesystem.getSource(), "base")
    loadSettings()
    Menu.setSettingsHandlers(settings, saveSettings)
    Menu.load()
    layoutPauseButtons()
end

function hitLane(lane)
    if settings.eyeCandy then
        receptorFlashes[lane] = 1
    end
    local hitFound = false

    for i = 1, #activeNotes do
        local n = activeNotes[i]
        if n.dir == lane and not n.hit then
            local noteHitTimeMs = (n.beat * 60 / bpm) * 1000
            local currentTimeMs = (songTime * 1000) + globalOffsetMs + currentSongOffsetMs
            local diffMs = math.abs(currentTimeMs - noteHitTimeMs)
            if diffMs <= timingWindows.good then
                n.hit = true
                hitFound = true
                processHit(diffMs, lane)
                table.remove(activeNotes, i)
                break
            end
        end
    end

    if not hitFound then
        combo = 0
        judgments.miss = judgments.miss + 1
        showJudgment("MISS", {1, 0.2, 0.2})
    end
end

function love.keypressed(key)
    if gameState == "menu" then
        if Menu.keypressed and Menu.keypressed(key) then return end
        if key == "escape" then love.event.quit() end
        return
    end

    if gameState == "results" then
        if key == "return" or key == "space" then
            returnToMenu()
        elseif key == "r" then
            startGame(currentSongInfo)
        end
        return
    end

    if gameState == "pause" then
        if key == "escape" then
            resumeGame()
        elseif key == "r" then
            startGame(currentSongInfo)
        end
        return
    end

    if key == "escape" then
        pauseGame()
        return
    end

    local lane = keys[key]
    if lane then hitLane(lane) end
end

function processHit(diffMs, lane)
    hits = hits + 1
    notesFinished = notesFinished + 1
    combo = combo + 1
    if combo > maxCombo then maxCombo = combo end

    if settings.eyeCandy then
        table.insert(hitParticles, { x = xPositions[lane], y = endY, radius = 25, alpha = 1 })
    end

    if diffMs <= timingWindows.marvelous then
        score = score + 1200
        judgments.marvelous = judgments.marvelous + 1
        showJudgment("MARVELOUS", {1, 0.6, 1})
    elseif diffMs <= timingWindows.perfect then
        score = score + 1000
        judgments.perfect = judgments.perfect + 1
        showJudgment("PERFECT", {1, 0.8, 0})
    elseif diffMs <= timingWindows.great then
        score = score + 500
        judgments.great = judgments.great + 1
        showJudgment("GREAT", {0.2, 1, 0.2})
    else
        score = score + 200
        judgments.good = judgments.good + 1
        showJudgment("GOOD", {0.2, 0.6, 1})
    end
end

function showJudgment(text, color)
    judgment.text = text
    judgment.color = color
    judgment.alpha = 1
    judgment.scale = 1.5
end

function love.textinput(t)
    if gameState == "menu" and Menu.textinput then
        Menu.textinput(t)
    end
end

function love.mousepressed(x, y, button)
    local px, py = resolvePointerToPixels(x, y)
    local scaleX, scaleY = getVirtualScale()
    px = px / scaleX
    py = py / scaleY
    if gameState == "menu" then
        Menu.mousepressed(px, py, button, startGame)
    elseif gameState == "results" and button == 1 then
        returnToMenu()
    elseif gameState == "pause" and button == 1 then
        layoutPauseButtons()
        if pointInRect(px, py, pauseButtons.continue) then
            resumeGame()
        elseif pointInRect(px, py, pauseButtons.restart) then
            startGame(currentSongInfo)
        elseif pointInRect(px, py, pauseButtons.exit) then
            returnToMenu()
        end
    end
end

function love.touchpressed(_, x, y)
    local px, py, sw = resolvePointerToPixels(x, y)
    local scaleX, scaleY = getVirtualScale()
    px = px / scaleX
    py = py / scaleY
    sw = sw / scaleX

    if gameState == "pause" then
        layoutPauseButtons()
        if pointInRect(px, py, pauseButtons.continue) then
            resumeGame()
        elseif pointInRect(px, py, pauseButtons.restart) then
            startGame(currentSongInfo)
        elseif pointInRect(px, py, pauseButtons.exit) then
            returnToMenu()
        end
        return
    end

    if gameState == "play" then
        if px < 120 and py < 80 then
            pauseGame()
            return
        end

        local lane = math.floor(px / (sw / 4)) + 1
        if lane >= 1 and lane <= 4 then
            hitLane(lane)
        end
    elseif gameState == "menu" then
        Menu.mousepressed(px, py, 1, startGame)
    end
end

function love.wheelmoved(x, y)
    if gameState == "menu" then Menu.wheelmoved(x, y) end
end

function love.resize()
    startY = (VIRTUAL_HEIGHT / 2) - 500
    endY = (VIRTUAL_HEIGHT / 2) + 200
    xPositions = {VIRTUAL_WIDTH / 2 - 125, VIRTUAL_WIDTH / 2 - 25, VIRTUAL_WIDTH / 2 + 75, VIRTUAL_WIDTH / 2 + 175}
    layoutPauseButtons()
end

function love.update(dt)
    if gameState == "menu" then
        Menu.update(dt)
        return
    end
    if gameState == "results" or gameState == "pause" then
        return
    end

    if not bgmStarted then
        songTime = songTime + dt
        if songTime >= 0 then
            if bgm then bgm:play() end
            bgmStarted = true
        end
    else
        if bgm and bgm:isPlaying() then
            songTime = bgm:tell()
        else
            songTime = songTime + dt
            if notesFinished >= totalPossibleNotes and #activeNotes == 0 then
                endTimer = endTimer + dt
                if endTimer > 1.5 then showResults() end
            end
        end
    end

    local currentBeat = songTime * (bpm / 60)
    local beatInt = math.floor(currentBeat)
    if beatInt > lastBeat then
        lastBeat = beatInt
        if settings.eyeCandy then
            beatFlash = 0.35
        end
    end
    beatFlash = math.max(0, beatFlash - dt * 2.5)

    for i = #chart.notes, 1, -1 do
        local n = chart.notes[i]
        if currentBeat >= n.beat - spawnAheadBeats then
            local duration = (spawnAheadBeats * 60) / bpm
            table.insert(activeNotes, { beat = n.beat, dir = n.dir, speed = travelDistance / duration, y = startY, hit = false })
            table.remove(chart.notes, i)
        end
    end

    for i = #activeNotes, 1, -1 do
        local n = activeNotes[i]
        n.y = n.y + n.speed * dt
        if n.y > endY + 60 then
            notesFinished = notesFinished + 1
            table.remove(activeNotes, i)
            combo = 0
            judgments.miss = judgments.miss + 1
            showJudgment("MISS", {1, 0.2, 0.2})
        end
    end

    if judgment.alpha > 0 then
        judgment.alpha = judgment.alpha - dt
        if judgment.scale > 1 then judgment.scale = judgment.scale - dt * 3 end
    end

    if settings.eyeCandy then
        for i = #hitParticles, 1, -1 do
            local p = hitParticles[i]
            p.radius = p.radius + 150 * dt
            p.alpha = p.alpha - 3 * dt
            if p.alpha <= 0 then table.remove(hitParticles, i) end
        end

        for i = 1, 4 do
            if receptorFlashes[i] > 0 then receptorFlashes[i] = math.max(0, receptorFlashes[i] - dt * 4) end
        end
    end

    if settings.framerateCap > 0 then
        local targetFrameTime = 1 / settings.framerateCap
        local frameTime = love.timer.getDelta()
        if frameTime < targetFrameTime then
            love.timer.sleep(targetFrameTime - frameTime)
        end
    end
end

function love.draw()
    local scaleX, scaleY = getVirtualScale()
    love.graphics.push()
    love.graphics.scale(scaleX, scaleY)

    local sw, sh = VIRTUAL_WIDTH, VIRTUAL_HEIGHT

    if gameState == "menu" then
        Menu.draw()
        love.graphics.pop()
        return
    end

    if gameState == "results" then
        love.graphics.setColor(0.05, 0.03, 0.09)
        love.graphics.rectangle("fill", 0, 0, sw, sh)
        love.graphics.setColor(1, 0.5, 0.8)
        love.graphics.printf("RESULTS", 0, 80, sw, "center")
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("Score: " .. finalResults.score, 0, 160, sw, "center")
        love.graphics.printf(string.format("Accuracy: %.2f%%", finalResults.accuracy), 0, 200, sw, "center")
        love.graphics.printf("Max Combo: " .. finalResults.maxCombo, 0, 240, sw, "center")
        love.graphics.printf("Grade: " .. finalResults.grade, 0, 280, sw, "center")
        love.graphics.printf(string.format("Marvelous %d | Perfect %d | Great %d | Good %d | Miss %d", judgments.marvelous, judgments.perfect, judgments.great, judgments.good, judgments.miss), 0, 340, sw, "center")
        love.graphics.printf("Press R to Retry, Enter/Space to Continue", 0, 420, sw, "center")
        love.graphics.pop()
        return
    end

    local bg = settings.eyeCandy and (0.05 + beatFlash) or 0.05
    love.graphics.setColor(bg, bg, bg + 0.03)
    love.graphics.rectangle("fill", 0, 0, sw, sh)

    love.graphics.setColor(1, 1, 1)
    love.graphics.print("Score: " .. score, 20, 20)
    love.graphics.print("Combo: " .. combo, 20, 40)
    local notesProcessed = totalPossibleNotes - #chart.notes
    local acc = notesProcessed > 0 and (hits / notesProcessed) * 100 or 0
    love.graphics.print(string.format("Accuracy: %.2f%%", acc), 20, 60)

    for i, x in ipairs(xPositions) do
        love.graphics.setColor(1, 1, 1, 0.2)
        love.graphics.circle("line", x, endY, 25)
        if settings.eyeCandy and receptorFlashes[i] > 0 then
            love.graphics.setColor(1, 1, 1, receptorFlashes[i] * 0.5)
            love.graphics.circle("fill", x, endY, 25)
        end
    end

    love.graphics.setColor(1, 0.4, 0.4)
    for _, n in ipairs(activeNotes) do love.graphics.circle("fill", xPositions[n.dir], n.y, 25) end

    if settings.eyeCandy then
        love.graphics.setLineWidth(2)
        for _, p in ipairs(hitParticles) do
            love.graphics.setColor(1, 1, 1, p.alpha)
            love.graphics.circle("line", p.x, p.y, p.radius)
        end
        love.graphics.setLineWidth(1)
    end

    if love.system.getOS() == "Android" or love.system.getOS() == "iOS" then
        local laneWidth = sw / 4
        for i = 1, 4 do
            local x = (i - 1) * laneWidth
            love.graphics.setColor(1, 1, 1, 0.05)
            love.graphics.rectangle("fill", x, sh - 200, laneWidth, 200)
            love.graphics.setColor(1, 1, 1, 0.15)
            love.graphics.rectangle("line", x, sh - 200, laneWidth, 200)
        end

        love.graphics.setColor(0.8, 0.3, 0.3, 0.9)
        love.graphics.rectangle("fill", 20, 20, 90, 45, 6)
        love.graphics.setColor(1,1,1)
        love.graphics.printf("PAUSA", 20, 34, 90, "center")
    end

    if judgment.alpha > 0 then
        local c = judgment.color
        love.graphics.setColor(c[1], c[2], c[3], judgment.alpha)
        love.graphics.push()
        love.graphics.translate(sw/2, sh/2)
        love.graphics.scale(judgment.scale, judgment.scale)
        love.graphics.printf(judgment.text, -100, -10, 200, "center")
        love.graphics.pop()
    end

    if gameState == "pause" then
        love.graphics.setColor(0, 0, 0, 0.65)
        love.graphics.rectangle("fill", 0, 0, sw, sh)
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("PAUSA", 0, sh / 2 - 180, sw, "center")

        local colors = {
            continue = {0.2, 0.6, 0.3},
            restart = {0.2, 0.4, 0.8},
            exit = {0.8, 0.3, 0.3}
        }

        for key, rect in pairs(pauseButtons) do
            local c = colors[key]
            love.graphics.setColor(c[1], c[2], c[3], 1)
            love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h, 6)
            love.graphics.setColor(1, 1, 1)
            love.graphics.printf(rect.text, rect.x, rect.y + 22, rect.w, "center")
        end
    end

    love.graphics.pop()
end
