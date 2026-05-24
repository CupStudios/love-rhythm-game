local json = require "json"
local Menu = require "menu"

local gameState = "menu" -- Can be "menu", "play", or "results"

local loadedChart = { notes = {} }
local chart = { notes = {} }
local activeNotes = {}
local songTime = 0
local bpm = 120
local spawnAheadBeats = 4
local travelDistance = 700
local startY, endY = 0, 0
local bgmStarted = false
local endTimer = 0 -- To handle waiting a few seconds after the song ends

-- Scoring and Stats
local score, combo, maxCombo, hits, totalPossibleNotes = 0, 0, 0, 0, 0
local judgments = { marvelous = 0, perfect = 0, great = 0, good = 0, miss = 0 }
local finalResults = nil

local notesFinished = 0

-- Eye Candy Variables
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
local timingWindows = {
    marvelous = 18,
    perfect = 35,
    great = 60,
    good = 90
}

local importedMessage = ""
local importedMessageTimer = 0

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

function startGame(filename)
    resetGame()

    if not filename then
        return
    end
    
    -- Load the chosen package
    local archivePath = "songs/" .. filename
    
    -- FIX ANDROID: Apuntar a la ruta absoluta de la carpeta externa de desarrollo
    local fullOSPath = love.filesystem.getSource() .. "/" .. archivePath
    
    local success = love.filesystem.mount(fullOSPath, "loaded_song")
    if not success then 
        print("Error: No se pudo montar " .. fullOSPath)
        return 
    end

    local manifestData = love.filesystem.read("loaded_song/manifest.json")
    if not manifestData then
        love.filesystem.unmount(archivePath)
        return
    end

    local okManifest, decodedManifest = pcall(json.decode, json, manifestData)
    if not okManifest or not decodedManifest then
        love.filesystem.unmount(archivePath)
        return
    end

    currentSongInfo = decodedManifest
    currentSongInfo.filename = filename

    if currentSongInfo.audio then
        local okAudio, source = pcall(love.audio.newSource, "loaded_song/" .. currentSongInfo.audio, "stream")
        if okAudio and source then
            bgm = source
            bgm:setVolume(0.8)
        else
            bgm = nil
        end
    end

    if not currentSongInfo.difficulties or not currentSongInfo.difficulties.hard then
        love.filesystem.unmount(archivePath)
        return
    end

    local chartData = love.filesystem.read("loaded_song/" .. currentSongInfo.difficulties.hard)
    if chartData then
        local okChart, decodedChart = pcall(json.decode, json, chartData)
        if not okChart or type(decodedChart) ~= "table" or type(decodedChart.notes) ~= "table" then
            love.filesystem.unmount(archivePath)
            return
        end

        loadedChart = decodedChart
        chart = { notes = {} }
        for _, note in ipairs(loadedChart.notes) do
            table.insert(chart.notes, note)
        end
        bpm = currentSongInfo.bpm
        totalPossibleNotes = #loadedChart.notes
        currentSongOffsetMs = currentSongInfo.offset or 0
    else
        love.filesystem.unmount(archivePath)
        return
    end

    local delaySeconds = (spawnAheadBeats * 60) / bpm
    songTime = -delaySeconds 
    
    gameState = "play"
end

function returnToMenu()
    if currentSongInfo.filename then
        love.filesystem.unmount("songs/" .. currentSongInfo.filename)
    end
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
    finalResults = {
        score = score,
        maxCombo = maxCombo,
        accuracy = accuracy,
        grade = gradeFromAccuracy(accuracy)
    }
    gameState = "results"
end

function importLRGFile(path)
    if not path then
        return
    end

    local filename = path:match("([^/]+%.lrg)$")

    if not filename then
        importedMessage = "Invalid file!"
        importedMessageTimer = 3
        return
    end

    local data = love.filesystem.read(path)

    if not data then
        importedMessage = "Failed to read file!"
        importedMessageTimer = 3
        return
    end

    love.filesystem.createDirectory("songs")
    love.filesystem.write("songs/" .. filename, data)

    importedMessage = "Imported: " .. filename
    importedMessageTimer = 3
end

