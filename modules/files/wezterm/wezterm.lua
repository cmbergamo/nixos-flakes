-- WezTerm gerenciado pelo flake (modules/files/wezterm/wezterm.lua).
-- Exclusivo para a configuração do cmb-nix.
-- Publicado em /etc/xdg/wezterm/wezterm.lua via modules/terminal.nix.

local wezterm = require "wezterm"
local act = wezterm.action
local config = wezterm.config_builder()

-- Shell padrão: no Linux/NixOS executa 'nu -l'; em compatibilidade Windows usa 'nu.exe'
if wezterm.target_triple:find("windows") then
  config.default_prog = { "nu.exe" }
else
  config.default_prog = { "nu", "-l" }
end

-- Tipografia
config.font = wezterm.font("Fira Mono")
config.font_size = 11.5
config.line_height = 1.0

-- Paleta e Tema Escuro Catppuccin Mocha
config.color_scheme = "Catppuccin Mocha"
config.window_background_opacity = 0.95
config.window_padding = {
  left = 12,
  right = 12,
  top = 10,
  bottom = 10,
}

-- Comportamento e Janela
config.enable_wayland = true
config.exit_behavior = "Close"
config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false
config.window_decorations = "TITLE | RESIZE"
config.integrated_title_button_alignment = "Right"
config.window_close_confirmation = "NeverPrompt"
config.scrollback_lines = 10000

-- Atalhos de teclado
config.keys = {
  { key = "r", mods = "CTRL|SHIFT", action = act.SplitHorizontal { domain = "CurrentPaneDomain" } },
  { key = "d", mods = "CTRL|SHIFT", action = act.SplitVertical { domain = "CurrentPaneDomain" } },
  { key = "C", mods = "CTRL|SHIFT", action = act.CopyTo "Clipboard" },
  { key = "V", mods = "CTRL|SHIFT", action = act.PasteFrom "Clipboard" },
}

return config
