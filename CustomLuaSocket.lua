--region coLuaSocket.lua
--Author : brianlee
--Date   : 2017/9/22
--Socket operations
--静态类：关于socket的一些操作
--endregion

CoLuaSocket = class("CoLuaSocket")

require("socket")

CoLuaSocket._TAG = "CoLuaSocket"

local ByteArray=require("coFramework.util.byteArray")

CoLuaSocket.HEART_TIME     = 15           -- 心跳包时间间隔

-- socket连接
-- 参数 ip ip地址 port 端口号
CoLuaSocket.open = function(host, port)
    if not CoLuaSocket.isConnected() and not CoLuaSocket.is_opening and host and port then 
        CoLuaSocket.host=host
        CoLuaSocket.port=port
        CoLuaSocket.getSocket(host, port)
    end
end

-- 关闭socket连接
CoLuaSocket.close = function()
    for _ ,client in pairs(CoLuaSocket.set or {}) do
        client:close()
    end
    CoLuaSocket.stopHeartBeat()
    CoLuaSocket.stopSocketUpdate()
    CoLuaSocket.set={}
    CoLuaSocket.s_socket = nil
    CoLuaSocket.onClose("")
end

-- 获取socket
CoLuaSocket.getSocket = function(host,port)
    if not CoLuaSocket.s_socket then
        CoLuaSocket.s_socket = CoLuaSocket.checkIpType(host) and socket.tcp6() or socket.tcp()
        if nil ~= CoLuaSocket.s_socket then
            CoLuaSocket.s_socket:settimeout(0)
            --连接socket
            local res,err = CoLuaSocket.s_socket:connect(host, port)
            if not res and not err=="timeout" then
		        CoLuaSocket.onError(err)
		        return false
            end
            CoLuaSocket.s_connected = false
            CoLuaSocket.is_opening = true
            --通知连接socket
            EventDispatcher.getInstance():dispatch(EventID.SocketEvent, EventID.SOCKET_CONNECT_OPENING)
            CoLuaSocket.newset()
            CoLuaSocket.set:insert(CoLuaSocket.s_socket)
            -- 设置心跳包间隔时间
            CoLuaSocket.setHeartBeatInterval(CoLuaSocket.HEART_TIME)
            -- 设置心跳包命令字
            CoLuaSocket.setHeartBeatCmd(SocketCmd.CMD_HEART_BEAT)
            CoLuaSocket.startHeartBeat()
            CoLuaSocket.s_SocketSchedulerID = cc.Director:getInstance():getScheduler():scheduleScriptFunc(CoLuaSocket.update,0,false) 
            CoLuaSocket.Loading_error=nil
        else
           CoLuaSocket.onError("create socket context faile") 
        end
    end
    return CoLuaSocket.s_socket
end

function CoLuaSocket.checkIpType(host)
    local result = socket.dns.getaddrinfo(host)
    for k,v in pairs(result or {}) do
        if v.family == "inet6" then
            printInfo("is inet6")
            return true
        end
    end
    printInfo("is inet4")
    return false
end

--创建数据包集合
function CoLuaSocket.newset()
    local reverse = {}
    CoLuaSocket.set = {}
    return setmetatable(CoLuaSocket.set, {__index = {
        insert = function(set, value)
            if not reverse[value] then
                table.insert(set, value)
                reverse[value] = table.getn(set)
            end
        end,
        remove = function(set, value)
            local index = reverse[value]
            if index then
                reverse[value] = nil
                local top = table.remove(set)
                if top ~= value then
                    reverse[top] = index
                    set[index] = top
                end
            end
        end
    }})
end

