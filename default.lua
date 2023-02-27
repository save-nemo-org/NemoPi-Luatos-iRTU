default = {}

require "libnet"
iot_fota=require"iot_fota"
db=require "db"
create =require "create"
dtulib=require "dtulib"
-- require "soc_fota"


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
lbs = {}
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
        {1, 115200, 8, uart.PAR_NONE, uart.STOP_1},
        {2, 115200, 8, uart.PAR_NONE, uart.STOP_1},
        {3, 115200, 8, uart.PAR_NONE, uart.STOP_1},
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
function setLocation(lat, lng)
    lbs.lat, lbs.lng = lat, lng
    log.info("基站定位请求的结果:", lat, lng)
end


---------------------------------------------------------- 开机读取保存的配置文件 ----------------------------------------------------------
-- 自动任务采集
local function autoSampl(uid, t)
    while true do
        sys.waitUntil("AUTO_SAMPL_" .. uid)
        for i = 2, #t do
            local str = t[i]:match("function(.+)end")
            if not str then
                if t[i] ~= "" then write(uid, (t[i]:fromHex())) end
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
    if dtu.apn and dtu.apn[1] and dtu.apn[1] ~= "" then link.setAPN(unpack(dtu.apn)) end
    if dtu.cmds and dtu.cmds[1] and tonumber(dtu.cmds[1][1]) then sys.taskInit(autoSampl, 1, dtu.cmds[1]) end
    if dtu.cmds and dtu.cmds[2] and tonumber(dtu.cmds[2][1]) then sys.taskInit(autoSampl, 2, dtu.cmds[2]) end
    if tonumber(dtu.nolog) ~= 1 then 
        _G.LOG_LEVEL = log.LOG_INFO
        log.setLevel("INFO") end
end

---------------------------------------------------------- 用户控制 GPIO 配置 ----------------------------------------------------------
-- function gpio_set() end

-- sys.timerLoopStart(function()
--     local Total_memory, user_memory, Maximum_available_memory = rtos.meminfo()
--     local _, all_fs, user_fs, fs_kb, _ = fs.fsstat("/")
--     log.info("总内存", Total_memory, "当前内存已用", user_memory,
--              "历史最高已使用的内存大小", Maximum_available_memory)
--     log.info("当前文件系统区总内存", all_fs * fs_kb, "已用",
--              user_fs * fs_kb, "剩余可用", all_fs * fs_kb - user_fs * fs_kb) -- 打印打印根分区的信息
-- end, 3000)

-- 重置DTU
function resetConfig(msg)
    if msg ~= cpu.INT_GPIO_POSEDGE then
        db.remove(cfg)
        if io.exists("/alikey.cnf") then os.remove("/alikey.cnf") end
        if io.exists("/qqiot.dat") then os.remove("/qqiot.dat") end
        if io.exists("/bdiot.dat") then os.remove("/bdiot.dat") end
        dtulib.restart("软件恢复出厂默认值: OK")
    end
end

