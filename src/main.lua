function QuickApp:onInit()
    self:debug("-------------------")
    self:debug("HC3 <-> MQTT BRIDGE")
    self:debug("Version: 1.0.171")
    self:debug("-------------------")

    self:turnOn()  
end

function QuickApp:publish(topic, payload)
    self.mqtt:publish(topic, tostring(payload), {retain = true})
end

function QuickApp:turnOn() 
    self:establishMqttConnection()
end

function QuickApp:turnOff()
    self:debug("HC3-to-MQTT bridget shutdown sequence initiated")
    self:disconnectFromMqttAndHc3()
    self:updateProperty("value", false)
    self:debug("HC3-to-MQTT bridge shutdown sequence complete")
end

function QuickApp:establishMqttConnection() 
    self.devices = {}

    -- IDENTIFY WHICH MQTT CONVENTIONS TO BE USED (e.g. Home Assistant, Homio, etc)
    self.mqttConventions = { }
    local mqttConventionStr = self:getVariable("mqttConvention")
    if (isEmptyString(mqttConventionStr)) then
        self.mqttConventions[0] = MqttConventionHomeAssistant
    else
        local arr = splitString(mqttConventionStr, ",")
        for i, j in ipairs(arr) do
            local convention = mqttConventionMappings[j]
            if (convention) then
                self.mqttConventions[i] = clone(convention)
            end
        end
    end

    local mqttConnectionParameters = self:getMqttConnectionParameters()
    self:trace("MQTT Connection Parameters: " .. json.encode(mqttConnectionParameters))

    local mqttClient = mqtt.Client.connect(
                                    self:getVariable("mqttUrl"),
                                    mqttConnectionParameters) 

    mqttClient:addEventListener('connected', function(event) self:onConnected(event) end)
    mqttClient:addEventListener('closed', function(event) self:onClosed(event) end)
    mqttClient:addEventListener('message', function(event) self:onMessage(event) end)
    mqttClient:addEventListener('error', function(event) self:onError(event) end)    
    
    self.mqtt = mqttClient
end

function QuickApp:getMqttConnectionParameters()
    local mqttConnectionParameters = {
        -- pickup last will from primary MQTT Convention provider
        lastWill = self.mqttConventions[1]:getLastWillMessage()
    }

    -- MQTT CLIENT ID (OPTIONAL)
    local mqttClientId = self:getVariable("mqttClientId")
    if (isEmptyString(mqttClientId)) then
        local autogeneratedMqttClientId = "HC3-" .. plugin.mainDeviceId .. "-" .. tostring(os.time())
        self:warning("All is good - we have just autogenerated mqttClientId for you \"" .. autogeneratedMqttClientId .. "\"")
        mqttConnectionParameters.clientId = autogeneratedMqttClientId
    else
        mqttConnectionParameters.clientId = mqttClientId
    end

    -- MQTT KEEP ALIVE PERIOD
    local mqttKeepAlivePeriod = self:getVariable("mqttKeepAlive")
    if (mqttKeepAlivePeriod) then
        mqttConnectionParameters.keepAlivePeriod = tonumber(mqttKeepAlivePeriod)
    else
        mqttConnectionParameters.keepAlivePeriod = 60
    end

    -- MQTT AUTH (USERNAME/PASSWORD)
    local mqttUsername = self:getVariable("mqttUsername")
    local mqttPassword = self:getVariable("mqttPassword")

    if (mqttUsername) then
        mqttConnectionParameters.username = mqttUsername
    end
    if (mqttPassword) then
        mqttConnectionParameters.password = mqttPassword
    end

    return mqttConnectionParameters
end

function QuickApp:disconnectFromMqttAndHc3()
    self.hc3ConnectionEnabled = false
    self:closeMqttConnection()
    self:debug("Disconnected from MQTT")
end

function QuickApp:closeMqttConnection()
    for i, j in ipairs(self.mqttConventions) do
        if (j.mqtt ~= MqttConventionPrototype.mqtt) then
            j:onDisconnected()
        end
    end

    self.mqtt:disconnect()
