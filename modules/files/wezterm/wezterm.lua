-- WezTerm gerenciado pelo flake (modules/files/wezterm/wezterm.lua).
-- Lido via XDG_CONFIG_DIRS=/etc/xdg. Para personalizar, crie
-- ~/.config/wezterm/wezterm.lua — ele tem prioridade sobre este.

local wezterm = require "wezterm"
local config = wezterm.config_builder()

-- Nushell como shell padrão de toda janela/aba.
-- "-l" = login shell: carrega ~/.config/nushell/env.nu, config.nu e
-- login.nu (se existir).
config.default_prog = { "nu", "-l" }

return config
