--- Wide Hand
-- When a card area (hand, jokers, consumables) holds more cards than fit comfortably,
-- hovering it can:
--   1. widen the area across the screen, drawn over the rest of the UI;
--   2. shift cards apart under the cursor so the card there is fully visible.
-- Which of the two (or both), and for which areas, is chosen in the mod's config tab.
-- All distances are in game units; card widths are expressed as multiples of G.CARD_W.

WideHand = WideHand or {}
local WH = WideHand

WH.MODES = {SHIFT = 1, WIDEN = 2, BOTH = 3}
WH.settings = (SMODS.current_mod and SMODS.current_mod.config) or {mode = WH.MODES.BOTH}

WH.cfg = {
    crowd_ratio  = 0.5,   -- activate only when normal spacing between cards is below this * card width
    target_gap   = 0.45,  -- desired spacing between cards in the widened area (* card width)
    screen_margin = 0.15, -- keep the widened area this far from the screen edges
    focus_gap    = 1.05,  -- gap right after the focused card (* card width); >= 1 shows the whole card
    focus_sigma  = 1.1,   -- how many neighbouring gaps share the extra room (gaussian sigma, in cards)
    min_gap      = 0.06,  -- never squeeze far-away cards closer than this (* card width)
    hover_pad    = 0.35,  -- extra hover tolerance around the widened area
    backdrop_alpha = 0.45,
}

-- Per-area state, keyed by the CardArea (areas are recreated every run).
-- Fields: active, fade, layout {x0, w, y0, y1, widened}, draw_on_top
WH.states = setmetatable({}, {__mode = 'k'})
WH.current = nil -- the area currently expanded (only one at a time)

local function shift_enabled() return WH.settings.mode ~= WH.MODES.WIDEN end
local function widen_enabled() return WH.settings.mode ~= WH.MODES.SHIFT end

-- Settings key of a supported area, or nil. G.jokers is checked first because
-- Cryptid's "beta" deck makes G.consumeables the same area as G.jokers.
local function area_key(area)
    if area == nil then return nil end
    if area == G.hand then return 'hand' end
    if area == G.jokers then return 'jokers' end
    if area == G.consumeables then return 'consumables' end
end

local function state_of(area)
    local st = WH.states[area]
    if not st then
        st = {active = false, fade = 0}
        WH.states[area] = st
    end
    return st
end

local function cursor_room()
    if not (G.CURSOR and G.ROOM) then return nil end
    return G.CURSOR.T.x - G.ROOM.T.x, G.CURSOR.T.y - G.ROOM.T.y
end

local function card_sort(a, b)
    return a.T.x + a.T.w/2 - 100*((a.pinned and not a.ignore_pinned) and a.sort_id or 0)
         < b.T.x + b.T.w/2 - 100*((b.pinned and not b.ignore_pinned) and b.sort_id or 0)
end

local function can_activate(area, key)
    if WH.settings[key] == false then return false end
    if G.OVERLAY_MENU or G.SETTINGS.paused then return false end
    if G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller then return false end
    if not area.states.visible then return false end
    if key == 'hand' then
        if area.config.type ~= 'hand' or G.VIEWING_DECK then return false end
        if G.view_deck and G.view_deck[1] and G.view_deck[1].cards then return false end
    elseif area.config.type ~= 'joker' then
        return false
    end
    return #area.cards >= 3
end

-- Vertical band currently occupied by the area's cards (for the hand this covers both
-- the normal and the booster-pack layout).
local function card_band(area)
    local y0, y1 = math.huge, -math.huge
    for _, card in ipairs(area.cards) do
        if not card.states.drag.is then
            y0 = math.min(y0, card.T.y)
            y1 = math.max(y1, card.T.y + card.T.h)
        end
    end
    if y0 > y1 then y0, y1 = area.T.y, area.T.y + area.T.h end
    return y0, y1
end