end

function QuickApp:onClosed(event)
    self:updateProperty("value", false)
end

function QuickApp:onError(event)
    self:error("MQTT ERROR: " .. json.encode(event))
    if event.code == 2 then
        self:warning("MQTT username and/or password is possibly indicated wrongly")
    end
    self:turnOff()
    self:scheduleReconnectToMqtt();
end

function QuickApp:scheduleReconnectToMqtt()
    fibaro.setTimeout(10000, function() 
        self:debug("Attempt to reconnect to MQTT...")
        self:establishMqttConnection()
    end)
end

function QuickApp:onMessage(event)
    for i, j in ipairs(self.mqttConventions) do
        j:onCommand(event)
    end
end

function QuickApp:onConnected(event) 
    self:debug("MQTT connection established")

    for _, mqttConvention in ipairs(self.mqttConventions) do
        mqttConvention.mqtt = self.mqtt
        mqttConvention.devices = self.devices
        mqttConvention:onConnected()
    end

    self:discoverDevicesAndPublishToMqtt()

    self.hc3ConnectionEnabled = true
    self:scheduleHc3EventsFetcher()

    self:updateProperty("value", true)
end

function QuickApp:identifyAndPublishDeviceToMqtt(fibaroDevice)
    local bridgedDevice = identifyDevice(fibaroDevice)
    self:publishDeviceToMqtt(bridgedDevice)
end

