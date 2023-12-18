# **硬件说明**

## **Air780E/700E 硬件说明**

### **AIR780-GPIO**

- NET_LED：
  - NET_LED —— 16脚 ( GPIO_27 )

- 重置参数：
  - RSP —— 78 脚（GPIO_28)

- 网络连接通知：
  - RDY —— 25脚（GPIO_26）


### **TTL 输出脚**

    UART1_RXD —— PIN17 （GPIO_18）
    UART1_TXD —— PIN18 （GPIO_19）
    UART2_RXD —— PIN28 （GPIO_10）
    UART2_TXD —— PIN29 （GPIO_11）



## **LED闪烁规则**

    NETRDY 亮 ——连接服务器
    NETRDY 灭 ——没有连接服务器
    NETLED 100ms 闪烁 —— 注册GSM
    NETLED 500ms 闪烁 —— 附着GPRS
    NETLED 200ms 亮, 1800ms 灭 —— 已连接到服务器

# **附表可远程控制GPIO表**


### **Air780系列表**

| PIN  | GPIO  | PIN  | GPIO  |
| ---- | ----- | ---- | ----- |
| 49   | pio1  | 107  | pio21 |
| 21   | pio2  | 19   | pio22 |
| 54   | pio3  | 99   | pio23 |
| 80   | pio4  | 20   | pio24 |
| 81   | pio5  | 106  | pio25 |
| 55   | pio6  | 25   | pio26 |
| 56   | pio7  | 16   | pio27 |
| 52   | pio8  | 78   | pio28 |
| 50   | pio9  | 30   | pio29 |
| 22   | pio16 | 31   | pio30 |
| 23   | pio17 | 32   | pio31 |
| 102  | pio20 |      |       |
