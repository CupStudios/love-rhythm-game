local json = require "json"

local Menu = {
    songs = {},
    selectedIndex = 1,
    hoverIndex = 0,
    scroll = 0
}

local importButton = {
    x = 50,
    y = 0,
    w = 0,
    h = 60
}

Menu.importMessage = ""
Menu.importMessageTimer = 0

function Menu.load()
    Menu.songs = {}
    
    -- 1. Ensure the directory exists
    love.filesystem.createDirectory("songs")
    
    -- 2. Get all items in the folder
    local files = love.filesystem.getDirectoryItems("songs")
    
    for _, file in ipairs(files) do
        if file:lower():match("%.lrg$") then
            local filepath = "songs/" .. file
            -- Generate a safe, unique mount point
            local mountPoint = "mount_" .. file:gsub("%W", "")
            
            if love.filesystem.mount(filepath, mountPoint) then
                -- 3. Look for manifest.json (Root OR Subfolder)
                local manifestPath = nil
                local topLevelItems = love.filesystem.getDirectoryItems(mountPoint)
                
                for _, item in ipairs(topLevelItems) do
                    if item == "manifest.json" then
                        manifestPath = mountPoint .. "/manifest.json"
                        break
                    elseif love.filesystem.getInfo(mountPoint .. "/" .. item .. "/manifest.json") then
                        manifestPath = mountPoint .. "/" .. item .. "/manifest.json"
                        -- Store the subfolder prefix so we can load assets correctly later
                        -- (You'll need this to find the .ogg inside that subfolder)
                        mountPoint = mountPoint .. "/" .. item 
                        break
                    end
                end

                -- 4. Process the manifest if found
                if manifestPath then
                    local manifestData = love.filesystem.read(manifestPath)
                    local success, info = pcall(json.decode, json, manifestData)
                    
                    if success and info then
                        info.filename = file
                        info.artist = info.artist or "Unknown Artist"
                        info.title = info.title or file:gsub("%.lrg$", "")
                        -- Store the internal path so the game knows where to look for audio/chart
                        info.mountPath = mountPoint 
                        
                        table.insert(Menu.songs, info)
                        print("Loaded: " .. info.title)
                    else
                        print("Error: JSON Decode failed in " .. file)
                    end
                else
                    print("Error: No manifest.json found in " .. file)
                end
                
                -- 5. Unmount to keep things clean
                love.filesystem.unmount(filepath)
            else
                print("Error: Failed to mount " .. file)
            end
        end
    end

    if #Menu.songs == 0 then
        Menu.selectedIndex = 0
    else
        Menu.selectedIndex = math.max(1, math.min(Menu.selectedIndex, #Menu.songs))
    end
end

function Menu.importLRG(path)
    if not path then
        return false
    end

    local filename = path:match("([^/]+%.lrg)$")

    if not filename then
        Menu.importMessage = "Invalid .lrg file"
        Menu.importMessageTimer = 3
        return false
    end

    local file = io.open(path, "rb")

    if not file then
        Menu.importMessage = "Cannot open file"
        Menu.importMessageTimer = 3
        return false
    end

    local data = file:read("*all")
    file:close()

    love.filesystem.createDirectory("songs")

    love.filesystem.write("songs/" .. filename, data)

    Menu.importMessage = "Imported: " .. filename
    Menu.importMessageTimer = 3

    Menu.load()

    return true
end

function Menu.update(dt)
    if Menu.importMessageTimer > 0 then
       Menu.importMessageTimer = Menu.importMessageTimer - dt
    end
    
    local sw, sh = love.graphics.getDimensions()
    local rightPanelX = sw / 2
    local itemHeight = 70
    local mouseX, mouseY = love.mouse.getPosition()

    Menu.hoverIndex = 0
    -- Check if hovering over the right panel
    if mouseX > rightPanelX then
        local listY = mouseY - Menu.scroll
        local index = math.floor(listY / itemHeight) + 1
        if index >= 1 and index <= #Menu.songs then
            Menu.hoverIndex = index
        end
    end
end

function Menu.mousepressed(x, y, button, startGameCallback)
    local sw, sh = love.graphics.getDimensions()
    local rightPanelX = sw / 2

    -- IMPORT BUTTON
if love.system.getOS() == "Android" then
    if x > importButton.x and x < importButton.x + importButton.w and
       y > importButton.y and y < importButton.y + importButton.h then

        -- Opens Android file picker area
        love.system.openURL("file:///storage/emulated/0/Download/")
        return
    end
end

    if button == 1 then
        if x > rightPanelX then
            if Menu.hoverIndex > 0 then
                -- Double click a song to play, or select it if not selected
                if Menu.selectedIndex == Menu.hoverIndex then
                    startGameCallback(Menu.songs[Menu.selectedIndex].filename)
                else
                    Menu.selectedIndex = Menu.hoverIndex
                end
            end
        else
            -- Clicked the big "PLAY" Button on the left
            local btnX, btnY, btnW, btnH = 50, sh - 120, sw/2 - 100, 60
            if x > btnX and x < btnX + btnW and y > btnY and y < btnY + btnH then
                if #Menu.songs > 0 then
                    startGameCallback(Menu.songs[Menu.selectedIndex].filename)
                end
            end
        end
    end
end

function Menu.wheelmoved(x, y)
    -- Scrolling the list
    local _, sh = love.graphics.getDimensions()
    local itemHeight = 70
    local listHeight = #Menu.songs * itemHeight
    local minScroll = math.min(0, sh - listHeight)

    Menu.scroll = Menu.scroll + (y * 40)
    if Menu.scroll > 0 then Menu.scroll = 0 end
    if Menu.scroll < minScroll then Menu.scroll = minScroll end
end

function Menu.draw()
    local sw, sh = love.graphics.getDimensions()

    -- Background
    love.graphics.setColor(0.05, 0.05, 0.08)
    love.graphics.rectangle("fill", 0, 0, sw, sh)

    -- Center Divider
    love.graphics.setColor(1, 1, 1, 0.2)
    love.graphics.line(sw/2, 0, sw/2, sh)

    if #Menu.songs == 0 then
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("No .lrg packages found in the 'songs' folder!", 0, sh/2, sw, "center")
        return
    end

    local selectedSong = Menu.songs[Menu.selectedIndex]

    -- === LEFT PANEL (INFO & EYE CANDY) ===
    love.graphics.setColor(1, 1, 1)
    love.graphics.push()
    love.graphics.scale(1.5, 1.5)
    love.graphics.printf(selectedSong.title or "Unknown Title", 30, 30, (sw/3) - 60, "left")
    love.graphics.pop()

    love.graphics.setColor(0.7, 0.7, 1)
    love.graphics.print("Artist: " .. selectedSong.artist, 50, 120)
    love.graphics.print("BPM: " .. (selectedSong.bpm or "Unknown"), 50, 160)
    love.graphics.print("File: " .. selectedSong.filename, 50, 200)

    -- Play Button
    local btnX, btnY, btnW, btnH = 50, sh - 120, sw/2 - 100, 60
    love.graphics.setColor(0.2, 0.6, 0.2)
    love.graphics.rectangle("fill", btnX, btnY, btnW, btnH, 5)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("PLAY SONG", btnX, btnY + 23, btnW, "center")

    -- Import Button
if love.system.getOS() == "Android" then
    importButton.x = 50
    importButton.y = sh - 190
    importButton.w = sw/2 - 100

    love.graphics.setColor(0.2, 0.4, 0.8)
    love.graphics.rectangle(
        "fill",
        importButton.x,
        importButton.y,
        importButton.w,
        importButton.h,
        5
    )

    love.graphics.setColor(1,1,1)
    love.graphics.printf(
        "IMPORT .LRG",
        importButton.x,
        importButton.y + 23,
        importButton.w,
        "center"
    )
end

    if Menu.importMessageTimer > 0 then
    love.graphics.setColor(1,1,1)
    love.graphics.printf(
        Menu.importMessage,
        0,
        sh - 40,
        sw,
        "center"
    )
end

    -- === RIGHT PANEL (SONG LIST) ===
    local rightPanelX = sw / 2
    local itemHeight = 70

    love.graphics.push()
    love.graphics.translate(0, Menu.scroll)
    for i, song in ipairs(Menu.songs) do
        local itemY = (i - 1) * itemHeight

        -- Dynamic Background Colors
        if i == Menu.selectedIndex then
            love.graphics.setColor(0.3, 0.5, 1, 0.4) -- Selected (Blueish)
        elseif i == Menu.hoverIndex then
            love.graphics.setColor(1, 1, 1, 0.1) -- Hover
        else
            love.graphics.setColor(0, 0, 0, 0)
        end
        love.graphics.rectangle("fill", rightPanelX, itemY, sw/2, itemHeight)

        -- Border
        love.graphics.setColor(1, 1, 1, 0.1)
        love.graphics.rectangle("line", rightPanelX, itemY, sw/2, itemHeight)

        -- Text Content
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(song.title or song.filename, rightPanelX + 25, itemY + 15)
        love.graphics.setColor(0.6, 0.6, 0.6)
        love.graphics.print("BPM: " .. (song.bpm or "?"), rightPanelX + 25, itemY + 40)
    end
    love.graphics.pop()
end

return Menu
