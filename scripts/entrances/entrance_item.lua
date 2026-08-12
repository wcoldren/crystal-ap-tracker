-- EntranceItem: one custom Lua item per randomizable entrance.
-- Extends the pack's CustomItem base (scripts/custom_items/custom_item.lua).
--
-- Each item is keyed by its region-string token, which it provides as its item CODE (used
-- for hosted_item placement in the location JSON); the LuaItem Name is the pretty name, so
-- the UI/tooltip/feed shows that instead. Its connection state is revealed by the
-- autotracker (archipelago.lua's updateEntrances) from the DataStorage "entered" list:
--   forwardTarget = token of where entering THIS entrance emerges (left-click destination)
--   reverseSource = token of the entrance that emerges HERE          (right-click source)
-- Both are independent and may be nil (decoupled seeds / one-way holes only fill one).
--
-- Clicks are pure navigation (no manual connecting):
--   left   -> tab to where this entrance leads          (no-op if unrevealed)
--   right  -> tab to what leads to this entrance         (no-op if unrevealed)
--   middle -> route mode (pick two entrances -> GetRoute)

ENTRANCE_CLOSED_ICON = "images/entrances/entrance_unexplored.png" -- unrevealed marker
ENTRANCE_OPEN_ICON = "images/entrances/entrance_explored.png"     -- revealed marker

-- Temp-highlight state (feature: briefly highlight the destination after navigating).
local HIGHLIGHT_TARGET = nil
local HIGHLIGHT_TIME = 0
local HIGHLIGHT_SECONDS = 5

function RemoveEntranceHighlight()
    if os.clock() - HIGHLIGHT_TIME > HIGHLIGHT_SECONDS then
        ScriptHost:RemoveOnFrameHandler("entrance highlight handler")
        if HIGHLIGHT_TARGET then
            HIGHLIGHT_TARGET.Highlight = Highlight.None
        end
        HIGHLIGHT_TARGET = nil
        HIGHLIGHT_TIME = 0
    end
end

EntranceItem = CustomItem:extend()

function EntranceItem:init(token, row)
    self:createItem(row.pretty, {token}) -- display name; the token is provided as the item CODE
    self.token = token
    self.ids = row.ids
    self.pretty = row.pretty
    self.tab = row.tab
    self.node = EntranceSourceRegion(token) -- region this entrance sits in (route mode start/finish)
    self.forwardTarget = nil
    self.reverseSource = nil
    self:updateBadge()
end

--- Set/clear the revealed connection directions, then refresh the display.
function EntranceItem:setForward(token)
    self.forwardTarget = token
    self:updateBadge()
end

function EntranceItem:setReverse(token)
    self.reverseSource = token
    self:updateBadge()
end

function EntranceItem:reset()
    self.forwardTarget = nil
    self.reverseSource = nil
    self:updateBadge()
end

--- Whether either direction has been revealed.
function EntranceItem:isRevealed()
    return self.forwardTarget ~= nil or self.reverseSource ~= nil
end

--- Badge + icon. Badge rule:
---   one direction known -> "->dest" or "<-src"
---   both known & equal  -> "<->name"   (coupled/symmetric)
---   both known & differ -> two lines "->dest" / "<-src"  (decoupled)
function EntranceItem:updateBadge()
    local inst = self.ItemInstance
    local fwd = self.forwardTarget and ENTRANCE_REGISTRY[self.forwardTarget]
    local rev = self.reverseSource and ENTRANCE_REGISTRY[self.reverseSource]
    -- UTF-8 arrow glyphs as byte escapes (version-agnostic): -> = \226\134\146,
    -- <- = \226\134\144, <-> = \226\134\148
    local ARROW_FWD = "\226\134\146"
    local ARROW_REV = "\226\134\144"
    local ARROW_BOTH = "\226\134\148"
    local text = ""
    if fwd and rev then
        if self.forwardTarget == self.reverseSource then
            text = ARROW_BOTH .. fwd.pretty
        else
            text = ARROW_FWD .. fwd.pretty .. "\n" .. ARROW_REV .. rev.pretty
        end
    elseif fwd then
        text = ARROW_FWD .. fwd.pretty
    elseif rev then
        text = ARROW_REV .. rev.pretty
    end
    if text ~= "" then
        text = text .. "\n"
    end
    inst.BadgeText = text
    inst.BadgeTextColor = "#abcdef"
    inst:SetOverlayBackground("#c0000000")
    inst:SetOverlayFontSize(10)
    inst:SetOverlayAlign("left")
    if self:isRevealed() then
        inst.Icon = ImageReference:FromPackRelativePath(ENTRANCE_OPEN_ICON)
    else
        inst.Icon = ImageReference:FromPackRelativePath(ENTRANCE_CLOSED_ICON)
    end
end

--- Walk a tab-title chain to bring the destination marker into view.
local function activateTabChain(chain)
    if chain then
        for _, t in ipairs(chain) do
            Tracker:UiHint("ActivateTab", t)
        end
    end
end

--- Briefly highlight the destination marker (if its section is registered).
local function highlightTarget(token)
    local row = ENTRANCE_REGISTRY[token]
    if not row or not row.section then
        return
    end
    if HIGHLIGHT_TARGET then
        HIGHLIGHT_TARGET.Highlight = Highlight.None
    end
    HIGHLIGHT_TARGET = Tracker:FindObjectForCode(row.section)
    if HIGHLIGHT_TARGET then
        HIGHLIGHT_TARGET.Highlight = Highlight.Avoid
        HIGHLIGHT_TIME = os.clock()
        ScriptHost:AddOnFrameHandler("entrance highlight handler", RemoveEntranceHighlight)
    end
end

--- Navigate to a target entrance token (tab there + highlight it).
local function navigateTo(token)
    local row = ENTRANCE_REGISTRY[token]
    if row then
        activateTabChain(row.tab)
    end
    highlightTarget(token)
end

function EntranceItem:onLeftClick()
    if self.forwardTarget then
        navigateTo(self.forwardTarget)
    end
end

function EntranceItem:onRightClick()
    if self.reverseSource then
        navigateTo(self.reverseSource)
    end
end

-- Route mode: first middle-click picks the start. Second click on a different entrance routes
-- between the two; on the same entrance, routes from the player's current position to it.
ROUTE_START = nil      -- source region name of the first-picked entrance
ROUTE_START_ITEM = nil -- first-picked item, to detect the same entrance twice

function EntranceItem:onMiddleClick()
    if ROUTE_START == nil then
        ROUTE_START = self.node
        ROUTE_START_ITEM = self
    else
        if ROUTE_START_ITEM == self then
            local from = CurrentRegionNode()
            if from then
                GetRoute(from, NAMED_NODES[self.node])
            else
                ShowRouteMessage("Position Unknown")
            end
        else
            GetRoute(NAMED_NODES[ROUTE_START], NAMED_NODES[self.node])
        end
        ROUTE_START = nil
        ROUTE_START_ITEM = nil
    end
end

function EntranceItem:canProvideCode(code)
    return code == self.token
end

--- Collected state for the section hosting this entrance (hosted_item = the token).
function EntranceItem:providesCode(code)
    if code == self.token and self:isRevealed() then
        return 1
    end
    return 0
end

--- token -> ER category, harvested from the graph's entrance edges (the category lives on the
--- connect_*_entrance edge as exit[4], with the token as exit[5]). Built once after the graph
--- is loaded, so we can tell which registry rows belong to a shuffled category.
ENTRANCE_CATEGORY = {}
function buildEntranceCategoryMap()
    if not NAMED_NODES_KEYS then
        return
    end
    for _, name in ipairs(NAMED_NODES_KEYS) do
        local node = NAMED_NODES[name]
        if node then
            for _, exit in ipairs(node.exits) do
                if exit[3] then -- is_entrance edge
                    ENTRANCE_CATEGORY[exit[5]] = exit[4]
                end
            end
        end
    end
