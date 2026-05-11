local json = require "json"
local Menu = require "menu"

local gameState = "menu" -- Can be "menu" or "play"

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

local importedMessage = ""
local importedMessageTimer = 0

function resetGame()
    score, combo, maxCombo, hits = 0, 0, 0, 0
    activeNotes = {}
    notesFinished = 0
    hitParticles = {}
    receptorFlashes = {0, 0, 0, 0}
    judgment = { text = "", alpha = 0, scale = 1 }
    bgmStarted = false
    endTimer = 0
    if bgm then bgm:stop() end
end

function startGame(filename)
    resetGame()
    
    -- Load the chosen package
    local success = love.filesystem.mount("songs/" .. filename, "loaded_song")
    if not success then return end

    local manifestData = love.filesystem.read("loaded_song/manifest.json")
    currentSongInfo = json:decode(manifestData)
    currentSongInfo.filename = filename

    if currentSongInfo.audio then
        bgm = love.audio.newSource("loaded_song/" .. currentSongInfo.audio, "stream")
        bgm:setVolume(0.8)
    end

    local chartData = love.filesystem.read("loaded_song/" .. currentSongInfo.difficulties.hard)
    if chartData then
        chart = json:decode(chartData)
        bpm = currentSongInfo.bpm
        totalPossibleNotes = #chart.notes
    end

    local delaySeconds = (spawnAheadBeats * 60) / bpm
    songTime = -delaySeconds 
    
    gameState = "play"
end

function returnToMenu()
    if currentSongInfo.filename then
        love.filesystem.unmount("songs/" .. currentSongInfo.filename)
    end
    resetGame()
    Menu.load()
    gameState = "menu"
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
            local diff = math.abs(n.y - endY)

            if diff < 100 then
                n.hit = true
                hitFound = true

                processHit(diff, lane)

                table.remove(activeNotes, i)
                break
            end
        end
    end

    if not hitFound then
        combo = 0
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

    if key == "escape" then
        returnToMenu()
        return
    end

    local lane = keys[key]

    if lane then
        hitLane(lane)
    end
end

function processHit(diff, lane)
    hits = hits + 1
    notesFinished = notesFinished + 1
    combo = combo + 1
    if combo > maxCombo then maxCombo = combo end

    table.insert(hitParticles, { x = xPositions[lane], y = endY, radius = 25, alpha = 1 })

    if diff < 25 then
        score = score + 1000
        showJudgment("PERFECT", {1, 0.8, 0})
    elseif diff < 55 then
        score = score + 500
        showJudgment("GREAT", {0.2, 1, 0.2})
    else
        score = score + 200
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
                    returnToMenu()
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
