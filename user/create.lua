create = {}

libnet = require "libnet"
dtulib = require "dtulib"

local datalink, defChan = {}, 1
-- 定时采集任务的参数
local interval, samptime = {0, 0, 0}, {0, 0, 0}

-- 获取经纬度
local latdata, lngdata = 0, 0
-- 无网络重启时间，飞行模式启动时间
local rstTim, flyTim = 300000, 300000
local output, input = {}, {}


-- 用户读取ADC
function create.getADC(id)
    adc.open(id)
    local adcValue = adc.get(id)
    adc.close(id)
    if adcValue ~= 0xFFFF then
        return adcValue
    end
end

function create.getDatalink(cid)
    if tonumber(cid) then
        return datalink[cid]
    else
        return datalink[defChan]
    end
end
function create.setchannel(cid)
    defChan = tonumber(cid) or 1
    return cid
end
function create.getTimParam()
    return interval, samptime
end

local function netCB(msg)
	log.info("未处理消息", msg[1], msg[2], msg[3], msg[4])
end

-- 获取纬度
function create.getLat()
    return latdata
end
-- 获取经度
function create.getLng()
    return lngdata
end
-- 获取实时经纬度
function create.getRealLocation()
    lbsLoc.request(function(result, lat, lng, addr,time,locType)
        if result then
            latdata=lat
            lngdata=lng
            --default.setLocation(lat, lng)
        end
    end)
    return latdata, lngdata
end


--- 用户串口和远程调用的API接口
-- @string str：执行API的命令字符串
-- @retrun str : 处理结果字符串
function create.userapi(str)
    local t = str:match("(.+)\r\n") and dtulib.split(str:match("(.+)\r\n"),',') or dtulib.split(str,',')
    local first = table.remove(t, 1)
    local second = table.remove(t, 1) or ""
    if tonumber(second) and tonumber(second) > 0 and tonumber(second) < 8 then
        return cmd[first]["pipe"](t, second) .. "\r\n"
    elseif cmd[first][second] then
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
    local tmp = dtulib.split(str,"|")
    for v = 1, #tmp do
        local tmpdata=tmp[v]:lower()
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
            tmp[v] = hex and string.format("%02X", mobile.csq()) or tostring(mobile.csq())
        end
        if tmpdata==tmp[v] and v>1 then tmp[v] = "|"..tmp[v] end
    end
    return hex and dtulib.fromHexnew((table.concat(tmp))) or table.concat(tmp)
end
-- 登陆报文
local function loginMsg(str)
    if tonumber(str) == 0 then
        return nil
    elseif tonumber(str) == 1 then
        return json.encode({
            csq = mobile.csq(),
            imei = mobile.imei(),
            iccid = mobile.iccid(),
            ver = _G.VERSION
        })
    elseif tonumber(str) == 2 then
        return dtulib.fromHexnew(tostring(mobile.csq())) .. dtulib.fromHexnew((mobile.imei() .. "0")) .. dtulib.fromHexnew(mobile.iccid())
    elseif type(str) == "string" and #str ~= 0 then
        return conver(str)
    else
        return nil
    end
