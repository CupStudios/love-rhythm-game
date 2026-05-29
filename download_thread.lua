local http = require("socket.http")
local ltn12 = require("ltn12")

local requestChannel = love.thread.getChannel("download_request")
local statusChannel = love.thread.getChannel("download_status")

while true do
    local payload = requestChannel:demand()
    if payload == "__quit__" then break end

    local url, filename = payload:match("^(.-)|(.+)$")
    
    -- FORZAR ENCODIFICACIÓN URL (importante para espacios)
    url = string.gsub(url, " ", "%%20")

    local chunks = {}
    -- Usamos un timeout para que el juego no se congele si el server tarda
    local res, code, headers, status = http.request({
        url = url,
        sink = ltn12.sink.table(chunks),
        timeout = 10 
    })

    if code == 200 then
        -- En lugar de escribir aquí, enviamos los datos al canal principal
        -- para que el hilo principal (main thread) guarde el archivo
        local data = table.concat(chunks)
        love.thread.getChannel("file_data"):push({filename = filename, data = data})
        statusChannel:push("done|" .. filename)
    else
        statusChannel:push("error|HTTP " .. tostring(code))
    end
end
