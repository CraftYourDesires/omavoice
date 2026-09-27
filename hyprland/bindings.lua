-- omavoice dictation keys for Omarchy (Hyprland Lua config).
-- Add these lines to ~/.config/hypr/bindings.lua (install.sh prints this).
-- All shortcuts go through dictation-record, which warms the cleanup LLM and
-- starts the live cleaner while you talk.

-- Tap Super + Alt to start, tap again to stop and paste. Fires on release, so
-- Super + Alt + <key> shortcuts are unaffected. On release Hyprland still counts
-- the released key as held, so both modifiers are listed; whichever key is let
-- go first triggers it and the second release no longer matches.
o.bind("SUPER + ALT + ALT_L", "Toggle dictation", "dictation-record toggle", { release = true })
o.bind("SUPER + ALT + ALT_R", "Toggle dictation", "dictation-record toggle", { release = true })
o.bind("SUPER + ALT + SUPER_L", "Toggle dictation", "dictation-record toggle", { release = true })

-- Replace Omarchy's default dictation keys with the omavoice wrapper.
hl.unbind("SUPER + CTRL + X")
hl.unbind("F9")
o.bind("SUPER + CTRL + X", "Toggle dictation", "dictation-record toggle")
o.bind("F9", "Start dictation (push-to-talk)", "dictation-record start")
o.bind("F9", "Stop dictation (push-to-talk)", "dictation-record stop", { release = true })
