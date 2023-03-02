mqttdtu={}
libnet = require "libnet"
dtulib = require "dtulib"

-- 无网络重启时间，飞行模式启动时间
local rstTim= 300000

---------------------------------------------------------- MQTT 服务 ----------------------------------------------------------
local function listTopic(str, addImei, ProductKey, deviceName)
    local topics = str:split(";")
    if #topics == 1 and (not addImei or addImei == "") then
        topics[1] = topics[1]:sub(-1, -1) == "/" and topics[1] .. mobile.imei() or topics[1] .. "/" .. mobile.imei()
    else
        local tmp = {}
        for i = 1, #topics, 2 do
            tmp = topics[i]:split("/")
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

function mqttdtu.mqttTask(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, addr, port, usr, pwd,
    cleansession, sub, pub, qos, retain, uid, clientID, addImei, ssl, will, idAddImei, prTopic, cert)
    cid, keepAlive, timeout, uid = tonumber(cid) or 1, tonumber(keepAlive) or 300, tonumber(timeout), tonumber(uid)
    cleansession, qos, retain = tonumber(cleansession) or 0, tonumber(qos) or 0, tonumber(retain) or 0
    prTopic = prTopic and prTopic or ""
    log.info("CLIENTID", clientID)
    log.info("ADDIMEI", addImei)
    log.info("ADDIMEI!", type(addImei))
    log.info("IDADDIMEI", idAddImei)
    if idAddImei == "1" then
        log.info("为1，进到这里了")
        clientID = (clientID == "" or not clientID) and mobile.imei() or clientID
        log.info("CLIENTID2", clientID)
    else
        log.info("为空，进到这里了")
        clientID = (clientID == "" or not clientID) and mobile.imei() or mobile.imei() .. clientID
        log.info("CLIENTID3", clientID)
    end
    log.info("SUB1", sub)
    if timeout then
        sys.timerLoopStart(sys.publish, timeout * 1000, "AUTO_SAMPL_" .. uid)
    end
    if type(sub) == "string" then
        sub = listTopic(sub, addImei)
        local topics = {}
        for i = 1, #sub do
            topics[sub[i]] = tonumber(sub[i + 1]) or qos
        end
        sub = topics
    end
    for key, value in pairs(sub) do
        log.info("key", key, value)
    end
    if type(pub) == "string" then
        pub = listTopic(pub, addImei)
    end
    local dwprotFnc = dwprot and dwprot[cid] and dwprot[cid] ~= "" and loadstring(dwprot[cid]:match("function(.+)end"))
    local upprotFnc = upprot and upprot[cid] and upprot[cid] ~= "" and loadstring(upprot[cid]:match("function(.+)end"))
    if not will or will == "" then
        will = nil
    else
        will = {
            qos = 1,
            retain = 0,
            topic = will,
            payload = mobile.imei()
        }
    end
    log.info("MQTT HOST:PORT", addr, port)
    log.info("MQTT clientID,user,pwd", clientID, create.conver(usr), create.conver(pwd))
    local idx = 0
    while true do
        local messageId = false
        if mobile.status() ~= 1 and not sys.waitUntil("IP_READY", rstTim) then
            dtulib.restart("网络初始化失败!")
        end
        log.info("CONVER1", create.conver(usr))
        log.info("CONVER1", create.conver(pwd))
        log.info("CLIENTID", clientID)
        log.info("keepAlive", keepAlive)
        log.info("CLEANSESSION", cleansession)
        local mqttc = mqtt.create(nil, addr, port, ssl == "tcp_ssl" and true or false)
        -- 是否为ssl加密连接,默认不加密,true为无证书最简单的加密，table为有证书的加密
        mqttc:auth(clientID, create.conver(usr), create.conver(pwd))
        mqttc:keepalive(keepAlive)
        mqttc:connect()
        -- local mqttc = mqtt.client(clientID, keepAlive, conver(usr), conver(pwd), cleansession, will, "3.1.1")
        log.info("ADDR", addr)
        log.info("PORT", port)
        log.info("SSL", ssl)
        mqttc:on(function(mqtt_client, event, data, payload) -- mqtt回调注册
            -- 用户自定义代码，按event处理
            log.info("mqtt", "event", event, mqtt_client, data, payload)
            if event == "conack" then
                sys.publish("mqtt_conack"..(passon and cid or uid))
            elseif event == "recv" then -- 服务器下发的数据
                log.info("mqtt", "downlink", "topic", data, "payload", payload)
                sys.publish("NET_SENT_RDY_" .. (passon and cid or uid), "recv", data, payload)
                -- 这里继续加自定义的业务处理逻辑
            elseif event == "sent" then -- publish成功后的事件
                log.info("mqtt", "sent", "pkgid", data)
            end
        end)
        local conres = sys.waitUntil("mqtt_conack"..(passon and cid or uid), 30000)
        if mqttc:ready() and conres then
            log.info("mqtt连接成功")
            create.datalink[cid] = true
            -- 初始化订阅主题
            log.info("sub1", sub[1])
            log.info("pub1", pub[1])
            log.info("qos1", qos)
            -- sub1={["/luatos/1234567"]=1,["/luatos/12345678"]=2}
            if mqttc:subscribe(sub, qos) then
                -- local a=mqttc:subscribe(topic3,1)
                log.info("A的", a)
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
                            if not mqttc:publish(pub[1], (topic:toHex()), tonumber(pub[2]) or qos, retain) then
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
                                res, msg = pcall(upprotFnc, msg)
                                if not res then
                                    log.error("数据流模版错误:", msg)
                                end
                            end
                            if not mqttc:publish(pub[1], msg, tonumber(pub[2]) or qos, retain) then
                                break
                            end
                        elseif convert == 1 then -- 转换为HEX String
                            log.info("进到这里了2")
                            sys.publish("UART_SENT_RDY_" .. uid, uid, (payload:fromHex()))
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
        create.datalink[cid] = false
        mqttc:disconnect()
        sys.wait((2 * idx) * 1000)
        idx = (idx > 9) and 1 or (idx + 1)
    end