end

--- Restored connections from the save, keyed by token: ENTRANCE_SAVED_STATE[token] = {fwd, rev}.
--- Populated by EntranceStateItem:load(), consumed by createEntrancesForEnabled(). Kept around
--- after it is applied because the two run in either order (see EntranceStateItem below).
ENTRANCE_SAVED_STATE = {}

--- Apply any restored connection for this token to an existing item.
local function applySavedState(token, item)
    local saved = ENTRANCE_SAVED_STATE[token]
    if saved then
        item:setForward(saved[1])
        item:setReverse(saved[2])
    end
end

--- Instantiate EntranceItems ONLY for entrances whose ER category is currently enabled.
--- A vanilla (non-shuffled) entrance has a fixed connection and needs no tracker item, so the
--- LuaItem count tracks what's actually shuffled (0 on a non-ER seed). This is what keeps
--- PopTracker's per-update cost down -- a large _luaItems set makes every item toggle laggy
--- regardless of the logic path. Idempotent and additive: safe to call repeatedly (e.g. from
--- refreshERCategories on connect / manual toggle). Items are never removed once created
--- (PopTracker has no RemoveItems), which is fine because categories are fixed per seed.
--- Call after ENTRANCE_REGISTRY, the graph, and buildEntranceCategoryMap() are ready.
ENTRANCE_ITEMS = {}
function createEntrancesForEnabled()
    if not ENTRANCE_REGISTRY or not ER_CATEGORY_ENABLED then
        return
    end
    for token, row in pairs(ENTRANCE_REGISTRY) do
        if not ENTRANCE_ITEMS[token] then
            local cat = ENTRANCE_CATEGORY[token]
            if cat and ER_CATEGORY_ENABLED[cat] then
                local item = EntranceItem(token, row)
                ENTRANCE_ITEMS[token] = item
                applySavedState(token, item)
            end
        end
    end
