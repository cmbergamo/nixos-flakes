-- WezTerm gerenciado pelo flake (modules/files/wezterm/wezterm.lua).
-- Lido via XDG_CONFIG_DIRS=/etc/xdg. Para personalizar, crie
-- ~/.config/wezterm/wezterm.lua — ele tem prioridade sobre este.

local wezterm = require "wezterm"
local config = wezterm.config_builder()

-- Nushell como shell padrão de toda janela/aba.
-- "-l" = login shell: carrega ~/.config/nushell/env.nu, config.nu e
-- login.nu (se existir).
config.default_prog = { "nu", "-l" }

-- Tema escuro moderno de alto contraste e legibilidade
config.color_scheme = "Catppuccin Mocha"

-- Tipografia Fira Mono
config.font = wezterm.font("Fira Mono")
config.font_size = 11.5

-- Visual e acabamento
config.window_background_opacity = 0.95
config.window_padding = {
  left = 12,
  right = 12,
  top = 10,
  bottom = 10,
}
config.hide_tab_bar_if_only_one_tab = true
config.scrollback_lines = 10000
config.use_fancy_tab_bar = false

return config