function love.load()
    love.filesystem.createDirectory("songs")

    love.window.setTitle("Rhythm Game")
    love.window.setMode(1000, 700, {resizable = true})
    
    local sw, sh = love.graphics.getDimensions()
    startY = sh/2 - 500
    endY = sh/2 + 200
    xPositions = {sw/2 - 125, sw/2 - 25, sw/2 + 75, sw/2 + 175}

    love.filesystem.mount(love.filesystem.getSource(), "base")
    
    Menu.load()
end

function hitLane(lane)
    receptorFlashes[lane] = 1

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
        if key == "escape" then
            love.event.quit()
        end
        return
    end
    if gameState == "results" then
        if key == "return" or key == "space" then
            returnToMenu()
        elseif key == "r" then
            startGame(currentSongInfo.filename)
        end
        return
    end

    if key == "escape" then
        returnToMenu()
        return
    end

    local lane = keys[key]

    if lane then
        hitLane(lane)
    end
end

function processHit(diffMs, lane)
    hits = hits + 1
    notesFinished = notesFinished + 1
    combo = combo + 1
    if combo > maxCombo then maxCombo = combo end

    table.insert(hitParticles, { x = xPositions[lane], y = endY, radius = 25, alpha = 1 })

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

function love.mousepressed(x, y, button)
    if gameState == "menu" then
        Menu.mousepressed(x, y, button, startGame)
    elseif gameState == "results" and button == 1 then
        returnToMenu()
    end
end

function love.touchpressed(id, x, y, dx, dy, pressure)
    if gameState ~= "play" then
        return
    end

    local sw, sh = love.graphics.getDimensions()

    -- Convert normalized coords to screen coords
    x = x * sw
    y = y * sh

    local laneWidth = sw / 4

    local lane = math.floor(x / laneWidth) + 1

    if lane >= 1 and lane <= 4 then
        hitLane(lane)
    end
end

function love.wheelmoved(x, y)
    if gameState == "menu" then
        Menu.wheelmoved(x, y)
    end
end

function love.update(dt)
    if gameState == "menu" then
        Menu.update(dt)
        return
    end
    if gameState == "results" then
        return
    end

    -- GAME LOGIC
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
            
            -- Song completion
            if notesFinished >= totalPossibleNotes and #activeNotes == 0 then
                endTimer = endTimer + dt

                if endTimer > 1.5 then
                    showResults()
                end
            end
        end
    end
    
    local currentBeat = songTime * (bpm / 60)

    -- Beat flash
    local beatInt = math.floor(currentBeat)

    if beatInt > lastBeat then
        lastBeat = beatInt
        beatFlash = 0.35
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

    for i = #hitParticles, 1, -1 do
        local p = hitParticles[i]
        p.radius = p.radius + 150 * dt
        p.alpha = p.alpha - 3 * dt
        if p.alpha <= 0 then table.remove(hitParticles, i) end
    end

    for i = 1, 4 do
        if receptorFlashes[i] > 0 then
            receptorFlashes[i] = math.max(0, receptorFlashes[i] - dt * 4)
        end
    end
end

function love.draw()
    if gameState == "menu" then
        Menu.draw()
        return
    end
    if gameState == "results" then
        local sw, sh = love.graphics.getDimensions()
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
        return
    end

    -- GAME RENDERING
    local sw, sh = love.graphics.getDimensions()
    local bg = 0.05 + beatFlash
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
        if receptorFlashes[i] > 0 then
            love.graphics.setColor(1, 1, 1, receptorFlashes[i] * 0.5)
            love.graphics.circle("fill", x, endY, 25)
        end
    end

    love.graphics.setColor(1, 0.4, 0.4)
    for _, n in ipairs(activeNotes) do
        love.graphics.circle("fill", xPositions[n.dir], n.y, 25)
    end

    love.graphics.setLineWidth(2)
    for _, p in ipairs(hitParticles) do
        love.graphics.setColor(1, 1, 1, p.alpha)
        love.graphics.circle("line", p.x, p.y, p.radius)
    end
    love.graphics.setLineWidth(1)

    -- Mobile touch areas
    if love.system.getOS() == "Android" or love.system.getOS() == "iOS" then
       local laneWidth = sw / 4

    for i = 1, 4 do
        local x = (i - 1) * laneWidth

        love.graphics.setColor(1, 1, 1, 0.05)
        love.graphics.rectangle("fill", x, sh - 200, laneWidth, 200)

        love.graphics.setColor(1, 1, 1, 0.15)
        love.graphics.rectangle("line", x, sh - 200, laneWidth, 200)
        end
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
end