end

-- Persistence for the revealed connections.
--
-- The EntranceItems themselves cannot carry this. PopTracker assigns Lua items their stable
-- save IDs exactly once, right after init.lua returns, and at that moment no EntranceItem
-- exists yet: the ER toggles are still at their default Off stage, so refreshERCategories()
-- enables nothing and createEntrancesForEnabled() creates nothing. The items are only built
-- later, when the restored toggles (or onClear) fire the er_<cat> watch -- too late for an ID.
-- Items without a stable ID fall back to matching on an unstable sequential ID handed out in
-- pairs(ENTRANCE_REGISTRY) order, which would restore connections onto the wrong entrances.
--
-- So the whole map lives on this single item instead, created during init (hence it gets a
-- stable ID) and keyed by token rather than by position. One item also keeps _luaItems small,
-- which is the same reason entrances are only materialized per enabled category.
--
-- Payload is flat (token -> "<fwd>|<rev>", either side possibly empty) because CustomItem:save
-- is documented for simple value types.
--
-- NOTE: the Name below feeds the stable ID. Renaming it orphans every existing save.
EntranceStateItem = CustomItem:extend()

function EntranceStateItem:init()
    self:createItem("ER Connection State", {})
end

function EntranceStateItem:save()
    local data = {}
    if ENTRANCE_ITEMS then
        for token, item in pairs(ENTRANCE_ITEMS) do
            if item:isRevealed() then
                data[token] = (item.forwardTarget or "") .. "|" .. (item.reverseSource or "")
            end
        end
    end
    return data
end

function EntranceStateItem:load(data)
    ENTRANCE_SAVED_STATE = {}
    if type(data) ~= "table" then
        return true
    end
    for token, packed in pairs(data) do
        if type(packed) == "string" then
            local fwd, rev = string.match(packed, "^([^|]*)|([^|]*)$")
            if fwd then
                fwd = fwd ~= "" and fwd or nil
                rev = rev ~= "" and rev or nil
                ENTRANCE_SAVED_STATE[token] = {fwd, rev}
                -- The entrances may already exist: PopTracker restores json_items (the ER
                -- toggles, whose watch builds them) before lua_items. Whichever of the two
                -- runs first, the other path fills in the rest.
                local item = ENTRANCE_ITEMS and ENTRANCE_ITEMS[token]
                if item then
                    item:setForward(fwd)
                    item:setReverse(rev)
                end
            end
        end
    end
    return true
end
