dtulib={}
--- 软件重启
-- @string r 重启原因，用户自定义，一般是string类型，重启后的trace中会打印出此重启原因
-- @return 无
-- @usage sys.restart('程序超时软件重启')
function restart(r)
    assert(r and r ~= "", "sys.restart cause null")
    log.warn("sys.restart",r)
    mobile.flymode(0, true)--重启前进入下飞行模式，避免重启前上次模块和基站的心跳没断导致下次驻网不上
    mobile.flymode(1, true)
    rtos.reboot()
end
--- table.merge(...) 合并多个表格
-- @table[...],要合并的多个table
-- @return table,返回合并后的表格
-- @usage table.merge({1,2,3},{3, a = 4, b = 5, 6})
function merge(...)
    local tabs = {...}
    if #tabs == 0 then return {} end
    local origin = tabs[1]
    for i = 2, #tabs do
        if origin then
            if tabs[i] then
                for k, v in pairs(tabs[i]) do
                    if type(k) == "number" then
                        table.insert(origin, v)
                    else
                        origin[k] = v
                    end
                end
            end
        else
            origin = tabs[i]
        end
    end
    return origin
end


local Content_type = {'application/x-www-form-urlencoded', 'application/json', 'application/octet-stream'}

--- 处理表的url编码
-- @table query: 需要转码的查询表
-- @return string: 经过urlEncode转换后的字符串
-- @usage local q = table.urlEncode({a="1",b="2"})
function urlEncode(query)
    local msg = {}
    for k, v in pairs(query) do
        if type(k) == "number" then
            table.insert(msg, tostring(v):urlEncode())
        else
            table.insert(msg, k:urlEncode() .. "=" .. tostring(v):urlEncode())
        end
    end
    return table.concat(msg, "&")
end

-- 处理表的url编码
function urlencodeTab(params)
    local msg = {}
    for k, v in pairs(params) do
        table.insert(msg,  urlEncode(k) .. '=' .. urlEncode(v))
        table.insert(msg, '&')
    end
    table.remove(msg)
    return table.concat(msg)
end

--- HTTP客户端
-- @string method,提交方式"GET" or "POST"
-- @string url,HTTP请求超链接
-- @number timeout,超时时间
-- @param params,table类型，请求发送的查询字符串，通常为键值对表
-- @param data,table类型，正文提交的body,通常为键值对、json或文件对象类似的表
-- @number ctype,Content-Type的类型(可选1,2,3),默认1:"urlencode",2:"json",3:"octet-stream"
-- @string basic,HTTP客户端的authorization basic验证的"username:password"
-- @param headers,table类型,HTTP headers部分
-- @param cert,table类型，此参数可选，默认值为： nil，ssl连接需要的证书配置，只有ssl参数为true时，才参数才有意义，cert格式如下：
-- {
--  caCert = "ca.crt", --CA证书文件(Base64编码 X.509格式)，如果存在此参数，则表示客户端会对服务器的证书进行校验；不存在则不校验
--  clientCert = "client.crt", --客户端证书文件(Base64编码 X.509格式)，服务器对客户端的证书进行校验时会用到此参数
--  clientKey = "client.key", --客户端私钥文件(Base64编码 X.509格式) clientPassword = "123456", --客户端证书文件密码[可选]
--  }
-- @return string,table,string,正常返回response_code, response_header, response_body
-- @return string,string,错误返回 response_code, error_message
-- @usage local c, h, b = httpv2.request(url, method, headers, body)
-- @usage local r, e  = httpv2.request("http://wrong.url/ ")
function request(method, url, timeout, params, data, ctype, basic, head, cert, fnc)
    local _, idx, offset, ssl, auth, https, host, port, path
    local headers = {
        ['User-Agent'] = 'Mozilla/4.0',
        ['Accept'] = '*/*',
        ['Accept-Language'] = 'zh-CN,zh,cn',
        ['Connection'] = 'close',
    }
    if type(head) == "string" then
        log.info("user header:", basic, head)
        local tmp = {}
        for k, v in string.gmatch(head, "(.-):%s*(.-)\r\n") do tmp[k] = v end
        -- headers = tmp
        merge(headers, tmp)
    elseif type(head) == "table" then
        merge(headers, head)
    end

    _, idx, auth = url:find("(.-:.-)@", (offset or 0) + 1)
    offset = idx or offset
    -- 处理HTTP协议body部分的数据
    log.info("真的是1吗",ctype)
    ctype = ctype or 2
    headers['Content-Type'] = Content_type[ctype]
    log.info("这里是什么呢",headers['Content-Type'])
    if ctype == 1 and type(data) == 'table' then
        data = urlencodeTab(data)    
        log.info("进到1里面了")
    elseif ctype == 2 and data ~= nil then
        data = type(data) == 'string' and data or (type(data) == 'table' and json.encode(data)) or ""
    elseif ctype == 3 and type(data) == 'string' then
    elseif data and type(data) == "string" then
        log.info("进到elseif里面了")
    end
    -- 处理HTTP Basic Authorization 验证
    if auth then
        headers['Authorization'] = 'Basic ' .. crypto.base64_encode(auth, #auth)
    elseif type(basic) == 'string' and basic ~= "" then
        headers['Authorization'] = 'Basic ' .. crypto.base64_encode(basic, #basic)
    end
    -- 处理headers部分
    local str = ""
    for k, v in pairs(headers) do str = str .. k .. ": " .. v .. "\r\n" end
    log.info("URL",url)
    for k, v in pairs(headers) do log.info("k",k,v) end
    log.info("DATA11",data)
    log.info("method",method)
    return http.request(method,url,headers,data,{timeout=timeout}).wait()
end

return{
    restart=restart,
    request=request
}