-- File-queue bridge between Lightroom Classic and the Claude MCP server.
--
-- The Python server drops request files into   ~/.claude-lightroom-bridge/requests/<id>.json
-- This loop picks them up, runs the command, and writes   .../responses/<id>.json
-- Previews are rendered into                   .../previews/
-- A heartbeat file tells the server Lightroom is alive.

local LrDate            = import 'LrDate'
local LrFileUtils       = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrLogger          = import 'LrLogger'
local LrPathUtils       = import 'LrPathUtils'
local LrTasks           = import 'LrTasks'

local json     = require 'json'
local Commands = require 'Commands'

local logger = LrLogger('ClaudeEditor')
logger:enable('logfile') -- Documents\LrClassicLogs\ClaudeEditor.log

local Bridge = {}

local POLL_SECONDS = 0.2
local HEARTBEAT_SECONDS = 2

local function paths()
  local home = LrPathUtils.getStandardFilePath('home')
  local root = LrPathUtils.child(home, '.claude-lightroom-bridge')
  return {
    root      = root,
    requests  = LrPathUtils.child(root, 'requests'),
    responses = LrPathUtils.child(root, 'responses'),
    previews  = LrPathUtils.child(root, 'previews'),
    owner     = LrPathUtils.child(root, 'owner.txt'),
    heartbeat = LrPathUtils.child(root, 'heartbeat.json'),
  }
end

Bridge.paths = paths

local function readFile(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  return data
end

-- LrFileUtils.move's return value isn't reliable across versions, so check the result on disk.
local function moveFile(src, dst)
  LrTasks.pcall(LrFileUtils.move, src, dst)
  return LrFileUtils.exists(dst) and not LrFileUtils.exists(src)
end
Bridge.moveFile = moveFile

local function writeFileAtomic(path, data)
  local tmp = path .. '.tmp'
  local f = assert(io.open(tmp, 'wb'))
  f:write(data)
  f:close()
  if LrFileUtils.exists(path) then LrFileUtils.delete(path) end
  if not moveFile(tmp, path) then
    -- fall back to direct write
    local g = assert(io.open(path, 'wb'))
    g:write(data)
    g:close()
    LrFileUtils.delete(tmp)
  end
end

local function sanitizeId(id)
  id = tostring(id or '')
  id = id:gsub('[^%w%-_]', '')
  if id == '' then id = 'unknown' end
  return id
end

local stats = { handled = 0, lastError = nil, lastCommand = nil, startedAt = nil }

local function handleRequestFile(p, path)
  -- Claim the file first so a second loop can never process it twice.
  local working = path .. '.working'
  if not moveFile(path, working) then return end

  local raw = readFile(working)
  LrFileUtils.delete(working)

  local stem = LrPathUtils.removeExtension(LrPathUtils.leafName(path))
  local okDecode, req = LrTasks.pcall(json.decode, raw or '')
  local id = sanitizeId(okDecode and type(req) == 'table' and req.id or stem)

  local response
  if not okDecode or type(req) ~= 'table' then
    response = { id = id, ok = false, error = 'Bad request JSON: ' .. tostring(req) }
  else
    stats.lastCommand = req.command
    local ctx = { requestId = id, previewDir = p.previews }
    local ok, result = LrTasks.pcall(Commands.dispatch, req.command, req.params, ctx)
    if ok then
      response = { id = id, ok = true, result = result }
    else
      stats.lastError = tostring(result)
      logger:error('Command ' .. tostring(req.command) .. ' failed: ' .. tostring(result))
      response = { id = id, ok = false, error = tostring(result) }
    end
  end

  stats.handled = stats.handled + 1
  writeFileAtomic(LrPathUtils.child(p.responses, id .. '.json'), json.encode(response))
end

local function pollOnce(p)
  local pending = {}
  for file in LrFileUtils.files(p.requests) do
    if file:sub(-5) == '.json' then pending[#pending + 1] = file end
  end
  table.sort(pending)
  for _, file in ipairs(pending) do
    handleRequestFile(p, file)
  end
end

local function writeHeartbeat(p, token)
  local beat = {
    time          = os.time(),
    token         = token,
    pluginVersion = Commands.PLUGIN_VERSION,
    handled       = stats.handled,
    lastCommand   = stats.lastCommand,
    lastError     = stats.lastError,
    startedAt     = stats.startedAt,
  }
  writeFileAtomic(p.heartbeat, json.encode(beat))
end

local function newToken()
  local t = string.format('%.6f', LrDate.currentTime()):gsub('%.', '-')
  return t
end

-- Starts a new loop. Any older loop sees the owner token change and exits.
function Bridge.start()
  local p = paths()
  LrFileUtils.createAllDirectories(p.requests)
  LrFileUtils.createAllDirectories(p.responses)
  LrFileUtils.createAllDirectories(p.previews)

  local token = newToken()
  writeFileAtomic(p.owner, token)
  stats.startedAt = os.time()
  logger:info('Claude bridge starting, token ' .. token)

  LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('ClaudeBridgeLoop', function(context)
      local lastBeat = 0
      while true do
        local owner = readFile(p.owner)
        if owner ~= token then
          logger:info('Claude bridge loop ' .. token .. ' stopping')
          break
        end
        local ok, err = LrTasks.pcall(pollOnce, p)
        if not ok then
          stats.lastError = tostring(err)
          logger:error('Poll error: ' .. tostring(err))
        end
        if os.time() - lastBeat >= HEARTBEAT_SECONDS then
          LrTasks.pcall(writeHeartbeat, p, token)
          lastBeat = os.time()
        end
        LrTasks.sleep(POLL_SECONDS)
      end
    end)
  end)
  return token
end

function Bridge.stop()
  local p = paths()
  LrFileUtils.createAllDirectories(p.root)
  writeFileAtomic(p.owner, 'stopped')
end

function Bridge.status()
  local p = paths()
  local raw = readFile(p.heartbeat)
  local beat = nil
  if raw then
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == 'table' then beat = decoded end
  end
  local owner = readFile(p.owner) or '(none)'
  return beat, owner, p
end

return Bridge
