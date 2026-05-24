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
    
    -- Asegurar que existan las carpetas necesarias en el almacenamiento seguro
    love.filesystem.createDirectory("songs")
    love.filesystem.createDirectory("extracted_songs")
    
    -- Listar los archivos .lrg que pusiste en la carpeta songs
    local files = love.filesystem.getDirectoryItems("songs")
    
    for _, file in ipairs(files) do
        if file:lower():match("%.lrg$") then
            local filepath = "songs/" .. file
            -- Crear un nombre de carpeta único para extraer la canción
            local folderName = file:gsub("%W", "")
            local targetFolder = "extracted_songs/" .. folderName
            
            love.filesystem.createDirectory(targetFolder)
            
            -- ¡Truco maestro!: Montamos el .lrg temporalmente en una ruta de lectura
            local tempMount = "temp_" .. folderName
            if love.filesystem.mount(filepath, tempMount) then
                
                -- Copiar los archivos internos del .lrg a la carpeta real extraída
                local insideItems = love.filesystem.getDirectoryItems(tempMount)
                
                -- Si los archivos están envueltos en una subcarpeta interna dentro del zip
                local sourceSubfolder = ""
                if #insideItems == 1 and love.filesystem.getInfo(tempMount .. "/" .. insideItems[1]).type == "directory" then
                    sourceSubfolder = insideItems[1] .. "/"
                    insideItems = love.filesystem.getDirectoryItems(tempMount .. "/" .. insideItems[1])
                end
                
                -- Extraer de verdad cada archivo (manifest, audio, chart)
                for _, item in ipairs(insideItems) do
                    local fileData = love.filesystem.read(tempMount .. "/" .. sourceSubfolder .. item)
                    if fileData then
                        love.filesystem.write(targetFolder .. "/" .. item, fileData)
                    end
                end
                
                -- Ya no necesitamos el montaje temporal, lo desmontamos
                love.filesystem.unmount(filepath)
                
                -- Ahora leemos el manifest desde la carpeta ya extraída físicamente
                local manifestPath = targetFolder .. "/manifest.json"
                if love.filesystem.getInfo(manifestPath) then
                    local manifestData = love.filesystem.read(manifestPath)
                    if manifestData then
                        local ok, decoded = pcall(json.decode, json, manifestData)
                        if ok and decoded then
                            -- Guardamos los datos clave para cuando el juego los necesite
                            decoded.filename = file
                            decoded.folderPath = targetFolder -- Guardamos la ruta física real
                            table.insert(Menu.songs, decoded)
                        end
                    end
                end
            end
        end
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
    local itemHeight = 70 -- Mantener la misma altura que usas en el Menu.draw

    -- IMPORT BUTTON (Para Android)
    if love.system.getOS() == "Android" then
        if x > importButton.x and x < importButton.x + importButton.w and
           y > importButton.y and y < importButton.y + importButton.h then

            Menu.importMessage = "Abre el archivo .lrg desde el explorador nativo de Android"
            Menu.importMessageTimer = 4
            return
        end
    end

    if button == 1 then
        -- === CLICK EN EL PANEL DERECHO (LISTA DE CANCIONES) ===
        if x > rightPanelX then
            -- Calculamos el índice real basándonos en la posición Y del mouse y el scroll
            local calculatedIndex = math.floor((y - Menu.scroll) / itemHeight) + 1
            
            -- Verificar que el índice esté dentro del rango de canciones existentes
            if calculatedIndex >= 1 and calculatedIndex <= #Menu.songs then
                if Menu.selectedIndex == calculatedIndex then
                    -- DOBLE CLICK: El usuario presiona la canción que ya estaba seleccionada. 
                    -- FIX: Pasamos el objeto de canción completo con sus rutas extraídas
                    startGameCallback(Menu.songs[Menu.selectedIndex])
                else
                    -- PRIMER CLICK: Solo selecciona la canción de la lista
                    Menu.selectedIndex = calculatedIndex
                end
            end
            
        -- === CLICK EN EL PANEL IZQUIERDO (BOTÓN JUGAR GRANDE) ===
        else
            local btnX, btnY, btnW, btnH = 50, sh - 120, sw/2 - 100, 60
            if x > btnX and x < btnX + btnW and y > btnY and y < btnY + btnH then
                if #Menu.songs > 0 and Menu.songs[Menu.selectedIndex] then
                    -- FIX: Pasamos el objeto de canción completo al presionar el botón de PLAY
                    startGameCallback(Menu.songs[Menu.selectedIndex])
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
