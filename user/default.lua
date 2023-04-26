default = {}

require "libnet"
libfota=require"libfota"
db=require "db"
create =require "create"
dtulib=require "dtulib"
local lbsLoc = require("lbsLoc")


-- 串口缓冲区最大值
local SENDSIZE =4096
-- 串口写空闲
local writeIdle = {true, true, true}
-- 串口读缓冲区
local recvBuff, writeBuff = {{}, {}, {}, {}}, {{}, {}, {}, {}}
-- 串口流量统计
local flowCount, timecnt = {0, 0, 0, 0}, 1
-- 定时采集任务的初始时间
local startTime = {0, 0, 0}
-- 定时采集任务缓冲区
local sendBuff = {{}, {}, {}, {}}
-- 基站定位坐标
local lbs = {lat, lng}
local gpsUartId=2
-- 配置文件
local dtu = {
    defchan = 1, -- 默认监听通道
    host = "", -- 自定义参数服务器
    passon = 0, --透传标志位
    plate = 0, --识别码标志位
    convert = 0, --hex转换标志位
    reg = 0, -- 登陆注册包
    param_ver = 0, -- 参数版本
    flow = 0, -- 流量监控
    fota = 0, -- 远程升级
    uartReadTime = 500, -- 串口读超时
    netReadTime = 50, -- 网络读超时
    nolog = "1", --日志输出
    isRndis = "0", --是否打开Rndis
    isRndis2="1",
    webProtect = "0", --是否守护全部网络通道
    pwrmod = "normal",
    password = "",
    protectContent={}, --守护的线路
    upprot = {}, -- 上行自定义协议
    dwprot = {}, -- 下行自定义协议
    apn = {nil, nil, nil}, -- 用户自定义APN
    cmds = {{}, {}}, -- 自动采集任务参数
    pins = {"", "", ""}, -- 用户自定义IO: netled,netready,rstcnf,
    conf = {{}, {}, {}, {}, {}, {}, {}}, -- 用户通道参数
    preset = {number = "", delay = 1, smsword = "SMS_UPDATE"}, -- 用户预定义的来电电话,延时时间,短信关键字
    uconf = {
        {1, 115200, 8, 1,  uart.None,1,18,0},
        {1, 115200, 8, 1,  uart.None,1,18,0},
        -- {1, 115200, 8, 1,  uart.None},
        -- {1, 115200, 8, 1,  uart.None},
        -- {3, 115200, 8, 1,  uart.None},
    }, -- 串口配置表
    gps = {
        fun = {"", "115200", "0", "5", "1", "json", "100", ";", "60"}, -- 用户捆绑GPS的串口,波特率，功耗模式，采集间隔,采集方式支持触发和持续, 报文数据格式支持 json 和 hex，缓冲条数,分隔符,状态报文间隔
        pio = {"", "", "", "", "0", "16"}, -- 配置GPS用到的IO: led脚，vib震动输入脚，ACC输入脚,内置电池充电状态监视脚,adc通道,分压比
    },
    warn = {
        gpio = {},
        adc0 = {},
        adc1 = {},
        vbatt = {}
    },
    task = {}, -- 用户自定义任务列表
}
-- 获取参数版本
getParamVer = function() return dtu.param_ver end

-- 保存获取的基站坐标
function default.setLocation(lat, lng)
    lbs.lat, lbs.lng = lat, lng
    log.info("基站定位请求的结果:", lat, lng)
end

sys.timerLoopStart(function ()
    -- log.info("RTOS>MEMINFO",rtos.meminfo("sys"))
    -- log.info("RTOS>MEMINFO2",rtos.meminfo("lua"))
    collectgarbage()
end,1000)

---------------------------------------------------------- 开机读取保存的配置文件 ----------------------------------------------------------
-- 自动任务采集
local function autoSampl(uid, t)
    while true do
        sys.waitUntil("AUTO_SAMPL_" .. uid)
        for i = 2, #t do
            local str = t[i]:match("function(.+)end")
            if not str then
                if t[i] ~= "" then 
                    write(uid, (dtulib.fromHexnew(t[i]))) end
            else
                local res, msg = pcall(loadstring(str))
                if res then
                    sys.publish("NET_SENT_RDY_" .. uid, msg)
                end
            end
            sys.wait(tonumber(t[1]))
        end
    end
end
-- 加载用户预置的配置文件
local cfg = db.new("/luadb/".. "irtu.cfg")
local sheet = cfg:export()
-- log.info("用户脚本文件:", cfg:export("string"))
if type(sheet) == "table" and sheet.uconf then
    dtu = sheet
    if dtu.apn and dtu.apn[1] and dtu.apn[1] ~= "" then mobile.apn(nil,nil,dtu.apn[1],dtu.apn[2],dtu.apn[3]) end
    if dtu.cmds and dtu.cmds[1] and tonumber(dtu.cmds[1][1]) then sys.taskInit(autoSampl, 1, dtu.cmds[1]) end
    if dtu.cmds and dtu.cmds[2] and tonumber(dtu.cmds[2][1]) then sys.taskInit(autoSampl, 2, dtu.cmds[2]) end
    if tonumber(dtu.nolog) ~= 1 then
        log.info("没有日志了哦")
        log.setLevel("SILENT") 
    end
end

-- 解除报警的等待时间秒,GPS打开的起始时间utc秒
local clearTime, gpsstartTime = 300, 0
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
function open(uid,baud,sleep)
    libgnss.clear()
    uart.setup(uid, baud)
    pm.power(pm.GPS, true)
    libgnss.bind(uid)
    gpsUartId=uid
    log.info("----------------------------------- GPS START -----------------------------------")
    if openFlag then return end
    openFlag=true
    tid=sys.timerLoopStart(function()
        -- log.info("Air800 上报GSP信息", getAllMsg())
        sys.publish("GPS_MSG_REPORT", libgnss.isFix() and 1 or 0)
    end, sleep * 1000)