end

---------------------------------------------------------- OneNet 云服务器 ----------------------------------------------------------
-- onenet新版 mqtt 协议支持
function mqttdtu.oneNet_mqtt(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, addr, port, productId,
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

function mqttdtu.getOneSecret(RegionId, ProductKey, ProductSecret)
    if io.exists(alikey) then
        local dat, res, err = json.decode(io.readFile(alikey))
        if res then
            return dat.data.deviceName, dat.data.deviceSecret
        end
    end

    local random = os.time()
    local data = "deviceName" .. mobile.imei() .. "productKey" .. ProductKey .. "random" .. random
    local sign = crypto.hmac_md5(data, ProductSecret)
    local body = "productKey=" .. ProductKey .. "&deviceName=" .. mobile.imei() .. "&random=" .. random .. "&sign=" ..
                     sign .. "&signMethod=HmacMD5"
    for i = 1, 3 do
        local code, head, body = http.request("POST",
            "https://iot-auth." .. RegionId .. ".aliyuncs.com/auth/register/device", nil, body)
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
function mqttdtu.aliyunOmok(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, RegionId, ProductKey,
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
function mqttdtu.aliyunOtok(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, RegionId, ProductKey,
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

---------------------------------------------------------- 腾讯IOT云 ----------------------------------------------------------

function mqttdtu.txiot(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, Region, ProductId, SecretId,
    SecretKey, sub, pub, cleansession, qos, uid)
    if not io.exists("/qqiot.dat") then
        local version = "2018-06-14"
        local data = {
            ProductId = ProductId,
            DeviceName = mobile.imei()
        }
        local timestamp = os.time()
        local head = {
            ["X-TC-Action"] = "CreateDevice",
            ["X-TC-Timestamp"] = timestamp,
            ["X-TC-Version"] = "2018-06-14",
            ["X-TC-Region"] = (not Region or Region == "") and "ap-guangzhou" or Region,
            ["Content-Type"] = "application/json",
            Authorization = "TC3-HMAC-SHA256 Credential=" .. SecretId .. "/"
        }
        local SignedHeaders = "content-type;host"
        local CanonicalRequest = "POST\n/\n\ncontent-type:application/json\nhost:iotcloud.tencentcloudapi.com\n\n" ..
                                     SignedHeaders .. "\n" .. crypto.sha256(json.encode(data)):lower()
        local c = os.date("!*t")
        local date = string.format("%04d-%02d-%02d", c.year, c.month, c.day)
        local CredentialScope = date .. "/iotcloud/tc3_request"
        local StringToSign = "TC3-HMAC-SHA256\n" .. timestamp .. "\n" .. CredentialScope .. "\n" ..
                                 crypto.sha256(CanonicalRequest):lower()
        local SecretDate = crypto.hmac_sha256(date, "TC3" .. SecretKey):fromHex()
        local SecretService = crypto.hmac_sha256("iotcloud", SecretDate):fromHex()
        local SecretSigning = crypto.hmac_sha256("tc3_request", SecretService):fromHex()
        local Signature = crypto.hmac_sha256(StringToSign, SecretSigning):lower()
        head.Authorization = head.Authorization .. CredentialScope .. ",SignedHeaders=" .. SignedHeaders ..
                                 ",Signature=" .. Signature
        for i = 1, 3 do
            local code, head, body = http.request("POST", "https://iotcloud.tencentcloudapi.com", head, data)
            if body then
                local dat, result, errinfo = json.decode(body)
                if result then
                    if not dat.Response.Error then
                        io.writeFile("/qqiot.dat", body)
                        -- log.info("腾讯云注册设备成功:", body)
                    else
                        log.info("腾讯云注册设备失败:", body)
                    end
                    break
                end
            end
            sys.wait(5000)
        end
    end
    if not io.exists("/qqiot.dat") then
        log.warn("腾讯云设备注册失败或不存在设备信息!")
        return
    end
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
    local dat = json.decode(io.readFile("/qqiot.dat"))
    local clientID = ProductId .. mobile.imei()
    local connid = rtos.tick()
    local expiry = tostring(os.time() + 3600)
    local usr = string.format("%s;12010126;%s;%s", clientID, connid, expiry)
    local raw_key = crypto.base64_decode(dat.Response.DevicePsk)
    local pwd = crypto.hmac_sha256(usr, raw_key):lower() .. ";hmacsha256"
    local addr, port = "iotcloud-mqtt.gz.tencentdevices.com", 1883
    mqttTask(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, addr, port, usr, pwd, cleansession,
        sub, pub, qos, retain, uid, clientID, addImei, ssl, will, "1")
end
---------------------------------------------------------------------------------------------------------------------------------------------------
local function serBack(body, head)
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
end

function mqttdtu.dev_txiotnew(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, Region, deviceName,
    ProductId, ProductSecret, sub, pub, cleansession, qos, uid)
    enrol_end = false
    if not io.exists("/qqiot.dat") then
        local nonce = math.random(1, 100)
        -- local version = "2018-06-14"
        -- local data = {ProductId = ProductId, DeviceName = misc.getImei()}
        deviceName = deviceName ~= "" and deviceName or mobile.imei()
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
    local payload = json.decode(crypto.aes_decrypt("CBC", "ZERO", crypto.base64_decode(dat.payload),
        string.sub(ProductSecret, 1, 16), "0000000000000000"))
    local pwd
    log.info("CLIENTID", clientID)
    log.info("user", usr)
    if payload.encryptionType == 2 then
        local raw_key = crypto.base64_decode(payload.psk) -- 生成 MQTT 的 设备密钥 部分
        pwd = crypto.hmac_sha256(usr, raw_key):lower() .. ";hmacsha256" -- 根据物联网通信平台规则生成 password 字段
        log.info("PWD", pwd)
    elseif payload.encryptionType == 1 then
        io.writeFile("/client.crt", payload.clientCert)
        io.writeFile("/client.key", payload.clientKey)
        ssl = "tcp_ssl"
    end
    log.info("SECRETID", deviceName)
    log.info("productid", ProductId)
    log.info("SecretKey", ProductKey)
    local addr, port = ProductId .. ".iotcloud.tencentdevices.com", 1883
    log.info("ADDR", addr)
    if type(sub) ~= "string" or sub == "" then
        sub = ProductId .. "/" .. mobilie.imei() .. "/control"
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
    log.info("sub", sub)
    log.info("pub", pub)
    log.info("qos", qos)
    mqttTask(cid, pios, reg, convert, passon, upprot, dwprot, keepAlive, timeout, addr, port, usr, pwd, cleansession,
        sub, pub, qos, retain, uid, clientID, addImei, ssl, will, "1", cert)
    log.info("腾讯云新版连接方式开启")
end

