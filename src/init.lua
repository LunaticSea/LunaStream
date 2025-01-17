require('./utils/luaex')

local setInterval = require('timer').setInterval
local clearInterval = require('timer').clearInterval
local weblit = require('weblit')
local json = require('json')
local class = require('class')

local config = require('./utils/config')
local source = require("./sources")
local generateSessionId = require('./utils/generatesessionid')

local LunaStream, get = class('LunaStream')

local function requireRoute(target, req, res, luna)
  local answer = function (body, code, headers)
    res.body = body
    res.code = code
    for key, value in pairs(headers) do
      res.headers[key] = value
    end
  end
  require(target)(req, res, answer, luna)
end

function LunaStream:__init(devmode)
  self._initialRunTime = os.time()
  self._devmode = devmode
  self._manifest = require('./utils/manifest.lua')(devmode)
  self:printInitialInfo()
  self._config = config
  self._app = weblit.app
  self._prefix = "/v" .. self._manifest.version.major
  self._sessions = {}
  self._logger = require('./utils/logger')(5,
    '!%Y-%m-%dT%TZ',
    config.logger.logToFile and 'lunatic.sea.log' or '',
  14)
  self._sources = source(self)
  self._services = {
    statusMonitor =  require('./services/statusMonitor')(self)
  }
end

function get:sources()
  return self._sources
end

function get:config()
  return self._config
end

function get:logger()
  return self._logger
end

function get:manifest()
  return self._manifest
end

function get:services()
  return self._services
end

function LunaStream:printInitialInfo()
  local table_data = {
    self._manifest.version.semver,
    self._manifest.buildTime,
    os.date('%F %T', self._manifest.buildTime),
    self._manifest.git.branch,
    self._manifest.git.commit,
    os.date('%F %T', tonumber(self._manifest.git.commitTime)),
    self._manifest.runtime.luvit,
    self._manifest.runtime.luvi,
    self._manifest.runtime.libuv,
  }
  local template = string.format([[
                                                               __________________
 _                      ____  _                               / ______________  /
| |   _   _ _ __   __ _/ ___|| |_ _ __ ___  __ _ _ __ ___    / /   _/\__     / /
| |  | | | | '_ \ / _` \___ \| __| '__/ _ \/ _` | '_ ` _ \  / /   \    /    / / 
| |__| |_| | | | | (_| |___) | |_| | |  __/ (_| | | | | | |/ /    /_  _\   / /  
|_____\__,_|_| |_|\__,_|____/ \__|_|  \___|\__,_|_| |_| |_/ /_______\/____/ /
=========================================================/_________________/

    - Version:          %s
    - Build:            %s
    - Build time:       %s
    - Branch:           %s
    - Commit:           %s
    - Commit time:      %s
    - Luvit:            %s
    - Luvi:             %s
    - Libuv:            %s
]], table.unpack(table_data))

  print(template)
end

function LunaStream:setupAddon()
  -- Load custom addons
  local addons_list = {
    "./addon/auth.lua",
    "./addon/req_logger.lua",
  }

  for _, path in pairs(addons_list) do
    self._app.use(function (req, res, go)
      require(path)(req, res, go, self)
    end)
  end

  -- Load third party addons
  self._app.use(weblit.autoHeaders)
  self._logger:info('LunaStream', 'All addons are ready!')
end

function LunaStream:setupRoutes()
  local route_list = {
    ["./router/version.lua"] = { path = "/version" },
    ["./router/info.lua"] = { path = self._prefix .. "/info" },
    ["./router/stats.lua"] = { path = self._prefix .. "/stats" },
    ["./router/encodetrack.lua"] = { path = self._prefix .. "/encodetrack", method = "POST" },
    ["./router/decodetrack.lua"] = { path = self._prefix .. "/decodetrack" },
    ["./router/trackstream.lua"] = { path = self._prefix .. "/trackstream" },
    ["./router/loadtracks.lua"] = { path = self._prefix .. "/loadtracks" },
    ["./router/sessions.lua"] = { path = self._prefix .. "/sessions/:sessionId/players/:guildId?" }
  }

  local processed_routes = {}
  for key, value in pairs(route_list) do
    local path = value.path
    local optional_param = path:match(":(%w+)%?")

    if optional_param then
      local required_path = path:gsub(":%w+%?", ":%1"):gsub("::", ":"):gsub("%?$", "")
      table.insert(processed_routes, { file = key, path = required_path, method = value.method })

      local optional_path = path:gsub("/:?" .. optional_param .. "%?", ""):gsub("::", ":"):gsub("%?$", "")
      table.insert(processed_routes, { file = key, path = optional_path, method = value.method })
    else
      table.insert(processed_routes, { file = key, path = path, method = value.method })
    end
  end

  for _, route in ipairs(processed_routes) do
    self._app.route({ path = route.path, method = route.method }, function (req, res)
      requireRoute(route.file, req, res, self)
    end)
  end

  self._logger:info('LunaStream', 'All routes are ready!')
end

function LunaStream:setupWebsocket()
  self._app.websocket({
    path = self._prefix .. "/websocket",
  }, function (req, read, write)
    -- Register some infomation
    local user_id = req.headers['User-Id']
    local client_name = req.headers['Client-Name']
    local session_id = generateSessionId(16)
    self._sessions[session_id] = { write = write, user_id = user_id, players = {}, interval = nil }

    -- Write session id
    write({
      opcode = 1,
      payload = string.format('{"op": "ready", "resumed": false, "sessionId": "%s"}', session_id)
    })

    -- Write current status
    local currentStats = self._services.statusMonitor:get()
    currentStats.op = "stats"
    write({ opcode = 1, payload = json.encode(currentStats) })

    -- Success logger
    self._logger:info('WebSocket', 'Connection established with %s', client_name)

    -- Setup status monitor
    self._sessions[session_id].interval = setInterval(60000, function ()
      coroutine.wrap(function ()
        local currentStatsCoro = self._services.statusMonitor:get()
        currentStatsCoro.op = "stats"
        write({ opcode = 1, payload = json.encode(currentStatsCoro) })
      end)()
    end)

    -- Keep connection
    for message in read do end

    -- End stream
    write()

    -- When disconnected
    clearInterval(self._sessions[session_id].interval)
    self._sessions[session_id] = nil
    self._logger:info('WebSocket', 'Connection closed with %s', client_name)
  end)
  self._logger:info('LunaStream', 'Websocket is ready!')
end

function LunaStream:start()
  self._app.bind({
    host = config.server.host,
    port = config.server.port
  })
  self._app.start()
  self._logger:info('LunaStream',
    'Currently running server [%s] at port: %s',
    config.server.host,
    config.server.port
  )
end

return LunaStream