function CoLuaSocket.update()
	if CoLuaSocket.set==nil or #CoLuaSocket.set<=0 or not CoLuaSocket.s_socket then
		return
    end
    if CoLuaSocket.is_opening then
        if  CoLuaSocket.s_socket and CoLuaSocket.host and CoLuaSocket.port then
            local res,err = CoLuaSocket.s_socket:connect(CoLuaSocket.host, CoLuaSocket.port)
            -- err in case of "already connected" is special fix for LuaSocket working on windows
            -- refer to: http://lua-users.org/lists/lua-l/2009-10/msg00584.html
            printInfo(" res: %d , err: %s",res or 0,err or "null")
            if res == 1 or err == "already connected" then
                CoLuaSocket.onOpen()
            end
        end
    else
        -- get sockets ready for read
        local readable, writeable, err = socket.select(CoLuaSocket.set, CoLuaSocket.set, 0)
        if err~=nil then
            -- some error happened in select
            if err=="timeout" then
                -- nothing to do, return
                return 
            end
            CoLuaSocket.onError(err)
        end
        for _, input in ipairs(readable) do
            --[[
                If successful, the method returns the received pattern. 
                In case of error, the method returns nil followed by an error message which can be the string 'closed' 
                in case the connection was closed before the transmission was completed or the string 'timeout' 
                in case there was a timeout during the operation. Also, after the error message, 
                the function returns the partial result of the transmission
            ]]
            local s, status, partial = input:receive('*a')
            if status == "timeout" or status == nil then
                CoLuaSocket.onMessage(s or partial)
            elseif status == "closed" then
                --连接失败
                printInfo("closed")
                CoLuaSocket.close()
                EventDispatcher.getInstance():dispatch(EventID.SocketEvent, EventID.SOCKET_CONNECT_DISABLED)
                return
            end
        end
    end
end

----------------------------------------------------socket连接状态------------------------------------------------------
function CoLuaSocket.onOpen()
    CoLuaSocket.s_connected = true
    CoLuaSocket.is_opening = false
    EventDispatcher.getInstance():dispatch(EventID.SocketEvent, EventID.SOCKET_CONNECT_SUCCESS)
    --[[启动心跳]]
    CoLuaSocket.startHeartBeat()
end

--接受到socket数据
function CoLuaSocket.onMessage(data)
    local packet=ByteArray.new(ByteArray.ENDIAN_BIG)
    packet:writeString(data)
    packet:setPos(1)
    local len=packet:getLen()
    local pos=1
    local round=1
    while pos<=len and round < 10 do
        packet:setPos(pos)
        local p_len=packet:readUInt()
        packet:setPos(pos)
        if len-p_len==4 then
            --整包
            -- printInfo("-----------------整包"..p_len)
            CoLuaSocket.dispatch(packet)
            return
        else
            --粘包
            -- printInfo("-----------------粘包"..p_len)
            if len< pos+p_len+4-1 then
                printInfo("-----------------包不完整")
                return 
            end
            local temp=ByteArray.new(ByteArray.ENDIAN_BIG)
            temp:writeBytes(packet,pos,p_len+4)
            CoLuaSocket.dispatch(temp)
            pos=pos+p_len+4
        end
        round=round+1
    end
end

--分发数据包
function CoLuaSocket.dispatch(packet)
    CoLuaSocket.decrypt(packet) 
    local cmd = CoLuaSocket.readbegin(packet)
    CoLuaSocket.onResponseHeartBeat()
    if cmd and SocketObject[cmd] then
        local param=require(SocketObject[cmd]).doResponse(packet)
        if param then
            EventDispatcher.getInstance():dispatch(EventID.SocketEvent,cmd,param)
        end
    end
end

-- socket连接超时，一般是很久没收到服务器的心跳包。
CoLuaSocket.onTimeout = function()
    printInfo("%s%s",CoLuaSocket._TAG,"socket onTimeout")
    CoLuaSocket.close()
    EventDispatcher.getInstance():dispatch(EventID.SocketEvent, EventID.SOCKET_CONNECT_TIMEOUT)
end

--socket关闭
function CoLuaSocket.onClose(data)
    printInfo("%s%s",CoLuaSocket._TAG,"socket onClose")
    CoLuaSocket.s_connected = false
    CoLuaSocket.is_opening = false
    EventDispatcher.getInstance():dispatch(EventID.SocketEvent, EventID.SOCKET_CONNECT_CLOSED)
end

--socket报错
function CoLuaSocket.onError(data)
    printInfo("%s%s%s",CoLuaSocket._TAG,"socket onError",data)
    EventDispatcher.getInstance():dispatch(EventID.SocketEvent, EventID.SOCKET_CONNECT_ERROR)
end

--socket不可用
function CoLuaSocket.onDisabled(data)
    printInfo("%s%s%s",CoLuaSocket._TAG,"socket onError",data)
    EventDispatcher.getInstance():dispatch(EventID.SocketEvent, EventID.SOCKET_CONNECT_ERROR)
end

