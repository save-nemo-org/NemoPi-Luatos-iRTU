create = {}

libnet = require "libnet"
dtulib = require "dtulib"
httpdtu = require "httpdtu"
mqttdtu = require "mqttdtu"
socketdtu = require "socketdtu"

local datalink, defChan = {}, 1
-- 定时采集任务的参数
local interval, samptime = {0, 0, 0}, {0, 0, 0}

-- 获取经纬度
local lat, lng = 0, 0
-- 无网络重启时间，飞行模式启动时间
local rstTim, flyTim = 300000, 300000

function getDatalink(cid)
    if tonumber(cid) then
        return datalink[cid]
    else
        return datalink[defChan]
    end
end
function setchannel(cid)
    defChan = tonumber(cid) or 1
    return cid
end
function getTimParam()
    return interval, samptime
end

local function netCB(msg)
	log.info("未处理消息", msg[1], msg[2], msg[3], msg[4])
end

--- 用户串口和远程调用的API接口
-- @string str：执行API的命令字符串
-- @retrun str : 处理结果字符串
function create.userapi(str)
    local t = str:match("(.+)\r\n") and str:match("(.+)\r\n"):split(',') or str:split(',')
    local first = table.remove(t, 1)
    local second = table.remove(t, 1) or ""
    log.info("FIRST",first)
    log.info("SECONDE",second)
    log.info("THREE",three)
    if tonumber(second) and tonumber(second) > 0 and tonumber(second) < 8 then
        log.info("进到这里了1")
        return cmd[first]["pipe"](t, second) .. "\r\n"
    elseif cmd[first][second] then
        log.info("进到这里了2")
        return cmd[first][second](t, str) .. "\r\n"
    else
        return "ERROR\r\n"
    end
end
---------------------------------------------------------- DTU的网络任务部分 ----------------------------------------------------------
local function conver(str)
    if str:match("function(.+)end") then
        return loadstring(str:match("function(.+)end"))()
    end
    local hex = str:sub(1, 2):lower() == "0x"
    str = hex and str:sub(3, -1) or str
    local tmp = str:split("|")
    for v = 1, #tmp do
        if tmp[v]:lower() == "sn" then
            tmp[v] = hex and (mobile.sn():toHex()) or mobile.sn()
        end
        if tmp[v]:lower() == "imei" then
            tmp[v] = hex and (mobile.imei():toHex()) or mobile.imei()
        end
        if tmp[v]:lower() == "muid" then
            tmp[v] = hex and (mobile.muid():toHex()) or mobile.muid()
        end
        if tmp[v]:lower() == "imsi" then
            tmp[v] = hex and (mobile.imsi():toHex()) or mobile.imsi()
        end
        if tmp[v]:lower() == "iccid" then
            tmp[v] = hex and (mobile.iccid():toHex()) or mobile.iccid()
        end
        if tmp[v]:lower() == "csq" then
            tmp[v] = hex and string.format("%02X", mobile.rssi()) or tostring(mobile.rssi())
        end
    end
    return hex and (table.concat(tmp):fromHex()) or table.concat(tmp)
end
-- 登陆报文
local function loginMsg(str)
    if tonumber(str) == 0 then
        return nil
    elseif tonumber(str) == 1 then
        return json.encode({
            csq = mobile.rssi(),
            imei = mobile.imei(),
            iccid = mobile.iccid(),
            ver = _G.VERSION
        })
    elseif tonumber(str) == 2 then
        return tostring(mobile.rssi()):fromHex() .. (mobile.imei() .. "0"):fromHex() .. mobile.iccid():fromHex()
    elseif type(str) == "string" and #str ~= 0 then
        return conver(str)
    else
        return nil
    end
end

