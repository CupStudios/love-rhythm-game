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
    onlineStatusTimer = 0
}

local importButton = { x = 50, y = 0, w = 0, h = 60 }
local onlineButton = { x = 50, y = 0, w = 0, h = 60 }
local backButton = { x = 50, y = 0, w = 220, h = 60 }

Menu.importMessage = ""
Menu.importMessageTimer = 0

local androidImportPaths = {
    "/storage/emulated/0/Download",
    "/storage/emulated/0/Documents",
    "/storage/emulated/0/Android/data/org.love2d.android/files/save/songs",
    "/storage/emulated/0/Android/data/org.love2d.android/lovegame/songs"
}

local SONGS_API = "http://mi-servidor-local:8080/songs.json"
local FILES_API_BASE = "http://mi-servidor-local:8080/files/"
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

local function ensureDownloadThread()
    if not downloadThread then
        downloadThread = love.thread.newThread("download_thread.lua")
        downloadThread:start()
    end
end

local function parseOnlineSongsJson(body)
    local ok, decoded = pcall(json.decode, json, body)
    if not ok or type(decoded) ~= "table" then
        return nil
    end

    local songs = {}
    for _, item in ipairs(decoded) do
        if type(item) == "table" and item.file then
            table.insert(songs, {
                title = item.title or item.file,
                file = item.file
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
                    if fileData then
                        love.filesystem.write(targetFolder .. "/" .. item, fileData)
                    end
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

    if Menu.selectedIndex > #Menu.songs then
        Menu.selectedIndex = math.max(1, #Menu.songs)
    end
end

function Menu.fetchOnlineSongs()
    Menu.onlineStatus = "Cargando lista online..."
    Menu.onlineStatusTimer = 4

    local chunks = {}
    local _, code = http.request({ url = SONGS_API, sink = ltn12.sink.table(chunks) })
    if code ~= 200 then
        Menu.onlineStatus = "Error cargando songs.json (HTTP " .. tostring(code) .. ")"
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
    Menu.onlineStatus = "Lista online cargada"
    return true
end

function Menu.downloadOnlineSong(song)
    if not song or not song.file then return end
    ensureDownloadThread()

    local url = FILES_API_BASE .. song.file
    love.thread.getChannel("download_request"):push(url .. "|" .. song.file)
    Menu.onlineStatus = "Descargando " .. song.file .. "..."
    Menu.onlineStatusTimer = 6
end

function Menu.importLRG(path)
    if not path then return false end
    local filename = path:match("([^/]+%.lrg)$")
    if not filename then
        Menu.importMessage = "Invalid .lrg file"
        Menu.importMessageTimer = 3
        return false
    end

    if not copyFileFromAbsolutePath(path, "songs/" .. filename) then
        Menu.importMessage = "Cannot open file"
        Menu.importMessageTimer = 3
        return false
    end

    Menu.importMessage = "Imported: " .. filename
    Menu.importMessageTimer = 3
    Menu.load()
    return true
end

function Menu.importFromAndroidFolders()
    local importedCount = 0
    love.filesystem.createDirectory("songs")

    for _, folder in ipairs(androidImportPaths) do
        local command = string.format('ls -1 "%s" 2>/dev/null', folder)
        local pipe = io.popen(command)
        if pipe then
            for entry in pipe:lines() do
                if entry:lower():match("%.lrg$") then
                    local sourcePath = folder .. "/" .. entry
                    local destination = "songs/" .. entry
                    if not love.filesystem.getInfo(destination) and copyFileFromAbsolutePath(sourcePath, destination) then
                        importedCount = importedCount + 1
                    end
                end
            end
            pipe:close()
        end
    end

    if importedCount > 0 then
        Menu.importMessage = string.format("Imported %d song(s) from Android folders", importedCount)
        Menu.importMessageTimer = 4
        Menu.load()
        return true
    end

    Menu.importMessage = "No .lrg files found. Put songs in Download or Android/data/.../songs"
    Menu.importMessageTimer = 5
    return false
end

function Menu.importFromAndroidFolders()
    local importedCount = 0
    love.filesystem.createDirectory("songs")

    for _, folder in ipairs(androidImportPaths) do
        local command = string.format('ls -1 "%s" 2>/dev/null', folder)
        local pipe = io.popen(command)
        if pipe then
            for entry in pipe:lines() do
                if entry:lower():match("%.lrg$") then
                    local sourcePath = folder .. "/" .. entry
                    local destination = "songs/" .. entry
                    if not love.filesystem.getInfo(destination) and copyFileFromAbsolutePath(sourcePath, destination) then
                        importedCount = importedCount + 1
                    end
                end
            end
            pipe:close()
        end
    end

    if importedCount > 0 then
        Menu.importMessage = string.format("Imported %d song(s) from Android folders", importedCount)
        Menu.importMessageTimer = 4
        Menu.load()
        return true
    end

    Menu.importMessage = "No .lrg files found. Put songs in Download or Android/data/.../songs"
    Menu.importMessageTimer = 5
    return false
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
                Menu.onlineStatusTimer = 5
            elseif kind == "progress" then
                Menu.onlineStatus = msg
                Menu.onlineStatusTimer = 3
            end
        end
    end

    local sw = love.graphics.getWidth()
    local itemHeight = 70
    local mouseX, mouseY = love.mouse.getPosition()

    if Menu.state == "local" then
        Menu.hoverIndex = 0
        if mouseX > sw / 2 then
            local index = math.floor((mouseY - Menu.scroll) / itemHeight) + 1
            if index >= 1 and index <= #Menu.songs then
                Menu.hoverIndex = index
            end
        end
    else
        Menu.onlineHoverIndex = 0
        if mouseX > sw / 2 then
            local index = math.floor((mouseY - Menu.onlineScroll) / itemHeight) + 1
            if index >= 1 and index <= #Menu.onlineSongs then
                Menu.onlineHoverIndex = index
            end
        end
    end
end

function Menu.mousepressed(x, y, button, startGameCallback)
    if button ~= 1 then return end

    local sw, sh = love.graphics.getDimensions()
    local rightPanelX = sw / 2
    local itemHeight = 70

    if Menu.state == "online" then
        if x > backButton.x and x < backButton.x + backButton.w and y > backButton.y and y < backButton.y + backButton.h then
            Menu.state = "local"
            return
        end

        if x > rightPanelX then
            local idx = math.floor((y - Menu.onlineScroll) / itemHeight) + 1
            if idx >= 1 and idx <= #Menu.onlineSongs then
                Menu.onlineSelectedIndex = idx
                local song = Menu.onlineSongs[idx]
                if x > sw - 190 and x < sw - 30 then
                    Menu.downloadOnlineSong(song)
                end
            end
        end
        return
    end

    if love.system.getOS() == "Android" then
        if x > importButton.x and x < importButton.x + importButton.w and y > importButton.y and y < importButton.y + importButton.h then
            Menu.importFromAndroidFolders()
            return
        end
    end

    if x > onlineButton.x and x < onlineButton.x + onlineButton.w and y > onlineButton.y and y < onlineButton.y + onlineButton.h then
        Menu.state = "online"
        Menu.fetchOnlineSongs()
        return
    end

    if x > rightPanelX then
        local calculatedIndex = math.floor((y - Menu.scroll) / itemHeight) + 1
        if calculatedIndex >= 1 and calculatedIndex <= #Menu.songs then
            if Menu.selectedIndex == calculatedIndex then
                startGameCallback(Menu.songs[Menu.selectedIndex])
            else
                Menu.selectedIndex = calculatedIndex
            end
        end
    else
        local btnX, btnY, btnW, btnH = 50, sh - 120, sw/2 - 100, 60
        if x > btnX and x < btnX + btnW and y > btnY and y < btnY + btnH then
            if #Menu.songs > 0 and Menu.songs[Menu.selectedIndex] then
                startGameCallback(Menu.songs[Menu.selectedIndex])
            end
        end
    end
end

function Menu.wheelmoved(_, y)
    local _, sh = love.graphics.getDimensions()
    local itemHeight = 70
    if Menu.state == "local" then
        local minScroll = math.min(0, sh - (#Menu.songs * itemHeight))
        Menu.scroll = math.max(minScroll, math.min(0, Menu.scroll + y * 40))
    else
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

    if Menu.state == "online" then
        backButton.x = 50
        backButton.y = sh - 120
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
            love.graphics.setColor(1, 1, 1)
            love.graphics.print(song.title or song.file, rightPanelX + 25, itemY + 15)

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

    if #Menu.songs == 0 then
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("No .lrg packages found in the 'songs' folder!", 0, sh/2, sw, "center")
    else
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
    end

    local btnX, btnY, btnW, btnH = 50, sh - 120, sw/2 - 100, 60
    love.graphics.setColor(0.2, 0.6, 0.2)
    love.graphics.rectangle("fill", btnX, btnY, btnW, btnH, 5)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("PLAY SONG", btnX, btnY + 23, btnW, "center")

    onlineButton.x = 50
    onlineButton.y = sh - 260
    onlineButton.w = sw/2 - 100
    love.graphics.setColor(0.7, 0.5, 0.2)
    love.graphics.rectangle("fill", onlineButton.x, onlineButton.y, onlineButton.w, onlineButton.h, 5)
    love.graphics.setColor(1,1,1)
    love.graphics.printf("ONLINE SONGS", onlineButton.x, onlineButton.y + 23, onlineButton.w, "center")

    if love.system.getOS() == "Android" then
        importButton.x = 50
        importButton.y = sh - 190
        importButton.w = sw/2 - 100
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
        if i == Menu.selectedIndex then
            love.graphics.setColor(0.3, 0.5, 1, 0.4)
        elseif i == Menu.hoverIndex then
            love.graphics.setColor(1, 1, 1, 0.1)
        else
            love.graphics.setColor(0, 0, 0, 0)
        end
        love.graphics.rectangle("fill", rightPanelX, itemY, sw/2, itemHeight)
        love.graphics.setColor(1, 1, 1, 0.1)
        love.graphics.rectangle("line", rightPanelX, itemY, sw/2, itemHeight)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(song.title or song.filename, rightPanelX + 25, itemY + 15)
        love.graphics.setColor(0.6, 0.6, 0.6)
        love.graphics.print("BPM: " .. (song.bpm or "?"), rightPanelX + 25, itemY + 40)
    end
    love.graphics.pop()
end

return Menu