end
---------------------------------------------------------- SOKCET 服务 ----------------------------------------------------------
local function tcpTask(dName, cid, pios, reg, convert, passon, upprot, dwprot, prot, ping, timeout, addr, port, uid, gap,
    report, intervalTime, ssl, login)
    cid, prot, timeout, uid = tonumber(cid) or 1, prot:upper(), tonumber(timeout) or 120, tonumber(uid) or 1
    local outputSocket = {}
    if not ping or ping == "" then
        ping = "0x00"
    end
    if tonumber(intervalTime) then
        sys.timerLoopStart(sys.publish, tonumber(intervalTime) * 1000, "AUTO_SAMPL_" .. uid)
    end
    local dwprotFnc = dwprot and dwprot[cid] and dwprot[cid] ~= "" and loadstring(dwprot[cid]:match("function(.+)end"))
    local upprotFnc = upprot and upprot[cid] and upprot[cid] ~= "" and loadstring(upprot[cid]:match("function(.+)end"))
    local tx_buff = zbuff.create(1024)
    local rx_buff = zbuff.create(1024)
    local idx = 0
    -- local dName = "SOCKET" .. cid
    local netc = socket.create(nil, dName)
    local subMessage = function(data)
        if data then
            table.insert(outputSocket, data)
            sys_send(dName, socket.EVENT, 0)
        end
    end
    sys.subscribe("NET_SENT_RDY_" .. (passon and cid or uid), subMessage)

    while true do
        if mobile.status() ~= 1 and not sys.waitUntil("IP_READY", rstTim) then
            dtulib.restart("网络初始化失败！")
        end
        local isUdp = prot == "UDP" and true or false
        local isSsl = ssl == "ssl" and true or false
        -- local isUdp = false
        -- local isSsl = false
        log.info("DNAME", dName, isUdp, isSsl, addr, prot, ping, port)
        socket.debug(netc, true)
        socket.config(netc, nil,isUdp,isSsl)
        local res = libnet.waitLink(dName, 0, netc)
        local result = libnet.connect(dName, timeout*1000, netc, addr, port)
        if result then
            log.info("tcp连接成功", dName, addr, port)
            -- 登陆报文
            datalink[cid] = true
            local login_data = login or loginMsg(reg)
            if login_data then
                log.info("发送登录报文", login_data:toHex())
                libnet.tx(dName, nil, netc, login_data)
            end
            interval[uid], samptime[uid] = tonumber(gap) or 0, tonumber(report) or 0
            while true do
                -- local result, data = sys.waitUntil("NET_SENT_RDY_" .. (passon and cid or uid),
                -- (timeout or 180) * 1000)
                log.info("循环等待消息")
                log.info("passon", passon, ",cid", cid, ",UID", uid)
                local result, param = libnet.wait(dName, timeout * 1000, netc)
                if not result then
                    log.info("网络异常", result, param) 
                    break
                end
                if param == false then
                    local result, param = libnet.tx(dName, nil, netc, conver(ping))
                    if not result then
                        break
                    end
                end
                -- local result, data, param = c:recv(timeout * 1000, "NET_SENT_RDY_" .. (passon and cid or uid))
                -- local result, data, param = c:recv(timeout * 1000, "NET_SENT_RDY_2")
                local succ, param, _, _ = socket.rx(netc, rx_buff)
                if not succ then
                    log.info("服务器断开了", succ, param, addr, port)
                    break
                end
                if rx_buff:used() > 0 then
                    log.info("收到服务器数据，长度", rx_buff:used())
                    local data = rx_buff:toStr(0, rx_buff:used())
                    if data:sub(1, 5) == "rrpc," or data:sub(1, 7) == "config," then
                        local res, msg = pcall(create.userapi, data, pios)
                            if not res then
                                log.error("远程查询的API错误:", msg)
                            end
                        if convert == 0 and upprotFnc then -- 转换为用户自定义报文
                            res, msg = pcall(upprotFnc, data)
                            if not res then
                                log.error("数据流模版错误:", msg)
                            end
                            res, msg = pcall(create.userapi, msg, pios)
                            if not res then
                                log.error("远程查询的API错误:", msg)
                            end
                        end
                        if not libnet.tx(dName, nil, netc, msg) then
                            break
                        end
                    elseif convert == 1 then -- 转换HEX String
                        local datahex1=dtulib.fromHexnew(data)
                        sys.publish("NET_RECV_WAIT_" .. uid, uid,datahex1)
                    elseif convert == 0 and dwprotFnc then -- 转换用户自定义报文
                        local res, msg = pcall(dwprotFnc, data)
                        if not res or not msg then
                            log.error("数据流模版错误:", msg)
                        else
                            sys.publish("NET_RECV_WAIT_" .. uid, uid, res and msg or data)
                        end
                    else -- 默认不转换
                        sys.publish("NET_RECV_WAIT_" .. uid, uid, data)
                    end
                    -- uart.tx(uart_id, rx_buff)
                    log.info("RXBUFF1",rx_buff)
                    rx_buff:del()
                    log.info("RXBUFF2",rx_buff)
                end
                tx_buff:copy(nil, table.concat(outputSocket))
                outputSocket={}
                if tx_buff:used() > 0 then
                    local data = tx_buff:toStr(0, tx_buff:used())
                    if convert == 1 then -- 转换为Hex String 报文
                        local datahex=data:toHex()
                        local result, param = libnet.tx(dName, nil, netc, datahex)
                        if not result then
                            if passon then
                                sys.publish("UART_SENT_RDY_" .. uid, uid, "SEND_ERROR\r\n")
                            end
                            log.info("tcp", "tx失败,退出循环", dName, addr, port)
                            break
                        end
                    elseif convert == 0 and upprotFnc then -- 转换为用户自定义报文
                        local res, msg = pcall(upprotFnc, data)
                        if not res or not msg then
                            log.error("数据流模版错误:", msg)
                        else
                            log.info("RES",res,msg)
                            local succ, param = libnet.tx(dName, nil, netc, res and msg or data)
                            -- TODO 缓冲区满的情况
                            if not succ then
                                if passon then
                                    sys.publish("UART_SENT_RDY_" .. uid, uid, "SEND_ERROR\r\n")
                                end
                                log.info("tcp", "tx失败,退出循环", dName, addr, port)
                                break
                            end
                        end
                    else -- 默认不转换
                        local succ, param = libnet.tx(dName, nil, netc, data)
                        -- TODO 缓冲区满的情况
                        if not succ then
                            if passon then
                                sys.publish("UART_SENT_RDY_" .. uid, uid, "SEND_ERROR\r\n")
                            end
                            log.info("tcp", "tx失败,退出循环", dName, addr, port)
                            break
                        end
                    end
                    if passon then
                        sys.publish("UART_SENT_RDY_" .. uid, uid, "SEND_OK\r\n")
                    end
                else
                    log.info("tcp", "无数据待发送", dName, addr, port)
                    --break
                end
                tx_buff:del()
                -- log.info("TXBUFF2",tx_buff:read())
                --log.info("TXBUFF1",tx_buff:used())
                if tx_buff:len() > 1024 then
                    tx_buff:resize(1024)
                end
                if rx_buff:len() > 1024 then
                    rx_buff:resize(1024)
                end
                log.info("RESULT", result, ",DATA", data, ",PARAM", param, ",passon", passon, ",cid", cid, ",UID", uid)
            end
        else
            log.info("tcp连接失败了", dName, addr, port)
        end
        log.info("关闭tcp链接", dName, addr, port)
        libnet.close(dName, 5000, netc)
        datalink[cid] = false
        sys.wait((2 * idx) * 1000)
        idx = (idx > 9) and 1 or (idx + 1)
    end
