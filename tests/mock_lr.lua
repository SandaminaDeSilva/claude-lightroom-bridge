-- Mock of the Lightroom SDK, enough to run the bridge plugin outside Lightroom.
local py = PY  -- python helpers injected from the harness
local M = {}
local tasks = {}
M.tasks = tasks

M.LrTasks = {
  pcall = pcall,
  sleep = function(s) coroutine.yield() end,
  startAsyncTask = function(f) tasks[#tasks + 1] = coroutine.create(f) end,
}
M.LrFileUtils = {
  exists = function(p) return py.exists(p) end,
  delete = function(p) return py.delete(p) end,
  move = function(a, b) return py.move(a, b) end,
  createAllDirectories = function(p) return py.mkdirs(p) end,
  files = function(p)
    local list = py.listfiles(p)
    local i = 0
    return function() i = i + 1; return list[i] end
  end,
}
M.LrPathUtils = {
  child = function(a, b) return a .. '/' .. b end,
  leafName = function(p) return p:match('([^/]+)$') end,
  removeExtension = function(p) return (p:gsub('%.[^.]*$', '')) end,
  getStandardFilePath = function(k) return HOME end,
}
M.LrDate = { currentTime = function() return py.now() end }
M.LrLogger = function() return { enable = function() end, info = function(_, m) end, error = function(_, m) print('LOG ERROR', m) end } end
M.LrFunctionContext = { callWithContext = function(name, f) return f({}) end }
M.LrDialogs = { showBezel = function() end, message = function() end }

-- Catalog with two photos
local function makePhoto(id, name, fmt)
  local settings = { Exposure2012 = 0, Contrast2012 = 0, Highlights2012 = 0, Temperature = 5200, Tint = 3,
    ToneCurvePV2012 = { 0, 0, 255, 255 }, ProcessVersion = '11.0', CameraProfile = 'Adobe Color' }
  local photo = { localIdentifier = id, _settings = settings, _snapshots = {} }
  local raw = { path = 'C:/Photos/' .. name, isVirtualCopy = false, fileFormat = fmt, rating = 3, pickStatus = 0 }
  local fmtd = { fileName = name, folderName = 'Shoot', cameraModel = 'ILCE-7M3', isoSpeedRating = '400',
    exposure = '1/250 sec', aperture = 'f / 2.8', focalLength = '35 mm', dateTimeOriginal = '2026-11-01 10:00' }
  function photo:getRawMetadata(k) return raw[k] end
  function photo:getFormattedMetadata(k)
    if k == 'bogusKey' then error('bad key') end
    return fmtd[k] or ''
  end
  function photo:getDevelopSettings()
    local copy = {}
    for k, v in pairs(self._settings) do copy[k] = v end
    return copy
  end
  function photo:applyDevelopSettings(s, hist)
    assert(M.inWrite, 'applyDevelopSettings outside write access')
    for k, v in pairs(s) do self._settings[k] = v end
  end
  function photo:createDevelopSnapshot(n, upd)
    assert(M.inWrite); self._snapshots[#self._snapshots + 1] = n
  end
  return photo
end
local photos = { makePhoto(101, 'DSC0001.ARW', 'RAW'), makePhoto(102, 'IMG_2.JPG', 'JPG') }
M.photos = photos
local catalog = {}
function catalog:getPhotoByLocalId(id) for _, p in ipairs(photos) do if p.localIdentifier == id then return p end end end
function catalog:getTargetPhotos() return photos end
function catalog:getTargetPhoto() return photos[1] end
function catalog:getPath() return 'C:/Lightroom/Test.lrcat' end
function catalog:setSelectedPhotos(a, list) M.selected = #list end
function catalog:withWriteAccessDo(name, f, t) M.inWrite = true; f(); M.inWrite = false; return 'executed' end
local folder = { _photos = photos }
function folder:getName() return 'Sample Trip 2026' end
function folder:getPath() return 'D:/Sample Trip 2026' end
function folder:getChildren() return {} end
function folder:getPhotos(inc) return { photos[2], photos[1] } end
function catalog:getFolders() return { folder } end
M.LrApplication = { activeCatalog = function() return catalog end }

M.LrExportSession = function(args)
  local s = { args = args }
  function s:doExportOnCurrentTask() self.done = true end
  function s:renditions()
    local done = false
    local es = self.args.exportSettings
    return function()
      if done then return nil end
      done = true
      local photo = self.args.photosToExport[1]
      local out = es.LR_export_destinationPathPrefix .. '/' .. photo:getFormattedMetadata('fileName') .. '.jpg'
      py.render(out, photo._settings.Exposure2012, es.LR_size_maxWidth)
      return 1, { waitForRender = function() return true, out end }
    end
  end
  return s
end

function import(name)
  local m = M[name]
  if not m then error('mock: no module ' .. name) end
  return m
end
return M
