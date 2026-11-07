local LrDialogs = import 'LrDialogs'
local LrTasks   = import 'LrTasks'
local Bridge = require 'Bridge'

LrTasks.startAsyncTask(function()
  local beat, owner, p = Bridge.status()
  local lines = {}
  if owner == 'stopped' then
    lines[#lines + 1] = 'Bridge is STOPPED. Use "Claude Bridge: Restart" to start it.'
  elseif beat and beat.time and (os.time() - beat.time) <= 10 then
    lines[#lines + 1] = 'Bridge is RUNNING.'
  else
    lines[#lines + 1] = 'Bridge is NOT responding. Try "Claude Bridge: Restart".'
  end
  if beat then
    lines[#lines + 1] = 'Requests handled: ' .. tostring(beat.handled or 0)
    lines[#lines + 1] = 'Last command: ' .. tostring(beat.lastCommand or '-')
    if beat.lastError then lines[#lines + 1] = 'Last error: ' .. tostring(beat.lastError) end
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Bridge folder: ' .. p.root
  LrDialogs.message('Claude Editor Bridge', table.concat(lines, '\n'), 'info')
end)