-- 当前socket连接状态
CoLuaSocket.isConnected = function()
    return CoLuaSocket.s_connected or false
end

CoLuaSocket.stopSocketUpdate = function()
    if CoLuaSocket.s_SocketSchedulerID then 
        cc.Director:getInstance():getScheduler():unscheduleScriptEntry(CoLuaSocket.s_SocketSchedulerID)   
    end
    CoLuaSocket.s_SocketSchedulerID = nil
end

---------------------------------------------------------  heart beat --------------------------------------------------

-- 设置心跳包时间
CoLuaSocket.setHeartBeatInterval = function(milliSecond)
    CoLuaSocket.HEART_TIME = milliSecond
end

CoLuaSocket.setHeartBeatCmd = function(cmd)
    CoLuaSocket.HEART_CMD = cmd
end

-- heart beat 收发心跳包
CoLuaSocket.startHeartBeat = function()
    if not CoLuaSocket.HEART_CMD then
        return
    end
    CoLuaSocket.stopHeartBeat()
    CoLuaSocket.TIME_OUT = false
    -- 是否连接超时（长时间没收到心跳包）
    CoLuaSocket.s_heartBeatSchedulerID = cc.Director:getInstance():getScheduler():scheduleScriptFunc(CoLuaSocket.onHeartBeat,CoLuaSocket.HEART_TIME,false)  
end

CoLuaSocket.onHeartBeat = function()
    if CoLuaSocket.TIME_OUT then
        CoLuaSocket.onHeartBeatTimeout()
        return
    end
    --[[发送心跳包]]
    if CoLuaSocket.s_socket and CoLuaSocket.isConnected() then
        local packet = CoLuaSocket.writeBegin(SocketCmd.CMD_HEART_BEAT)
        CoLuaSocket.writeEnd(packet)
    end
    -- 下次发心跳之前没收到服务器心跳包则 认为超时
    CoLuaSocket.TIME_OUT = true
end

CoLuaSocket.onResponseHeartBeat = function()
    CoLuaSocket.TIME_OUT = false
end

CoLuaSocket.onHeartBeatTimeout = function()
    CoLuaSocket.stopHeartBeat()
    CoLuaSocket.onTimeout()
end

CoLuaSocket.stopHeartBeat = function()
    if CoLuaSocket.s_heartBeatSchedulerID then 
        cc.Director:getInstance():getScheduler():unscheduleScriptEntry(CoLuaSocket.s_heartBeatSchedulerID)   
    end
    CoLuaSocket.s_heartBeatSchedulerID = nil
end

---------------------------------------------------------数据包解析相关------------------------------------------------------------------
--返回字符
function CoLuaSocket.get_buffer(packet)
    if CoLuaSocket.s_socket and CoLuaSocket.isConnected() then
        CoLuaSocket.s_socket:send(packet:getPack())
    elseif not CoLuaSocket.is_opening and UserDataController.getServerConfig() then
        CoLuaSocket.open(UserDataController.getServerConfig())
    end
end

function CoLuaSocket.writeBegin(cmd)
    if not cmd then
        if DEBUG >= 1 then
            printInfo("%s%s",CoLuaSocket._TAG,"writeBegin : cmd is nil")
        end
        return
    end
    local packet=ByteArray.new(ByteArray.ENDIAN_BIG)
------------------------自定义包头---------------------------
    packet:writeUInt(0)                           --数据包大小
    :writeString("QJ")                            --标志位(固定为QJ这两个字符)
    :writeByte(SERVER_REQUEST_VER)                --版本号
    :writeByte(0)                                 --拓展字段长度
    :writeUInt(cmd)                               --请求命令字
    :writeShort(CURRENT_GAMEID)                   --当前游戏id
    :writeByte(0)                                 --校验码
------------------------自定义包头---------------------------
    return packet
end

--[[
    修改包头的时候记得修改包头长度
]]
CoLuaSocket.HEAD_PACKET_SIZE=15

--[[
    write end
]]
function CoLuaSocket.writeEnd(packet,isr)
    packet:setPos(1)
    packet:writeUInt(packet:getLen()-4)     --数据包长度不包括数据包大小的长度
    CoLuaSocket.encrypt(packet)
    if isr then
        return packet
    end
    CoLuaSocket.get_buffer(packet)
end