function QuickApp:discoverDevicesAndPublishToMqtt()
    local startTime = os.time()

    local fibaroDevices = self:discoverDevices()
    
    self:identifyDevices(fibaroDevices)

    for _, device in pairs(self.devices) do
        self:publishDeviceToMqtt(device)
    end

    local diff = os.time() - startTime   

    local bridgedDevices = 0
    for _, _ in pairs(self.devices) do
        bridgedDevices = bridgedDevices + 1
    end
    
    self:updateView("availableDevices", "text", "Available devices: " .. #fibaroDevices)
    self:updateView("bridgedDevices", "text", "Bridged devices: " .. bridgedDevices) 
    self:updateView("bootTime" , "text", "Boot time: " .. diff .. "s")

    self:debug("")
    self:debug("----------------------------------")
    self:debug("Device discovery has been complete")
    self:debug("----------------------------------")

    return haDevices
end

function QuickApp:discoverDevices()
    local fibaroDevices

    local developmentModeStr = self:getVariable("developmentMode")
    if ((not developmentModeStr) or (developmentModeStr ~= "true")) then
        self:debug("Bridge mode: PRODUCTION")

        local customDeviceFilterJsonStr = self:getVariable("deviceFilter")

        fibaroDevices = getFibaroDevicesByFilter(customDeviceFilterJsonStr)
    else
        --smaller number of devices for development and testing purposes
        self:debug("Bridge mode: DEVELOPMENT")

        fibaroDevices = {
            --[[
            getFibaroDeviceById(41), -- switch Onyx light,
            getFibaroDeviceById(42), -- switch Fan,
            getFibaroDeviceById(260), -- iPad screen
            getFibaroDeviceById(287), -- door sensor
            getFibaroDeviceById(54), -- motion sensor
            getFibaroDeviceById(92), -- roller shutter
            getFibaroDeviceById(78), -- dimmer
            getFibaroDeviceById(66), -- temperature sensor
            getFibaroDeviceById(56), -- light sensor (lux)
            getFibaroDeviceById(245), -- volts
            getFibaroDeviceById(105), -- on/off thermostat from CH
            getFibaroDeviceById(106), -- temperature sensor
            getFibaroDeviceById(120), -- IR thermostat from CH
            getFibaroDeviceById(122), -- temperature sensor
            getFibaroDeviceById(335), -- on/off thermostat from Qubino
            getFibaroDeviceById(336), -- temperature sensor 
            getFibaroDeviceById(398), -- temperature sensor  
            ]]--
            getFibaroDeviceByInfo(
                json.decode(
                    "{ \"id\": 968, \"name\": \"LightsHolGaraj\", \"roomID\": 226, \"view\": [ { \"assetsPath\": \"dynamic-plugins/com.fibaro.multilevelSwitch\", \"name\": \"com.fibaro.multilevelSwitch\", \"translatesPath\": \"/assets/i18n/com.fibaro.multilevelSwitch\", \"type\": \"ts\" }, { \"assetsPath\": \"dynamic-plugins/energy\", \"name\": \"energy\", \"translatesPath\": \"/assets/i18n/energy\", \"type\": \"ts\" }, { \"assetsPath\": \"\", \"name\": \"level-change\", \"translatesPath\": \"/assets/i18n/level-change\", \"type\": \"ts\" }, { \"assetsPath\": \"dynamic-plugins/power\", \"name\": \"power\", \"translatesPath\": \"/assets/i18n/power\", \"type\": \"ts\" } ], \"type\": \"com.fibaro.FGD212\", \"baseType\": \"com.fibaro.multilevelSwitch\", \"enabled\": true, \"visible\": true, \"isPlugin\": false, \"parentId\": 965, \"viewXml\": false, \"hasUIView\": true, \"configXml\": false, \"interfaces\": [ \"energy\", \"levelChange\", \"light\", \"power\", \"zwave\", \"zwaveAlarm\", \"zwaveMultiChannelAssociation\", \"zwaveProtection\", \"zwaveSceneActivation\" ], \"properties\": { \"parameters\": [ { \"id\": 1, \"lastReportedValue\": 1, \"lastSetValue\": 1, \"size\": 1, \"value\": 1 }, { \"id\": 2, \"lastReportedValue\": 30, \"lastSetValue\": 30, \"size\": 1, \"value\": 30 }, { \"id\": 3, \"lastReportedValue\": 99, \"lastSetValue\": 99, \"size\": 1, \"value\": 99 }, { \"id\": 4, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 2, \"value\": 0 }, { \"id\": 5, \"lastReportedValue\": 99, \"lastSetValue\": 99, \"size\": 1, \"value\": 99 }, { \"id\": 6, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 2, \"value\": 0 }, { \"id\": 7, \"lastReportedValue\": 99, \"lastSetValue\": 99, \"size\": 1, \"value\": 99 }, { \"id\": 8, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 2, \"value\": 0 }, { \"id\": 9, \"lastReportedValue\": 1, \"lastSetValue\": 1, \"size\": 1, \"value\": 1 }, { \"id\": 10, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 2, \"value\": 0 }, { \"id\": 11, \"lastReportedValue\": 255, \"lastSetValue\": 255, \"size\": 2, \"value\": 255 }, { \"id\": 13, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 14, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 15, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 16, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 2, \"value\": 0 }, { \"id\": 19, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 20, \"lastReportedValue\": 1, \"lastSetValue\": 1, \"size\": 1, \"value\": 1 }, { \"id\": 21, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 22, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 23, \"lastReportedValue\": 1, \"lastSetValue\": 1, \"size\": 1, \"value\": 1 }, { \"id\": 24, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 25, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 26, \"lastReportedValue\": 1, \"lastSetValue\": 1, \"size\": 1, \"value\": 1 }, { \"id\": 27, \"lastReportedValue\": 15, \"lastSetValue\": 15, \"size\": 1, \"value\": 15 }, { \"id\": 28, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 29, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 30, \"lastReportedValue\": 2, \"lastSetValue\": 2, \"size\": 1, \"value\": 2 }, { \"id\": 31, \"lastReportedValue\": 1, \"lastSetValue\": 1, \"size\": 1, \"value\": 1 }, { \"id\": 32, \"lastReportedValue\": 1, \"lastSetValue\": 1, \"size\": 1, \"value\": 1 }, { \"id\": 33, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 34, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 35, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 37, \"lastReportedValue\": 1, \"lastSetValue\": 1, \"size\": 1, \"value\": 1 }, { \"id\": 39, \"lastReportedValue\": 250, \"lastSetValue\": 250, \"size\": 2, \"value\": 250 }, { \"id\": 40, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 41, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 42, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 43, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 44, \"lastReportedValue\": 600, \"lastSetValue\": 600, \"size\": 2, \"value\": 600 }, { \"id\": 45, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 46, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 47, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 48, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 49, \"lastReportedValue\": 1, \"lastSetValue\": 1, \"size\": 1, \"value\": 1 }, { \"id\": 50, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 52, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 2, \"value\": 0 }, { \"id\": 53, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 2, \"value\": 0 }, { \"id\": 54, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 58, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 1, \"value\": 0 }, { \"id\": 59, \"lastReportedValue\": 0, \"lastSetValue\": 0, \"size\": 2, \"value\": 0 } ], \"pollingTimeSec\": 0, \"zwaveCompany\": \"Fibargroup\", \"zwaveInfo\": \"3,4,5\", \"zwaveVersion\": \"3.5\", \"RFProtectionState\": 0, \"RFProtectionSupport\": 3, \"alarmLevel\": 0, \"alarmType\": 0, \"categories\": [ \"lights\" ], \"configured\": true, \"dead\": false, \"deadReason\": \"\", \"deviceControlType\": 2, \"deviceIcon\": 15, \"deviceRole\": \"Light\", \"emailNotificationID\": 0, \"emailNotificationType\": 0, \"endPointId\": 1, \"energy\": 31.16, \"icon\": { \"path\": \"/assets/icon/fibaro/light/light0.png\", \"source\": \"HC\" }, \"isLight\": true, \"localProtectionState\": 0, \"localProtectionSupport\": 5, \"log\": \"\", \"logTemp\": \"\", \"manufacturer\": \"\", \"markAsDead\": true, \"model\": \"\", \"nodeId\": 207, \"parametersTemplate\": \"740\", \"power\": 0, \"productInfo\": \"1,15,1,2,16,0,3,5\", \"protectionExclusiveControl\": 0, \"protectionExclusiveControlSupport\": false, \"protectionState\": 0, \"protectionTimeout\": 0, \"protectionTimeoutSupport\": false, \"pushNotificationID\": 0, \"pushNotificationType\": 0, \"saveLogs\": true, \"saveToEnergyPanel\": true, \"sceneActivation\": 0, \"serialNumber\": \"h'0000000000006c3a\", \"showEnergy\": true, \"smsNotificationID\": 0, \"smsNotificationType\": 0, \"state\": false, \"storeEnergyData\": true, \"supportedDeviceRoles\": [ \"Light\" ], \"useTemplate\": true, \"userDescription\": \"\", \"value\": 0 }, \"actions\": { \"reconfigure\": 0, \"reset\": 0, \"sceneActivationSet\": 0, \"setValue\": 1, \"startLevelDecrease\": 0, \"startLevelIncrease\": 0, \"stopLevelChange\": 0, \"toggle\": 0, \"turnOff\": 0, \"turnOn\": 0 }, \"created\": 1650490691, \"modified\": 1663354248, \"sortOrder\": 17 }"
                )
            ) 
        }
    end

    return fibaroDevices
end

function QuickApp:identifyDevices(fibaroDevices) 
    for _, fibaroDevice in ipairs(fibaroDevices) do
        local device = identifyDevice(fibaroDevice)
        if (device) then
            self:debug("Device " .. self:getDeviceDescription(device) .. " identified as " .. device.bridgeType .. "-" .. device.bridgeSubtype)
            self.devices[device.id] = device

            -- ***** ToDo: move to identifyDevice function, aiming support deviceRemoved and deviceModified and deviceCreated events

            -- Does device support energy monitoring? Create a dedicated sensor for Home Assistant
            if (table_contains_value(fibaroDevice.interfaces, "energy")) then 
                local energyDevice = self:createLinkedSensorDevice(device, "energy")
                self.devices[energyDevice.id] = energyDevice
            end

            -- Does device support power monitoring? Create a dedicated sensor for Home Assistant
            if (table_contains_value(fibaroDevice.interfaces, "power")) then 
                local powerDevice = self:createLinkedSensorDevice(device, "power")
                self.devices[powerDevice.id] = powerDevice
            end

            -- Battery powered device? Create a dedicated battery sensor for Home Assistant
            if (table_contains_value(fibaroDevice.interfaces, "battery")) then 
                local batteryLevelSensorDevice = self:createLinkedSensorDevice(device, "batteryLevel")
                self.devices[batteryLevelSensorDevice.id] = batteryLevelSensorDevice
            end


            -- Is it a "Remote Control" device? Created dedicated devices for each combination of Button and Press Type
            if (device.bridgeType == RemoteController.bridgeType and device.bridgeSubtype == RemoteController.bridgeSubtype) then
                if device.properties.centralSceneSupport then
                    for _, i in ipairs(device.properties.centralSceneSupport) do
                        for _, j in ipairs(i.keyAttributes) do
                            local keyDevice = self:createLinkedKey(device, i.keyId, j)
                            self.devices[keyDevice.id] = keyDevice 
                        end
                    end
                end
            end
        else
            self:debug("Couldn't recognize device #" .. fibaroDevice.id .. " - " .. fibaroDevice.name .. " - " .. fibaroDevice.baseType .. " - " .. fibaroDevice.type)
        end
    end
end

function QuickApp:createLinkedDevice(fromDevice, linkedProperty, linkedUnit)
    local newFibaroLinkedDevice = {
        id = fromDevice.id .. "_" .. linkedProperty,
        name = fromDevice.name,  
        roomID = fromDevice.roomID,
        roomName = fromDevice.roomName,
        parentId = fromDevice.parentId,
        linkedDevice = fromDevice,
        linkedProperty = linkedProperty,
        properties = {
            unit = linkedUnit
        },
        comment = "This device has been autogenerated by HC3 <-> Home Assistant bridge to adjust the data model difference between Fibaro HC3 and Home Assistant. Fibaro considers this device and the '" .. linkedProperty .. "' meter to be the single entity. And Home Asisstant requires these to be separate devices"
    }

    return newFibaroLinkedDevice
end

function QuickApp:createLinkedSensorDevice(fromDevice, linkedProperty)
    local linkedUnit
    if (linkedProperty == "energy") then
        linkedUnit = "kWh"
        -- lastReset = "1970-01-03T00:00:00+00:00"
    elseif (linkedProperty == "power") then
        linkedUnit = "W"
    end

    local newFibaroLinkedSensor = self:createLinkedDevice(fromDevice, linkedProperty, linkedUnit)
    newFibaroLinkedSensor.baseType = "com.fibaro.multilevelSensor"
    newFibaroLinkedSensor.type = "com.fibaro." .. linkedProperty .. "Sensor"

    local newLinkedSensor = identifyDevice(newFibaroLinkedSensor)
    newLinkedSensor.fibaroDevice.linkedDevice = nil

    return newLinkedSensor
end

function QuickApp:createLinkedKey(fromDevice, keyId, keyAttribute)
    local keyAttribute = string.lower(keyAttribute)

    local action = keyId .. "-" .. keyAttribute

    local newFibaroKey = self:createLinkedDevice(fromDevice, "value", nil)
    newFibaroKey.baseType = "com.alexander_vitishchenko.remoteKey"
    newFibaroKey.keyId = keyId
    newFibaroKey.keyAttribute = keyAttribute

    local newHaKey = identifyDevice(newFibaroKey)
    newHaKey.fibaroDevice.linkedDevice = nil
    
    return newHaKey
end


function QuickApp:publishDeviceToMqtt(device)
    ------------------------------------------------------------------
    ------- ANNOUNCE DEVICE EXISTANCE
    ------------------------------------------------------------------
    for i, j in ipairs(self.mqttConventions) do
        j:onDeviceCreated(device)
    end

    ------------------------------------------------------------------
    ------- ANNOUNCE DEVICE CURRENT STATE => BY SIMULATING HC3 EVENTS
    ------------------------------------------------------------------
    self:simulatePropertyUpdate(device, "dead", device.properties.dead)
    self:simulatePropertyUpdate(device, "state", device.properties.state)
    self:simulatePropertyUpdate(device, "value", device.properties.value)
    self:simulatePropertyUpdate(device, "heatingThermostatSetpoint", device.properties.heatingThermostatSetpoint)
    self:simulatePropertyUpdate(device, "thermostatMode", device.properties.thermostatMode)
    self:simulatePropertyUpdate(device, "energy", device.properties.energy)
    self:simulatePropertyUpdate(device, "power", device.properties.power)
    self:simulatePropertyUpdate(device, "batteryLevel", device.properties.batteryLevel)
    self:simulatePropertyUpdate(device, "color", device.properties.color)
end

function QuickApp:onPublished(event)
    -- do nothing, for now
end

-- FETCH HC3 EVENTS
local lastRefresh = 0
local http = net.HTTPClient()

function QuickApp:scheduleHc3EventsFetcher()
    self:readHc3EventAndScheduleFetcher()

    self:debug("")
    self:debug("---------------------------------------------------")
    self:debug("Started monitoring events from Fibaro Home Center 3")
    self:debug("---------------------------------------------------")
end

function QuickApp:readHc3EventAndScheduleFetcher()
    -- This a reliable and high-performance method to get events from Fibaro HC3, by using non-blocking HTTP calls. Where 'passwordles' api.get() has a risk of blocking calls => peformance isues

    local requestUrl = "http://127.0.0.1:11111/api/refreshStates?last=" .. lastRefresh
    --self:debug("Fetch events from " .. requestUrl .. " | " .. tostring(self.hc3ConnectionEnabled))

    local stat, res = http:request(
        requestUrl,
        {
        options = { },
        success=function(res)
            local data
            if (res and not isEmptyString(res.data)) then
                self:processFibaroHc3Events(json.decode(res.data))
            else
                self:error("Error while fetching events from Fibaro HC3. Response status code is " .. res.status .. ". HTTP response body is '" .. json.encode(res) .. "'")
                self:turnOff()
            end
        end,
        error=function(res) 
            self:error("Error while fetching Fibaro HC3 events " .. json.encode(res))
            self:turnOff()
        end
    })

    if (self.hc3ConnectionEnabled) then
        local delay
        if self.gotError then
            self:warning("Got error - retry in 1s")
            delay = 1000
        else
            delay = 1000
        end

        fibaro.setTimeout(delay, function()
            self:readHc3EventAndScheduleFetcher()
        end)
    else
        self:debug("Disconnected from HC3 (got flagged to stop reading HC3 events)")
    end

end

function QuickApp:processFibaroHc3Events(data)
    -- Debug for "paswordless" mode. Doesn't work well for now due to blocking api-calls. Significantly reducing performance

    if not self.hc3ConnectionEnabled then
        return
    end

    self.gotError = false
    if (data.status ~= 200 and data.status ~= "IDLE") then
        self:warning("Unexpected response status " .. tostring(data.status))
        -- Disable automated turnOff after unexpected response status
        -- Make QuickApp less sensetive, so QuickApp doesn't get shutdown when it is possible to continue its operation
        -- self:turnOff()
    end

    local events = data.events

    if (data.last) then
        lastRefresh = data.last
    end

    if events and #events>0 then 
        for i, v in ipairs(events) do
            self:dispatchFibaroEventToMqtt(v)
        end
    end
end

function QuickApp:simulatePropertyUpdate(device, propertyName, value)
    if value ~= nil then
        local event = createFibaroEventPayload(device, propertyName, value)
        event.simulation = true
        self:dispatchFibaroEventToMqtt(event)
    end
end

function QuickApp:dispatchFibaroEventToMqtt(event)
    --self:debug("Event: " .. json.encode(event))
    if (not event) then
        self:error("No event found")
        return
    end

    if (not event.data) then
        self:error("No event data found")
        return
    end

    local deviceId = event.data.id or event.data.deviceId

    if not deviceId then
        -- This is a system level event, which is not bound to a particular device => ignore
        -- self:trace("Unsupported system event (feel free to reach out to QuickApp developer if you need it): " .. json.encode(event))
        return
    end 

    if (not event.type) then
        event.type = "unknown"
    end

    local device = self.devices[deviceId]

    if (device) then
        if (event.type == "DevicePropertyUpdatedEvent") then
            self:dispatchDevicePropertyUpdatedEvent(device, event) 
        elseif (event.type == "CentralSceneEvent") then
            -- fabricate property updated event, instead of "CentralSceneEvent", so we reuse the existing value dispatch mechanism rather than reinventing a wheel
            local keyValueMapAsString = event.data.keyId .. "," .. string.lower(event.data.keyAttribute)
            self:trace("Action => " .. event.data.keyId .. "-" .. string.lower(event.data.keyAttribute))
            self:simulatePropertyUpdate(device, "value", keyValueMapAsString)
        elseif (event.type == "DeviceModifiedEvent") then
            self:dispatchDeviceModifiedEvent(device)
        elseif (event.type == "DeviceCreatedEvent") then
            self:dispatchDeviceCreatedEvent(device)
        elseif (event.type == "DeviceRemovedEvent") then 
            self:dispatchDeviceRemovedEvent(device)
        elseif (event.type == "DeviceActionRanEvent") then
        else
            local eventType = tostring(event.type)
            if (eventType == "PluginChangedViewEvent") then
                -- exclude the event type from Debug view, as it's not intended for translation to Home Assistant world, and thus no need to confuse QuickApp users
            else
                self:debug("Unsupported event type \"" .. eventType .. "\" for \"" .. self:getDeviceDescription(device) .. "\". All is good - feel free raise a request, and it could be possibly implemented in a future - https://github.com/alexander-vitishchenko/hc3-to-mqtt/issues/new")
                self:debug(json.encode(event))
            end
        end

    end
end

function QuickApp:dispatchDevicePropertyUpdatedEvent(device, event)
    -- *** OVERRIDE FIBARO PROPERTY NAMES, FOR BEING MORE CONSISTENT AND THUS EASIER TO HANDLE 
    local propertyName = event.data.property
    if not propertyName then
        propertyName = "unknown"
    end

    if (device.bridgeType == "binary_sensor") and (propertyName == "value") then
        -- Fibaro uses state/value fields inconsistently for binary sensor. Replace value --> state field
        event.data.property = "state"
    end

    local value = event.data.newValue
    if (isNumber(value)) then
        value = round(value, 2)
    end

    event.data.newValue = (type(value) == "number" and value or tostring(value))
    
    for i, j in ipairs(self.mqttConventions) do
        j:onPropertyUpdated(device, event)
    end
end

function QuickApp:rememberLastMqttCommandTime(deviceId)
    self.lastMqttCommandTime[deviceId] = os.time()
end

function QuickApp:dispatchDeviceCreatedEvent(device)
    local fibaroDevice = getFibaroDeviceById(device.id)

    if (fibaroDevice.visible and fibaroDevice.enabled) then
        self:debug("New device configuration " .. json.encode(fibaroDevice))
        self:identifyAndPublishDeviceToMqtt(fibaroDevice)
    end
end

function QuickApp:dispatchDeviceModifiedEvent(device)
    self:debug("Device modified " .. device.id)

    self:dispatchDeviceRemovedEvent(device)

    self:dispatchDeviceCreatedEvent(device)
end

function QuickApp:dispatchDeviceRemovedEvent(device)
    self:debug("Device removed " .. device.id)
    for i, j in ipairs(self.mqttConventions) do
        j:onDeviceRemoved(device)
    end
    --self:removeDeviceFromMqtt(device)
end

function QuickApp:getDeviceDescription(device)
    if device and device.name and device.id and device.roomName then
        return device.name .. " #" .. device.id .. " (" .. tostring(device.roomName) .. ")"
    else
        if device.id then
            return device.id
        else
            return "<unknown device>"
        end
    end
end
