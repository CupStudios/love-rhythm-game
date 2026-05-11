local json = require "json"

local Menu = {
    songs = {},
    selectedIndex = 1,
    hoverIndex = 0,
    scroll = 0,
    layout = nil,
    importMessage = "",
    importMessageTimer = 0,
}

function Menu.setLayout(layout)
    Menu.layout = layout
end

function Menu.load()
    Menu.songs = {}
    love.filesystem.createDirectory("songs")
    local files = love.filesystem.getDirectoryItems("songs")

    for _, file in ipairs(files) do
        if file:lower():match("%.lrg$") then
            local filepath = "songs/" .. file
            local mountPoint = "mount_" .. file:gsub("%W", "")
            if love.filesystem.mount(filepath, mountPoint) then
                local manifestPath = mountPoint .. "/manifest.json"
                if love.filesystem.getInfo(manifestPath) then
                    local manifestData = love.filesystem.read(manifestPath)
                    local success, info = pcall(json.decode, json, manifestData)
                    if success and info then
                        info.filename = file
                        info.artist = info.artist or "Unknown Artist"
                        info.title = info.title or file:gsub("%.lrg$", "")
                        table.insert(Menu.songs, info)
                    end
                end
                love.filesystem.unmount(filepath)
            end
        end
    end

    if #Menu.songs == 0 then Menu.selectedIndex = 0 else Menu.selectedIndex = math.max(1, math.min(Menu.selectedIndex, #Menu.songs)) end
end

function Menu.update(dt)
    if Menu.importMessageTimer > 0 then
        Menu.importMessageTimer = Menu.importMessageTimer - dt
    end

    local itemHeight = 70
    local mx, my = love.mouse.getPosition()
    if Menu.layout then
        mx = (mx - Menu.layout.ox) / Menu.layout.scale
        my = (my - Menu.layout.oy) / Menu.layout.scale
    end

    Menu.hoverIndex = 0
    if mx > 500 then
        local listY = my - Menu.scroll
        local index = math.floor(listY / itemHeight) + 1
        if index >= 1 and index <= #Menu.songs then Menu.hoverIndex = index end
    end
end

function Menu.mousepressed(x, y, button, startGameCallback)
    if button ~= 1 then return end
    if x > 500 then
        if Menu.hoverIndex > 0 then
            if Menu.selectedIndex == Menu.hoverIndex then
                startGameCallback(Menu.songs[Menu.selectedIndex].filename)
            else
                Menu.selectedIndex = Menu.hoverIndex
            end
        end
    else
        local btnX, btnY, btnW, btnH = 50, 580, 400, 60
        if x > btnX and x < btnX + btnW and y > btnY and y < btnY + btnH then
            if #Menu.songs > 0 then startGameCallback(Menu.songs[Menu.selectedIndex].filename) end
        end
    end
end

function Menu.wheelmoved(x, y)
    local viewH = 700
    local listHeight = #Menu.songs * 70
    local minScroll = math.min(0, viewH - listHeight)
    Menu.scroll = math.max(minScroll, math.min(0, Menu.scroll + y * 40))
end

function Menu.draw()
    love.graphics.setColor(0.05, 0.05, 0.08)
    love.graphics.rectangle("fill", 0, 0, 1000, 700)
    love.graphics.setColor(1, 1, 1, 0.2)
    love.graphics.line(500, 0, 500, 700)

    if #Menu.songs == 0 then
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("No .lrg packages found in the 'songs' folder!", 0, 350, 1000, "center")
        return
    end

    local selectedSong = Menu.songs[Menu.selectedIndex]
    love.graphics.setColor(1, 1, 1)
    love.graphics.push(); love.graphics.scale(1.5, 1.5)
    love.graphics.printf(selectedSong.title or "Unknown Title", 30, 30, 280, "left")
    love.graphics.pop()

    love.graphics.setColor(0.7, 0.7, 1)
    love.graphics.print("Artist: " .. selectedSong.artist, 50, 120)
    love.graphics.print("BPM: " .. (selectedSong.bpm or "Unknown"), 50, 160)
    love.graphics.print("File: " .. selectedSong.filename, 50, 200)

    love.graphics.setColor(0.2, 0.6, 0.2)
    love.graphics.rectangle("fill", 50, 580, 400, 60, 5)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("PLAY SONG", 50, 603, 400, "center")

    love.graphics.push()
    love.graphics.translate(0, Menu.scroll)
    for i, song in ipairs(Menu.songs) do
        local y = (i - 1) * 70
        if i == Menu.selectedIndex then
            love.graphics.setColor(0.3, 0.5, 1, 0.4)
        elseif i == Menu.hoverIndex then
            love.graphics.setColor(1, 1, 1, 0.1)
        else
            love.graphics.setColor(0, 0, 0, 0)
        end
        love.graphics.rectangle("fill", 500, y, 500, 70)
        love.graphics.setColor(1, 1, 1, 0.1)
        love.graphics.rectangle("line", 500, y, 500, 70)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(song.title or song.filename, 525, y + 15)
        love.graphics.setColor(0.6, 0.6, 0.6)
        love.graphics.print("BPM: " .. (song.bpm or "?"), 525, y + 40)
    end
    love.graphics.pop()
end

return Menu
