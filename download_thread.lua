local http = require("socket.http")
local ltn12 = require("ltn12")

local requestChannel = love.thread.getChannel("download_request")
local statusChannel = love.thread.getChannel("download_status")

while true do
    local payload = requestChannel:demand()
    if payload == "__quit__" then
        break
    end

    local url, filename = payload:match("^(.-)|(.+)$")
    if not url or not filename then
        statusChannel:push("error|Invalid download payload")
    else
        statusChannel:push("progress|Descargando " .. filename .. "...")

        local chunks = {}
        local _, code = http.request({
            url = url,
            sink = ltn12.sink.table(chunks)
        })

        if code == 200 then
            local data = table.concat(chunks)
            love.filesystem.createDirectory("songs")
            local ok = love.filesystem.write("songs/" .. filename, data)
            if ok then
                statusChannel:push("done|" .. filename)
            else
                statusChannel:push("error|No se pudo guardar " .. filename)
            end
        else
            statusChannel:push("error|HTTP " .. tostring(code) .. " al descargar " .. filename)
        end
    end
end
