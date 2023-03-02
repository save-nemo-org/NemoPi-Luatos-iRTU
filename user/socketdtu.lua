socketdtu={}
libnet = require "libnet"
dtulib = require "dtulib"
create = require "create"

-- 无网络重启时间，飞行模式启动时间
local rstTim = 300000
-- 定时采集任务的参数
interval, samptime = {0, 0, 0}, {0, 0, 0}

local outputSocket = {}
---------------------------------------------------------- SOKCET 服务 ----------------------------------------------------------
function socketdtu.tcpTask(dName, cid, pios, reg, convert, passon, upprot, dwprot, prot, ping, timeout, addr, port, uid, gap,
    report, intervalTime, ssl, login)
    log.info("进入到tcp里面了")
    cid, prot, timeout, uid = tonumber(cid) or 1, prot:upper(), tonumber(timeout) or 120, tonumber(uid) or 1
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
        log.info("进到sub里面了",data)
        log.info("进到sub里面了2",data:toHex())
        if data then
            log.info("进到data里面了")
            table.insert(outputSocket, data)
            for key, value in pairs(outputSocket) do
                log.info("KEY1",key,value)
            end
            sys_send(dName, socket.EVENT, 0)
        end
    end
    sys.subscribe("NET_SENT_RDY_" .. (passon and cid or uid), subMessage)
    while true do
        if mobile.status() ~= 1 and not sys.waitUntil("IP_READY", rstTim) then
            dtulib.restart("网络初始化失败！")
        end
        log.info("进到循环里面来了")
        log.info("mem.lua", rtos.meminfo())
        log.info("mem.sys", rtos.meminfo("sys"))
        log.info("prot", prot)
        log.info("ping", addr)
        local isUdp = prot == "TCP" and nil or true
        local isSsl = ssl and true or nil
        -- local isUdp = false
        -- local isSsl = false
        log.info("DNAME", dName, isUdp, isSsl, addr, prot, ping, port)
        socket.debug(netc, true)
        socket.config(netc, nil)
        result = libnet.waitLink(dName, 0, netc)
        result = libnet.connect(dName, timeout, netc, addr, port)
        if result then
            log.info("tcp连接成功", dName, addr, port)
            -- 登陆报文
            create.datalink[cid] = true
            local login_data = login or create.loginMsg(reg)
            if login_data then
                log.info("发送登录报文", login_data:toHex())
                socket.tx(netc, login_data)
            end
            interval[uid], samptime[uid] = tonumber(gap) or 0, tonumber(report) or 0
            while true do
                log.info("循环等待消息")
                log.info("passon", passon, ",cid", cid, ",UID", uid)
                local result, param = libnet.wait(dName, timeout * 1000, netc)
                if not result then
                    log.info("网络异常", result, param) 
                    break
                end
                if param == false then
                    local result, param = libnet.tx(dName, nil, netc, create.conver(ping))
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
                    log.info("DATA!",data)
                    log.info("DATA!!",data:toHex())
                    if data:sub(1, 5) == "rrpc," or data:sub(1, 7) == "config," then
                        local res, msg = pcall(create.userapi, data, pios)
                        if not res then
                            log.error("远程查询的API错误:", msg)
                        end
                        if convert == 0 and upprotFnc then -- 转换为用户自定义报文
                            res, msg = pcall(upprotFnc, msg)
                            if not res then
                                log.error("数据流模版错误:", msg)
                            end
                        end
                        if not socket.tx(netc, msg) then
                            break
                        end
                    elseif convert == 1 then -- 转换HEX String
                        sys.publish("NET_RECV_WAIT_" .. uid, uid, (data:fromHex()))
                    elseif convert == 0 and dwprotFnc then -- 转换用户自定义报文
                        local res, msg = pcall(dwprotFnc, data)
                        if not res or not msg then
                            log.error("数据流模版错误:", msg)
                        else
                            sys.publish("NET_RECV_WAIT_" .. uid, uid, res and msg or data)
                        end
                    else -- 默认不转换
                        log.info("走到这里了呀",data)
                        sys.publish("NET_RECV_WAIT_" .. uid, uid, data)
                    end
                    log.info("RXBUFF1",rx_buff)
                    rx_buff:del()
                    log.info("RXBUFF2",rx_buff)
                end
                log.info("USE大小1",tx_buff:used())
                log.info("表的大小是",#outputSocket)
                tx_buff:copy(nil, table.concat(outputSocket))
                outputSocket={}
                log.info("USE大小2",tx_buff:used())
                log.info("表的大小是2",#outputSocket)
                if tx_buff:used() > 0 then
                    local data = tx_buff:toStr(0, tx_buff:used())
                    log.info("DATA1",data)
                    log.info("DATA2a",data:toHex())
                    if convert == 1 then -- 转换为Hex String 报文
                        local result, param = libnet.tx(dName, nil, netc, data:toHex())
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
                log.info("TXBUFF3",tx_buff)
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
        create.datalink[cid] = false
        sys.wait((2 * idx) * 1000)
        idx = (idx > 9) and 1 or (idx + 1)
    end
end

