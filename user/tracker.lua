--- 模块功能：GPS TRACKERE 主逻辑


-- 解除报警的等待时间秒,GPS打开的起始时间utc秒
local clearTime, startTime = 300, 0
-- 轨迹消息缓冲区
-- local trackFile = {{}, {}, {}, {}, {}, {}, {}, {}, {}, {}}
local trackFile = {}
-- 传感器数据
local sens = {
    vib = false, -- 震动检测
    acc = false, -- 开锁检测
    act = false, -- 启动检测
    chg = false, -- 充电检测
    und = false, -- 剪线检测
    wup = false, -- 唤醒检测
    vcc = 0, -- 电池电压
}
local openFlag=false
--GPS打开功能
function open(uid,baud)
    libgnss.clear()
    uart.setup(uid, baud)
    pm.power(pm.GPS, true)
    log.info("----------------------------------- GPS START -----------------------------------")
    if openFlag then return end
    openFlag=true
    tid=sys.timerLoopStart(function()
        -- log.info("Air800 上报GSP信息", getAllMsg())
        sys.publish("GPS_MSG_REPORT", locateMessage())
    end, cycl * 1000)
end

function close(uid)
    openFlag = false
    sys.timerStop(tid)
    pm.power(pm.GPS, false)
    uart.close(uid)
    log.info("----------------------------------- GPS CLOSE -----------------------------------")
end

--- 获取GPS模块是否处于开启状态
-- @return boolean result，true表示开启状态，false或者nil表示关闭状态
-- @usage gps.isOpen()
function isOpen() return openFlag end

----------------------------------------------------------传感器部分----------------------------------------------------------
-- 配置GPS用到的IO: led脚，vib震动输入脚，ACC输入脚,内置电池充电状态监视脚,adc通道,分压比
function sensMonitor(ledio, vibio, accio, chgio, adcid, ratio)
    -- 点火监测采样队列
    local powerVolt, adcQue, acc, chg = 0, {0, 0, 0, 0, 0}
    -- GPS 定位成功指示灯
    if ledio and default.pios[ledio] then
        default.pios[ledio] = nil
        local led = gpio.setup(tonumber(ledio:sub(4, -1)), 0)
        sys.subscribe("GPS_MSG_REPORT", led)
    end
    -- 震动传感器检测
    if vibio and default.pios[vibio] then
        gpio.setup(tonumber(vibio:sub(4, -1)), function(msg) if msg == gpio.RISING then sens.vib = true end end, gpio.PULLUP)
        default.pios[vibio] = nil
    end
    -- ACC开锁检测
    if accio and default.pios[accio] then
        acc = gpio.setup(tonumber(accio:sub(4, -1)), nil, gpio.PULLUP)
        default.pios[accio] = nil
    end
    -- 内置锂电池充电状态监控脚
    if chgio and default.pios[chgio] then
        chg = gpio.setup(tonumber(chgio:sub(4, -1)), nil, gpio.PULLUP)
        default.pios[chgio] = nil
    end
    adc.open(tonumber(adcid) or 0)
    while true do
        local adcValue, voltValue = adc.read(tonumber(adcid) or 0)
        if adcValue ~= 0xFFFF or voltValue ~= 0xFFFF then
            voltValue = voltValue * (tonumber(ratio)) / 3
            -- 点火检测部分
            powerVolt = (adcQue[1] + adcQue[2] + adcQue[3] + adcQue[4] + adcQue[5]) / 5
            table.remove(adcQue, 1)
            table.insert(adcQue, voltValue)
            if voltValue + 1500 < powerVolt or voltValue - 1500 > powerVolt then
                sens.act = true
            else
                sens.act = false
            end
        end
        sens.acc, sens.chg = acc and acc() == 0, chg and chg() == 0
        sens.vcc, sens.und = voltValue, voltValue < 4000
        sys.wait(1000)
        sens.vib = false
    end
    adc.close(tonumber(adcid) or 0)
end
----------------------------------------------------------设备逻辑任务----------------------------------------------------------
-- 上报设备状态,这里是用户自定义上报报文的顺序的
-- sta = {"isopen", "vib", "acc", "act", "chg", "und", "volt", "vbat", "csq"}
-- 远程获取gps的信息。
function deviceMessage(format)

    if format:lower() ~= "hex" then
        return json.encode({
            sta = {isOpen(),  sens.vib, sens.acc, sens.act, sens.chg, sens.und, sens.vcc, mobile.rssi()}
        })
    else
        return pack.pack(">b7IHb", 0x55, isOpen() and 1 or 0, sens.vib and 1 or 0,
        sens.acc and 1 or 0, sens.act and 1 or 0, sens.chg and 1 or 0, sens.und and 1 or 0, sens.vcc, mobile.rssi())
    end
end

