local json = require "json"
local Menu = require "menu"

local gameState = "menu"
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
local frameDelayTarget = 0

local pauseButtons = {
    continue = { x = 0, y = 0, w = 320, h = 60, text = "Continuar" },
    restart = { x = 0, y = 0, w = 320, h = 60, text = "Reiniciar" },
    exit = { x = 0, y = 0, w = 320, h = 60, text = "Salir" }
}

local function settings() return Menu.settings or { eyeCandy = true, framerateCap = 60 } end
local function eyeCandyEnabled() return settings().eyeCandy ~= false end

local function applyFramerateCap()
    local cap = tonumber(settings().framerateCap) or 60
    if cap <= 0 then frameDelayTarget = 0 else frameDelayTarget = 1 / cap end
end

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
        if okAudio and source then bgm = source bgm:setVolume(0.8) else bgm = nil end
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

local function showResults()
    local weightedHitScore = (judgments.marvelous * 1.0) + (judgments.perfect * 0.95) + (judgments.great * 0.75) + (judgments.good * 0.5)
    local accuracy = totalPossibleNotes > 0 and (weightedHitScore / totalPossibleNotes) * 100 or 0
    local grade = (accuracy >= 99 and "S") or (accuracy >= 95 and "A") or (accuracy >= 90 and "B") or (accuracy >= 80 and "C") or "D"
    finalResults = { score = score, maxCombo = maxCombo, accuracy = accuracy, grade = grade }
    gameState = "results"
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
    Menu.loadSettings()
    Menu.load()
    applyFramerateCap()
    layoutPauseButtons()
end

function love.textinput(t)
    if gameState == "menu" then Menu.textinput(t) end
end

function love.keypressed(key)
    if gameState == "menu" then
        Menu.keypressed(key)
        if key == "escape" then love.event.quit() end
        return
    elseif gameState == "results" then
        if key == "return" or key == "space" then returnToMenu() elseif key == "r" then startGame(currentSongInfo) end
        return
    elseif gameState == "pause" then
        if key == "escape" then resumeGame() elseif key == "r" then startGame(currentSongInfo) end
        return
    end
    if key == "escape" then pauseGame() return end
    local lane = keys[key]
    if lane then
        receptorFlashes[lane] = eyeCandyEnabled() and 1 or 0
    end
end

function love.mousepressed(x, y, button)
    if gameState == "menu" then Menu.mousepressed(x, y, button, startGame)
    elseif gameState == "results" and button == 1 then returnToMenu()
    elseif gameState == "pause" and button == 1 then
        if pointInRect(x, y, pauseButtons.continue) then resumeGame()
        elseif pointInRect(x, y, pauseButtons.restart) then startGame(currentSongInfo)
        elseif pointInRect(x, y, pauseButtons.exit) then returnToMenu() end
    end
end

function love.touchpressed(_, x, y)
    local sw, sh = love.graphics.getDimensions(); x, y = x * sw, y * sh
    if gameState == "pause" then
        if pointInRect(x, y, pauseButtons.continue) then resumeGame() elseif pointInRect(x, y, pauseButtons.restart) then startGame(currentSongInfo) elseif pointInRect(x, y, pauseButtons.exit) then returnToMenu() end
        return
    end
    if gameState == "play" and x < 120 and y < 80 then pauseGame(); return end
    if gameState == "menu" then Menu.mousepressed(x, y, 1, startGame) end
end

function love.wheelmoved(x, y) if gameState == "menu" then Menu.wheelmoved(x, y) end end
function love.resize() layoutPauseButtons() end

