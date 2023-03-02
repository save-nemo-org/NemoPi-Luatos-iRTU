httpdtu={}

libnet = require "libnet"
dtulib = require "dtulib"
create = require "create"

-- 无网络重启时间
local rstTim = 300000
function httpdtu.httpTask(cid, convert, passon, upprot, dwprot, uid, method, url, timeout, way, dtype, basic,
    headers, iscode, ishead, isbody)
    cid, timeout, uid = tonumber(cid) or 1, tonumber(timeout) or 30, tonumber(uid) or 1
        way, dtype = tonumber(way) or 1, tonumber(dtype) or 1
        local dwprotFnc = dwprot and dwprot[cid] and dwprot[cid] ~= "" and
                                loadstring(dwprot[cid]:match("function(.+)end"))
        local upprotFnc = upprot and upprot[cid] and upprot[cid] ~= "" and
                                loadstring(upprot[cid]:match("function(.+)end"))
        while true do
            create.datalink[cid] = mobile.status() == 1
            local result, msg = sys.waitUntil("NET_SENT_RDY_" .. (passon and cid or uid))
            if result and msg then
                if convert == 1 then -- 转换为Hex String 报文
                    msg = msg:toHex()
                elseif convert == 0 and upprotFnc then -- 转换为用户自定义报文
                    local res, dat = pcall(upprotFnc, msg)
                    if not res or not msg then
                        log.error("数据流模版错误:", msg)
                    end
                    msg = res and dat or msg
                end
                if passon then
                    sys.publish("UART_SENT_RDY_" .. uid, uid, "SEND_OK\r\n")
                end
                local code, head, body = dtulib.request(method:upper(), url, timeout * 1000,
                    way == 0 and msg or nil, way == 1 and msg or nil, dtype, basic, headers)
                local headstr = ""
                if type(head) == "table" then
                    for k, v in pairs(head) do
                        headstr = headstr .. k .. ": " .. v .. "\r\n"
                    end
                else
                    headstr = head
                end
                if convert == 1 then -- 转换HEX String
                    local str = (tonumber(iscode) ~= 1 and code .. "\r\n" or "") ..
                                    (tonumber(ishead) ~= 1 and headstr or "") ..
                                    (tonumber(isbody) ~= 1 and body and (body:fromHex()) or "")
                    sys.publish("NET_RECV_WAIT_" .. uid, uid, str)
                elseif convert == 0 and dwprotFnc then -- 转换用户自定义报文
                    local res, code, head, body = pcall(dwprotFnc, code, head, body)
                    if not res or not msg then
                        log.error("数据流模版错误:", msg)
                    else
                        local str = (tonumber(iscode) ~= 1 and code .. "\r\n" or "") ..
                                        (tonumber(ishead) ~= 1 and headstr or "") ~= 1 ..
                                        (tonumber(isbody) ~= 1 and body or "")
                        sys.publish("NET_RECV_WAIT_" .. uid, uid, res and str or code)
                    end
                else -- 默认不转换
                    sys.publish("NET_RECV_WAIT_" .. uid, uid,
                        (tonumber(iscode) ~= 1 and code .. "\r\n" or "") ..
                            (tonumber(ishead) ~= 1 and headstr or "") .. (tonumber(isbody) ~= 1 and body or ""))
                end
            end
            sys.wait(100)
        end
        datalink[cid] = false
end