---------------------------------------------------------- 参数配置,任务转发，线程守护主进程----------------------------------------------------------
function connect(pios, conf, reg, convert, passon, upprot, dwprot, webProtect, protectContent)
    local flyTag = false
    if mobile.status() ~= 1 and not sys.waitUntil("IP_READY", rstTim) then
        dtulib.restart("网络初始化失败!")
    end
    sys.waitUntil("DTU_PARAM_READY", 120000)
    if webProtect == nil or protectContent == nil then
        webProtect = "1"
        log.info("这里赋值了")
    end
    -- 自动创建透传任务并填入参数
    for k, v in pairs(conf or {}) do
        -- log.info("Task parameter information:", k, pios, reg, convert, passon, upprot, dwprot, unpack(v))
        if v[1] and (v[1]:upper() == "TCP" or v[1]:upper() == "UDP") then
            log.warn("----------------------- TCP/UDP is start! --------------------------------------")
            log.info("webProtect", webProtect, protectContent[1])
            local taskName = "DTU_" .. tostring(k)
            sysplus.taskInitEx(socketdtu.tcpTask, taskName, netCB, taskName, k, pios, reg, convert, passon, upprot, dwprot, unpack(v))
        elseif v[1] and v[1]:upper() == "MQTT" then
            log.warn("----------------------- MQTT is start! --------------------------------------")
            log.info("VVVVVVV1", v[18])
            log.info("UNPACK1", unpack(v))
            log.info("UNPACK", unpack(v, 2))
            log.info("KKKK", k)
            log.info("PIOS", pios)
            log.info("REG", reg)
            log.info("convert", convert)
            log.info("passon", passon)
            log.info("upprot", upprot)
            log.info("dwprot", dwprot)
            sys.taskInit(mqttdtu.mqttTask, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 2))
        elseif v[1] and v[1]:upper() == "HTTP" then
            log.warn("----------------------- HTTP is start! --------------------------------------")
            sys.taskInit(httpdtu.httpTask,k, convert, passon, upprot, dwprot, unpack(v, 2))
        elseif v[1] and v[1]:upper() == "ONENET" then
            log.warn("----------------------- OneNET is start! --------------------------------------")
            sys.taskInit(mqttdtu.oneNet_mqtt, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 3))
        elseif v[1] and v[1]:upper() == "ALIYUN" then
            log.warn("----------------------- Aliyun iot is start! --------------------------------------")
            while not ntp.isEnd() do
                sys.wait(1000)
            end
            if v[2]:upper() == "OTOK" then -- 一型一密
                sys.taskInit(mqttdtu.aliyunOtok, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 3))
            elseif v[2]:upper() == "OMOK" then -- 一机一密
                sys.taskInit(mqttdtu.aliyunOmok, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 3))
            end
        elseif v[1] and v[1]:upper() == "TXIOT" then
            log.warn("----------------------- tencent iot is start! --------------------------------------")
            log.info("UNPACK1", unpack(v))
            log.info("UNPACK", unpack(v, 2))
            log.info("KKKK", k)
            log.info("PIOS", pios)
            log.info("REG", reg)
            log.info("convert", convert)
            log.info("passon", passon)
            log.info("upprot", upprot)
            log.info("dwprot", dwprot)
            while not ntp.isEnd() do
                sys.wait(1000)
            end
            sys.taskInit(mqttdtu.txiot, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 2))
        elseif v[1] and v[1]:upper() == "TXIOTNEW" then
            log.warn("----------------------- tencent iot is start! --------------------------------------")
            log.info("UNPACK1", unpack(v))
            log.info("UNPACK", unpack(v, 2))
            log.info("KKKK", k)
            log.info("PIOS", pios)
            log.info("REG", reg)
            log.info("convert", convert)
            log.info("passon", passon)
            log.info("upprot", upprot)
            log.info("dwprot", dwprot)
            while not ntp.isEnd() do
                sys.wait(1000)
            end
            sys.taskInit(mqttdtu.dev_txiotnew, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 2))
        end
    end
    -- 守护进程
    log.info("webProtect", webProtect, protectContent[1])
    log.info("守护线程")
    -- sys.timerStart(sys.restart, rstTim, "Server connection failed")
    -- sys.timerStart(sys.restart, 60000, "Server connection failed")
    log.info("webProtect", webProtect, protectContent[1])
    for i = 1, #conf do
        if webProtect == "1" then
            if conf[i][1] ~= nil then
                log.info("守护全部线程", i)
                sys.timerStart(dtulib.restart, rstTim, "Server connection failed" .. i)
            end
        else
            if protectContent[i] == 1 and conf[tonumber(i)][1] ~= nil then
                sys.timerStart(dtulib.restart, rstTim, "Server connection failed" .. i)
            end
        end
    end
    log.info("开启了")
    while true do
        -- log.info("守护在循环")
        log.info("webProtect", webProtect, protectContent)
        -- 这里是网络正常,但是链接服务器失败重启

        for i = 1, #conf do
            if webProtect == "1" then
                if conf[i][1] ~= nil and datalink[tonumber(i)] then
                    sys.timerStart(dtulib.restart, rstTim, "Server connection failed" .. i)
                end
            else
                if protectContent[i] == 1 and conf[tonumber(i)][1] ~= nil and datalink[tonumber(i)] then
                    sys.timerStart(dtulib.restart, rstTim, "Server connection failed" .. i)
                end
            end
        end
        sys.wait(5000)
    end
end
-- NTP同步失败强制重启
-- local tid = sys.timerStart(function()
--     net.switchFly(true)
--     sys.timerStart(net.switchFly, 5000, false)
-- end, flyTim)
sys.subscribe("IP_READY", function()
    -- sys.timerStop(tid)
    log.info("---------------------- 网络注册已成功 ----------------------")
end)

return {
    getDatalink = getDatalink,
    setchannel = setchannel,
    getTimParam = getTimParam,
    connect = connect,
    conver=conver,
    loginMsg=loginMsg

}
