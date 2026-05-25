local json = require "json"
local http = require("socket.http")
local ltn12 = require("ltn12")

local Menu = {
    songs = {},
    selectedIndex = 1,
    hoverIndex = 0,
    scroll = 0,
    state = "local",
    onlineSongs = {},
    onlineSelectedIndex = 1,
    onlineHoverIndex = 0,
    onlineScroll = 0,
    onlineStatus = "",
    onlineStatusTimer = 0,
    settings = {
        repositoryUrl = "http://192.168.1.X:3000",
        eyeCandy = true,
        framerateCap = 60
    },
    settingsInputActive = false
}

local importButton = { x = 50, y = 0, w = 0, h = 60 }
local onlineButton = { x = 50, y = 0, w = 0, h = 60 }
local settingsButton = { x = 50, y = 0, w = 0, h = 60 }
local backButton = { x = 50, y = 0, w = 220, h = 60 }
local saveSettingsButton = { x = 50, y = 0, w = 300, h = 60 }
local eyeCandyButton = { x = 0, y = 0, w = 220, h = 50 }
local fpsButtons = {}
local repositoryInputBox = { x = 0, y = 0, w = 0, h = 50 }

Menu.importMessage = ""
Menu.importMessageTimer = 0

local androidImportPaths = {
    "/storage/emulated/0/Download",
    "/storage/emulated/0/Documents",
    "/storage/emulated/0/Android/data/org.love2d.android/files/save/songs",
    "/storage/emulated/0/Android/data/org.love2d.android/lovegame/songs"
}

local downloadThread

local function copyFileFromAbsolutePath(path, destination)
    local file = io.open(path, "rb")
    if not file then return false end
    local data = file:read("*all")
    file:close()
    if not data or #data == 0 then return false end
    return love.filesystem.write(destination, data)
end

local function getSongDisplayValue(song, key, fallback)
    local value = song and song[key]
    if value == nil or value == "" then return fallback end
    return tostring(value)
end

local function settingsPath()
    return "settings.json"
end

function Menu.saveSettings()
    local ok = love.filesystem.write(settingsPath(), json.encode(Menu.settings))
    if ok then
        Menu.onlineStatus = "Configuración guardada"
        Menu.onlineStatusTimer = 3
    end
end

function Menu.loadSettings()
    local defaults = {
        repositoryUrl = "http://192.168.1.X:3000",
        eyeCandy = true,
        framerateCap = 60
    }

    if love.filesystem.getInfo(settingsPath()) then
        local data = love.filesystem.read(settingsPath())
        if data then
            local ok, decoded = pcall(json.decode, json, data)
            if ok and type(decoded) == "table" then
                defaults.repositoryUrl = decoded.repositoryUrl or defaults.repositoryUrl
                defaults.eyeCandy = decoded.eyeCandy ~= false
                defaults.framerateCap = decoded.framerateCap or defaults.framerateCap
            end
        end
    else
        love.filesystem.write(settingsPath(), json.encode(defaults))
    end

    Menu.settings = defaults
end

local function ensureDownloadThread()
    if not downloadThread then
        downloadThread = love.thread.newThread("download_thread.lua")
        downloadThread:start()
    end
end

local function parseOnlineSongsJson(body)
    local ok, decoded = pcall(json.decode, json, body)
    if not ok or type(decoded) ~= "table" then return nil end
    local songs = {}
    for _, item in ipairs(decoded) do
        if type(item) == "table" and item.filename then
            table.insert(songs, {
                title = item.title or item.filename,
                artist = item.artist or "Unknown",
                bpm = item.bpm or "?",
                file = item.filename,
                size = item.size or 0
            })
        end
    end
    return songs
end

