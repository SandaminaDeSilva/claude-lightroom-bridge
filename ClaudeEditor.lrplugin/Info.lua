-- Claude Editor Bridge: lets Claude read and edit develop settings in Lightroom Classic.
return {
  LrSdkVersion        = 10.0,
  LrSdkMinimumVersion = 6.0,
  LrToolkitIdentifier = 'com.github.claude-lightroom-bridge',
  LrPluginName        = 'Claude Editor Bridge',
  LrPluginInfoUrl     = 'https://github.com/YOUR_USERNAME/claude-lightroom-bridge',

  LrInitPlugin        = 'Init.lua',
  LrForceInitPlugin   = true,
  LrShutdownPlugin    = 'Shutdown.lua',

  LrLibraryMenuItems = {
    { title = 'Claude Bridge: Status',  file = 'MenuStatus.lua' },
    { title = 'Claude Bridge: Restart', file = 'MenuRestart.lua' },
    { title = 'Claude Bridge: Stop',    file = 'MenuStop.lua' },
  },
  LrExportMenuItems = {
    { title = 'Claude Bridge: Status',  file = 'MenuStatus.lua' },
    { title = 'Claude Bridge: Restart', file = 'MenuRestart.lua' },
    { title = 'Claude Bridge: Stop',    file = 'MenuStop.lua' },
  },

  VERSION = { major = 1, minor = 0, revision = 0, build = 1 },
}
