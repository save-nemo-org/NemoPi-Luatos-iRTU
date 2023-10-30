-- LuaTools需要PROJECT和VERSION这两个信息
PROJECT = "test_iRTU"
VERSION = "1.0.5"

-- PRODUCT_KEY = "0LkZx9Kn3tOhtW7uod48xhilVNrVsScV" --618DTU正式版本的key固定为它
PRODUCT_KEY = "z1OoDfAP2LDtOStiMQTVDfXO6RkrWeBG" --618DTU测试版本的key固定为它



log.info("main", PROJECT, VERSION)

-- 一定要添加sys.lua !!!!
_G.sys = require("sys")
_G.sysplus = require("sysplus")

require "libnet"
require "libfota"
require "lbsLoc"

collectgarbage()
collectgarbage()

db = require("db")

--添加硬狗防止程序卡死
if wdt then
    wdt.init(9000) -- 初始化watchdog设置为9s
    sys.timerLoopStart(wdt.feed, 3000) -- 3s喂一次狗
end
ver = rtos.bsp()

default = require "default"

collectgarbage()
collectgarbage()
-- log.info("mem.lua", rtos.meminfo())
-- log.info("mem.sys", rtos.meminfo("sys"))

-- 用户代码已结束---------------------------------------------
-- 结尾总是这一句
sys.run()
-- sys.run()之后后面不要加任何语句!!!!!