--[[加密数据]]
function CoLuaSocket.encrypt(packet)
	local body_len = packet:getLen()-CoLuaSocket.HEAD_PACKET_SIZE
	if body_len <= 0 then
		return
	end
	packet:setPos(CoLuaSocket.HEAD_PACKET_SIZE+1)
    local code = 0
    local temp=""
	for i=1, body_len do
		local real_value = packet:readByte()
		local decode_value = CoLuaSocket.sendByteMap[real_value+1]  
        if decode_value then
            packet:setPos(packet:getPos()-1)
            packet:writeByte(decode_value)
        end
        code = code + real_value
        temp=string.format("%s-%02x",temp,real_value)
    end
    packet:setPos(CoLuaSocket.HEAD_PACKET_SIZE)
    local max=math.pow(2,8)
    if code~=0 then
        code=code%max
        code=max-code
    end
    code=code==max and 0 or code
    printInfo(code)
    packet:writeByte(code)
end

function CoLuaSocket.writeUInt(packet,val)
    packet:writeUInt(val)
end

function CoLuaSocket.writeInt(packet,val)
    packet:writeInt(val)
end

function CoLuaSocket.writeInt64(packet,val)
    local mid=math.pow(2,32)
    local high=math.floor(math.abs(val)/mid)
    local low=math.abs(val)%mid
    if val < 0 and high ~= 0 then
        high=0-high
    elseif val < 0 and high==0 then
        low=0-low
    end
    packet:writeInt(high)
    packet:writeInt(low)
end

function CoLuaSocket.writeShort(packet,val)
    packet:writeShort(val)
end

function CoLuaSocket.writeUShort(packet,val)
    packet:writeUShort(val)
end

function CoLuaSocket.writeByte(packet,val)
    packet:writeByte(val)
end

function CoLuaSocket.writeString(packet,val)
    packet:writeStringUInt(val)
end

function CoLuaSocket.writeChar(packet,val)
    packet:writeChar(val)
end


-------------------read----------------------------------------

function CoLuaSocket.readbegin(packet)
    packet:setPos(1)
    packet:readUInt()
    packet:readString(2)
    packet:readByte()
    packet:readByte()
    local cmd= packet:readUInt()
    packet:readShort()
    local code=packet:readChar()
    local temp=0
    local pos=packet:getPos()
    while (#packet._buf >= packet._pos)
    do
        local real_value = packet:readByte()
        temp=temp+real_value
    end
    temp=bit.bnot(code)+1
    if temp+code==0 then
        packet:setPos(pos)
        return cmd
    end
end

function CoLuaSocket.readInt(packet)
    return packet:readInt()
end

function CoLuaSocket.readInt64(packet)
    local div = math.pow(2,32)
    local high=packet:readInt()
    local low=packet:readInt()
    if high>=0 then
        result=high*div+(low+div)%div
    else
        low=bit.bnot(low)+1
        local temp_high=0
        if low==0 then
            temp_high=bit.bnot(high)+1
        else
            temp_high=bit.bnot(high)
        end
        result=0-(temp_high*div+(low+div)%div)
    end
    return result
end

function CoLuaSocket.readUInt(packet)
    return packet:readUInt()
end

function CoLuaSocket.readShort(packet)
    return packet:readShort()
end

function CoLuaSocket.readUShort(packet)
    return packet:readUShort()
end

function CoLuaSocket.readByte(packet)
    return packet:readByte()
end

function CoLuaSocket.readString(packet)
    return packet:readStringUInt()
end

function CoLuaSocket.readChar(packet)
    return packet:readChar()
end

function CoLuaSocket.decrypt(packet)
	local body_len = packet:getLen()-CoLuaSocket.HEAD_PACKET_SIZE
	if body_len <= 0 then
		return
	end
	packet:setPos(CoLuaSocket.HEAD_PACKET_SIZE+1)
	for i=1, body_len do
		local real_value = packet:readByte()
		local decode_value = table.indexof(CoLuaSocket.sendByteMap,real_value)
        if decode_value then
            packet:setPos(packet:getPos()-1)
            packet:writeByte(decode_value-1)
        end
	end
end

----------------------前后端讨论定义---------------------------
CoLuaSocket.sendByteMap = {
    -- 加密
} 

CoLuaSocket.recvByteMap = {
    -- 解密
} 