---------------------------------------------------------- DTU 任务部分 ----------------------------------------------------------
-- 配置串口
if dtu.pwrmod ~= "energy" then pm.request(pm.LIGHT) end

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
function write(uid, str)
    log.info("进到串口写里面来了")
    uid = tonumber(uid)
    if not str or str == "" or not uid then return end
    if uid == uart.USB then return uart.write(uart.USB, str) end
    if str ~= true then
        for i = 1, #str, SENDSIZE do
            table.insert(writeBuff[uid], str:sub(i, i + SENDSIZE - 1))
        end
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
    ["getcsq"] = function(t) return "rrpc,getcsq," .. (mobile.rssi() or "error ") end,
    ["getadc"] = function(t) return "rrpc,getadc," .. create.getADC(tonumber(t[1]) or 0) end,
    ["setchannel"] = function(t)
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
    ["reboot"] = function(t)sys.timerStart(dtulib.restart, 1000, "Remote reboot!") return "OK" end,
    ["getimei"] = function(t) return "rrpc,getimei," .. (mobile.imei() or "error") end,
    ["getmuid"] = function(t) return "rrpc,getmuid," .. (mobile.muid() or "error") end,
    ["getimsi"] = function(t) return "rrpc,getimsi," .. (mobile.imsi() or "error") end,
    ["getvbatt"] = function(t) return "rrpc,getvbatt," .. adc.read(adc.CH_VBAT) end,
    ["geticcid"] = function(t) return "rrpc,geticcid," .. (mobile.iccid() or "error") end,
    ["getproject"] = function(t) return "rrpc,getproject," .. _G.PROJECT end,
    ["getcorever"] = function(t) return "rrpc,getcorever," .. rtos.version() end,
    -- ["getlocation"] = function(t) return "rrpc,location," .. (lbs.lat or 0) .. "," .. (lbs.lng or 0) end,
    -- ["getreallocation"] = function(t)
    --     lbsLoc.request(function(result, lat, lng, addr)
    --         if result then
    --             lbs.lat, lbs.lng = lat, lng
    --             setLocation(lat, lng)
    --         end
    --     end)
    --     return "rrpc,location," .. (lbs.lat or 0) .. "," .. (lbs.lng or 0)
    -- end,
    ["gettime"] = function(t)
        local c = rtc.get()
        return "rrpc,nettime," .. string.format("%04d,%02d,%02d,%02d,%02d,%02d\r\n", c.year, c.month, c.day, c.hour, c.min, c.sec)
    end,

    -- if misc.getModelType() == "724UG" return "rrpc,getpio" .. t[1] .. "," .. pio.pin.getval(t[1])
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
    --["getsht"] = function(t) local tmp, hum = iic.sht(2, tonumber(t[1])) return "rrpc,getsht," .. (tmp or 0) .. "," .. (hum or 0) end,
    --["getam2320"] = function(t) local tmp, hum = iic.am2320(2, tonumber(t[1])) return "rrpc,getam2320," .. (tmp or 0) .. "," .. (hum or 0) end,
    ["netstatus"] = function(t)
        if t == nil or t == "" or t[1] == nil or t[1] == "" then
            return "rrpc,netstatus," .. (create.getDatalink() and "RDY" or "NORDY")
        else
            log.info("TTTT",t[1],t[2],t[3])
            return "rrpc,netstatus," .. (t[1] and (t[1] .. ",") or "") .. (create.getDatalink(tonumber(t[1])) and "RDY" or "NORDY")
        end
    end,
    ["gps_wakeup"] = function(t)sys.publish("REMOTE_WAKEUP") return "rrpc,gps_wakeup,OK" end,
    ["gps_getsta"] = function(t) return "rrpc,gps_getsta," .. tracker.deviceMessage(t[1] or "json") end,
    ["gps_getmsg"] = function(t) return "rrpc,gps_getmsg," .. tracker.locateMessage(t[1] or "json") end,
    ["gps_close"] = function(t) if (misc.getModelType()):find("820UG") then sys.publish("REMOTE_CLOSE") return "rrpc,gps_close,ok" else return "error" end end,
    ["upconfig"] = function(t)sys.publish("UPDATE_DTU_CNF") return "rrpc,upconfig,OK" end,
    ["function"] = function(t)log.info("rrpc,function:", table.concat(t, ",")) return "rrpc,function," .. (loadstring(table.concat(t, ","))() or "OK") end,
    -- ["tts_play"] = function(t)
    --     if not isTTS then return "rrpc,tts_play,not_tts_lod" end
    --     local str = string.upper(t[1]) == "GB2312" and common.gb2312ToUtf8(t[2]) or t[2]
    --     audio.play(1, "TTS", str, tonumber(t[3]) or 7, nil, false, 0)
    --     return "rrpc,tts_play,OK"
    -- end,
    ["getSN"] = function(t) log.info("rrpc,getSN,"..mobile.sn()) return "rrpc,getSN,"..(mobile.sn() or 0) end,
    --["setSN"] = function(t) log.info("rrpc,setSN,",misc.setSn(t[1])) return "ok" end,

}

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
        local t = str:match("(.+)\r\n") and str:match("(.+)\r\n"):split(',') or str:split(',')
        if not socket.isReady() then write(uid, "NET_NORDY\r\n") return end
        sys.taskInit(function(t, uid)
            local code, head, body = http.request(t[2]:upper(), t[3],t[8],nil, jsonstr or t[5], tonumber(t[6]) or 1, t[7])
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
        sys.taskInit(function(uid, prot, ip, port, ssl, timeout, data)
            local c = prot:upper() == "TCP" and socket.tcp(ssl and ssl:lower() == "ssl") or socket.udp()
            while not c:connect(ip, port) do sys.wait(2000) end
            if c:send(data) then
                write(uid, "SEND_OK\r\n")
                local r, s = c:recv(timeout * 1000)
                if r then write(uid, s) end
            else
                write(uid, "SEND_ERR\r\n")
            end
            c:close()
        end, uid, s:match("(.-),(.-),(.-),(.-),(.-),(.+)"))
        return
    end
    -- 添加设备识别码
    if tonumber(dtu.passon) == 1 then
        log.info("进到识别码里面来了")
        local interval, samptime = create.getTimParam()
        if interval[uid] > 0 then -- 定时采集透传模式
            -- 这里注意间隔时长等于预设间隔时长的时候就要采集,否则1秒的采集无法采集
            if os.difftime(os.time(), startTime[uid]) >= interval[uid] then
                if os.difftime(os.time(), startTime[uid]) < interval[uid] + samptime[uid] then
                    table.insert(sendBuff[uid], s)
                elseif startTime[uid] == 0 then
                    -- 首次上电立刻采集1次
                    table.insert(sendBuff[uid], s)
                    startTime[uid] = os.time() - interval[uid]
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
            log.info("进到识别码里面来来3")
            log.info("这个里面的内容是",tonumber(dtu.plate) == 1 and mobile.imei() .. s or s)
            sys.publish("NET_SENT_RDY_" .. uid, tonumber(dtu.plate) == 1 and mobile.imei() .. s or s)
        end
    else
        -- 非透传模式,解析数据
        if s:sub(1, 5) == "send," then
            log.info("进到识别码里面来来4")
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
    log.info("串口的数据是",uconf[i][1], uconf[i][2], uconf[i][3], uconf[i][5], uconf[i][4],uconf[i][6])
    uart.setup(uconf[i][1], uconf[i][2], uconf[i][3], uconf[i][5], uconf[i][4])
    uart.on(uconf[i][1], "sent", writeDone)
    if uconf[i][1] == uart.USB or tonumber(dtu.uartReadTime) > 0 then
        log.info("进到这里面来了呀1")
        uart.on(uconf[i][1], "receive", function(uid, length)
            log.info("接收到的数据是",uid,length)
            table.insert(recvBuff[i], uart.read(uconf[i][1], length or 8192))
            sys.timerStart(sys.publish, tonumber(dtu.uartReadTime) or 25, "UART_RECV_WAIT_" .. uconf[i][1], uconf[i][1], i)
        end)
    else
        log.info("进到这里面来了呀2")
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
    --sys.subscribe("UART_SENT_RDY_1", write)
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
    -- 485方向控制
    -- if not dtu.uconf[i][6] or dtu.uconf[i][6] == "" then -- 这么定义是为了和之前的代码兼容
    --     if i == 1 then
    --         if is8910 then
    --             default["dir1"] = 18
    --         elseif is1802S then
    --             default["dir1"] = 61
    --         elseif is4gLod then
    --             default["dir1"] = 23
    --         else
    --             default["dir1"] = 2
    --         end
    --     elseif i == 2 then
    --         if is8910 then
    --             default["dir2"] = 23
    --         elseif is1802S then
    --             default["dir2"] = 31
    --         elseif is4gLod then
    --             default["dir2"] = 59
    --         else
    --             default["dir2"] = 6
    --         end
    --     elseif i == 3 then
    --         if is8910 then
    --             default["dir3"] = 7
    --         end
    --     end
    -- else
    --     if pios[dtu.uconf[i][6]] then
    --         default["dir" .. i] = tonumber(dtu.uconf[i][6]:sub(4, -1))
    --         pios[dtu.uconf[i][6]] = nil
    --     else
    --         default["dir" .. i] = nil
    --     end
    -- end
    -- if default["dir" .. i] then
    --     pins.setup(default["dir" .. i], 0)
    --     uart.set_rs485_oe(i, default["dir" .. i])
    -- end
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
            log.info("dtuURL+++++")
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
            iot_fota.otaDemo()
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
        -- lbsLoc.request(function(result, lat, lng, addr)
        --     if result then
        --         lbs.lat, lbs.lng = lat, lng
        --         setLocation(lat, lng)
        --     end
        -- end)
        log.warn("短信或电话请求更新:", sys.waitUntil("UPDATE_DTU_CNF", 86400000))
    end
end)

-- 初始化配置UART1和UART2
--local uidgps = dtu.gps and dtu.gps.fun and tonumber(dtu.gps.fun[1])
if uidgps ~= 1 and dtu.uconf and dtu.uconf[1] and tonumber(dtu.uconf[1][1]) == 1 then
    log.info("我配置串口1了啊")
    uart_INIT(1, dtu.uconf) end
if uidgps ~= 2 and dtu.uconf and dtu.uconf[2] and tonumber(dtu.uconf[2][1]) == 2 then uart_INIT(2, dtu.uconf) end

-- 启动GPS任务
-- if uidgps then
--     -- 从pios列表去掉自定义的io
--     if dtu.gps.pio then
--         for i = 1, 3 do if pios[dtu.gps.pio[i]] then pios[dtu.gps.pio[i]] = nil end end
--     end
--     --sys.taskInit(tracker.sensMonitor, unpack(dtu.gps.pio))
--     sys.taskInit(tracker.alert, unpack(dtu.gps.fun))
-- end



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

sys.timerLoopStart(function()
    log.info("mem.lua", rtos.meminfo())
    log.info("mem.sys", rtos.meminfo("sys"))
 end, 3000)

return {setLocation = setLocation, gpio_set = gpio_set}
