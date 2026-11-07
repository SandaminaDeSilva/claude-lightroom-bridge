-- Command handlers for the Claude Editor Bridge.
-- Every handler runs inside an LrTasks async task, so it may yield.

local LrApplication   = import 'LrApplication'
local LrExportSession = import 'LrExportSession'
local LrFileUtils     = import 'LrFileUtils'
local LrPathUtils     = import 'LrPathUtils'
local LrTasks         = import 'LrTasks'

local Commands = {}

local PLUGIN_VERSION = '1.1.0'

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function catalog()
  return LrApplication.activeCatalog()
end

local function getPhoto(id)
  local n = tonumber(id)
  if not n then error('photo_id must be a number, got ' .. tostring(id)) end
  local photo = catalog():getPhotoByLocalId(n)
  if not photo then error('No photo with id ' .. tostring(id) .. ' in this catalog') end
  return photo
end

local function getPhotos(ids)
  if type(ids) ~= 'table' then ids = { ids } end
  local photos = {}
  for _, id in ipairs(ids) do photos[#photos + 1] = getPhoto(id) end
  if #photos == 0 then error('No photo ids given') end
  return photos
end

local function safeRaw(photo, key)
  local ok, v = LrTasks.pcall(function() return photo:getRawMetadata(key) end)
  if ok then return v end
  return nil
end

local function safeFormatted(photo, key)
  local ok, v = LrTasks.pcall(function() return photo:getFormattedMetadata(key) end)
  if ok and v ~= '' then return v end
  return nil
end

local function describe(photo)
  return {
    id            = photo.localIdentifier,
    fileName      = safeFormatted(photo, 'fileName'),
    copyName      = safeFormatted(photo, 'copyName'),
    folder        = safeFormatted(photo, 'folderName'),
    path          = safeRaw(photo, 'path'),
    isVirtualCopy = safeRaw(photo, 'isVirtualCopy'),
    fileFormat    = safeRaw(photo, 'fileFormat'),
    rating        = safeRaw(photo, 'rating'),
    pickStatus    = safeRaw(photo, 'pickStatus'),
    captureTime   = safeFormatted(photo, 'dateTimeOriginal'),
    dimensions    = safeFormatted(photo, 'croppedDimensions'),
    camera        = safeFormatted(photo, 'cameraModel'),
    lens          = safeFormatted(photo, 'lens'),
    iso           = safeFormatted(photo, 'isoSpeedRating'),
    shutter       = safeFormatted(photo, 'exposure'),
    aperture      = safeFormatted(photo, 'aperture'),
    focalLength   = safeFormatted(photo, 'focalLength'),
  }
end

local function pick(tbl, keys)
  if type(keys) ~= 'table' or #keys == 0 then return tbl end
  local out = {}
  for _, k in ipairs(keys) do out[k] = tbl[k] end
  return out
end

-------------------------------------------------------------------------------
-- Handlers
-------------------------------------------------------------------------------

local handlers = {}

function handlers.ping(params, ctx)
  return {
    pong = true,
    pluginVersion = PLUGIN_VERSION,
    catalog = catalog():getPath(),
  }
end

-- params.scope: 'selected' (default) = selected photos, or every photo in the
-- filmstrip when nothing is selected; 'active' = only the most-selected photo.
function handlers.list_photos(params, ctx)
  local cat = catalog()
  local scope = params.scope or 'selected'
  local photos
  if scope == 'active' then
    local p = cat:getTargetPhoto()
    photos = p and { p } or {}
  else
    photos = cat:getTargetPhotos() or {}
  end
  local limit = tonumber(params.limit) or 100
  local out = {}
  for i, photo in ipairs(photos) do
    if i > limit then break end
    out[#out + 1] = describe(photo)
  end
  return { count = #photos, returned = #out, photos = out }
end

-- Photos in a catalog folder, matched by folder name or full path.
-- params: folder (required), offset (default 0), limit (default 50),
--         include_subfolders (default false), sort ('capture' | 'name')
function handlers.list_folder(params, ctx)
  local wanted = tostring(params.folder or '')
  if wanted == '' then error('folder is required') end
  local lw = wanted:lower()
  local matches, names = {}, {}
  local function walk(folders)
    for _, f in ipairs(folders or {}) do
      local name, path = f:getName(), f:getPath()
      names[#names + 1] = name
      if name:lower() == lw or path:lower() == lw then matches[#matches + 1] = f end
      walk(f:getChildren())
    end
  end
  walk(catalog():getFolders())
  if #matches == 0 then
    -- fall back to partial name match
    local function walk2(folders)
      for _, f in ipairs(folders or {}) do
        if f:getName():lower():find(lw, 1, true) then matches[#matches + 1] = f end
        walk2(f:getChildren())
      end
    end
    walk2(catalog():getFolders())
  end
  if #matches == 0 then
    error('No folder matching "' .. wanted .. '". Folders: ' .. table.concat(names, ', '))
  end
  local folder = matches[1]
  local photos = folder:getPhotos(params.include_subfolders and true or false) or {}

  local keys = {}
  for _, p in ipairs(photos) do
    local t = safeRaw(p, 'dateTimeOriginal') or safeRaw(p, 'dateTime') or 0
    keys[p] = { t = tonumber(t) or 0, n = safeFormatted(p, 'fileName') or '' }
  end
  local byName = params.sort == 'name'
  table.sort(photos, function(a, b)
    local ka, kb = keys[a], keys[b]
    if not byName and ka.t ~= kb.t then return ka.t < kb.t end
    return ka.n < kb.n
  end)

  local offset = tonumber(params.offset) or 0
  local limit = tonumber(params.limit) or 50
  local out = {}
  for i = offset + 1, math.min(#photos, offset + limit) do
    out[#out + 1] = describe(photos[i])
  end
  return { folder = folder:getPath(), count = #photos, offset = offset, returned = #out,
           other_matches = #matches - 1, photos = out }
end

function handlers.get_photo_info(params, ctx)
  return describe(getPhoto(params.photo_id))
end

function handlers.get_settings(params, ctx)
  local photo = getPhoto(params.photo_id)
  local settings = photo:getDevelopSettings()
  return { photo_id = photo.localIdentifier, settings = pick(settings, params.keys) }
end

function handlers.apply_settings(params, ctx)
  local photos = getPhotos(params.photo_ids or params.photo_id)
  local settings = params.settings
  if type(settings) ~= 'table' then error('settings must be an object') end
  local historyName = params.history_name or 'Claude edit'

  local status = catalog():withWriteAccessDo('Claude: ' .. historyName, function()
    for _, photo in ipairs(photos) do
      photo:applyDevelopSettings(settings, historyName)
    end
  end, { timeout = 30 })

  local keys = {}
  for k in pairs(settings) do keys[#keys + 1] = k end
  local results = {}
  for _, photo in ipairs(photos) do
    results[#results + 1] = {
      photo_id = photo.localIdentifier,
      now = pick(photo:getDevelopSettings(), keys),
    }
  end
  return { status = status, applied = results }
end

function handlers.create_snapshot(params, ctx)
  local photo = getPhoto(params.photo_id)
  local name = params.name or ('Claude ' .. os.date('%Y-%m-%d %H:%M:%S'))
  local ok, err = LrTasks.pcall(function()
    catalog():withWriteAccessDo('Claude: snapshot', function()
      photo:createDevelopSnapshot(name, true)
    end, { timeout = 30 })
  end)
  if not ok then
    error('Could not create snapshot (needs Lightroom Classic 9.x or newer): ' .. tostring(err))
  end
  return { photo_id = photo.localIdentifier, snapshot = name }
end

function handlers.select_photo(params, ctx)
  local photos = getPhotos(params.photo_ids or params.photo_id)
  catalog():setSelectedPhotos(photos[1], photos)
  return { selected = #photos }
end

-- Renders a JPEG of the photo with its current develop settings.
function handlers.export_preview(params, ctx)
  local photo = getPhoto(params.photo_id)
  local size = tonumber(params.size) or 1600
  local quality = tonumber(params.quality) or 0.85

  local renderDir = LrPathUtils.child(ctx.previewDir, 'render_' .. ctx.requestId)
  LrFileUtils.createAllDirectories(renderDir)

  local exportSettings = {
    LR_export_destinationType       = 'specificFolder',
    LR_export_destinationPathPrefix = renderDir,
    LR_export_useSubfolder          = false,
    LR_collisionHandling            = 'overwrite',
    LR_renamingTokensOn             = false,
    LR_format                       = 'JPEG',
    LR_jpeg_quality                 = quality,
    LR_export_colorSpace            = 'sRGB',
    LR_export_bitDepth              = 8,
    LR_size_doConstrain             = true,
    LR_size_doNotEnlarge            = true,
    LR_size_resizeType              = 'wh',
    LR_size_maxWidth                = size,
    LR_size_maxHeight               = size,
    LR_size_units                   = 'pixels',
    LR_size_resolution              = 72,
    LR_outputSharpeningOn           = false,
    LR_minimizeEmbeddedMetadata     = true,
    LR_removeLocationMetadata       = true,
    LR_useWatermark                 = false,
    LR_reimportExportedPhoto        = false,
    LR_includeVideoFiles            = false,
  }

  local session = LrExportSession {
    photosToExport = { photo },
    exportSettings = exportSettings,
  }
  session:doExportOnCurrentTask()

  local renderedPath, failure
  for _, rendition in session:renditions() do
    local success, pathOrMessage = rendition:waitForRender()
    if success then renderedPath = pathOrMessage else failure = pathOrMessage end
  end
  if not renderedPath then
    error('Preview render failed: ' .. tostring(failure))
  end

  local finalPath = LrPathUtils.child(ctx.previewDir, ctx.requestId .. '.jpg')
  if LrFileUtils.exists(finalPath) then LrFileUtils.delete(finalPath) end
  LrTasks.pcall(LrFileUtils.move, renderedPath, finalPath)
  local moved = LrFileUtils.exists(finalPath) and not LrFileUtils.exists(renderedPath)
  if moved then
    LrFileUtils.delete(renderDir)
  else
    finalPath = renderedPath
  end

  return { photo_id = photo.localIdentifier, path = finalPath }
end

-------------------------------------------------------------------------------

function Commands.dispatch(command, params, ctx)
  local handler = handlers[command]
  if not handler then error('Unknown command: ' .. tostring(command)) end
  return handler(params or {}, ctx)
end

Commands.PLUGIN_VERSION = PLUGIN_VERSION

return Commands