-- Gaps between consecutive cards with the extra room centered on continuous index f
-- (nil f = no focus, even spacing). gaps[i] is the distance from card i's left edge
-- to card i+1's left edge.
local function compute_gaps(n, span, f, cw, gaps)
    local cfg = WH.cfg
    local peak, min_gap = cfg.focus_gap*cw, cfg.min_gap*cw
    local uniform = span/(n - 1)
    if not f or uniform >= peak then
        for i = 1, n - 1 do gaps[i] = uniform end
        return gaps
    end
    local two_s2 = 2*cfg.focus_sigma*cfg.focus_sigma
    local sum_e = 0
    for i = 1, n - 1 do
        local d = i + 0.5 - f
        local e = math.exp(-d*d/two_s2)
        gaps[i] = e
        sum_e = sum_e + e
    end
    local base, bump
    local denom = (n - 1) - sum_e
    if denom > 0 then base = (span - peak*sum_e)/denom end
    if not base or base < min_gap then
        base = math.min(min_gap, uniform)
        bump = (span - (n - 1)*base)/sum_e
    else
        bump = peak - base
    end
    for i = 1, n - 1 do gaps[i] = base + bump*gaps[i] end
    return gaps
end

-- Position of continuous index f: card k's visible strip is [k, k+1).
local function index_to_x(n, x0, cw, gaps, f)
    local x = x0
    for i = 1, n - 1 do
        local t = f - i
        if t <= 0 then return x end
        if t < 1 then return x + gaps[i]*t end
        x = x + gaps[i]
    end
    return x + cw*math.max(0, math.min(1, f - n))
end

-- Find f so that the magnified layout puts index f exactly under the cursor.
local function solve_focus(n, x0, span, cw, cx, gaps)
    local lo, hi = 1, n + 0.999
    if cx <= x0 then return lo end
    for _ = 1, 28 do
        local mid = (lo + hi)/2
        compute_gaps(n, span, mid, cw, gaps)
        if index_to_x(n, x0, cw, gaps, mid) < cx then lo = mid else hi = mid end
    end
    return (lo + hi)/2
end

local gaps_buf = {}

local function deactivate(area, st)
    st.active = false
    if WH.current == area then WH.current = nil end
end

function WH.apply(area, key, order_before)
    local cfg = WH.cfg
    local st = state_of(area)
    local n = #area.cards
    local cw = area.card_w or G.CARD_W
    local cx, cy = cursor_room()

    if not cx or not can_activate(area, key) then return deactivate(area, st) end
    if WH.current and WH.current ~= area and state_of(WH.current).active then
        return deactivate(area, st)
    end

    local normal_gap = (area.T.w - cw)/math.max(n - 1, 1)
    if normal_gap >= cfg.crowd_ratio*cw then return deactivate(area, st) end

    local shift, widen = shift_enabled(), widen_enabled()

    local x0, w = area.T.x, area.T.w
    if widen then
        local room_w = G.ROOM.T.w
        local margin = cfg.screen_margin
        local want_w = (n - 1)*cfg.target_gap*cw + cw + (shift and 2*cfg.focus_gap*cw or 0)
        w = math.max(area.T.w, math.min(want_w, room_w - 2*margin))
        x0 = area.T.x + area.T.w/2 - w/2
        x0 = math.max(margin, math.min(x0, room_w - margin - w))
    end
    local y0, y1 = card_band(area)

    -- hover test: enter through the normal area, stay while inside the current one
    local pad = cfg.hover_pad
    local inside
    if st.active then
        inside = cx >= x0 - pad and cx <= x0 + w + pad and cy >= y0 - pad and cy <= y1 + pad
    else
        inside = cx >= area.T.x and cx <= area.T.x + area.T.w and cy >= y0 and cy <= y1
    end
    if not inside then return deactivate(area, st) end
    st.active = true
    WH.current = area

    -- undo the base game's drag re-sort (see CardArea:align_cards below)
    if order_before and #order_before == n then
        for i, card in ipairs(order_before) do area.cards[i] = card end
    end

    local f = shift and solve_focus(n, x0, w - cw, cw, cx, gaps_buf) or nil

    local gaps = compute_gaps(n, w - cw, f, cw, gaps_buf)
    local x = x0
    for k, card in ipairs(area.cards) do
        if not card.states.drag.is then
            card.T.x = x + 0.5*(cw - card.T.w) + card.shadow_parrallax.x/30
        end
        x = x + (gaps[k] or 0)
    end

    -- Cryptid modifiers that lock joker order: the base game skips sorting then too
    local locked = key ~= 'hand' and G.GAME and G.GAME.modifiers
        and (G.GAME.modifiers.cry_conveyor or G.GAME.cry_fastened)
    if not locked then
        table.sort(area.cards, card_sort)
        for k, card in ipairs(area.cards) do card.rank = k end
    end

    st.layout = {x0 = x0, w = w, y0 = y0, y1 = y1, widened = widen}
