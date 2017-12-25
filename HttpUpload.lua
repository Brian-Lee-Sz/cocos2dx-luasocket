--region httpUpload.lua
--Author : brianlee
--Date   : 2017/10/17
--发送http请求，一个请求一个实例

local HttpUpload={}

function HttpUpload:doRequest(cmd,path,data)
    if not cmd then
        return
    end
    local xhr = cc.XMLHttpRequest:new()
    local this=self
    xhr.responseType = cc.XMLHTTPREQUEST_RESPONSE_JSON
    local boundary="***852***"
    local lineEnd = "\r\n"
    local twoHyphens = "--"
    local slash="\""
    xhr:setRequestHeader("Content-Type",string.format("multipart/form-data; boundary=%s",boundary))
    local url = string.format("%s%s.php",PackageConfig.phpUrl,PhpObject[cmd].address)
    xhr:open("POST",url)
    local function onReadyStateChanged()
        local succeed
        local output
        if xhr.readyState == 4 and (xhr.status >= 200 and xhr.status < 207) then
            if (string.startsWith(xhr.response, "[") or string.startsWith(xhr.response, "{")) and (string.endWith(xhr.response, "]") or string.endWith(xhr.response, "}")) then
                output = cjson.decode(xhr.response)
                succeed=true
                cc.FileUtils:getInstance():removeFile(path)
            else
                printInfo("cmd:%s data type error  response:%s",cmd,xhr.response)
            end
        else
            printInfo(string.format("cmd :%d  %s%d%s%d",cmd,"xhr.readyState is:  ", xhr.readyState, " xhr.status is: ",xhr.status))
        end
        this:doResponse(cmd,output)
        if callback then callback(succeed,output) end
        xhr:unregisterScriptHandler()
    end
    local body=""
    local content=io.readfile(path)
    if content and content~="" then
        xhr:registerScriptHandler(onReadyStateChanged)
        local data=data or {}--添加公用参数
        data.sid=PackageConfig.clienttype
        data.bid=PackageConfig.bid
        data.lid= data.lid or tonumber(FileHelper:getStringForKey("qiji_login_type") or 0)
        data.language=data.language or UserDataController.getLanguage()
        data.uid=UserDataController.getUserID()
        data.version=VERSION.APK_VERSION
        data.clientid=PackageConfig.clientid
        body=string.format("%s%s%s",lineEnd,twoHyphens,boundary,lineEnd)--"\r\n--" + boundary + "\r\n"
        --Build the body of the request
        for k,v in pairs(data) do
            body=string.format("%sContent-Disposition: form-data; name=\"%s\"%s%s%s%s",body,k,lineEnd,lineEnd,v,lineEnd)
            body=string.format("%s%s%s%s",body,twoHyphens,boundary,lineEnd)
        end
        --Specify the type of upload img
        body=string.format("%sContent-Disposition: form-data; name=\"%s\";filename=\"%s\"%s",body,"upload","icon.png",lineEnd)
        --Specify the content disposition and type
        body=string.format("%s%s%s",body,"Content-Type: application/octet-stream",lineEnd)
        body=string.format("%s%s%s%s",body,"Content-Transfer-Encoding: binary",lineEnd,lineEnd)
        --Then append the file data and again the boundary
        body=string.format("%s%s",body,content)
        body=string.format("%s%s%s%s%s%s",body,lineEnd,twoHyphens,boundary,twoHyphens,lineEnd)
        xhr:send(body)
    else
        this:doResponse(cmd,{code=-8,resean="file path is wrong"})
        if callback then callback(succeed,"file path is wrong") end
    end
end

function HttpUpload:doResponse(cmd,data)
    if cmd then
        EventDispatcher.getInstance():dispatch(EventID.HttpEvent,cmd,data or {})
    end
end

return HttpUpload
--endregion