end

function close()
    openFlag = false
    sys.timerStop(tid)
    pm.power(pm.GPS, false)
    uart.close(gpsUartId)
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
    if ledio and pios[ledio] then
        pios[ledio] = nil
        local led = gpio.setup(tonumber(ledio:sub(4, -1)), 0)
        sys.subscribe("GPS_MSG_REPORT", led)
    end
    -- 震动传感器检测
    if vibio and pios[vibio] then
        gpio.setup(tonumber(vibio:sub(4, -1)), function(msg) if msg == gpio.RISING then sens.vib = true end end, gpio.PULLUP)
        pios[vibio] = nil
    end
    -- ACC开锁检测
    if accio and pios[accio] then
        acc = gpio.setup(tonumber(accio:sub(4, -1)), nil, gpio.PULLUP)
       pios[accio] = nil
    end
    -- 内置锂电池充电状态监控脚
    if chgio and pios[chgio] then
        chg = gpio.setup(tonumber(chgio:sub(4, -1)), nil, gpio.PULLUP)
        pios[chgio] = nil
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
    log.info("进到DEVICE里面来了啊")
    if format:lower() ~= "hex" then
        return json.encode({
            sta = {isOpen(),  sens.vib, sens.acc, sens.act, sens.chg, sens.und, sens.vcc, mobile.csq()}
        })
    else
        return pack.pack(">b7IHb", 0x55, isOpen() and 1 or 0, sens.vib and 1 or 0,
        sens.acc and 1 or 0, sens.act and 1 or 0, sens.chg and 1 or 0, sens.und and 1 or 0, sens.vcc, mobile.csq())
    end
end

-- 上传定位信息
-- [是否有效,经度,纬度,海拔,方位角,速度,载噪比,定位卫星,时间戳]
-- 用户自定义上报GPS数据的报文顺序
-- msg = {"isfix", "stamp", "lng", "lat", "altitude", "azimuth", "speed", "sateCno", "sateCnt"},
function locateMessage(format)
    local isFix = libgnss.isFix()
    local a, b, speed = libgnss.getIntLocation()
    local gsvTable=libgnss.getGsv()
    local ggaTable=libgnss.getGga()
    local altitude = ggaTable["altitude"]       --海拔
    if gsvTable["sats"] then
        if gsvTable["sats"][1] then
            if gsvTable["sats"][1]["azimuth"] then
                azimuth = gsvTable["sats"][1]["azimuth"]
            else
                azimuth=0     
            end
        else
            azimuth=0 
        end
    else
        azimuth=0
    end
    log.info("AZIMUTH",azimuth)
    local sateCnt = ggaTable["satellites_tracked"]   --gga的参与定位的卫星数量
    local rmc = libgnss.getRmc(2)
    local lat,lng=rmc.lat, rmc.lng
    log.info("rmc", rmc.lat, rmc.lng)
    if format:lower() ~= "hex" then
        return json.encode({msg = {isFix, os.time(), lng, lat, altitude, azimuth, speed, sateCnt}})
    else
        return pack.pack(">b2i3H2b3", 0xAA, isFix and 1 or 0, os.time(), lng, lat, altitude, azimuth, speed, sateCnt)
    end
end

-- 用户捆绑GPS的串口,波特率，功耗模式，采集间隔,采集方式支持触发和持续, 报文数据格式支持 json 和 hex，缓冲条数,数据分隔符(不包含,),状态报文间隔分钟
function alert(uid, baud, pwmode, sleep, guard, format, num, sep, interval, cid)
    uid, baud, num = tonumber(uid), tonumber(baud), tonumber(num) or 0
    sleep=tonumber(sleep) or 60
    interval = (tonumber(interval) or 0) * 60000
    local cnt=0
    local report = function(format)
        sys.publish("NET_SENT_RDY_" .. tonumber(cid) or uid, deviceMessage(format)) end
    while true do
        -- 布防判断
        sys.wait(3000)
        log.info("0---------------------------0", "GPS 任务启动")
        if not isOpen()  then
            gpsstartTime = os.time()
            
            -- GPS TRACKER 模式
            open(uid, baud,sleep)
            -- 布防上报
            log.info("gps开了+++++++")
            report(format)
            log.info("INTERVAL",interval)
            if interval ~= 0 then
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
                else
                    cnt = cnt < num and cnt + 1 or 0
                    table.insert(trackFile, locateMessage(format))
                    if cnt == 0 then 
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
        if  sys.timerIsActive(report,format) then
            sys.timerStop(report,format)
        end
        sys.waitUntil("GPS_GO")
        sys.wait(100)
    end
end

-- NTP同步后清零一次startTime,避免第一次开机的时候utc时间跳变
-- sys.subscribe("NTP_SUCCEED", function()startTime = os.time() end)
sys.taskInit(function()
    -- NTP只需要等一次,执行完成后这个task就退出了,释放内存
    sys.waitUntil("NTP_UPDATE")
    local t = os.date("*t")
    log.info("网络时间已同步", string.format("%04d-%02d-%02d %02d:%02d:%02d", t.year,t.month,t.day,t.hour,t.min,t.sec))
    gpsstartTime = os.time()
end)
-- 订阅服务器远程唤醒指令
sys.subscribe("REMOTE_WAKEUP", function()
    sys.publish("GPS_GO")
    sens.wup = true 
end)
--订阅服务器远程关闭指令
sys.subscribe("REMOTE_CLOSE",function ()
    log.info("GPS已关闭-------------------------------------")
    close()
end)
---------------------------------------------------------- 用户控制 GPIO 配置 ----------------------------------------------------------
-- function gpio_set() end