end

local align_cards_ref = CardArea.align_cards
function CardArea:align_cards(...)
    local key = area_key(self)
    -- While a card of this area is dragged, the base game re-sorts it against the
    -- positions of the normal (narrow) layout. Remember the order beforehand so the
    -- drop position can be decided against our layout instead.
    local order_before
    local dragged = G.CONTROLLER and G.CONTROLLER.dragging and G.CONTROLLER.dragging.target
    if key and dragged and dragged.area == self then
        order_before = {}
        for i, card in ipairs(self.cards) do order_before[i] = card end
    end
    local ret = align_cards_ref(self, ...)
    if key then WH.apply(self, key, order_before) end
    return ret
end

-- Skip the normal draw of an expanded area; it is drawn later by WH.draw_on_top
-- (hooked into Game:draw through lovely.toml).
local draw_ref = CardArea.draw
function CardArea:draw(...)
    if WH.patch_ok and not WH.drawing_top then
        local st = WH.states[self]
        if st and st.draw_on_top then return end
    end
    return draw_ref(self, ...)
end

local function draw_area_on_top(area, st)
    love.graphics.push()
    area:translate_container()

    local L = st.layout
    if L and L.widened and st.fade > 0 then
        local ts = G.TILESIZE
        local pad = 0.15
        love.graphics.push()
        love.graphics.scale(G.TILESCALE, G.TILESCALE)
        love.graphics.setColor(0, 0, 0, WH.cfg.backdrop_alpha*st.fade)
        love.graphics.rectangle('fill', (L.x0 - pad)*ts, (L.y0 - pad)*ts,
            (L.w + 2*pad)*ts, (L.y1 - L.y0 + 2*pad)*ts, 0.15*ts, 0.15*ts)
        love.graphics.pop()
        love.graphics.setColor(1, 1, 1, 1)
    end

    WH.drawing_top = true
    area:draw()
    WH.drawing_top = false
    love.graphics.pop()
end

function WH.draw_on_top()
    WH.patch_ok = true
    local dt = G.real_dt or 0
    for area, st in pairs(WH.states) do
        st.fade = st.active and math.min(1, st.fade + dt*8) or math.max(0, st.fade - dt*6)
        st.draw_on_top = (st.active or st.fade > 0) and area_key(area) ~= nil and not area.REMOVED
    end
    -- fading-out areas first, the currently expanded one last (on top, first for hover)
    for area, st in pairs(WH.states) do
        if st.draw_on_top and area ~= WH.current and not area.parent then draw_area_on_top(area, st) end
    end
    local cur = WH.current
    if cur and WH.states[cur] and WH.states[cur].draw_on_top and not cur.parent then
        draw_area_on_top(cur, WH.states[cur])
    end
end

-- Config tab (Mods -> Wide Hand -> Config)
G.FUNCS.widehand_set_mode = function(args)
    WH.settings.mode = args.to_key
end

if SMODS.current_mod then
    SMODS.current_mod.config_tab = function()
        for _, k in ipairs({'hand', 'jokers', 'consumables'}) do
            if WH.settings[k] == nil then WH.settings[k] = true end
        end
        return {n = G.UIT.ROOT, config = {align = 'cm', padding = 0.2, colour = G.C.BLACK, r = 0.1, minw = 8}, nodes = {
            create_option_cycle({
                label = 'When hovering a crowded area',
                scale = 0.8,
                w = 5,
                options = {'Shift cards', 'Widen area', 'Both'},
                current_option = WH.settings.mode or WH.MODES.BOTH,
                opt_callback = 'widehand_set_mode',
            }),
            {n = G.UIT.R, config = {align = 'cm', padding = 0.05}, nodes = {
                {n = G.UIT.C, config = {align = 'cr'}, nodes = {
                    create_toggle({label = 'Hand', ref_table = WH.settings, ref_value = 'hand'}),
                    create_toggle({label = 'Jokers', ref_table = WH.settings, ref_value = 'jokers'}),
                    create_toggle({label = 'Consumables', ref_table = WH.settings, ref_value = 'consumables'}),
                }},
            }},
        }}
    end
end