-- 上传定位信息
-- [是否有效,经度,纬度,海拔,方位角,速度,载噪比,定位卫星,时间戳]
-- 用户自定义上报GPS数据的报文顺序
-- msg = {"isfix", "stamp", "lng", "lat", "altitude", "azimuth", "speed", "sateCno", "sateCnt"},
function locateMessage(format)
    local isFix = libgnss.isFix()
    local lat, lng, speed = libgnss.getIntLocation()
    local gsvTable=libgnss.getGsv()
    local ggaTable=libgnss.getGga()
    local ggatable,result,errinfo=json.decode(ggaTable)
    local altitude = ggatable["alitude"]       --海拔
    log.info("ggatable",ggatable["alitude"])
    local gsvtable,result,errinfo=json.decode(gsvTable)
    log.info("gsvtable",gsvtable["sats"]["azimuth"])
    local azimuth = gsvtable["sats"]["azimuth"]    --方向角

    local sateCnt = ggatable["satellites_tracked"]   --gga的参与定位的卫星数量
    log.info("ggatable2",ggatable["satellites_tracked"])

    -- local sateCno = {}
    -- if sys.is8910 then
    --     sateCno = gpsv2.getMaxCno()
    -- else
    --     sateCno = gpsv2.getCno()
    --     table.sort(sateCno)
    --     sateCno = table.remove(sateCno) or 0
    -- end
    -- local total_sats=gsvtable[total_sats]
    if format:lower() ~= "hex" then
        return json.encode({msg = {isFix, os.time(), lng, lat, altitude, azimuth, speed, sateCnt}})
    else
        return pack.pack(">b2i3H2b3", 0xAA, isFix and 1 or 0, os.time(), lng, lat, altitude, azimuth, speed, sateCnt)
    end
end

-- 用户捆绑GPS的串口,波特率，功耗模式，采集间隔,采集方式支持触发和持续, 报文数据格式支持 json 和 hex，缓冲条数,数据分隔符(不包含,),状态报文间隔分钟
function alert(uid, baud, pwmode, sleep, guard, format, num, sep, interval, cid)
    uid, baud, num = tonumber(uid), tonumber(baud), tonumber(num) or 0
    interval = (tonumber(interval) or 0) * 60000
    local cnt, report = 0, function(format)
        log.info("进到REPORT里面来了")
        sys.publish("NET_SENT_RDY_" .. tonumber(cid) or uid, deviceMessage(format)) end
    while true do
        -- 布防判断
        sys.wait(3000)
        log.info("0---------------------------0", "GPS 任务启动")
        if not isOpen()  then
            startTime = os.time()
            -- GPS TRACKER 模式
            open(uid, baud,sleep)
            -- 布防上报
            log.info("gps开了+++++++")
            report(format)
            log.info("INTERVAL",interval)
            if interval ~= 0 then
                log.info("到这里了interval不等于0")
                sys.timerLoopStart(report, interval, format) end
        end
        while isOpen() do
            log.info("GPSV2open",isOpen())
            -- 撤防判断
            -- if os.difftime(os.time(), startTime) > clearTime then
            --     log.info("进到撤防判断里面来了")
            --     if guard and sens.vib and sens.acc and sens.act and sens.und and gpsv2.getSpeed() == 0 then
            --         log.info("关闭rep")
            --         sys.timerStopAll(report)
            --         close(uid)
            --     else
            --         startTime = os.time()
            --     end
            -- end
            --上报消息
            if sys.waitUntil("GPS_MSG_REPORT",1000) then
                log.info("进到这里来了GPS_MSG_REPORT")
                if num == 0 then
                    sys.publish("NET_SENT_RDY_" .. tonumber(cid) or uid, locateMessage(format))
                    log.info("NUM==0",num)
                else
                    log.info("CNT++",cnt)
                    cnt = cnt < num and cnt + 1 or 0
                    table.insert(trackFile, locateMessage(format))
                    log.info("gps里面的内容是",locateMessage(format))
                    log.info("表里面的内容是",trackFile[1])
                    if cnt == 0 then 
                        log.info("进到cnt=0里面了")
                        sys.publish("NET_SENT_RDY_" .. tonumber(cid) or uid, table.concat(trackFile, sep)) 
                        trackFile={}
                    end     
                end
            else
                if not isOpen() then
                break
                end
            end
            sys.wait(100)
        end
        log.info("aaaaa")
        if  sys.timerIsActive(report,format) then
            log.info("到这里关闭了")
            sys.timerStop(report,format)
        end
        sys.waitUntil("GPS_GO")
        sys.wait(100)
    end
end

-- NTP同步后清零一次startTime,避免第一次开机的时候utc时间跳变
sys.subscribe("NTP_SUCCEED", function()startTime = os.time() end)
-- 订阅服务器远程唤醒指令
sys.subscribe("REMOTE_WAKEUP", function()
    sys.publish("GPS_GO")
    sens.wup = true 
end)
--订阅服务器远程关闭指令
sys.subscribe("REMOTE_CLOSE",function ()
    log.info("GPS已关闭-------------------------------------")
    close(uid)
end)  