pios = {
    pio1 = gpio.setup(1, nil, gpio.PULLDOWN),
    pio2 = gpio.setup(2, nil, gpio.PULLDOWN),
    pio3 = gpio.setup(3, nil, gpio.PULLDOWN),
    pio4 = gpio.setup(4, nil, gpio.PULLDOWN),
    pio5 =gpio.setup(5, nil,gpio.PULLDOWN),
    pio6 =gpio.setup(6, nil,gpio.PULLDOWN),
    pio7 =gpio.setup(7, nil,gpio.PULLDOWN),
    pio8 =gpio.setup(8, nil,gpio.PULLDOWN),
    pio9 =gpio.setup(9, nil,gpio.PULLDOWN),
    pio16 =gpio.setup(16, nil,gpio.PULLDOWN),
    pio17 =gpio.setup(17, nil,gpio.PULLDOWN),
    pio19 =gpio.setup(19, nil,gpio.PULLDOWN),
    pio20 =gpio.setup(20, nil,gpio.PULLDOWN),
    pio21 =gpio.setup(21, nil,gpio.PULLDOWN),
    pio22 =gpio.setup(22, nil,gpio.PULLDOWN),
    pio24 =gpio.setup(24, nil,gpio.PULLDOWN),
    pio25 =gpio.setup(25, nil,gpio.PULLDOWN),
    pio26 =gpio.setup(26, nil,gpio.PULLDOWN),  --READY指示灯
    pio27 =gpio.setup(27, nil,gpio.PULLDOWN),  --NET指示灯
    pio28 =gpio.setup(28, nil,gpio.PULLDOWN),  
    pio29 =gpio.setup(29, nil,gpio.PULLDOWN),
    pio30 =gpio.setup(30, nil,gpio.PULLDOWN),
    pio31 =gpio.setup(31, nil,gpio.PULLDOWN),
    pio32 =gpio.setup(32, nil,gpio.PULLDOWN),
    pio33 =gpio.setup(33, nil,gpio.PULLDOWN),
    pio34 =gpio.setup(34, nil,gpio.PULLDOWN),
    pio35 =gpio.setup(35, nil,gpio.PULLDOWN),
}

-- 网络READY信号
if not dtu.pins or not dtu.pins[2] or not pios[dtu.pins[2]] then 
    netready = gpio.setup(27, 0)
else
    netready = gpio.setup(tonumber(dtu.pins[2]:sub(4, -1)), 0)
    pios[dtu.pins[2]] = nil
end
-- 重置DTU
function resetConfig(msg)
    if msg and msg == 0 then
        db.remove(cfg)
        if io.exists("/alikey.cnf") then os.remove("/alikey.cnf") end
        if io.exists("/qqiot.dat") then os.remove("/qqiot.dat") end
        if io.exists("/bdiot.dat") then os.remove("/bdiot.dat") end
        dtulib.restart("软件恢复出厂默认值: OK")
    end
end
if not dtu.pins or not dtu.pins[3] or not pios[dtu.pins[3]] then 

else
    gpio.setup(tonumber(dtu.pins[3]:sub(4, -1)), resetConfig, gpio.PULLUP)
    pios[dtu.pins[3]] = nil
end

-- NETLED指示灯任务
local function blinkPwm(ledPin, light, dark)
    ledPin(1)
    sys.wait(light)
    ledPin(0)
    sys.wait(dark)
end

local function netled(led)
    local ledpin = gpio.setup(led, 1)
    while true do
        -- GSM注册中
        while mobile.status()==0 do blinkPwm(ledpin, 100, 100) end
        while mobile.status()==1 do
            if create.getDatalink() then
                netready(1)
                blinkPwm(ledpin, 200, 1800)
            else
                netready(0)
                blinkPwm(ledpin, 500, 500)
            end
        end
        sys.wait(100)
    end
end
if not dtu.pins or not dtu.pins[1] or not pios[dtu.pins[1]] then 
    sys.taskInit(netled,26)
else
    sys.taskInit(netled, tonumber(dtu.pins[1]:sub(4, -1)))
    pios[dtu.pins[1]] = nil
end
---------------------------------------------------------- DTU 任务部分 ----------------------------------------------------------
-- 配置串口
if dtu.pwrmod ~= "energy" then 
    pm.request(pm.IDLE) 
else
    pm.request(pm.LIGHT)
end

-- 每隔1分钟重置串口计数
sys.timerLoopStart(function()
    flow = tonumber(dtu.flow)
    if flow and flow ~= 0 then
        if flowCount[1] > flow then
            uart.on(1, "receive")
            log.info("uart1 close")
            uart.close(1)
            log.info("uart1.read length count:", flowCount[1])
        end
        if flowCount[2] > flow then
            uart.on(2, "receive")
            log.info("uart2 close")
            uart.close(2)
            log.info("uart2.read length count:", flowCount[2])
        end
    end
    if timecnt > 60 then
        timecnt = 1
        flowCount[4], flowCount[1], flowCount[2], flowCount[3] = 0, 0, 0, 0
    else
        timecnt = timecnt + 1
    end
end, 1000)