end
---------------------------------------------------------- MQTT 服务 ----------------------------------------------------------
local function listTopic(str, addImei, ProductKey, deviceName)
    log.info("STR",str)
    --local topics = str:split(";")
    local topics = dtulib.split(str,";")
    for key, value in pairs(topics) do
        log.info("KEYv",key,value)
    end
    if #topics == 1 and (not addImei or addImei == "") then
        topics[1] = topics[1]:sub(-1, -1) == "/" and topics[1] .. mobile.imei() or topics[1] .. "/" .. mobile.imei()
    else
        local tmp = {}
        for i = 1, #topics, 2 do
            --tmp = split(topics[i],"/")
            tmp = dtulib.split(topics[i],"/")
            for key, value in pairs(tmp) do
                log.info("KEY2",key,value)
            end
            for v = 1, #tmp do
                if tmp[v]:lower() == "imei" then
                    tmp[v] = mobile.imei()
                end
                if tmp[v]:lower() == "muid" then
                    tmp[v] = mobile.muid()
                end
                if tmp[v]:lower() == "imsi" then
                    tmp[v] = mobile.imsi()
                end
                if tmp[v]:lower() == "iccid" then
                    tmp[v] = mobile.iccid()
                end
                if tmp[v]:lower() == "productid" or tmp[v]:lower() == "{pid}" then
                    tmp[v] = ProductKey
                end
                if tmp[v]:lower() == "SN" then
                    tmp[v] = hex and (mobile.sn():toHex()) or mobile.sn()
                end
                if tmp[v]:lower() == "messageid" or tmp[v]:lower() == "${messageid}" then
                    tmp[v] = "+"
                end
                if tmp[v]:lower() == "productkey" or tmp[v]:lower() == "${productkey}" or tmp[v]:lower() ==
                    "${yourproductkey}" then
                    tmp[v] = ProductKey
                end
                if tmp[v]:lower() == "devicename" or tmp[v]:lower() == "${devicename}" or tmp[v]:lower() ==
                    "${yourdevicename}" or tmp[v]:lower() == "{device-name}" then
                    tmp[v] = deviceName
                end
            end
            topics[i] = table.concat(tmp, "/")
            log.info("订阅或发布主题:", i, topics[i])
        end
    end
    return topics
end

