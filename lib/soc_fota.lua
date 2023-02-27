-- 用http方式下载ota固件并实现升级
--[[
-- 这个是用uart3直接把升级包发给mcu，作为本地升级的一种参考，高速串口单次发送不要超过4K
local rbuff = zbuff.create(16384)
local function uartRx(id, len)
    uart.rx(id, rbuff)
    if rbuff:used() > 0 then 
        local isError,fotaDone,nCache = fota.run(rbuff)
        
        if not isError then
            
        else
            log.error("fota写入异常，请至少在1秒后重试")
            fota.finish(false)
            return
        end
        rbuff:del()
        -- log.info("收到服务器数据，长度", rbuff:used(), "fota结果", isError, done, "总共", filelen)
        if fotaDone then
            log.info("下载完成")
            sys.publish("downloadOK")
        end
    end
end

local function otaTask()
    local spiFlash = spi.deviceSetup(spi.SPI_1,pin.PA7,0,0,8,24*1000*1000,spi.MSB,1,1)
    fota.init(0, 0x00200000, spiFlash)
    while not fota.wait() do
        sys.wait(100)
    end
    
    uart.setup(3,1500000)
    uart.on(3, "receive", uartRx)
    uart.write(3,"ready")
    sys.waitUntil("downloadOK")                       
    while true do
        local isError,fotaDone  = fota.isDone()
        if fotaDone then
            fota.finish(true)
            log.info("FOTA完成")
            rtos.reboot()   --如果还有其他事情要做，就不要立刻reboot
            break
        end
        sys.wait(100)
    end
end
function otaDemo()
    sys.taskInit(otaTask)
end
]]


local libnet = require "libnet"

local taskName = "OTA_TASK"
local function netCB(msg)
    if msg[1] == socket.EVENT then
        log.info("socket网络状态变更")
    elseif msg[1] == socket.TX_OK then
        log.info("socket发送完成")
    elseif msg[1] == socket.EV_NW_RESULT_CLOSE then
        log.info("socket关闭")
    else
        log.info("未处理消息", msg[1], msg[2], msg[3], msg[4])
    end
end

local function otaTask()
    fota.init()
    local isError, param, ip, port, total, findhead, filelen, rcvCache,d1,d2,statusCode,retry,rspHead,rcvChunked,done,fotaDone,nCache
    local tbuff = zbuff.create(512)
    local rbuff = zbuff.create(4096)
    local netc = socket.create(nil, taskName)
    socket.config(netc, nil, nil, nil) -- http用的普通TCP连接
    filelen = 0
    total = 0
    retry = 0
    done = false
    rspHead = {}
    local result = libnet.waitLink(taskName, 0, netc)
    while retry < 3 and not done do
        result = libnet.connect(taskName, 30000, netc, "airtest.openluat.com", 2900) --后续出了http库则直接用http来处理
        tbuff:del()
        -- 用的iot平台，所以固件名称和版本号需要对应处理
        -- 用的自建平台，可以自主定制规则
        local v = rtos.version()
        v = tonumber(v:sub(2, 5))
        tbuff:copy(0, "GET /download/ce11.bin" .. " HTTP/1.1\r\n")
        tbuff:copy(nil,"Host: airtest.openluat.com:2900\r\n")
        if filelen > 0 then --断网重连的话，只需要下载剩余的部分就行了
            tbuff:copy(nil,"Range: bytes=" .. total .. "-\r\n") 
        end
        
       tbuff:copy(nil,"Accept: application/octet-stream\r\n\r\n")
        log.info(tbuff:query())
        result = libnet.tx(taskName, 5000, netc, tbuff)
        rbuff:del()
        findhead = false
        while result do
            isError, param, ip, port = socket.rx(netc, rbuff)
            if isError then
                log.info("服务器断开了", isError, param, ip, port)
                break
            end
            if rbuff:used() > 0 then
                if findhead then
                    isError,fotaDone,nCache = fota.run(rbuff)
                    
                    if not isError then
                        total = total + rbuff:used()
                    else
                        log.error("fota写入异常，请至少在1秒后重试")
                        fota.finish(false)
                        done = true
                        break
                    end
                    log.info("收到服务器数据，长度", rbuff:used(), "fota结果", isError, done, "总共", filelen)
                    rbuff:del()
                    if fotaDone then
                        log.info("下载完成")
                        while true do
                            isError,fotaDone  = fota.isDone()
                            if fotaDone then
                                fota.finish(true)
                                log.info("FOTA完成")
                                done = true
                                sys.publish("IRTU_UPDATE_RES", res == true)
                            
                                break
                            end
                            sys.wait(100)
                        end
                        break
                    end
                else
                    rcvCache = rbuff:query()
                    d1,d2 = rcvCache:find("\r\n\r\n")
                    -- 打印出http response head
                    -- log.info(rcvCache:sub(1, d2))    
                    if d2 then
                        --状态行
                        _,d1,statusCode = rcvCache:find("%s(%d+)%s.-\r\n")
                        if not statusCode then
                            log.info("http没有状态返回")
                            break
                        end
                        statusCode = tonumber(statusCode)
                        if statusCode ~= 200 and statusCode ~= 206 then
                            log.info("http应答不OK", statusCode)
                            done = true
                            break
                        end
                        --应答头
                        for k,v in string.gmatch(rcvCache:sub(d1+1,d2-2),"(.-):%s*(.-)\r\n") do
                            rspHead[k] = v
                            if (string.upper(k)==string.upper("Transfer-Encoding")) and (string.upper(v)==string.upper("chunked")) then rcvChunked = true end
                        end
                        if filelen == 0 and not rcvChunked then 
                            if not rcvChunked then
                                filelen = tonumber(rspHead["Content-Length"] or "2147483647")
                            end
                        end
                        --未处理的body数据
                        rbuff:del(0, d2)
                        isError,fotaDone,nCache = fota.run(rbuff)
                        if not isError then
                            total = total + rbuff:used()
                        else
                            log.error("fota写入异常，请至少在1秒后重试")
                            fota.finish(false)
                            done = true
                            break
                        end
                        log.info("收到服务器数据，长度", rbuff:used(), "fota结果", isError, done, "总共", filelen)
                        rbuff:del()
                        if fotaDone then
                            log.info("下载完成")
                            while true do
                                isError,fotaDone  = fota.isDone()
                                if fotaDone then
                                    fota.finish(true)
                                    log.info("FOTA完成")
                                    done = true
                                    sys.publish("IRTU_UPDATE_RES", res == true)
                                    
                                    break
                                end
                                sys.wait(100)
                            end
                            break
                        end
                    else
                        break
                    end
                    findhead = true
                end
            end 
            log.info("等待新数据到来")
            result, param = libnet.wait(taskName, 5000, netc)
            log.info(result, param)
            if not result then
                log.info("服务器断开了", result, param)
                break
            elseif not param then
                log.info("服务器没有数据", result, param)
                break
            end
        end
        libnet.close(taskName, 5000, netc)
        retry = retry + 1
    end
    socket.release(netc)
    sysplus.taskDel(taskName)
    fota.finish(false)
end

function otaDemo()
    sysplus.taskInitEx(otaTask, taskName, netCB)
end