-- 串口写数据处理
function write(uid, str,cid)
    uid = tonumber(uid)
    if not str or str == "" or not uid then return end
    if uid == uart.USB then return uart.write(uart.USB, str) end
    if str ~= true then
        for i = 1, #str, SENDSIZE do
            table.insert(writeBuff[uid], str:sub(i, i + SENDSIZE - 1))
        end
        log.info("str的实际值是",str)
        log.warn("uart" .. uid .. ".write data length:", writeIdle[uid], #str)
    end
    if writeIdle[uid] and writeBuff[uid][1] then
        if 0 ~= uart.write(uid, writeBuff[uid][1]) then
            table.remove(writeBuff[uid], 1)
            writeIdle[uid] = false
            log.warn("UART_" .. uid .. " writing ...")
        end
    end
end

local function writeDone(uid)
    if #writeBuff[uid] == 0 then
        writeIdle[uid] = true
        sys.publish("UART_" .. uid .. "_WRITE_DONE")
        log.warn("UART_" .. uid .. "write done!")
    else
        writeIdle[uid] = false
        uart.write(uid, table.remove(writeBuff[uid], 1))
        log.warn("UART_" .. uid .. "writing ...")
    end
end

-- DTU配置工具默认的方法表
cmd = {}
cmd.config = {
    ["pipe"] = function(t, num)dtu.conf[tonumber(num)] = t return "OK" end, -- "1"-"7" 为通道配置
    ["A"] = function(t)dtu.apn = t return "OK" end, -- APN 配置
    ["B"] = function(t)dtu.cmds[tonumber(table.remove(t, 1)) or 1] = t return "OK" end, -- 自动任务下发配置
    ["auth"] = function(t)dtu.auth = t return "OK" end, -- 设置专网APN
    ["pins"] = function(t)dtu.pins = t return "OK" end, -- 自定义GPIO
    ["host"] = function(t)dtu.host = t[1] return "OK" end, -- 自定义参数升级服务器
    ["0"] = function(t)-- 保存配置参数
        local password = ""
        dtu.passon, dtu.plate, dtu.convert, dtu.reg, dtu.param_ver, dtu.flow, dtu.fota, dtu.uartReadTime, dtu.pwrmod, password, dtu.netReadTime, dtu.nolog = unpack(t)
        if password == dtu.password or dtu.password == "" or dtu.password == nil then
            dtu.password = password
            cfg:import(dtu)
            sys.timerStart(dtulib.restart, 5000, "Setting parameters have been saved!")
            return "OK"
        else
            return "PASSWORD ERROR"
        end
    end,
    ["8"] = function(t)-- 串口配置默认方法
        local tmp = "1200,2400,4800,9600,14400,19200,28800,38400,57600,115200,230400,460800,921600"
        if t[1] and t[2] and t[3] and t[4] and t[5] then
            if ("1,2,3"):find(t[1]) and tmp:find(t[2]) and ("7,8"):find(t[3]) and ("0,1,2"):find(t[4]) and ("0,2"):find(t[5]) then
                dtu.uconf[tonumber(t[1])] = t
                return "OK"
            else
                return "ERROR"
            end
        end
    end,
    ["9"] = function(t)-- 预置白名单
        dtu.preset.number, dtu.preset.delay, dtu.preset.smsword = unpack(t)
        dtu.preset.delay = tonumber(dtu.preset.delay) or 1
        return "OK"
    end,
    ["readconfig"] = function(t)-- 读取整个DTU的参数配置
        if t[1] == dtu.password or dtu.password == "" or dtu.password == nil then
            return cfg:export("string")
        else
            return "PASSWORD ERROR"
        end
    end,  
    ["writeconfig"] = function(t, s)-- 读取整个DTU的参数配置
        local str = s:match("(.+)\r\n") and s:match("(.+)\r\n"):sub(20, -1) or s:sub(20, -1)
        local dat, result, errinfo = json.decode(str)
        if result then
            if dtu.password == dat.password or dtu.password == "" or dtu.password == nil then
                cfg:import(str)
                if dat.auth and tonumber(dat.auth[1]) and dat.auth[2] then
                    link.setAuthApn(tonumber(dat.auth[1]), dat.auth[2], dat.auth[3], dat.auth[4])
                end
                sys.timerStart(dtulib.restart, 5000, "Setting parameters have been saved!")
                return "OK"
            else
                return "PASSWORD ERROR"
            end
        else
            return "JSON ERROR"
        end
    end
}
cmd.rrpc = {
    ["getfwver"] = function(t) return "rrpc,getfwver," .. _G.PROJECT .. "_" .. _G.VERSION .. "_" .. rtos.version() end,
    ["getnetmode"] = function(t) return "rrpc,getnetmode," .. mobile.status() and mobile.status() or 1 end,
    ["getver"] = function(t) return "rrpc,getver," .. _G.VERSION end,
    ["getcsq"] = function(t) return "rrpc,getcsq," .. (mobile.csq() or "error ") end,
    ["getadc"] = function(t) return "rrpc,getadc," .. create.getADC(tonumber(t[1]) or 0) end,
    ["setchannel"] = function(t)
        log.info("进到setchannel里面了")
        log.info("wEB的值",cfg:select("webProtect"))
        for i=1,#t do
            if t[i]~=nil and t[i]~="all" then
                dtu.protectContent[tonumber(t[i])]=1
                cfg:update("protectContent", dtu.protectContent, true)
            end
            if t[1]=="all" then
                dtu.webProtect="1"
                cfg:update("webProtect", dtu.webProtect, true)
                log.info("wEB的值22",cfg:select("webProtect"))
            end
        end
        return "rrpc,setchannel,OK" 
    end,
    ["reboot"] = function(t)
        sys.timerStart(dtulib.restart, 1000, "Remote reboot!") 
        return "OK" end,
    ["getimei"] = function(t) return "rrpc,getimei," .. (mobile.imei() or "error") end,
    ["getmuid"] = function(t) return "rrpc,getmuid," .. (mobile.muid() or "error") end,
    ["getimsi"] = function(t) return "rrpc,getimsi," .. (mobile.imsi() or "error") end,
    ["getvbatt"] = function(t) return "rrpc,getvbatt," .. create.getADC(adc.CH_VBAT) end,
    ["geticcid"] = function(t) return "rrpc,geticcid," .. (mobile.iccid() or "error") end,
    ["getproject"] = function(t) return "rrpc,getproject," .. _G.PROJECT end,
    ["getcorever"] = function(t) return "rrpc,getcorever," .. rtos.version() end,
    ["getlocation"] = function(t) return "rrpc,location," .. (lbs.lat or 0) .. "," .. (lbs.lng or 0) end,
    ["getreallocation"] = function(t)
        lbsLoc.request(function(result, lat, lng, addr,time,locType)
            if result then
                lbs.lat, lbs.lng = lat, lng
                log.info("定位类型,基站定位成功返回0", locType)
                default.setLocation(lat, lng)
            end
        end)
        return "rrpc,location," .. (lbs.lat or 0) .. "," .. (lbs.lng or 0)
    end,
    ["gettime"] = function(t)
        local t = os.date("*t")
        return "rrpc,nettime," .. string.format("%04d-%02d-%02d %02d:%02d:%02d", t.year,t.month,t.day,t.hour,t.min,t.sec)
    end,
    ["setpio"] = function(t) 
        if pios["pio" .. t[1]] and (tonumber(t[2]) > -1 and tonumber(t[2]) < 2) then 
            pios["pio" .. t[1]](tonumber(t[2]) or 0)
            return "OK" 
        end 
        return "ERROR" end,
    ["getpio"] = function(t)
        if pios["pio" .. t[1]] then 
            return "rrpc,getpio" .. t[1] .. "," .. gpio.get(t[1]) 
        end
        return "ERROR" end,
    ["netstatus"] = function(t)
        if t == nil or t == "" or t[1] == nil or t[1] == "" then
            return "rrpc,netstatus," .. (create.getDatalink() and "RDY" or "NORDY")
        else
            return "rrpc,netstatus," .. (t[1] and (t[1] .. ",") or "") .. (create.getDatalink(tonumber(t[1])) and "RDY" or "NORDY")
        end
    end,
    ["gps_wakeup"] = function(t)sys.publish("REMOTE_WAKEUP") return "rrpc,gps_wakeup,OK" end,
    ["gps_getsta"] = function(t) return "rrpc,gps_getsta," .. deviceMessage(t[1] or "json") end,
    ["gps_getmsg"] = function(t) return "rrpc,gps_getmsg," .. locateMessage(t[1] or "json") end,
    ["gps_close"] = function(t) sys.publish("REMOTE_CLOSE") return "rrpc,gps_close,ok" end,
    ["upconfig"] = function(t)sys.publish("UPDATE_DTU_CNF") return "rrpc,upconfig,OK" end,
    ["function"] = function(t)log.info("rrpc,function:", table.concat(t, ",")) return "rrpc,function," .. (loadstring(table.concat(t, ","))() or "OK") end,
    ["simcross"] = function(t) 
        if tonumber(t[1])==1 or tonumber(t[1])==0 then
            mobile.flymode(0, true)
            mobile.simid(t[1])
            mobile.flymode(0, false)
             return "simcross,ok,"..t[1] 
        else
            return "simcross,error,"..t[1]
        end
    end,
}


-- 串口读指令
local function read(uid, idx)
    log.error("uart.read--->", uid, idx)
    local s = table.concat(recvBuff[idx])
    recvBuff[idx] = {}
    -- 串口流量统计
    flowCount[idx] = flowCount[idx] + #s
    log.info("UART_" .. uid .. " read:", #s, (s:sub(1, 100):toHex()))
    log.info("串口流量统计值:", flowCount[idx])
    -- 根据透传标志位判断是否解析数据
    if s:sub(1, 3) == "+++" or s:sub(1, 5):match("(.+)\r\n") == "+++" then
        write(uid, "OK\r\n")
        db.remove(cfg)
        if io.exists("/alikey.cnf") then os.remove("/alikey.cnf") end
        if io.exists("/qqiot.dat") then os.remove("/qqiot.dat") end
        if io.exists("/bdiot.dat") then os.remove("/bdiot.dat") end
        dtulib.restart("Restore default parameters:", "OK")
    end
    -- DTU的参数配置
    if s:sub(1, 7) == "config," or s:sub(1, 5) == "rrpc," then
        return write(uid, create.userapi(s))
    end
    -- 执行单次HTTP指令
    if s:sub(1, 5) == "http," then
        local str = ""
        local idx1, idx2, jsonstr = s:find(",[\'\"](.+)[\'\"],")
        if jsonstr then
            str = s:sub(1, idx1) .. s:sub(idx2, -1)
        else
            -- 判是不是json，如果不是json，则是普通的字符串
            idx1, idx2, jsonstr = s:find(",([%[{].+[%]}]),")
            if jsonstr then
                str = s:sub(1, idx1) .. s:sub(idx2, -1)
            else
                str = s
            end
        end
        --local t = str:match("(.+)\r\n") and str:match("(.+)\r\n"):split(',') or str:split(',')
        local t = str:match("(.+)\r\n") and dtulib.split(str:match("(.+)\r\n"),',') or dtulib.split(str,',')
        if not mobile.status() == 1 then write(uid, "NET_NORDY\r\n") return end
        sys.taskInit(function(t, uid)
            local httpbody=jsonstr or t[5]
            if type(dtulib.unSerialize(jsonstr or t[5])) =="table" then
                httpbody=dtulib.unSerialize(jsonstr or t[5])
            end
            local code, head, body = dtulib.request(t[2]:upper(), t[3],t[8],nil, httpbody, tonumber(t[6]) or 1, t[7])
            log.info("uart http response:", body)
            write(uid, body)
        end, t, uid)
        return
    end
    -- 执行单次SOCKET透传指令
    if s:sub(1, 4):upper() == "TCP," or s:sub(1, 4):upper() == "UDP," then
        -- local t = s:match("(.+)\r\n") and s:match("(.+)\r\n"):split(',') or s:split(',')
        s = s:match("(.+)\r\n") or s
        if mobile.status()~=1 then 
            write(uid, "NET_NORDY\r\n")
            --tulib.restart("网络初始化失败！")
        end
        local dName = "dtu"..uid
        sys.taskInitEx(function(uid, prot, ip, port, ssl, timeout, data)
            local c = prot:upper() 
            local netc = socket.create(nil, dName)
            local isUdp = prot == "TCP" and nil or true
            local isSsl = ssl and true or nil
            local rx_buff = zbuff.create(1024)
            socket.config(netc, nil,isUdp,isSsl)
            libnet.waitLink(dName, 0, netc)
            result = libnet.connect(dName, timeout, netc, ip, port)
            while not result do sys.wait(2000) end
            local succ, param =libnet.tx(dName, nil, netc, data)
            if succ then
                write(uid, "SEND_OK\r\n")
                local result, param = libnet.wait(dName, timeout * 1000, netc)
                if not result then
                    log.info("网络异常", result, param) 
                end
                local succ, param, _, _ = socket.rx(netc, rx_buff)
                if succ then 
                    s=rx_buff:toStr()
                    write(uid, s) end
            else
                write(uid, "SEND_ERR\r\n")
            end
            socket.close(netc)
        end, dName, function() end, uid, s:match("(.-),(.-),(.-),(.-),(.-),(.+)"))
        return
    end
    -- 添加设备识别码
    if tonumber(dtu.passon) == 1 then
        log.info("进到识别码里面来了")
        local interval, samptime = create.getTimParam()
        log.info("INTERVAL",interval[uid],samptime[uid])
        if interval[uid] > 0 then -- 定时采集透传模式
            --如果定时采集间隔>0，证明有定时采集间隔
            -- 这里注意间隔时长等于预设间隔时长的时候就要采集,否则1秒的采集无法采集
            if os.difftime(os.time(), startTime[uid]) >= interval[uid] then
                --那么就判断当前时间减去上次时间是否大于被动上报间隔
                if os.difftime(os.time(), startTime[uid]) < interval[uid] + samptime[uid] then
                    --如果当前时间减去上次时间，小于被动上报间隔+被动采集间隔，就把数据插入到表内
                    table.insert(sendBuff[uid], s)
                elseif startTime[uid] == 0 then
                    --第一次的时候，立即采集一次串口数据。
                    log.info("直接采集了一次")
                    -- 首次上电立刻采集1次
                    table.insert(sendBuff[uid], s)
                    startTime[uid] = os.time() - interval[uid]
                    --上一次的时间等于os.time-被动上报间隔。
                else
                    startTime[uid] = os.time()
                    if #sendBuff[uid] ~= 0 then
                        log.info("进到识别码里面来来2")
                        sys.publish("NET_SENT_RDY_" .. uid, tonumber(dtu.plate) == 1 and mobile.imei() .. table.concat(sendBuff[uid]) or table.concat(sendBuff[uid]))
                        sendBuff[uid] = {}
                    end
                end
            else
                sendBuff[uid] = {}
            end
        else -- 正常透传模式
            log.info("这个里面的内容是",tonumber(dtu.plate) == 1 and mobile.imei() .. s or s)
            sys.publish("NET_SENT_RDY_" .. uid, tonumber(dtu.plate) == 1 and mobile.imei() .. s or s)
        end
    else
        -- 非透传模式,解析数据
        if s:sub(1, 5) == "send," then
            sys.publish("NET_SENT_RDY_" .. s:sub(6, 6), s:sub(8, -1))
        else
            write(uid, "ERROR\r\n")
        end
    end
end

-- uart 的初始化配置函数
-- 数据流模式
local streamlength = 0
local function streamEnd(uid)
    if #recvBuff[uid] > 0 then
        sys.publish("NET_SENT_RDY_" .. uid, table.concat(recvBuff[uid]))
        recvBuff[uid] = {}
        streamlength = 0
    end
end
function uart_INIT(i, uconf)
    uconf[i][1] = tonumber(uconf[i][1])
    log.info("串口的数据是",uconf[i][1], uconf[i][2], uconf[i][3], uconf[i][4], uconf[i][5],uconf[i][6])
    local stb=uconf[i][5]==0 and 1 or 2
    local rs485us=tonumber(uconf[i][7]) and tonumber(uconf[i][7]) or 0
    local parity=uart.None
    if uconf[i][4]==0 then
        parity=uart.EVEN
    elseif  uconf[i][4]==1 then
        parity=uart.Odd
    elseif uconf[i][4]==2 then
        parity=uart.None
    end
    if pios[dtu.uconf[i][6]] then
        default["dir" .. i] = tonumber(dtu.uconf[i][6]:sub(4, -1))
        pios[dtu.uconf[i][6]] = nil
    else
        default["dir" .. i] = nil
    end
    log.info("DEFAULT",default["dir" .. i])
    log.info("rs485us",rs485us)
    uart.setup(uconf[i][1], uconf[i][2], uconf[i][3], stb,parity,uart.LSB,SENDSIZE, default["dir" .. i],0,rs485us)
    uart.on(uconf[i][1], "sent", writeDone)
    if uconf[i][1] == uart.USB or tonumber(dtu.uartReadTime) > 0 then
        uart.on(uconf[i][1], "receive", function(uid, length)
            log.info("接收到的数据是",uid,length)
            table.insert(recvBuff[i], uart.read(uconf[i][1], length or 8192))
            sys.timerStart(sys.publish, tonumber(dtu.uartReadTime) or 25, "UART_RECV_WAIT_" .. uconf[i][1], uconf[i][1], i)
        end)
    else
        uart.on(uconf[i][1], "receive", function(uid, length)
            local str = uart.read(uconf[i][1], length or 8192)
            sys.timerStart(streamEnd, 1000, i)
            streamlength = streamlength + #str
            table.insert(recvBuff[i], str)
            if streamlength > 29200 then
                sys.publish("NET_SENT_RDY_" .. uconf[i][1], table.concat(recvBuff[i]))
                recvBuff[i] = {}
                streamlength = 0
            end
        end)
    end
    -- 处理串口接收到的数据
    sys.subscribe("UART_RECV_WAIT_" .. uconf[i][1], read)
    sys.subscribe("UART_SENT_RDY_" .. uconf[i][1], write)
    -- 网络数据写串口延时分帧
    sys.subscribe("NET_RECV_WAIT_" .. uconf[i][1], function(uid, str)
        if tonumber(dtu.netReadTime) and tonumber(dtu.netReadTime) > 5 then
            for j = 1, #str, SENDSIZE do
                table.insert(writeBuff[uid], str:sub(j, j + SENDSIZE - 1))
            end
            sys.timerStart(sys.publish, tonumber(dtu.netReadTime) or 30, "UART_SENT_RDY_" .. uid, uid, true)
        else
            sys.publish("UART_SENT_RDY_" .. uid, uid, str)
        end
    end)
end
sys.taskInit(function()
    local rst, code, head, body, url = false
    while mobile.status() == 0 do
        sys.wait(1000)
    end
    -- 如果是专网就禁止公网操作代码
    if dtu.auth and dtu.auth[2] and tonumber(dtu.auth[1]) then
        sys.wait(5000)
        return sys.publish("DTU_PARAM_READY")
    end
    -- 加载错入日志和远程升级功能
    --加载错误日志管理功能模块【强烈建议打开此功能】
    --如下2行代码，只是简单的演示如何使用errDump功能，详情参考errDump的api
    --errDump.request("udp://ota.airm2m.com:9072")
    errDump.config(true,3600)
    --ntp.timeSync(24, function()log.info(" AutoTimeSync is Done!") end)
    while true do
        rst = false
        if dtu.host and dtu.host ~= "" then
            log.info("dtu.host+++++")
            local param = {product_name = _G.PROJECT, param_ver = dtu.param_ver, imei = mobile.imei()}
            code, head, body = dtulib.request("GET", dtu.host,30000,param,nil,1)
        else
            log.info("dtuURL+++++",mobile.muid(),mobile.imei())
            url = "http://dtu.openluat.com/api/site/device/" .. mobile.imei() .. "/param?product_name=" .. _G.PROJECT .. "&param_ver=" .. dtu.param_ver       
            code, head, body = dtulib.request("GET", url,30000,nil,nil,1,mobile.imei()..":"..mobile.muid())
        end
        if tonumber(code) == 200 and body then
            log.info("Parameters issued from the server:", body)
            local dat, res, err = json.decode(body)
            if res and tonumber(dat.param_ver) ~= tonumber(dtu.param_ver) then
                cfg:import(body)
                rst = true
            end
        else
            log.info("COde",code,body,head)
        end
        -- 检查是否有更新程序
        if tonumber(dtu.fota) == 1 then
            log.info("----- update firmware:", "start!")
            libfota.request(function(result)
                log.info("OTA", result)
                if result == 0 then
                    log.info("ota", "succuss")
                    -- TODO 重启
                end
                sys.publish("IRTU_UPDATE_RES", result == 0)
            end)
            local res, val = sys.waitUntil("IRTU_UPDATE_RES")
            rst = rst or val
            log.info("----- update firmware:", "end!")
        end
        if rst then dtulib.restart("DTU Parameters or firmware are updated!")  end
        ---------- 启动网络任务 ----------
        log.info("走到这里了")
        sys.publish("DTU_PARAM_READY")
        sys.wait(30000)
        ---------- 基站坐标查询 ----------
        lbsLoc.request(function(result, lat, lng, addr,time,locType)
            if result then
                lbs.lat, lbs.lng = lat, lng
                log.info("定位类型,基站定位成功返回0", locType)
                default.setLocation(lat, lng)
            end
        end)
        log.warn("短信或电话请求更新:", sys.waitUntil("UPDATE_DTU_CNF", 86400000))
    end
end)

-- 初始化配置UART1和UART2
local uidgps = dtu.gps and dtu.gps.fun and tonumber(dtu.gps.fun[1])
if uidgps ~= 1 and dtu.uconf and dtu.uconf[1] and tonumber(dtu.uconf[1][1]) == 1 then
    uart_INIT(1, dtu.uconf) end
if uidgps ~= 2 and dtu.uconf and dtu.uconf[2] and tonumber(dtu.uconf[2][1]) == 2 then uart_INIT(2, dtu.uconf) end

-- 启动GPS任务
if uidgps then
    -- 从pios列表去掉自定义的io
    if dtu.gps.pio then
        for i = 1, 3 do if pios[dtu.gps.pio[i]] then pios[dtu.gps.pio[i]] = nil end end
    end
    sys.taskInit(sensMonitor, unpack(dtu.gps.pio))
    sys.taskInit(alert, unpack(dtu.gps.fun))
end

---------------------------------------------------------- 预警任务线程 ----------------------------------------------------------
if dtu.warn and dtu.warn.gpio and #dtu.warn.gpio > 0 then
    log.info("DTU<",dtu.warn.gpio)
    for key, value in pairs(dtu.warn.gpio) do
        log.info("KEY的值是",key,value)
        for key1, value1 in pairs(value) do
            log.info("VALUE",key1,value1)
        end
    end
    log.info("DTU#",#dtu.warn.gpio)
    -- log.info("gpio值是",tonumber(dtu.warn.gpio[i][1]:sub(4, -1)))
    for i = 1, #dtu.warn.gpio do
        gpio.debounce(tonumber(dtu.warn.gpio[i][1]:sub(4, -1)),500)
        local irq=dtu.warn.gpio[i][2]==1 and gpio.FALLING or gpio.RISING
        log.info("IRQ",irq)
        log.info("IRQ2",gpio.FALLING,gpio.RISING)
        gpio.setup(tonumber(dtu.warn.gpio[i][1]:sub(4, -1)), function(msg)
            log.info("MSG是",msg)
            log.info("MSG2是",gpio.RISING)
            log.info("MSG3是",gpio.FALLING)
            if (msg == gpio.RISING and tonumber(dtu.warn.gpio[i][2]) == 1) or (msg == gpio.FALLING and tonumber(dtu.warn.gpio[i][3]) == 1) then
                log.info("进到第一个判断里面来了")
                if tonumber(dtu.warn.gpio[i][6]) == 1 then 
                    log.info("发布一个主题","NET_SENT_RDY_" .. dtu.warn.gpio[i][5], dtu.warn.gpio[i][4]) 
                    sys.publish("NET_SENT_RDY_" .. dtu.warn.gpio[i][5], dtu.warn.gpio[i][4]) 
                end
                if dtu.preset and tonumber(dtu.preset.number) then
                    if tonumber(dtu.warn.gpio[i][7]) == 1 then sms.send(dtu.preset.number,dtu.warn.gpio[i][4]) end
                end
            end
        end, gpio.PULLUP,irq)
    end
end


local function adcWarn(adcid, und, lowv, over, highv, diff, msg, id, sfreq, upfreq, net, note, tel)
    local upcnt, scancnt, adcValue, voltValue = 0, 0, 0, 0
    diff = tonumber(diff) or 1
    lowv = tonumber(lowv) or 1
    highv = tonumber(highv) or 4200
    while true do
        -- 获取ADC采样电压
        scancnt = scancnt + 1
        if scancnt == tonumber(sfreq) then
            -- if adcid == 0 or adcid == 1 then
                -- end
                adc.open(adcid)
                adcValue, voltValue = adc.read(adcid)
                if adcValue ~= 0xFFFF or voltValue ~= 0xFFFF then
                    voltValue = (voltValue - voltValue % 3) / 3
                end
                adc.close(adcid)
            scancnt = 0
        end
        -- 处理上报
        if ((tonumber(und) == 1 and voltValue < tonumber(lowv)) or (tonumber(over) == 1 and voltValue > tonumber(highv))) then
            if upcnt == 0 then
                if tonumber(net) == 1 then sys.publish("NET_SENT_RDY_" .. id, msg) end
                if tonumber(note) == 1 and dtu.preset and tonumber(dtu.preset.number) then sms.send(dtu.preset.number,msg) end
                upcnt = tonumber(upfreq)
            else
                upcnt = upcnt - 1
            end
        end
        -- 解除警报
        if voltValue > tonumber(lowv) + tonumber(diff) and voltValue < tonumber(highv) - tonumber(diff) then upcnt = 0 end
        sys.wait(1000)
    end
end
if dtu.warn and dtu.warn.adc0 and dtu.warn.adc0[1] then
    sys.taskInit(adcWarn, 0, unpack(dtu.warn.adc0))
end
if dtu.warn and dtu.warn.adc1 and dtu.warn.adc1[1] then
    sys.taskInit(adcWarn, 1, unpack(dtu.warn.adc1))
end
if dtu.warn and dtu.warn.vbatt and dtu.warn.vbatt[1] then
    sys.taskInit(adcWarn, 9, unpack(dtu.warn.vbatt))
end


---------------------------------------------------------- 参数配置,任务转发，线程守护主进程----------------------------------------------------------
sys.taskInit(create.connect, pios, dtu.conf, dtu.reg, tonumber(dtu.convert) or 0, (tonumber(dtu.passon) == 0), dtu.upprot, dtu.dwprot,dtu.webProtect,dtu.protectContent)

---------------------------------------------------------- 用户自定义任务初始化 ---------------------------------------------------------
if dtu.task and #dtu.task ~= 0 then
    for i = 1, #dtu.task do
        if dtu.task[i] and dtu.task[i]:match("function(.+)end") then
            sys.taskInit(loadstring(dtu.task[i]:match("function(.+)end")))
        end
    end
end

-- sys.timerLoopStart(function()
--     -- log.info("mem.lua", rtos.meminfo())
--     -- log.info("mem.sys", rtos.meminfo("sys"))
--     -- -- log.info("VERSION",_G.VERSION)
--     sys.publish("UART_SENT_RDY_1" , 1, "SENDOK")
--  end, 3000)

return default
