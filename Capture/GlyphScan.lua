-- =============================================================================
-- Capture/GlyphScan.lua
--
-- Compatibility shim for WoW 2.4.3. The glyph system was introduced after
-- The Burning Crusade, so stock 2.4.3 has no glyph sockets or glyph API.
-- Keeping these functions preserves the shared Capture API without inventing
-- data that cannot exist on this client.
-- =============================================================================

local Log = Chronicle.Logger
local Capture = Chronicle.Capture

function Capture.ScanGlyphs()
    Log:Debug("GlyphScan: unavailable on WoW 2.4.3")
    return nil
end

function Capture.PrintGlyphs(glyphs)
    Log:Info("Glyphs are not available on WoW 2.4.3")
end

function Capture.ProbeGlyphs()
    Log:Info("Glyph APIs do not exist on WoW 2.4.3")
end
