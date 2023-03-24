# 应用手册 iRTU   V1.0

## 概述

iRTU:实现远程终端控制和数据传输功能，由合宙自主研发，采用Luat架构，免费并开源软硬件的远程控制系统。

## iRTU简介

- **DTU**(Data Transfer Unit):数据传输单元,主要用来处理本地和服务器之间的通信业务。通常用于将串口数据转换为IP数据或将IP数据转为串口数据，通过无线通信网络进行数据传输。广泛用于气象，水文水利，地质，抄表，数据采集等行业。
- **RTU**(Remote Terminal Unit):远程终端单元一般由信号输入、控制输出、通信设备、电源、微处理器等组成，并通过自身软件或系统执行远程下发的采集和控制任务，并且具备DTU的所有功能。
- **iRTU**:实现远程终端控制和数据传输功能，由合宙自主研发，采用Luat架构，免费并开源软硬件的远程控制系统。实现了DTU和RTU的主要功能，成本低廉，稳定可靠，已经广泛应用于各种行业系统中。因为开源特性，用户可以根据自己的特殊需要利用源码进行二次开发，实现定制化功能。

## 功能介绍

可以通过WEB端配置和指令，实现以下功能：

- 支持TCP/UDP socket,支持HTTP,MQTT,等常见透传和非透传模式
  
- 支持OneNET,阿里云，百度云，腾讯云等常见公有云。
- 支持RTU主控模式
- 支持数据流模板，任务
- 支持消息推送(电话，短信，网络通知)
- 支持GPS数据以及相关数据采集
- 支持ADC,I2C等外设，可以方便的扩展为屏幕、二维码等解决方案
- 支持空中升级
- **LUAT云功能说明**
  
  - 地址：<https://dtu.openluat.com/>
  
      借助Luat云可以实现远程FOTA和自动参数配置，用户无需用上位机配置程序来逐个配置iRTU，此方式可以极大减少人工费用和时间。使用远程固件更新和远程参数下发需要用户注册Luat云,用户注册自己的IMEI到云端，指定不同的IMEI到对应的参数版本，iRTU模块自动请求参数并保存到到iRTU模块中存储。

  - **远程固件更新**：用户只需在iRTU的web配置界面**基本参数**里勾选**自动更新**即可，当固件进行系统性的升级时，用户的iRTU即可自动进行自动远程升级。
  - **远程参数下发**：用户可以通过服务器下发相应的参数配置指令，进行远程参数下发。

 **目录如下** ：

## WEB端配置

## 指令功能

## 实例

## 常见问题及排查方法

## 修改记录

## 准备工作

## 1. 硬件准备

首次调试，建议准备一块合宙官方开发板，比如：724UG-A13,720U-A15,722-A10等。

参考设计如下：
[DTU-202-kicad](http://openluat-luatcommunity.oss-cn-hangzhou.aliyuncs.com/attachment/20210825165528609_DTU-Air202-kicad.rar)

[DTU-720D-kicad](http://openluat-luatcommunity.oss-cn-hangzhou.aliyuncs.com/attachment/20210825165533465_DTU-Air720D-kicad.rar)

[DTU-724UG-kicad](http://openluat-luatcommunity.oss-cn-hangzhou.aliyuncs.com/attachment/20210825165536942_DTU-Air724UG-kiacd.rar)

## 2. 软件准备

准备IRTU固件

* CAT1-8910平台（720UH/720UG/724UG/722UG）[8910-4GCAT1](http://openluat-luatcommunity.oss-cn-hangzhou.aliyuncs.com/attachment/20210825175156032_8910-4GCAT1.rar)

* 2G-8955平台（Air202/202S/208/800）[8955-2G](http://openluat-luatcommunity.oss-cn-hangzhou.aliyuncs.com/attachment/20210825175208561_8955-2G.rar)

* CAT4 -1802平台(720H/720G/720D) [1802-4GCAT4](http://openluat-luatcommunity.oss-cn-hangzhou.aliyuncs.com/attachment/20210825175233661_1802-4GCAT4.rar)

* CAT4-1802S平台（720SG/720SH/720SD）[1802S-4GCAT4](http://openluat-luatcommunity.oss-cn-hangzhou.aliyuncs.com/attachment/20210825175249490_1802S-4GCAT4.rar)

## 3. 在线配置账号

[点我进入 - IRTU 在线配置平台](http://dtu.openluat.com/login/ "点我进入 - IRTU 在线配置平台")  ，在线配置平台账号和密码与IOT平台一致

[点我进入IOT平台介绍](https://doc.openluat.com/wiki/21?wiki_page_id=2432 "点我进入- IOT平台介绍")

## 4. 串口工具

* [sscom](http://openluat-luatcommunity.oss-cn-hangzhou.aliyuncs.com/attachment/20210816202756489_sscom5.13.1.rar)
* [llcom](https://gitee.com/chenxuuu/llcom/releases/1.0.1.1)

## 5. [点我了解环境搭建：usb驱动安装，固件烧录等](https://doc.openluat.com/wiki/21?wiki_page_id=1923 "环境搭建")

   下载[Luatools](https://wiki.luatos.com/pages/tools.html)开发工具或者使用[LuatIDE](https://doc.openluat.com/article/3203# "LuatIDE")烧录固件