function love.update(dt)
    applyFramerateCap()
    if gameState == "menu" then Menu.update(dt)
    elseif gameState ~= "results" and gameState ~= "pause" then
        if not bgmStarted then
            songTime = songTime + dt
            if songTime >= 0 then if bgm then bgm:play() end; bgmStarted = true end
        else
            if bgm and bgm:isPlaying() then songTime = bgm:tell() else songTime = songTime + dt; if notesFinished >= totalPossibleNotes and #activeNotes == 0 then endTimer = endTimer + dt if endTimer > 1.5 then showResults() end end end
        end

        local currentBeat = songTime * (bpm / 60)
        local beatInt = math.floor(currentBeat)
        if beatInt > lastBeat then lastBeat = beatInt; if eyeCandyEnabled() then beatFlash = 0.35 end end
        if eyeCandyEnabled() then beatFlash = math.max(0, beatFlash - dt * 2.5) else beatFlash = 0 end

        for i = #chart.notes, 1, -1 do
            local n = chart.notes[i]
            if currentBeat >= n.beat - spawnAheadBeats then
                local duration = (spawnAheadBeats * 60) / bpm
                table.insert(activeNotes, { beat = n.beat, dir = n.dir, speed = travelDistance / duration, y = startY, hit = false })
                table.remove(chart.notes, i)
            end
        end
        for i = #activeNotes, 1, -1 do
            local n = activeNotes[i]; n.y = n.y + n.speed * dt
            if n.y > endY + 60 then notesFinished = notesFinished + 1; table.remove(activeNotes, i); combo = 0; judgments.miss = judgments.miss + 1 end
        end

        if judgment.alpha > 0 then judgment.alpha = judgment.alpha - dt if judgment.scale > 1 then judgment.scale = judgment.scale - dt * 3 end end
        if eyeCandyEnabled() then
            for i = #hitParticles, 1, -1 do local p = hitParticles[i]; p.radius = p.radius + 150 * dt; p.alpha = p.alpha - 3 * dt; if p.alpha <= 0 then table.remove(hitParticles, i) end end
            for i = 1, 4 do if receptorFlashes[i] > 0 then receptorFlashes[i] = math.max(0, receptorFlashes[i] - dt * 4) end end
        else
            hitParticles = {}
            receptorFlashes = {0,0,0,0}
        end
    end

    if frameDelayTarget > 0 then
        local frameTime = love.timer.getDelta()
        if frameTime < frameDelayTarget then love.timer.sleep(frameDelayTarget - frameTime) end
    end
end

function love.draw()
    if gameState == "menu" then Menu.draw(); return end
    local sw, sh = love.graphics.getDimensions()
    if gameState == "results" then
        love.graphics.setColor(0.05, 0.03, 0.09); love.graphics.rectangle("fill", 0, 0, sw, sh)
        love.graphics.setColor(1,1,1); love.graphics.printf("RESULTS",0,80,sw,"center"); love.graphics.printf("Score: "..finalResults.score,0,160,sw,"center")
        return
    end
    local bg = eyeCandyEnabled() and (0.05 + beatFlash) or 0.05
    love.graphics.setColor(bg,bg,bg + 0.03); love.graphics.rectangle("fill",0,0,sw,sh)
    for i,x in ipairs(xPositions) do
        love.graphics.setColor(1,1,1,0.2); love.graphics.circle("line",x,endY,25)
        if eyeCandyEnabled() and receptorFlashes[i] > 0 then love.graphics.setColor(1,1,1,receptorFlashes[i]*0.5); love.graphics.circle("fill",x,endY,25) end
    end
    if eyeCandyEnabled() then
        love.graphics.setLineWidth(2)
        for _,p in ipairs(hitParticles) do love.graphics.setColor(1,1,1,p.alpha); love.graphics.circle("line",p.x,p.y,p.radius) end
        love.graphics.setLineWidth(1)
    end
    if gameState == "pause" then
        love.graphics.setColor(0,0,0,0.65); love.graphics.rectangle("fill",0,0,sw,sh)
        for _,rect in pairs(pauseButtons) do love.graphics.setColor(0.2,0.5,0.7,1); love.graphics.rectangle("fill",rect.x,rect.y,rect.w,rect.h,6); love.graphics.setColor(1,1,1); love.graphics.printf(rect.text,rect.x,rect.y+22,rect.w,"center") end
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
end