local function mqttTask(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, addr, port, usr, pwd,
    cleansession, sub, pub, qos, retain, uid, clientID, addImei, ssl, will, idAddImei, prTopic, cert)
    cid, keepAlive, timeout, uid = tonumber(cid) or 1, tonumber(keepAlive) or 300, tonumber(timeout), tonumber(uid)
    cleansession, qos, retain = tonumber(cleansession) or 0, tonumber(qos) or 0, tonumber(retain) or 0
    prTopic = prTopic and prTopic or ""
    if idAddImei == "1" then
        log.info("为1，进到这里了")
        clientID = (clientID == "" or not clientID) and mobile.imei() or clientID
    else
        log.info("为空，进到这里了")
        clientID = (clientID == "" or not clientID) and mobile.imei() or mobile.imei() .. clientID
    end
    if timeout then
        sys.timerLoopStart(sys.publish, timeout * 1000, "AUTO_SAMPL_" .. uid)
    end
    if type(sub) == "string" then
        sub = listTopic(sub, addImei)
        local topics = {}
        for i = 1, #sub do
            topics[sub[i]] = tonumber(sub[i + 1]) or qos
            log.info("TOPICS",topics[sub[i]])
        end
        sub = topics
    end
    if type(pub) == "string" then
        pub = listTopic(pub, addImei)
    end
    local dwprotFnc = dwprot and dwprot[cid] and dwprot[cid] ~= "" and loadstring(dwprot[cid]:match("function(.+)end"))
    local upprotFnc = upprot and upprot[cid] and upprot[cid] ~= "" and loadstring(upprot[cid]:match("function(.+)end"))

    log.info("MQTT HOST:PORT", addr, port)
    log.info("MQTT clientID,user,pwd", clientID, conver(usr), conver(pwd))
    local idx = 0
    local mqttc = mqtt.create(nil, addr, port, ssl == "tcp_ssl" and true or false)
    -- 是否为ssl加密连接,默认不加密,true为无证书最简单的加密，table为有证书的加密
    mqttc:auth(clientID, conver(usr), conver(pwd))
    log.info("KEEPALIVE",keepAlive)
    mqttc:keepalive(keepAlive)
    mqttc:on(function(mqtt_client, event, data, payload) -- mqtt回调注册
        -- 用户自定义代码，按event处理
        log.info("mqtt", "event", event, mqtt_client, data, payload)
        if event == "conack" then
            sys.publish("mqtt_conack")
        elseif event == "recv" then -- 服务器下发的数据
            log.info("mqtt", "downlink", "topic", data, "payload", payload)
            sys.publish("NET_SENT_RDY_" .. (passon and cid or uid), "recv", data, payload)
            -- 这里继续加自定义的业务处理逻辑
        elseif event == "sent" then -- publish成功后的事件
            log.info("mqtt", "sent", "pkgid", data)
        elseif event == "disconnect" then
            -- 非自动重连时,按需重启mqttc
            -- mqtt_client:connect()
            sys.publish("NET_SENT_RDY_" .. (passon and cid or uid))
        end
    end)
    if not will or will == "" then
        will = nil
    else
        mqttc:will(will, mobile.imei(), 1, 0)
    end
  
    while true do
        log.info("chysTest.sendTestTelemetry1", sendTestTelemetryCount, rtos.version(),
	    "mem.lua", rtos.meminfo("lua"));
        local messageId = false
        if mobile.status() ~= 1 and not sys.waitUntil("IP_READY", rstTim) then
            dtulib.restart("网络初始化失败!")
        end

        mqttc:connect()
        -- local mqttc = mqtt.client(clientID, keepAlive, conver(usr), conver(pwd), cleansession, will, "3.1.1")
        local conres = sys.waitUntil("mqtt_conack", 10000)
        if mqttc:ready() and conres then
            log.info("mqtt连接成功")
            datalink[cid] = true
            -- 初始化订阅主题
            -- sub1={["/luatos/1234567"]=1,["/luatos/12345678"]=2}
            if mqttc:subscribe(sub, qos) then
                -- local a=mqttc:subscribe(topic3,1)
                log.info("mqtt订阅成功")
                -- mqttc:publish(pub, "hello,server", qos) 
                if loginMsg(reg) then
                    mqttc:publish(pub[1], loginMsg(reg), tonumber(pub[2]) or qos, retain)
                end
                -- if loginMsg(reg) then mqttc:publish(sub, "hello,server", 1) end
                while true do
                    -- local r, packet, param = mqttc:receive((timeout or 180) * 1000, "NET_SENT_RDY_" .. (passon and cid or uid))
                    local ret, topic, data, payload = sys.waitUntil("NET_SENT_RDY_" .. (passon and cid or uid),
                        (timeout or 180) * 1000)
                    log.info("RET", ret, topic, data, payload)
                    if ret and topic ~= "recv" then
                        if convert == 1 then -- 转换为Hex String 报文
                            datahex=topic:toHex()
                            if not mqttc:publish(pub[1], datahex, tonumber(pub[2]) or qos, retain) then
                                if passon then
                                    sys.publish("UART_SENT_RDY_" .. uid, uid, "SEND_ERROR\r\n")
                                end
                                break
                            end
                        elseif convert == 0 and upprotFnc then -- 转换为用户自定义报文
                            local res, msg, index = pcall(upprotFnc, topic)
                            if not res or not msg then
                                log.error("数据流模版错误:", msg)
                            else
                                index = tonumber(index) or 1
                                local pub_topic = (pub[index]:sub(-1, -1) == "+" and messageId) and
                                                      pub[index]:sub(1, -2) .. messageId or pub[index]
                                log.info("-----发布的主题:", pub_topic)
                                if not mqttc:publish(pub_topic, res and msg or topic, tonumber(pub[index + 1]) or qos,
                                    retain) then
                                    if passon then
                                        sys.publish("UART_SENT_RDY_" .. uid, uid, "SEND_ERROR\r\n")
                                    end
                                    break
                                end
                            end
                        else
                            local pub_topic = (pub[1]:sub(-1, -1) == "+" and messageId) and pub[1]:sub(1, -2) ..
                                                  messageId or pub[1]
                            log.info("-----发布的主题:", pub_topic)
                            if not mqttc:publish(pub_topic, topic, tonumber(pub[2]) or qos, retain) then
                                if passon then
                                    sys.publish("UART_SENT_RDY_" .. uid, uid, "SEND_ERROR\r\n")
                                end
                                break
                            end
                        end
                            messageId = false
                        if passon then
                            sys.publish("UART_SENT_RDY_" .. uid, uid, "SEND_OK\r\n")
                        end
                        log.info('The client actively reports status information.')
                    elseif ret and topic == "recv" then
                        log.info("接收到了一条消息")
                        messageId = data:match(".+/rrpc/request/(%d+)")
                        log.info("MESSAGE", messageId)
                        log.info("RET2", ret, topic, data, payload)
                        -- 这里执行用户自定义的指令
                        if payload:sub(1, 5) == "rrpc," or payload:sub(1, 7) == "config," then
                            log.info("进到这里了1")
                            local res, msg = pcall(create.userapi, payload, pios)
                            if not res then
                                log.error("远程查询的API错误:", msg)
                            end
                            if convert == 0 and upprotFnc then -- 转换为用户自定义报文
                                res, msg = pcall(upprotFnc,payload)
                                if not res then
                                    log.error("数据流模版错误:", msg)
                                end
                                res, msg = pcall(create.userapi, msg, pios)
                                if not res then
                                    log.error("远程查询的API错误:", msg)
                                end
                            end
                            if not mqttc:publish(pub[1], msg, tonumber(pub[2]) or qos, retain) then
                                break
                            end
                        elseif convert == 1 then -- 转换为HEX String
                            log.info("进到这里了2")
                            sys.publish("UART_SENT_RDY_" .. uid, uid, (dtulib.fromHexnew(payload)))
                        elseif convert == 0 and dwprotFnc then -- 转换用户自定义报文
                            log.info("进到这里了3")
                            local res, msg = pcall(dwprotFnc, payload, data)
                            if not res or not msg then
                                log.error("数据流模版错误:", msg)
                            else
                                if prTopic == "1" then
                                    sys.publish("UART_SENT_RDY_" .. uid, uid,
                                        res and ("[+MSUB:" .. data .. "," .. #msg .. "," .. msg .. "]") or
                                            ("[+MSUB:" .. data .. "," .. #payload .. "," .. payload .. "]"))
                                else
                                    sys.publish("UART_SENT_RDY_" .. uid, uid, res and msg or payload)
                                end
                                -- sys.publish("UART_SENT_RDY_" .. uid, uid, res and msg or payload)
                            end
                        else -- 默认不转换
                            log.info("prTopic", prTopic, "UART_SENT_RDY_" .. uid)
                            if prTopic == "1" then
                                log.info("prTopic1", prTopic, "UART_SENT_RDY_" .. uid)
                                sys.publish("UART_SENT_RDY_" .. uid, uid,
                                    ("[+MSUB:" .. data .. "," .. #payload .. "," .. payload .. "]"))
                            else
                                log.info("prTopic2", prTopic, "UART_SENT_RDY_" .. uid)
                                sys.publish("UART_SENT_RDY_" .. uid, uid, payload)
                            end
                            -- sys.publish("UART_SENT_RDY_" .. uid, uid, payload)
                        end
                    elseif ret==false then
                        log.warn("等待超时了")
                    else
                        log.warn('The MQTTServer connection is broken.')
                        break
                    end
                    -- elseif packet == 'timeout' then
                    --     -- sys.publish("AUTO_SAMPL_" .. uid)
                    --     log.debug('The client timeout actively reports status information.')
                    -- elseif packet == ("NET_SENT_RDY_" .. (passon and cid or uid)) then

                    -- end
                end
            else
                log.info("订阅失败")
            end
        else
            log.info("连接服务器失败")
        end
        datalink[cid] = false
        mqttc:disconnect()
        sys.wait((2 * idx) * 1000)
        idx = (idx > 9) and 1 or (idx + 1)
    end
end

---------------------------------------------------------- OneNet 云服务器 ----------------------------------------------------------
-- onenet新版 mqtt 协议支持
local function oneNet_mqtt(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, addr, port, productId,
    productSecret, deviceName, sub, pub, cleansession, qos, retain, uid)
    cid, keepAlive, timeout, uid = tonumber(cid) or 1, tonumber(keepAlive) or 300, tonumber(timeout), tonumber(uid)
    cleansession, qos, retain = tonumber(cleansession) or 0, tonumber(qos) or 0, tonumber(retain) or 0
    if timeout then
        sys.timerLoopStart(sys.publish, timeout * 1000, "AUTO_SAMPL_" .. uid)
    end
    local clinentId, username, password = iotauth.onenet(productId, productSecret, deviceName)
    local dwprotFnc = dwprot and dwprot[cid] and dwprot[cid] ~= "" and loadstring(dwprot[cid]:match("function(.+)end"))
    local upprotFnc = upprot and upprot[cid] and upprot[cid] ~= "" and loadstring(upprot[cid]:match("function(.+)end"))
    local idx = 0
    if type(sub) ~= "string" or sub == "" then
        sub = "$sys/" .. productId .. "/" .. deviceName .. "/thing/property/post"
    else
        sub = listTopic(sub, "addImei", productId, deviceName)
        local topics = {}
        for i = 1, #sub do
            topics[sub[i]] = tonumber(sub[i + 1]) or qos
        end
        sub = topics
    end
    if type(pub) ~= "string" or pub == "" then
        pub = "$sys/" .. productId .. "/" .. deviceName .. "/thing/property/post/reply"
    else
        pub = listTopic(pub, "addImei", productId, deviceName)
    end
    mqttTask(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, addr, port, username, password,
        cleansession, sub, pub, qos, retain, uid, clinentId, addImei, ssl, will, "1")

end
---------------------------------------------------------- 阿里IOT云 ----------------------------------------------------------
local alikey = "/alikey.cnf"
-- 处理表的RFC3986编码

local function getOneSecret(RegionId, ProductKey, ProductSecret)
    if io.exists(alikey) then
        local dat, res, err = json.decode(io.readFile(alikey))
        if res then
            return dat.data.deviceName, dat.data.deviceSecret
        end
    end

    local random = 2717
    local data = "deviceName" .. mobile.imei() .. "productKey" .. ProductKey .. "random" .. random
    local sign = crypto.hmac_md5(data, ProductSecret)
    local body = "productKey=" .. ProductKey .. "&deviceName=" .. mobile.imei() .. "&random=" .. random .. "&sign=" ..sign .. "&signMethod=HmacMD5"
    for i = 1, 3 do
        local code, head, body = dtulib.request("POST",
            "https://iot-auth." .. RegionId .. ".aliyuncs.com/auth/register/device",10000, nil, body,1)
        if tonumber(code) == 200 and body then

            local dat, result, errinfo = json.decode(body)
            if result and dat.message and dat.data then
                io.writeFile(alikey, body)
                return dat.data.deviceName, dat.data.deviceSecret
            end
        else
            if io.exists(alikey) then
                local dat, res, err = json.decode(io.readFile(alikey))
                if res then
                    return dat.data.deviceName, dat.data.deviceSecret
                end
            end
        end
        log.warn("阿里云查询请求失败:", code, body)
        sys.wait(5000)
    end
end

-- 一机一密方案，所有方案最终都会到这里执行
local function aliyunOmok(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, RegionId, ProductKey,
    deviceSecret, deviceName, ver, cleansession, qos, uid, sub, pub)
    cid, keepAlive, timeout, uid = tonumber(cid) or 1, tonumber(keepAlive) or 300, tonumber(timeout), tonumber(uid)
    cleansession, qos = tonumber(cleansession) or 0, tonumber(qos) or 0
    local data = "clientId" .. mobile.iccid() .. "deviceName" .. deviceName .. "productKey" .. ProductKey
    local usr = deviceName .. "&" .. ProductKey
    local pwd = crypto.hmac_sha1(data, deviceSecret)
    local clientID = mobile.iccid() .. "|securemode=3,signmethod=hmacsha1|"
    local addr = ProductKey .. ".iot-as-mqtt." .. RegionId .. ".aliyuncs.com"
    local port = 1883
    if type(sub) ~= "string" or sub == "" then
        sub = ver:lower() == "basic" and "/" .. ProductKey .. "/" .. deviceName .. "/get" or "/" .. ProductKey .. "/" ..
                  deviceName .. "/user/get"
    else
        sub = listTopic(sub, "addImei", ProductKey, deviceName)
        local topics = {}
        for i = 1, #sub do
            topics[sub[i]] = tonumber(sub[i + 1]) or qos
        end
        sub = topics
    end
    if type(pub) ~= "string" or pub == "" then
        pub =
            ver:lower() == "basic" and "/" .. ProductKey .. "/" .. deviceName .. "/update" or "/" .. ProductKey .. "/" ..
                deviceName .. "/user/update"
    else
        pub = listTopic(pub, "addImei", ProductKey, deviceName)
    end
    local dwprotFnc = dwprot and dwprot[cid] and dwprot[cid] ~= "" and loadstring(dwprot[cid]:match("function(.+)end"))
    local upprotFnc = upprot and upprot[cid] and upprot[cid] ~= "" and loadstring(upprot[cid]:match("function(.+)end"))
    mqttTask(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, addr, port, usr, pwd, cleansession,
        sub, pub, qos, retain, uid, clientID, "addImei", ssl, will, "1")

end

-- 一型一密认证方案
local function aliyunOtok(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, RegionId, ProductKey,
    ProductSecret, ver, cleansession, qos, uid, sub, pub)
    local deviceName, deviceSecret = getOneSecret(RegionId, ProductKey, ProductSecret)
    if not deviceName or not deviceSecret then
        log.error("阿里云注册失败:", ProductKey, ProductSecret)
        return
    end
    log.warn("一型一密动态注册返回三元组:", deviceName ~= nil, deviceSecret ~= nil)
    aliyunOmok(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, RegionId, ProductKey, deviceSecret,
        deviceName, ver, cleansession, qos, uid, sub, pub)
end



function dev_txiotnew(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, Region, deviceName,
    ProductId, ProductSecret, sub, pub, cleansession, qos, uid)
    enrol_end = false
    deviceName = deviceName ~= "" and deviceName or mobile.imei()
    if not io.exists("/qqiot.dat") then
        log.info("确实没有文件了")
        local nonce = math.random(1, 100)
        -- local version = "2018-06-14"
        -- local data = {ProductId = ProductId, DeviceName = misc.getImei()}
       
        local timestamp = os.time()
        local data = "deviceName=" .. deviceName .. "&nonce=" .. nonce .. "&productId=" .. ProductId .. "&timestamp=" ..
                         timestamp
        log.info("deviceNAME", deviceName)
        local hmac_sha1_data = crypto.hmac_sha1(data, ProductSecret):lower()
        local signature = crypto.base64_encode(hmac_sha1_data)
        local tx_body = {
            deviceName = deviceName,
            nonce = nonce,
            productId = ProductId,
            timestamp = timestamp,
            signature = signature
        }
        local tx_body_json = json.encode(tx_body)
        http.request("POST", "https://ap-guangzhou.gateway.tencentdevices.com/register/dev", {
            ["Content-Type"] = "application/json; charset=UTF-8"
        }, tx_body_json).cb(function(code, headers, body)
            -- body
            log.info("testHttp.serBack", head, body)
            local dat, result, errinfo = json.decode(body)
            if result then
                if dat.code == 0 then
                    io.writeFile("/qqiot.dat", body)
                    log.info("腾讯云注册设备成功:", body)
                else
                    log.info("腾讯云设备注册失败:", body)
                end
                enrol_end = true
            end
        end)
        -- http.request("POST","https://ap-guangzhou.gateway.tencentdevices.com/register/dev",nil,{["Content-Type"]="application/json; charset=UTF-8"},tx_body_json,30000,serBack)
        while not enrol_end do
            sys.wait(100)
        end
    else
        log.info("有文件啊")
    end
    if not io.exists("/qqiot.dat") then
        log.warn("腾讯云设备注册失败或不存在设备信息!")
        return
    end

    local dat = json.decode(io.readFile("/qqiot.dat"))
    local clientID = ProductId .. deviceName -- 生成 MQTT 的 clientid 部分, 格式为 ${productid}${devicename}
    local connid = math.random(10000, 99999)
    local expiry = tostring(os.time() + 3600)
    local usr = string.format("%s;12010126;%s;%s", clientID, connid, expiry) -- 生成 MQTT 的 username 部分, 格式为 ${clientid};${sdkappid};${connid};${expiry}
    local payload = json.decode(crypto.cipher_decrypt("AES-128-CBC", "ZERO", crypto.base64_decode(dat.payload),
        string.sub(ProductSecret, 1, 16), "0000000000000000"))
    local pwd
    if payload.encryptionType == 2 then
        local raw_key = crypto.base64_decode(payload.psk) -- 生成 MQTT 的 设备密钥 部分
        pwd = crypto.hmac_sha256(usr, raw_key):lower() .. ";hmacsha256" -- 根据物联网通信平台规则生成 password 字段
        log.info("PWD", pwd)
    elseif payload.encryptionType == 1 then
        io.writeFile("/client.crt", payload.clientCert)
        io.writeFile("/client.key", payload.clientKey)
        ssl = "tcp_ssl"
    end

    local addr, port = ProductId .. ".iotcloud.tencentdevices.com", 1883
    if type(sub) ~= "string" or sub == "" then
        sub = ProductId .. "/" .. mobile.imei() .. "/control"
    else
        sub = listTopic(sub, "addImei", ProductId, mobile.imei())
        local topics = {}
        for i = 1, #sub do
            topics[sub[i]] = tonumber(sub[i + 1]) or qos
        end
        sub = topics
    end
    if type(pub) ~= "string" or pub == "" then
        pub = ProductId .. "/" .. mobile.imei() .. "/event"
    else
        pub = listTopic(pub, "addImei", ProductId, mobile.imei())
    end

    mqttTask(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, addr, port, usr, pwd, cleansession,
        sub, pub, qos, retain, uid, clientID, "addImei", ssl, will, "1", cert)
    log.info("腾讯云新版连接方式开启")
end

---------------------------------------------------------- 参数配置,任务转发，线程守护主进程----------------------------------------------------------
function create.connect(pios, conf, reg, convert, passon, upprot, dwprot, webProtect, protectContent)
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
            --log.info("webProtect", webProtect, protectContent[1])
            local taskName = "DTU_" .. tostring(k)
            sysplus.taskInitEx(tcpTask, taskName, netCB, taskName, k, pios, reg, convert, passon, upprot, dwprot, unpack(v))
        elseif v[1] and v[1]:upper() == "MQTT" then
            log.warn("----------------------- MQTT is start! --------------------------------------")
            sys.taskInit(mqttTask, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 2))
        elseif v[1] and v[1]:upper() == "HTTP" then
            log.warn("----------------------- HTTP is start! --------------------------------------")
            sys.taskInit(function(cid, convert, passon, upprot, dwprot, uid, method, url, timeout, way, dtype, basic,
                headers, iscode, ishead, isbody)
                cid, timeout, uid = tonumber(cid) or 1, tonumber(timeout) or 30, tonumber(uid) or 1
                way, dtype = tonumber(way) or 1, tonumber(dtype) or 1
                local dwprotFnc = dwprot and dwprot[cid] and dwprot[cid] ~= "" and
                                      loadstring(dwprot[cid]:match("function(.+)end"))
                local upprotFnc = upprot and upprot[cid] and upprot[cid] ~= "" and
                                      loadstring(upprot[cid]:match("function(.+)end"))
                while true do
                    datalink[cid] =  mobile.status() == 1
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
                                            (tonumber(isbody) ~= 1 and body and (dtulib.fromHexnew(body)) or "")
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
            end, k, convert, passon, upprot, dwprot, unpack(v, 2))
        elseif v[1] and v[1]:upper() == "ONENET" then
            log.warn("----------------------- OneNET is start! --------------------------------------")
            sys.taskInit(oneNet_mqtt, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 3))
        elseif v[1] and v[1]:upper() == "ALIYUN" then
            log.warn("----------------------- Aliyun iot is start! --------------------------------------")
            -- while not ntp.isEnd() do
            --     sys.wait(1000)
            -- end
            socket.sntp()
            if v[2]:upper() == "OTOK" then -- 一型一密
                sys.taskInit(aliyunOtok, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 3))
            elseif v[2]:upper() == "OMOK" then -- 一机一密
                sys.taskInit(aliyunOmok, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 3))
            end
        elseif v[1] and v[1]:upper() == "TXIOTNEW" then
            log.warn("----------------------- tencent iot is start! --------------------------------------")
            socket.sntp()
            sys.taskInit(dev_txiotnew, k, pios, reg, convert, passon, upprot, dwprot, unpack(v, 2))
        end
    end
    -- 守护进程
    --log.info("webProtect", webProtect, protectContent[1])
    log.info("守护线程")
    -- sys.timerStart(sys.restart, rstTim, "Server connection failed")
    -- sys.timerStart(sys.restart, 60000, "Server connection failed")
    --log.info("webProtect", webProtect, protectContent[1])
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
        -- log.info("webProtect", webProtect, protectContent)
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
sys.subscribe("IP_LOSE", function(adapter)
    log.info("---------------------- 网络注册失败 ----------------------")
    log.info("mobile", "IP_LOSE", (adapter or -1) == socket.LWIP_GP)
end)

return create