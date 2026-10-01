-- Real frosted glass behind the omavoice overlay (overlay_style = "glass").
-- Add these lines to ~/.config/hypr/looknfeel.lua.
--
-- Omarchy ships with blur turned off. Hyprland only blurs anything while
-- decoration.blur is enabled, so this turns it on, then opts every window
-- back out so windows look exactly as before. Only the overlay's layer
-- surface (namespace omavoice-overlay) gets blurred.
hl.config({
  decoration = {
    blur = {
      enabled = true,
      size = 6,
      passes = 3,
      noise = 0.03,
      contrast = 1.0,
      brightness = 0.95,
      vibrancy = 0.25,
      new_optimizations = true,
    },
  },
})
o.window(".*", { no_blur = true })

-- ignore_alpha: the soft shadow and glow around the panel stay unblurred;
-- the glass body (alpha about 0.4 and up) is blurred.
hl.layer_rule({
  match = { namespace = "^omavoice-overlay$" },
  blur = true,
  ignore_alpha = 0.4,
})
