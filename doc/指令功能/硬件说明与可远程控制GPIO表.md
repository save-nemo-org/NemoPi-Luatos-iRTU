# **硬件说明**

## **Air202/208/800 硬件说明**

### **AIR202-GPIO**

- 看门狗：
  - WDI —— 10脚 ( GPIO_31 )
  - RWD —— 11脚 ( GPIO_30 )

- NET_LED：
  - NET_LED —— 13脚 ( GPIO_33 )

- 重置参数：
  - RSP —— 12 脚（GPIO_29)

- 网络连接通知：
  - RDY —— 6脚（GPIO_3）

### **8.1.2、485 控制脚 (UART1)**

    RXD —— 9脚 (GPIO_0)
    TXD —— 8脚 (GPIO_1)
    DIR —— 7脚 (GPIO_2)

## **AIR720(S)/H/D/M/T/U 硬件说明**

### **AIR720-GPIO**

- NET_LED：
  - NET_LED ——  PIN6 ( GPIO_64 )

- 重置参数：
  - RSP —— PIN4（GPIO_68）

- 网络连接通知：
  - RDY —— PIN5 （GPIO_65）

### **TTL 输出脚**

    UART1_RXD —— PIN11 （GPIO_51）
    UART1_TXD —— PIN12 （GPIO_52）
    UART2_RXD —— PIN68 （GPIO_57）
    UART2_TXD —— PIN67 （GPIO_58）

### **485 控制脚**

    UART1_DIR —— PIN13 （GPIO_23） -- 720
    UART1_DIR —— PIN13 （GPIO_61） -- 720S
    
    UART2_DIR —— PIN64 （GPIO_59）-- 720
    UART2_DIR —— PIN64 （GPIO_31）-- 720S

## **720U/724U（RDA8910）硬件说明**

### **AIR720U-GPIO**

- NET_LED：
  - NET_LED ——  ( GPIO_01 )

- 重置参数：
  - RSP —— （GPIO_3）

- 网络连接通知：
  - RDY —— （GPIO_04）

### **TTL输出脚**

    UART1_RXD UART1_TXDUART2_RXD UART2_TXD

#### **485控制脚**

    UART1_DIR ——  （GPIO_18）
    UART2_DIR ——  （GPIO_23）

## **LED闪烁规则**

    100ms 闪烁 —— 注册GSM
    500ms 闪烁 —— 附着GPRS
    100ms 亮, 1900ms 灭 —— 已连接到服务器

# **附表可远程控制GPIO表**

### **Air202表**

| PIN  | GPIO    | PIN  | GPIO    |
| ---- | ------- | ---- | ------- |
| 29   | GPIO_6  | 5    | GPIO_12 |
| 30   | GPIO_7  | 11   | GPIO_30 |
| 3    | GPIO_8  | 10   | GPIO_31 |
| 2    | GPIO_10 | 4    | GPIO_11 |

### **Air800表**

| PIN  | GPIO    | PIN  | GPIO    |
| ---- | ------- | ---- | ------- |
| 4    | GPIO_6  | 21   | GPIO_11 |
| 3    | GPIO_7  | 22   | GPIO_12 |
| 19   | GPIO_8  | 28   | GPIO_31 |
| 20   | GPIO_10 | 27   | GPIO_30 |
| 18   | GPIO_9  | 29   | GPIO_29 |
| 17   | GPIO_13 | 41   | GPIO_18 |
| 37   | GPIO_14 | 47   | GPIO_34 |
| 38   | GPIO_15 | 40   | GPIO_17 |
| 39   | GPIO_16 |      |         |

### **Air720系列表**

| PIN  | GPIO  | PIN  | GPIO  |
| ---- | ----- | ---- | ----- |
| 26   | pio26 | 23   | pio70 |
| 25   | pio27 | 29   | pio71 |
| 24   | pio28 | 28   | pio72 |
| 39   | pio33 | 33   | pio73 |
| 40   | pio34 | 32   | pio74 |
| 38   | pio35 | 30   | pio75 |
| 37   | pio36 | 31   | pio76 |
| 65   | pio55 | 66   | pio77 |
| 62   | pio56 | 63   | pio78 |
| 1    | pio62 | 61   | pio79 |
| 2    | pio63 | 113  | pio80 |
| 115  | pio69 | 114  | pio81 |