function Menu.load()
    Menu.songs = {}
    love.filesystem.createDirectory("songs")
    love.filesystem.createDirectory("extracted_songs")

    local files = love.filesystem.getDirectoryItems("songs")
    for _, file in ipairs(files) do
        if file:lower():match("%.lrg$") then
            local filepath = "songs/" .. file
            local folderName = file:gsub("%W", "")
            local targetFolder = "extracted_songs/" .. folderName
            love.filesystem.createDirectory(targetFolder)

            local tempMount = "temp_" .. folderName
            if love.filesystem.mount(filepath, tempMount) then
                local insideItems = love.filesystem.getDirectoryItems(tempMount)
                local sourceSubfolder = ""
                if #insideItems == 1 and love.filesystem.getInfo(tempMount .. "/" .. insideItems[1]).type == "directory" then
                    sourceSubfolder = insideItems[1] .. "/"
                    insideItems = love.filesystem.getDirectoryItems(tempMount .. "/" .. insideItems[1])
                end
                for _, item in ipairs(insideItems) do
                    local fileData = love.filesystem.read(tempMount .. "/" .. sourceSubfolder .. item)
                    if fileData then love.filesystem.write(targetFolder .. "/" .. item, fileData) end
                end
                love.filesystem.unmount(filepath)

                local manifestPath = targetFolder .. "/manifest.json"
                if love.filesystem.getInfo(manifestPath) then
                    local manifestData = love.filesystem.read(manifestPath)
                    if manifestData then
                        local ok, decoded = pcall(json.decode, json, manifestData)
                        if ok and decoded then
                            decoded.filename = file
                            decoded.folderPath = targetFolder
                            table.insert(Menu.songs, decoded)
                        end
                    end
                end
            end
        end
    end

    Menu.selectedIndex = math.min(Menu.selectedIndex, math.max(1, #Menu.songs))
end

function Menu.fetchOnlineSongs()
    local baseUrl = Menu.settings.repositoryUrl
    local endpoint = baseUrl .. "/api/songs"
    Menu.onlineStatus = "Cargando canciones del servidor..."
    local chunks = {}
    local _, code = http.request({ url = endpoint, sink = ltn12.sink.table(chunks) })
    if code ~= 200 then
        Menu.onlineStatus = "Error HTTP " .. tostring(code)
        return false
    end

    local songs = parseOnlineSongsJson(table.concat(chunks))
    if not songs then
        Menu.onlineStatus = "JSON inválido del servidor"
        return false
    end

    Menu.onlineSongs = songs
    Menu.onlineSelectedIndex = 1
    Menu.onlineScroll = 0
    Menu.onlineStatus = "Catálogo cargado"
    Menu.onlineStatusTimer = 3
    return true
end

function Menu.downloadOnlineSong(song)
    if not song or not song.file then return end
    ensureDownloadThread()
    local url = Menu.settings.repositoryUrl .. "/api/download/" .. song.file
    love.thread.getChannel("download_request"):push(url .. "|" .. song.file)
    Menu.onlineStatus = "Descargando " .. song.file .. "..."
    Menu.onlineStatusTimer = 6
end

function Menu.importFromAndroidFolders()
    local importedCount = 0
    love.filesystem.createDirectory("songs")
    for _, folder in ipairs(androidImportPaths) do
        local pipe = io.popen(string.format('ls -1 "%s" 2>/dev/null', folder))
        if pipe then
            for entry in pipe:lines() do
                if entry:lower():match("%.lrg$") then
                    local src = folder .. "/" .. entry
                    local dst = "songs/" .. entry
                    if not love.filesystem.getInfo(dst) and copyFileFromAbsolutePath(src, dst) then
                        importedCount = importedCount + 1
                    end
                end
            end
            pipe:close()
        end
    end
    if importedCount > 0 then
        Menu.importMessage = string.format("Imported %d song(s)", importedCount)
        Menu.importMessageTimer = 4
        Menu.load()
    else
        Menu.importMessage = "No se encontraron .lrg"
        Menu.importMessageTimer = 4
    end
end

function Menu.update(dt)
    if Menu.importMessageTimer > 0 then Menu.importMessageTimer = Menu.importMessageTimer - dt end
    if Menu.onlineStatusTimer > 0 then Menu.onlineStatusTimer = Menu.onlineStatusTimer - dt end

    local statusChannel = love.thread.getChannel("download_status")
    while statusChannel:getCount() > 0 do
        local event = statusChannel:pop()
        if event then
            local kind, msg = event:match("^(.-)|(.+)$")
            if kind == "done" then
                Menu.onlineStatus = "¡Descarga completada! " .. msg
                Menu.onlineStatusTimer = 4
                Menu.load()
            elseif kind == "error" then
                Menu.onlineStatus = "Error: " .. msg
                Menu.onlineStatusTimer = 4
            elseif kind == "progress" then
                Menu.onlineStatus = msg
                Menu.onlineStatusTimer = 2
            end
        end
    end

    local sw = love.graphics.getWidth()
    local itemHeight = 70
    local mouseX, mouseY = love.mouse.getPosition()

    if Menu.state == "local" then
        Menu.hoverIndex = 0
        if mouseX > sw / 2 then
            local idx = math.floor((mouseY - Menu.scroll) / itemHeight) + 1
            if idx >= 1 and idx <= #Menu.songs then Menu.hoverIndex = idx end
        end
    elseif Menu.state == "online" then
        Menu.onlineHoverIndex = 0
        if mouseX > sw / 2 then
            local idx = math.floor((mouseY - Menu.onlineScroll) / itemHeight) + 1
            if idx >= 1 and idx <= #Menu.onlineSongs then Menu.onlineHoverIndex = idx end
        end
    end
end

function Menu.mousepressed(x, y, button, startGameCallback)
    if button ~= 1 then return end
    local sw, sh = love.graphics.getDimensions()
    local rightPanelX = sw / 2
    local itemHeight = 70

    if Menu.state == "settings" then
        -- Campo de texto seleccionable para editar URL del repositorio.
        Menu.settingsInputActive = x > repositoryInputBox.x and x < repositoryInputBox.x + repositoryInputBox.w and y > repositoryInputBox.y and y < repositoryInputBox.y + repositoryInputBox.h

        if x > eyeCandyButton.x and x < eyeCandyButton.x + eyeCandyButton.w and y > eyeCandyButton.y and y < eyeCandyButton.y + eyeCandyButton.h then
            Menu.settings.eyeCandy = not Menu.settings.eyeCandy
        end

        for _, btn in ipairs(fpsButtons) do
            if x > btn.x and x < btn.x + btn.w and y > btn.y and y < btn.y + btn.h then
                Menu.settings.framerateCap = btn.value
            end
        end

        if x > saveSettingsButton.x and x < saveSettingsButton.x + saveSettingsButton.w and y > saveSettingsButton.y and y < saveSettingsButton.y + saveSettingsButton.h then
            Menu.saveSettings()
            Menu.state = "local"
            Menu.settingsInputActive = false
        end
        return
    end

    if Menu.state == "online" then
        if x > backButton.x and x < backButton.x + backButton.w and y > backButton.y and y < backButton.y + backButton.h then
            Menu.state = "local"
            return
        end
        if x > rightPanelX then
            local idx = math.floor((y - Menu.onlineScroll) / itemHeight) + 1
            if idx >= 1 and idx <= #Menu.onlineSongs then
                Menu.onlineSelectedIndex = idx
                if x > sw - 190 and x < sw - 30 then Menu.downloadOnlineSong(Menu.onlineSongs[idx]) end
            end
        end
        return
    end

    if love.system.getOS() == "Android" and x > importButton.x and x < importButton.x + importButton.w and y > importButton.y and y < importButton.y + importButton.h then
        Menu.importFromAndroidFolders()
        return
    end

    if x > onlineButton.x and x < onlineButton.x + onlineButton.w and y > onlineButton.y and y < onlineButton.y + onlineButton.h then
        Menu.state = "online"
        Menu.fetchOnlineSongs()
        return
    end

    if x > settingsButton.x and x < settingsButton.x + settingsButton.w and y > settingsButton.y and y < settingsButton.y + settingsButton.h then
        Menu.state = "settings"
        Menu.settingsInputActive = false
        return
    end

    if x > rightPanelX then
        local idx = math.floor((y - Menu.scroll) / itemHeight) + 1
        if idx >= 1 and idx <= #Menu.songs then
            if Menu.selectedIndex == idx then startGameCallback(Menu.songs[idx]) else Menu.selectedIndex = idx end
        end
    else
        local btnX, btnY, btnW, btnH = 50, sh - 120, sw/2 - 100, 60
        if x > btnX and x < btnX + btnW and y > btnY and y < btnY + btnH and Menu.songs[Menu.selectedIndex] then
            startGameCallback(Menu.songs[Menu.selectedIndex])
        end
    end
end

function Menu.textinput(t)
    -- Manejo de input de texto para la URL del repositorio en settings.
    if Menu.state == "settings" and Menu.settingsInputActive then
        Menu.settings.repositoryUrl = (Menu.settings.repositoryUrl or "") .. t
    end
end

function Menu.keypressed(key)
    if Menu.state == "settings" and Menu.settingsInputActive then
        if key == "backspace" then
            local s = Menu.settings.repositoryUrl or ""
            Menu.settings.repositoryUrl = s:sub(1, -2)
        elseif key == "return" then
            Menu.settingsInputActive = false
        end
    end
end

function Menu.wheelmoved(_, y)
    local _, sh = love.graphics.getDimensions()
    local itemHeight = 70
    if Menu.state == "local" then
        local minScroll = math.min(0, sh - (#Menu.songs * itemHeight))
        Menu.scroll = math.max(minScroll, math.min(0, Menu.scroll + y * 40))
    elseif Menu.state == "online" then
        local minScroll = math.min(0, sh - (#Menu.onlineSongs * itemHeight))
        Menu.onlineScroll = math.max(minScroll, math.min(0, Menu.onlineScroll + y * 40))
    end
end

function Menu.draw()
    local sw, sh = love.graphics.getDimensions()
    love.graphics.setColor(0.05, 0.05, 0.08)
    love.graphics.rectangle("fill", 0, 0, sw, sh)
    love.graphics.setColor(1, 1, 1, 0.2)
    love.graphics.line(sw/2, 0, sw/2, sh)

    if Menu.state == "settings" then
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("CONFIGURACIÓN", 0, 40, sw, "center")

        eyeCandyButton.x, eyeCandyButton.y = 60, 120
        love.graphics.setColor(0.25, 0.5, 0.8)
        love.graphics.rectangle("fill", eyeCandyButton.x, eyeCandyButton.y, eyeCandyButton.w, eyeCandyButton.h, 6)
        love.graphics.setColor(1,1,1)
        love.graphics.printf("Eye Candy: " .. (Menu.settings.eyeCandy and "ON" or "OFF"), eyeCandyButton.x, eyeCandyButton.y + 16, eyeCandyButton.w, "center")

        love.graphics.setColor(1,1,1)
        love.graphics.print("Límite FPS:", 60, 200)
        local caps = {30, 60, 120, 0}
        fpsButtons = {}
        for i, cap in ipairs(caps) do
            local b = {x = 60 + (i-1)*120, y = 230, w = 100, h = 45, value = cap}
            table.insert(fpsButtons, b)
            local active = Menu.settings.framerateCap == cap
            love.graphics.setColor(active and 0.2 or 0.15, active and 0.8 or 0.3, 0.3, 1)
            love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 6)
            love.graphics.setColor(1,1,1)
            love.graphics.printf(cap == 0 and "∞" or tostring(cap), b.x, b.y + 14, b.w, "center")
        end

        love.graphics.setColor(1,1,1)
        love.graphics.print("URL del repositorio:", 60, 310)
        repositoryInputBox.x, repositoryInputBox.y, repositoryInputBox.w = 60, 340, sw - 120
        love.graphics.setColor(Menu.settingsInputActive and 0.2 or 0.1, 0.2, 0.3, 1)
        love.graphics.rectangle("fill", repositoryInputBox.x, repositoryInputBox.y, repositoryInputBox.w, repositoryInputBox.h, 6)
        love.graphics.setColor(1,1,1)
        love.graphics.printf(Menu.settings.repositoryUrl, repositoryInputBox.x + 10, repositoryInputBox.y + 16, repositoryInputBox.w - 20, "left")

        saveSettingsButton.x, saveSettingsButton.y = 60, sh - 110
        love.graphics.setColor(0.3, 0.6, 0.3)
        love.graphics.rectangle("fill", saveSettingsButton.x, saveSettingsButton.y, saveSettingsButton.w, saveSettingsButton.h, 6)
        love.graphics.setColor(1,1,1)
        love.graphics.printf("Guardar y Volver", saveSettingsButton.x, saveSettingsButton.y + 20, saveSettingsButton.w, "center")
        return
    end

    if Menu.state == "online" then
        backButton.x, backButton.y = 50, sh - 120
        love.graphics.setColor(0.5, 0.3, 0.8)
        love.graphics.rectangle("fill", backButton.x, backButton.y, backButton.w, backButton.h, 6)
        love.graphics.setColor(1,1,1)
        love.graphics.printf("VOLVER", backButton.x, backButton.y + 22, backButton.w, "center")

        love.graphics.setColor(1,1,1)
        love.graphics.printf("Catálogo Online", 50, 40, sw/2 - 100, "left")

        local rightPanelX = sw / 2
        local itemHeight = 70
        love.graphics.push()
        love.graphics.translate(0, Menu.onlineScroll)
        for i, song in ipairs(Menu.onlineSongs) do
            local itemY = (i - 1) * itemHeight
            love.graphics.setColor(i == Menu.onlineSelectedIndex and 0.3 or 0.1, 0.3, 0.6, 0.5)
            love.graphics.rectangle("fill", rightPanelX, itemY, sw/2, itemHeight)
            love.graphics.setColor(1,1,1)
            love.graphics.print((song.title or song.file) .. " - " .. tostring(song.artist), rightPanelX + 20, itemY + 10)
            love.graphics.print("BPM: " .. tostring(song.bpm) .. " | " .. math.floor((song.size or 0)/1024) .. "KB", rightPanelX + 20, itemY + 35)
            love.graphics.setColor(0.2, 0.7, 0.3)
            love.graphics.rectangle("fill", sw - 190, itemY + 15, 160, 40, 4)
            love.graphics.setColor(1,1,1)
            love.graphics.printf("DESCARGAR", sw - 190, itemY + 28, 160, "center")
        end
        love.graphics.pop()

        if Menu.onlineStatusTimer > 0 then
            love.graphics.setColor(1,1,1)
            love.graphics.printf(Menu.onlineStatus, 0, sh - 40, sw, "center")
        end
        return
    end

    if #Menu.songs > 0 then
        local selectedSong = Menu.songs[Menu.selectedIndex]
        love.graphics.setColor(1, 1, 1)
        love.graphics.push()
        love.graphics.scale(1.5, 1.5)
        love.graphics.printf(selectedSong.title or "Unknown Title", 30, 30, (sw/3) - 60, "left")
        love.graphics.pop()
        love.graphics.setColor(0.7, 0.7, 1)
        love.graphics.print("Artist: " .. getSongDisplayValue(selectedSong, "artist", "Unknown Artist"), 50, 120)
        love.graphics.print("BPM: " .. getSongDisplayValue(selectedSong, "bpm", "Unknown"), 50, 160)
        love.graphics.print("File: " .. getSongDisplayValue(selectedSong, "filename", "Unknown"), 50, 200)
    else
        love.graphics.setColor(1,1,1)
        love.graphics.printf("No .lrg found", 0, sh/2, sw, "center")
    end

    local btnX, btnY, btnW, btnH = 50, sh - 120, sw/2 - 100, 60
    love.graphics.setColor(0.2, 0.6, 0.2)
    love.graphics.rectangle("fill", btnX, btnY, btnW, btnH, 5)
    love.graphics.setColor(1,1,1)
    love.graphics.printf("PLAY SONG", btnX, btnY + 23, btnW, "center")

    onlineButton.x, onlineButton.y, onlineButton.w = 50, sh - 260, sw/2 - 100
    love.graphics.setColor(0.7, 0.5, 0.2)
    love.graphics.rectangle("fill", onlineButton.x, onlineButton.y, onlineButton.w, onlineButton.h, 5)
    love.graphics.setColor(1,1,1)
    love.graphics.printf("ONLINE SONGS", onlineButton.x, onlineButton.y + 23, onlineButton.w, "center")

    settingsButton.x, settingsButton.y, settingsButton.w = 50, sh - 330, sw/2 - 100
    love.graphics.setColor(0.35, 0.35, 0.75)
    love.graphics.rectangle("fill", settingsButton.x, settingsButton.y, settingsButton.w, settingsButton.h, 5)
    love.graphics.setColor(1,1,1)
    love.graphics.printf("CONFIGURACIÓN", settingsButton.x, settingsButton.y + 23, settingsButton.w, "center")

    if love.system.getOS() == "Android" then
        importButton.x, importButton.y, importButton.w = 50, sh - 190, sw/2 - 100
        love.graphics.setColor(0.2, 0.4, 0.8)
        love.graphics.rectangle("fill", importButton.x, importButton.y, importButton.w, importButton.h, 5)
        love.graphics.setColor(1,1,1)
        love.graphics.printf("IMPORT .LRG", importButton.x, importButton.y + 23, importButton.w, "center")
    end

    if Menu.importMessageTimer > 0 then
        love.graphics.setColor(1,1,1)
        love.graphics.printf(Menu.importMessage, 0, sh - 40, sw, "center")
    end

    local rightPanelX = sw / 2
    local itemHeight = 70
    love.graphics.push()
    love.graphics.translate(0, Menu.scroll)
    for i, song in ipairs(Menu.songs) do
        local itemY = (i - 1) * itemHeight
        if i == Menu.selectedIndex then love.graphics.setColor(0.3, 0.5, 1, 0.4)
        elseif i == Menu.hoverIndex then love.graphics.setColor(1,1,1,0.1)
        else love.graphics.setColor(0,0,0,0) end
        love.graphics.rectangle("fill", rightPanelX, itemY, sw/2, itemHeight)
        love.graphics.setColor(1,1,1,0.1)
        love.graphics.rectangle("line", rightPanelX, itemY, sw/2, itemHeight)
        love.graphics.setColor(1,1,1)
        love.graphics.print(song.title or song.filename, rightPanelX + 25, itemY + 15)
        love.graphics.setColor(0.6,0.6,0.6)
        love.graphics.print("BPM: " .. (song.bpm or "?"), rightPanelX + 25, itemY + 40)
    end
    love.graphics.pop()
end

return Menu
