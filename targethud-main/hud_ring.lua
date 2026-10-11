--[[
* targethud: ring module.
* From targetring 2.10.0 (Broguypal Windower original; Ashita v4 port).
--]]

require('common');

local d3d       = require('d3d8');
local ffi       = require('ffi');
local settings  = require('settings');
local C         = ffi.C;
local unpack_bits = ashita.bits.unpack_be;
local dev       = d3d.get_device();

local M = { };

-- Reload-safe typedef; ffi.sizeof throws on an unknown type.
if (not pcall(ffi.sizeof, 'tr_vertex_t')) then
    ffi.cdef[[
        typedef struct { float x, y, z, rhw; uint32_t color; } tr_vertex_t;
    ]];
end

----------------------------------------------------------------------------------------------------
-- Constants (ported 1:1 from the Windower module unless noted)
----------------------------------------------------------------------------------------------------
local MAX_VERTS     = 8190;                 -- multiple of 6
local STRIDE        = ffi.sizeof('tr_vertex_t');
local TWO_PI        = math.pi * 2.0;
local HALF_PI       = math.pi * 0.5;
local CLEARANCE     = 0.05;
local MAIN_BAND     = 0.075;
local GLOW_BAND     = 0.900;
local GLOW_ALPHA    = 0.200;
local INNER_SCALE   = 0.680;
local INNER_BAND    = 0.030;
local REAR_FADE     = 0.120;
local RUNE_SIZE     = 0.120;
local RUNE_THICK    = 0.200;
local PULSE_DEPTH   = 0.200;
local PULSE_SECS    = 0.800;
local ARROW_TIP     = 0.960;
local ARROW_BASE    = 0.520;
local ARROW_HALF    = 0.300;
local ARROW_NOTCH   = 0.720;
local PLAYER_FOOT   = 0.640;
local HUMANOID      = 1.150;
local COLOR_MOB     = 0xE6FF6A3C;
local COLOR_PC      = 0xE64CC4FF;
local COLOR_NPC     = 0xE62EA84E;   -- deep green

-- Range tints. The base hue survives inside range, washes toward amber across
-- the marginal band, then sinks into a dim slate past it, so a bright ring
-- always means reachable.
local RANGE_HYST    = 0.50;         -- yalms of overlap so the edge doesn't flicker
local FILL_SCALE    = 0.98;         -- fill stops just inside the main band

-- Actor (display) object offsets. GetActorPointer already hands back the display
-- object, so these match the Windower module's display_ptr + field layout.
local OFF_POS       = 0x678;                -- x, height, z  (model root / nameplate base)
local OFF_OBJ       = 0x034;                -- same layout, used for target type 3 (doors etc)
local OFF_HEADING   = 0x048;

-- GEO-HUD ring palette and tuning.
local GEO_GREEN     = 0xE63CFF6A;
local GEO_RED       = 0xE6FF3C3C;
local GEO_GLOW_MUL  = 1.18;
local GEO_GLOW_BAND = 0.34;
local GEO_MAIN_BAND = 0.12;
local BUBBLE_BAND   = 0.030;        -- boundary ring thickness, as a fraction of radius
local BUBBLE_ALPHA  = 0.60;
local ENTRUST_LIFE  = 600.0;        -- fallback expiry when no Colure Active data exists for the carrier
local BUFF_COLURE   = 612;          -- Colure Active
local COLURE_GRACE  = 2.5;          -- seconds after the cast before Colure Active must be present
local GEO_TICK      = 0.25;         -- seconds between bubble/tag rebuilds
local GEO_JOB       = 21;
local BUFF_WIDENED  = 508;
local GONE_GRACE    = 8.0;          -- seconds a vanished mob keeps its tag
local DEAD_CONFIRM  = 0.6;          -- seconds of 0 HP before the tag drops
local MAX_INDEX     = 0x900;

-- Indicolure duration (BG-Wiki Category:Geomancy / Compendium of Colure):
-- (180 + gear seconds + 2s per JP rank) * (1 + augment percent / 100).
local INDI_BASE     = 180.0;
local INDI_JP_STEP  = 2.0;
local GEO_JP_INDI   = 9;            -- 0x08D packet index, Indicolure Spell Effect Dur. (XiPackets)
local AUG_INDI_DUR  = 1250;         -- system 1 augment "Indi. eff. dur." (Windower extdata / LuAshitacast)
local LIVE_TTL      = 0.2;          -- outgoing equip packet trusted over memory this long (LuAshitacast)
local LAND_TAIL     = 0.6;          -- keep sampling after the spell lands
local SAMPLE_WINDOW = 12.0;

-- Action categories that can generate enmity when they finish.
local TAG_CATEGORY = {
    [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
    [6] = true, [13] = true, [14] = true, [15] = true,
};

-- Full Circle, Concentric Pulse, Mending Halation, Radial Arcana.
local LUOPAN_JA = { [345] = true, [353] = true, [354] = true, [355] = true };

-- 0x028 category 8 cmd_arg for Geomancy: 'cage' start, 'spge' interrupt (XiPackets).
local MAGIC_GEO_START     = 1701273955;
local MAGIC_GEO_INTERRUPT = 1701277811;

-- Element -> ARGB, matching GEO-HUD's orb palette.
local ELEMENT_COLOR = {
    [0] = 0xE6FF6E2D,   -- Fire
    [1] = 0xE696D7FF,   -- Ice
    [2] = 0xE66EFF8C,   -- Wind
    [3] = 0xE6E6BE50,   -- Earth
    [4] = 0xE6D282FF,   -- Thunder
    [5] = 0xE64696FF,   -- Water
    [6] = 0xE6FFFCD2,   -- Light
    [7] = 0xE6BE64FF,   -- Dark
};

-- Zones where every mob already has the party on its hate list.
local AUTO_TAG_ZONE = {
    [287] = true,       -- Maquette Abdhaljs-Legion B (Ambuscade)
};

-- Colure suffix -> bubble applies to allies (true) or enemies (false).
local COLURE_BUFF = {
    Regen = true, Refresh = true, Haste = true, Fury = true, Barrier = true,
    Acumen = true, Fend = true, Precision = true, Voidance = true, Focus = true,
    Attunement = true, STR = true, DEX = true, VIT = true, AGI = true,
    INT = true, MND = true, CHR = true,
};
local COLURE_DEBUFF = {
    Poison = true, Wilt = true, Frailty = true, Fade = true, Malaise = true,
    Slip = true, Torpor = true, Vex = true, Languor = true, Slow = true,
    Paralysis = true, Gravity = true,
};

local GLYPH = {
    { -1.55,  0.00, -1.10,  0.42 },
    { -1.10,  0.42, -0.65,  0.00 },
    { -0.65,  0.00, -1.10, -0.42 },
    { -1.10, -0.42, -1.55,  0.00 },
    { -0.35, -0.70,  0.30,  0.00 },
    {  0.30,  0.00, -0.35,  0.70 },
    {  0.45, -0.70,  1.10,  0.00 },
    {  1.10,  0.00,  0.45,  0.70 },
};

local default_settings = T{
    enabled = true,
    depth   = false,    -- Z-test the ring against the world; see /tring depth
    arrow   = true,
    runes   = true,
    fade    = true,
    flip    = false,    -- invert the facing-arrow heading if it points the wrong way
    scale   = 1.0,
    slices  = 48,

    -- Range feedback: in range the ring is lightly filled, out of range it is
    -- an empty outline.
    range        = true,
    range_geo    = false,   -- fill the GEO bubble rings the same way
    range_base   = 20.0,    -- standard magic range
    range_fill   = 0.35,    -- fill strength (normal alpha blend, not additive)
    range_hitbox = true,    -- add both hitboxes, so a big NM reads correctly

    -- GEO bubble rings (ported from GEO-HUD)
    geo         = true,
    geo_slices  = 24,
    geo_radius  = 6.0,      -- base Geo-/Indi- bubble radius in yalms
    geo_cap     = 16,       -- max rings drawn at once
    geo_scan    = 35.0,     -- yalms around the luopan to consider
    geo_cure    = true,     -- Cure on an ally with hate tags that ally's mobs
    geo_buffs   = true,     -- ring party members inside a buff (Geo-Regen etc) bubble
    geo_bubble  = true,     -- draw the bubble boundary itself
    geo_indi_jp = -1,       -- Indicolure duration JP rank from 0x08D; -1 = not seen yet
    migrated    = false,    -- old targetring settings imported
};
M.defaults = default_settings;

local cfg = default_settings;   -- replaced by M.set_cfg once the settings lib loads

local tr = {
    verts   = ffi.new('tr_vertex_t[?]', MAX_VERTS),
    count   = 0,
    m       = { },      -- view * projection, row-major, 1..16
    cosv    = { },
    sinv    = { },
    saved   = { rs = { }, tss = { } },
    vx      = 0,
    vy      = 0,
    vw      = 0,
    vh      = 0,
    hub     = 0.0,
    span    = 0.0,
    debug   = false,
    gcos    = { },
    gsin    = { },
    in_range = { },     -- entity index -> was inside the range edge last frame
    ent     = nil,      -- per-frame entity manager
    self_index = 0,     -- per-frame own entity index
    pulse   = 1.0,      -- per-frame ring pulse
};

local geo = {
    rings       = { },      -- draw cache: { index, radius, color }
    count       = 0,
    next_tick   = 0.0,
    id_index    = { },      -- server id -> entity index
    id_miss     = { },      -- server id -> os.clock() of last failed full scan
    id_miss_n   = 0,
    party_index = { },      -- entity index -> true (party + alliance)
    party_ids   = { },      -- server id -> true (party + alliance)
    tagged      = { },      -- server id -> os.clock() when tagged
    hate        = { },      -- ally id -> { mob id -> true }
    missing     = { },      -- server id -> first frame it vanished
    dying       = { },      -- server id -> first frame at 0 HP
    widened     = { },      -- party server id -> Widened Compass
    geo_id      = nil,      -- server id of the geomancer we watch
    luopan      = nil,      -- entity index of the luopan
    spell       = nil,      -- last Geo- spell name
    element     = nil,      -- last Geo- spell element
    is_buff     = false,    -- last Geo- spell buffs allies
    indi_buff   = false,    -- self-carried Indi- spell buffs allies
    status      = 'idle',

    -- Widened Compass is captured when the cast starts, because the bubble
    -- keeps the radius it was created with even after the buff drops.
    wide_luopan = false,
    wide_indi   = false,
    pending     = nil,      -- snapshot taken at category 8
    pending_by  = nil,      -- caster the snapshot belongs to
    pending_at  = 0.0,

    indi_id     = nil,      -- who is carrying the Indi bubble
    indi_at     = 0.0,      -- when the self-carried Indi landed
    colure      = { },      -- party server id -> Colure Active (0x076)
    party6      = { },      -- entity index -> true (own party, slots 0-5)
    indi_elem   = nil,
    entrust     = { },      -- target server id -> { element, wide, at }
    bubbles     = { },      -- boundary circles: { index, radius, color }
    bubble_n    = 0,
    job         = nil,
};

-- Indi/Entrust duration for casts we make ourselves. Gear is sampled across the
-- cast and the best reading wins, since land time is usually aftercast already.
local dur = {
    live     = { },     -- equip slot -> { container, index, os.clock() } from outgoing 0x050/0x051
    cache    = { },     -- item id .. extdata -> { flat, pct }
    until_at = nil,
    best     = -1,
    flat     = 0,
    pct      = 0,
    self_at  = nil,
    self_exp = nil,
    land_id  = nil,
    land_at  = nil,
    mode     = nil,     -- 'self' or 'entrust': which timer the current sample feeds
    jp       = nil,
};

local function build_ring_table(n, cosv, sinv)
    for i = 0, n do
        local a = (i / n) * TWO_PI;
        cosv[i] = math.cos(a);
        sinv[i] = math.sin(a);
    end
end

local function build_slices()
    local n = math.floor(cfg.slices);
    if (n < 8) then n = 8; elseif (n > 128) then n = 128; end
    cfg.slices = n;
    build_ring_table(n, tr.cosv, tr.sinv);

    local g = math.floor(cfg.geo_slices);
    if (g < 8) then g = 8; elseif (g > 96) then g = 96; end
    cfg.geo_slices = g;
    build_ring_table(g, tr.gcos, tr.gsin);
end


----------------------------------------------------------------------------------------------------
-- Math / projection
----------------------------------------------------------------------------------------------------
local function scale_alpha(color, s)
    local a = math.floor((color / 0x1000000) * s + 0.5);
    if (a < 0) then a = 0; elseif (a > 255) then a = 255; end
    return a * 0x1000000 + (color % 0x1000000);
end

local function fade(dist)
    if (not cfg.fade or tr.span <= 0.0) then
        return 1.0;
    end

    local t = (dist - tr.hub) / tr.span;
    if (t < 0.0) then t = 0.0; elseif (t > 1.0) then t = 1.0; end

    return 1.0 - (1.0 - REAR_FADE) * math.sqrt(t);
end

local function update_matrices()
    local r1, view = dev:GetTransform(C.D3DTS_VIEW);
    if (r1 ~= C.S_OK or view == nil) then return false; end

    local r2, proj = dev:GetTransform(C.D3DTS_PROJECTION);
    if (r2 ~= C.S_OK or proj == nil) then return false; end

    local r3, vp = dev:GetViewport();
    if (r3 ~= C.S_OK or vp == nil) then return false; end

    local m = tr.m;
    for r = 0, 3 do
        local a, b, c, d = view.m[r][0], view.m[r][1], view.m[r][2], view.m[r][3];
        for col = 0, 3 do
            m[r * 4 + col + 1] = a * proj.m[0][col] + b * proj.m[1][col] + c * proj.m[2][col] + d * proj.m[3][col];
        end
    end

    tr.vx, tr.vy, tr.vw, tr.vh = vp.X, vp.Y, vp.Width, vp.Height;

    return tr.vw > 0 and tr.vh > 0;
end

-- FFXI ground coords are x/z with height on the D3D y axis.
local function project(x, h, z)
    local m = tr.m;
    local cw = x * m[4] + h * m[8] + z * m[12] + m[16];
    if (cw <= 0.0001) then return nil; end

    local rhw = 1.0 / cw;
    local nx = (x * m[1] + h * m[5] + z * m[9] + m[13]) * rhw;
    local ny = (x * m[2] + h * m[6] + z * m[10] + m[14]) * rhw;
    if (nx < -4.0 or nx > 4.0 or ny < -4.0 or ny > 4.0) then return nil; end

    local nz = (x * m[3] + h * m[7] + z * m[11] + m[15]) * rhw;
    if (nz < 0.0) then nz = 0.0; elseif (nz > 1.0) then nz = 1.0; end

    return tr.vx + (nx + 1.0) * tr.vw * 0.5, tr.vy + (1.0 - ny) * tr.vh * 0.5, nz, rhw;
end

-- Ring vertices share one ground plane, so the constant height row of the
-- view-projection is folded in once by the caller instead of per point.
local function project_flat(x, z, kx, ky, kz, kw)
    local m = tr.m;
    local cw = x * m[4] + z * m[12] + kw;
    if (cw <= 0.0001) then return nil; end

    local rhw = 1.0 / cw;
    local nx = (x * m[1] + z * m[9] + kx) * rhw;
    local ny = (x * m[2] + z * m[10] + ky) * rhw;
    if (nx < -4.0 or nx > 4.0 or ny < -4.0 or ny > 4.0) then return nil; end

    local nz = (x * m[3] + z * m[11] + kz) * rhw;
    if (nz < 0.0) then nz = 0.0; elseif (nz > 1.0) then nz = 1.0; end

    return tr.vx + (nx + 1.0) * tr.vw * 0.5, tr.vy + (1.0 - ny) * tr.vh * 0.5, nz, rhw;
end

----------------------------------------------------------------------------------------------------
-- Range test
--------------------------------------------------------------------------------
-- Ashita's distance is centre-to-centre, so the real reach of a cast or a swing
-- is base range plus both hitboxes; a large NM is in range well past 20 yalms.
local function hitbox_of(ent, index)
    if (not cfg.range_hitbox or index == nil or index == 0) then return 0.0; end

    local h = ent:GetModelHitboxSize(index);
    if (type(h) ~= 'number' or h <= 0.0 or h > 20.0) then return 0.0; end

    return h;
end

-- The edge carries half a yalm of overlap so a target hovering on the boundary
-- doesn't strobe between filled and empty.
local function in_range(ent, index)
    if (not cfg.range) then return false; end

    local dsq = ent:GetDistance(index);
    if (type(dsq) ~= 'number' or dsq <= 0.0) then return false; end

    local near = cfg.range_base + hitbox_of(ent, tr.self_index) + hitbox_of(ent, index);
    if (tr.in_range[index]) then
        near = near + RANGE_HYST;
    end

    local inside = math.sqrt(dsq) <= near;
    tr.in_range[index] = inside;

    return inside;
end

--------------------------------------------------------------------------------
-- Batch
----------------------------------------------------------------------------------------------------
local function flush()
    if (tr.count >= 3) then
        dev:DrawPrimitiveUP(C.D3DPT_TRIANGLELIST, tr.count / 3, tr.verts, STRIDE);
    end
    tr.count = 0;
end

local function vert(x, y, z, rhw, color)
    local v = tr.verts[tr.count];
    v.x = x;
    v.y = y;
    v.z = z;
    v.rhw = rhw;
    v.color = color;
    tr.count = tr.count + 1;
end

local function room()
    if (tr.count + 6 > MAX_VERTS) then
        flush();
    end
end

----------------------------------------------------------------------------------------------------
-- Primitives
----------------------------------------------------------------------------------------------------
local function quad(ax, az, bx, bz, cx, cz, dx, dz, h, color)
    local x1, y1, z1, w1 = project(ax, h, az);
    if (x1 == nil) then return; end
    local x2, y2, z2, w2 = project(bx, h, bz);
    if (x2 == nil) then return; end
    local x3, y3, z3, w3 = project(cx, h, cz);
    if (x3 == nil) then return; end
    local x4, y4, z4, w4 = project(dx, h, dz);
    if (x4 == nil) then return; end

    local c1 = scale_alpha(color, fade(1.0 / w1));
    local c2 = scale_alpha(color, fade(1.0 / w2));
    local c3 = scale_alpha(color, fade(1.0 / w3));
    local c4 = scale_alpha(color, fade(1.0 / w4));

    room();
    vert(x1, y1, z1, w1, c1);
    vert(x2, y2, z2, w2, c2);
    vert(x3, y3, z3, w3, c3);
    vert(x1, y1, z1, w1, c1);
    vert(x3, y3, z3, w3, c3);
    vert(x4, y4, z4, w4, c4);
end

local function ground_ring(cx, cz, height, radius, band, color, cosv, sinv, slices)
    if (radius <= 0.0) then return; end

    local ri = math.max(radius - band * 0.5, 0.01);
    local ro = radius + band * 0.5;
    local h = height - CLEARANCE;
    local m = tr.m;

    local kx = h * m[5] + m[13];
    local ky = h * m[6] + m[14];
    local kz = h * m[7] + m[15];
    local kw = h * m[8] + m[16];

    local pix, piy, piz, piw, pic;
    local pox, poy, poz, pow, poc;
    local have_prev = false;

    for i = 0, slices do
        local ca, sa = cosv[i], sinv[i];

        local ix, iy, iz, iw = project_flat(cx + ri * ca, cz + ri * sa, kx, ky, kz, kw);
        local ox, oy, oz, ow = project_flat(cx + ro * ca, cz + ro * sa, kx, ky, kz, kw);

        if (ix == nil or ox == nil) then
            have_prev = false;
        else
            local ic = scale_alpha(color, fade(1.0 / iw));
            local oc = scale_alpha(color, fade(1.0 / ow));

            if (have_prev) then
                room();
                vert(pix, piy, piz, piw, pic);
                vert(pox, poy, poz, pow, poc);
                vert(ix, iy, iz, iw, ic);
                vert(ix, iy, iz, iw, ic);
                vert(pox, poy, poz, pow, poc);
                vert(ox, oy, oz, ow, oc);
            end

            pix, piy, piz, piw, pic = ix, iy, iz, iw, ic;
            pox, poy, poz, pow, poc = ox, oy, oz, ow, oc;
            have_prev = true;
        end
    end
end

-- Flat fan across the ring's interior. Drawn under the bands with the same
-- additive blend, so it reads as a faint wash rather than a solid plate.
local function ground_disc(cx, cz, height, radius, color, cosv, sinv, slices)
    if (radius <= 0.0) then return; end

    local h = height - CLEARANCE;
    local m = tr.m;

    local kx = h * m[5] + m[13];
    local ky = h * m[6] + m[14];
    local kz = h * m[7] + m[15];
    local kw = h * m[8] + m[16];

    local ox, oy, oz, ow = project_flat(cx, cz, kx, ky, kz, kw);
    if (ox == nil) then return; end
    local oc = scale_alpha(color, fade(1.0 / ow));

    local pex, pey, pez, pew, pec;
    local have_prev = false;

    for i = 0, slices do
        local ca, sa = cosv[i], sinv[i];
        local ex, ey, ez, ew = project_flat(cx + radius * ca, cz + radius * sa, kx, ky, kz, kw);

        if (ex == nil) then
            have_prev = false;
        else
            local ec = scale_alpha(color, fade(1.0 / ew));

            if (have_prev) then
                room();
                vert(ox, oy, oz, ow, oc);
                vert(pex, pey, pez, pew, pec);
                vert(ex, ey, ez, ew, ec);
            end

            pex, pey, pez, pew, pec = ex, ey, ez, ew, ec;
            have_prev = true;
        end
    end
end

local function facing_arrow(cx, cz, height, radius, aim, color)
    local fx, fz = math.cos(aim), math.sin(aim);
    local sx, sz = -fz, fx;
    local h = height - CLEARANCE;

    local function pt(fwd, side)
        return cx + fx * radius * fwd + sx * radius * side,
               cz + fz * radius * fwd + sz * radius * side;
    end

    local tx, tz = pt(ARROW_TIP, 0.0);
    local lx, lz = pt(ARROW_BASE, ARROW_HALF);
    local rx, rz = pt(ARROW_BASE, -ARROW_HALF);
    local nx, nz = pt(ARROW_NOTCH, 0.0);

    quad(tx, tz, lx, lz, nx, nz, nx, nz, h, color);
    quad(tx, tz, nx, nz, rx, rz, rx, rz, h, color);
end

-- Runes live in a local frame: u runs radially outward, v tangentially, so the
-- glyph stays upright relative to the ring wherever it sits.
local function ring_marker(cx, cz, height, radius, at, face, color)
    local seat = radius * (1.0 + INNER_SCALE) * 0.5;
    local scale = radius * RUNE_SIZE;
    local h = height - CLEARANCE;

    local px, pz = math.cos(at), math.sin(at);
    local ox, oz = math.cos(face), math.sin(face);
    local txv, tzv = -oz, ox;

    local bx = cx + px * seat;
    local bz = cz + pz * seat;

    for i = 1, #GLYPH do
        local g = GLYPH[i];
        local du = (g[3] - g[1]) * scale;
        local dv = (g[4] - g[2]) * scale;
        local len = math.sqrt(du * du + dv * dv);

        if (len > 0.0001) then
            local nu = -dv / len * RUNE_THICK * scale * 0.5;
            local nv = du / len * RUNE_THICK * scale * 0.5;

            local u0, v0 = g[1] * scale, g[2] * scale;
            local u1, v1 = g[3] * scale, g[4] * scale;

            quad(bx + ox * (u0 + nu) + txv * (v0 + nv), bz + oz * (u0 + nu) + tzv * (v0 + nv),
                 bx + ox * (u1 + nu) + txv * (v1 + nv), bz + oz * (u1 + nu) + tzv * (v1 + nv),
                 bx + ox * (u1 - nu) + txv * (v1 - nv), bz + oz * (u1 - nu) + tzv * (v1 - nv),
                 bx + ox * (u0 - nu) + txv * (v0 - nv), bz + oz * (u0 - nu) + tzv * (v0 - nv),
                 h, color);
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Device state
----------------------------------------------------------------------------------------------------
local RS_SAVE = {
    C.D3DRS_ALPHABLENDENABLE,
    C.D3DRS_SRCBLEND,
    C.D3DRS_DESTBLEND,
    C.D3DRS_ZENABLE,
    C.D3DRS_ZFUNC,
    C.D3DRS_ZWRITEENABLE,
    C.D3DRS_ALPHATESTENABLE,
    C.D3DRS_LIGHTING,
    C.D3DRS_CULLMODE,
    C.D3DRS_FOGENABLE,
};

local TSS_SAVE = {
    C.D3DTSS_COLOROP,
    C.D3DTSS_COLORARG1,
    C.D3DTSS_ALPHAOP,
    C.D3DTSS_ALPHAARG1,
};

local function begin_state()
    local s = tr.saved;

    for i = 1, #RS_SAVE do
        local _, v = dev:GetRenderState(RS_SAVE[i]);
        s.rs[i] = v;
    end

    for i = 1, #TSS_SAVE do
        local _, v = dev:GetTextureStageState(0, TSS_SAVE[i]);
        s.tss[i] = v;
    end

    local _, shader = dev:GetVertexShader();
    s.shader = shader;

    local _, tex = dev:GetTexture(0);
    s.tex = tex;

    dev:SetTexture(0, nil);
    dev:SetTextureStageState(0, C.D3DTSS_COLOROP, C.D3DTOP_SELECTARG1);
    dev:SetTextureStageState(0, C.D3DTSS_COLORARG1, C.D3DTA_DIFFUSE);
    dev:SetTextureStageState(0, C.D3DTSS_ALPHAOP, C.D3DTOP_SELECTARG1);
    dev:SetTextureStageState(0, C.D3DTSS_ALPHAARG1, C.D3DTA_DIFFUSE);

    dev:SetRenderState(C.D3DRS_ALPHABLENDENABLE, 1);
    dev:SetRenderState(C.D3DRS_SRCBLEND, C.D3DBLEND_SRCALPHA);
    dev:SetRenderState(C.D3DRS_DESTBLEND, C.D3DBLEND_ONE);
    -- Depth is opt-in: if Ashita's present-time render target has no depth
    -- surface bound, a Z-enabled draw fails outright and nothing appears.
    dev:SetRenderState(C.D3DRS_ZENABLE, cfg.depth and 1 or 0);
    dev:SetRenderState(C.D3DRS_ZFUNC, C.D3DCMP_LESSEQUAL);
    dev:SetRenderState(C.D3DRS_ZWRITEENABLE, 0);
    dev:SetRenderState(C.D3DRS_ALPHATESTENABLE, 0);
    dev:SetRenderState(C.D3DRS_LIGHTING, 0);
    dev:SetRenderState(C.D3DRS_CULLMODE, C.D3DCULL_NONE);
    dev:SetRenderState(C.D3DRS_FOGENABLE, 0);
    dev:SetVertexShader(bit.bor(C.D3DFVF_XYZRHW, C.D3DFVF_DIFFUSE));
end

local function end_state()
    local s = tr.saved;

    dev:SetTexture(0, s.tex);
    if (s.tex ~= nil) then
        s.tex:Release();
        s.tex = nil;
    end

    for i = 1, #TSS_SAVE do
        if (s.tss[i] ~= nil) then
            dev:SetTextureStageState(0, TSS_SAVE[i], s.tss[i]);
        end
    end

    for i = 1, #RS_SAVE do
        if (s.rs[i] ~= nil) then
            dev:SetRenderState(RS_SAVE[i], s.rs[i]);
        end
    end

    if (s.shader ~= nil) then
        dev:SetVertexShader(s.shader);
    end
end

----------------------------------------------------------------------------------------------------
-- Entity sampling
----------------------------------------------------------------------------------------------------
-- Flags0 bit 0x200 is the client's own "this slot is live and rendered" bit.
-- Without it, despawned mobs keep answering with stale names and coordinates,
-- which is how rings end up floating over empty ground.
local function is_rendered(ent, index)
    if (index == nil or index == 0 or index >= MAX_INDEX) then return false; end
    if (bit.band(ent:GetRenderFlags0(index), 0x200) == 0) then return false; end
    return ent:GetActorPointer(index) ~= 0;
end

local function ring_radius(ent, index)
    local flags = ent:GetSpawnFlags(index);

    if (bit.band(flags, 0x01) ~= 0) then
        return PLAYER_FOOT * cfg.scale;
    end

    local extent = ent:GetModelSize(index) or 0.0;
    if (extent <= 0.05) then
        extent = ent:GetModelHitboxSize(index) or 0.0;
    end

    if (extent ~= extent or extent <= 0.05) then
        return PLAYER_FOOT * cfg.scale;
    end

    if (extent > HUMANOID) then
        extent = HUMANOID + math.sqrt(extent - HUMANOID) * 0.62;
    end

    local foot = extent * 0.5 * cfg.scale;
    if (foot < 0.45) then foot = 0.45; elseif (foot > 8.0) then foot = 8.0; end

    return foot;
end

-- Returns x, height, z, heading (nil heading when unknown).
local function ring_position(ent, index)
    local ptr = ent:GetActorPointer(index);
    local etype = ent:GetType(index);

    if (ptr ~= nil and ptr ~= 0) then
        local base = (etype == 3) and OFF_OBJ or OFF_POS;
        local x = ashita.memory.read_float(ptr + base);
        local h = ashita.memory.read_float(ptr + base + 0x04);
        local z = ashita.memory.read_float(ptr + base + 0x08);

        if (x == x and h == h and z == z and math.abs(x) < 10000.0 and math.abs(z) < 10000.0) then
            local aim = ashita.memory.read_float(ptr + OFF_HEADING);
            if (aim ~= aim) then aim = nil; end
            return x, h, z, aim;
        end
    end

    -- Unrendered entities: fall back to the entity record. Ashita's local
    -- position is x / north / height, so y and z swap on the way in.
    local x = ent:GetLocalPositionX(index);
    local h = ent:GetLocalPositionZ(index);
    local z = ent:GetLocalPositionY(index);

    if (x ~= x or h ~= h or z ~= z) then return nil; end

    return x, h, z, ent:GetLocalPositionYaw(index);
end

local function ring_pulse()
    local phase = (os.clock() % PULSE_SECS) / PULSE_SECS;
    return 1.0 - PULSE_DEPTH * 0.5 * (1.0 - math.cos(phase * TWO_PI));
end

local function faction_color(ent, index)
    local flags = ent:GetSpawnFlags(index);

    -- A charmed mob keeps its mob flag, so party membership is checked first.
    if (geo.party_index[index]) then return COLOR_PC; end
    if (bit.band(flags, 0x01) ~= 0) then return COLOR_PC; end
    if (bit.band(flags, 0x10) ~= 0) then return COLOR_MOB; end

    local claim = ent:GetClaimStatus(index);
    if (type(claim) == 'number' and claim ~= 0) then return COLOR_MOB; end

    return COLOR_NPC;
end

-- Fade hub: everything on this ring fades on the side away from the camera.
local function set_hub(x, h, z, radius)
    local _, _, _, hrhw = project(x, h - CLEARANCE, z);
    if (hrhw ~= nil and hrhw > 0.0) then
        tr.hub = 1.0 / hrhw;
        tr.span = radius;
    else
        tr.span = 0.0;
    end
end

-- Pass 'fill' runs under normal alpha blending, pass 'band' under additive, so
-- the two are drawn in separate sweeps rather than interleaved per ring.
local function draw_ring(index, pass)
    if (index == nil or index == 0) then return; end

    local ent = tr.ent;
    if (not is_rendered(ent, index)) then return; end

    local x, h, z, aim = ring_position(ent, index);
    if (x == nil) then return; end

    local radius = ring_radius(ent, index);
    local color = faction_color(ent, index);
    local pulse = tr.pulse;

    set_hub(x, h, z, radius);

    if (pass == 'fill') then
        -- Green NPCs report no usable hitbox, so the range edge is unreliable
        -- for them; they always fill rather than reading as out of range.
        if (color == COLOR_NPC or in_range(ent, index)) then
            ground_disc(x, z, h, radius * FILL_SCALE, scale_alpha(color, cfg.range_fill * pulse), tr.cosv, tr.sinv, cfg.slices);
        end
        return;
    end

    local bright = scale_alpha(color, 0.95 * pulse);
    local soft = scale_alpha(color, 0.55 * pulse);

    -- Glow sits in the channel between the two rings, not on the bright one.
    local band_in = radius * INNER_SCALE;
    local band_mid = (band_in + radius) * 0.5;

    ground_ring(x, z, h, band_mid, (radius - band_in) * GLOW_BAND, scale_alpha(color, GLOW_ALPHA * pulse), tr.cosv, tr.sinv, cfg.slices);
    ground_ring(x, z, h, radius, radius * MAIN_BAND, bright, tr.cosv, tr.sinv, cfg.slices);
    ground_ring(x, z, h, band_in, radius * INNER_BAND, soft, tr.cosv, tr.sinv, cfg.slices);

    -- FFXI's ground heading mirrors across the east/west axis in ring space.
    if (aim ~= nil) then
        local face = cfg.flip and aim or -aim;
        if (cfg.arrow) then
            facing_arrow(x, z, h, radius, face, bright);
        end
        if (cfg.runes) then
            ring_marker(x, z, h, radius, face + HALF_PI, face, bright);
            ring_marker(x, z, h, radius, face - HALF_PI, face, bright);
        end
    end
end

--------------------------------------------------------------------------------
-- GEO bubble rings -- entity helpers
--------------------------------------------------------------------------------
local function entity()
    return AshitaCore:GetMemoryManager():GetEntity();
end

local function ent_name(ent, index)
    local n = ent:GetName(index);
    if (n == nil or n == '') then return nil; end
    return n;
end

local function is_luopan(ent, index)
    if (index == nil or index == 0) then return false; end
    local n = ent_name(ent, index);
    if (n == nil) then return false; end
    return n:lower():find('luopan', 1, true) ~= nil;
end

local function is_alive(ent, index)
    if (ent:GetHPPercent(index) == 0) then return false; end
    local st = ent:GetStatus(index);
    return st ~= 2 and st ~= 3;
end

local function is_mob(ent, index)
    if (not is_rendered(ent, index)) then return false; end

    local flags = ent:GetSpawnFlags(index);
    if (bit.band(flags, 0x10) == 0) then return false; end
    if (bit.band(flags, 0x01) ~= 0) then return false; end

    if (geo.party_index[index]) then return false; end
    if (ent_name(ent, index) == nil) then return false; end
    if (is_luopan(ent, index)) then return false; end

    -- An entity slot the client is not actually tracking reports no distance.
    local d = ent:GetDistance(index);
    if (type(d) ~= 'number' or d <= 0.0) then return false; end

    return is_alive(ent, index);
end

-- Server-side position; used for bubble distance, not for drawing.
local function local_pos(ent, index)
    return ent:GetLocalPositionX(index), ent:GetLocalPositionZ(index), ent:GetLocalPositionY(index);
end

-- Geo auras reach the target's hitbox edge on the ground plane, with a hard
-- cut-off (GEO-HUD 2.0.6-2.1.0). The client holds the server-sent hitbox for
-- PCs and mobs alike.
local function in_aura(ent, origin, index, radius)
    local ox, _, oz = local_pos(ent, origin);
    local tx, _, tz = local_pos(ent, index);
    local dx, dz = ox - tx, oz - tz;
    local d = math.sqrt(dx * dx + dz * dz);

    local h = ent:GetModelHitboxSize(index);
    if (type(h) ~= 'number' or h ~= h or h < 0.0 or h > 20.0) then h = 0.0; end

    return d <= radius + h, d;
end

local function dist3(ent, a, b)
    local ax, ah, az = local_pos(ent, a);
    local bx, bh, bz = local_pos(ent, b);
    local dx, dh, dz = ax - bx, ah - bh, az - bz;
    return math.sqrt(dx * dx + dh * dh + dz * dz);
end

local function index_of(id)
    if (id == nil or id == 0) then return nil; end

    local hit = geo.id_index[id];
    if (hit ~= nil) then return hit; end

    local ent = entity();

    -- NPC/mob server ids carry the entity index in the low 12 bits; verified
    -- against GetServerId, so a wrong guess just falls through to the scan.
    local guess = bit.band(id, 0xFFF);
    if (guess < MAX_INDEX and ent:GetServerId(guess) == id) then
        geo.id_index[id] = guess;
        return guess;
    end

    -- Full scan = 0x900 FFI calls. An id that missed within the last second is
    -- not rescanned (every foreign 0x028 actor/target used to cost one).
    local now = os.clock();
    local miss = geo.id_miss[id];
    if (miss ~= nil and now - miss < 1.0) then return nil; end

    for i = 0, MAX_INDEX - 1 do
        if (ent:GetServerId(i) == id) then
            geo.id_index[id] = i;
            geo.id_miss[id] = nil;
            return i;
        end
    end

    if (geo.id_miss_n >= 1024) then
        geo.id_miss = { };
        geo.id_miss_n = 0;
        miss = nil;
    end
    if (miss == nil) then geo.id_miss_n = geo.id_miss_n + 1; end
    geo.id_miss[id] = now;
    return nil;
end

local function has_buff(id)
    local buffs = AshitaCore:GetMemoryManager():GetPlayer():GetBuffs();
    if (buffs == nil) then return false; end

    -- The buff array surfaces as either a 0-based cdata block or a 1-based
    -- table depending on the binding, so both ends are checked.
    for i = 0, 32 do
        if (buffs[i] == id) then return true; end
    end

    return false;
end

local function spell_name(id)
    local res = AshitaCore:GetResourceManager():GetSpellById(id);
    if (res == nil) then return nil; end

    for i = 1, 3 do
        local ok, n = pcall(function () return res.Name[i]; end);
        if (ok and type(n) == 'string' and #n > 0) then return n; end
    end

    return nil;
end

local function spell_element(id)
    local res = AshitaCore:GetResourceManager():GetSpellById(id);
    if (res == nil) then return nil; end

    local ok, e = pcall(function () return res.Element; end);
    if (ok and type(e) == 'number') then return e; end

    return nil;
end

--------------------------------------------------------------------------------
-- GEO bubble rings -- bubble + enmity state
--------------------------------------------------------------------------------
-- Geo-Regen / Indi-Fury and friends sit on allies; Geo-Frailty and friends sit
-- on enemies. The suffix decides which side the bubble rings.
local function colure_is_buff(name)
    if (type(name) ~= 'string') then return nil; end

    local suffix = name:match('^[Gg]eo%-(.+)$') or name:match('^[Ii]ndi%-(.+)$');
    if (suffix == nil) then return nil; end

    suffix = suffix:gsub('%s+', '');
    if (COLURE_BUFF[suffix]) then return true; end
    if (COLURE_DEBUFF[suffix]) then return false; end

    return nil;
end

local function is_cure_name(name)
    if (type(name) ~= 'string') then return false; end
    return name:sub(1, 4) == 'Cure' or name:sub(1, 4) == 'Cura' or name == 'Full Cure';
end

local function caster_widened(actor_id)
    local party = AshitaCore:GetMemoryManager():GetParty();
    local self_index = party:GetMemberTargetIndex(0);
    local self_id = (self_index ~= 0) and entity():GetServerId(self_index) or 0;

    if (actor_id == nil or actor_id == self_id) then
        return has_buff(BUFF_WIDENED);
    end

    return geo.widened[actor_id] == true;
end

local function widened_radius(active)
    return active and (cfg.geo_radius * 2.0) or cfg.geo_radius;
end

local function current_radius()
    return widened_radius(geo.wide_luopan);
end

local function refresh_party(ent)
    local party = AshitaCore:GetMemoryManager():GetParty();

    table.clear(geo.party_index);
    table.clear(geo.party_ids);
    table.clear(geo.party6);
    for i = 0, 17 do
        if (party:GetMemberIsActive(i) ~= 0) then
            local idx = party:GetMemberTargetIndex(i);
            if (idx ~= 0) then
                geo.party_index[idx] = true;
                if (i <= 5) then geo.party6[idx] = true; end
                local id = ent:GetServerId(idx);
                if (id ~= 0) then
                    geo.id_index[id] = idx;
                    geo.party_ids[id] = true;
                end
            end
        end
    end
end

-- Luopan is the geomancer's pet: ours first, then any party member's, then the
-- last one we saw while it is still alive.
local function resolve_bubble(ent)
    local party = AshitaCore:GetMemoryManager():GetParty();
    local self_index = party:GetMemberTargetIndex(0);
    local self_id = (self_index ~= 0) and ent:GetServerId(self_index) or 0;

    if (self_index ~= 0) then
        local pet = ent:GetPetTargetIndex(self_index);
        if (is_luopan(ent, pet) and is_alive(ent, pet)) then
            geo.geo_id = self_id;
            geo.luopan = pet;
            return pet;
        end
    end

    for i = 1, 5 do
        if (party:GetMemberIsActive(i) ~= 0) then
            local idx = party:GetMemberTargetIndex(i);
            if (idx ~= 0) then
                local pet = ent:GetPetTargetIndex(idx);
                if (is_luopan(ent, pet) and is_alive(ent, pet)) then
                    geo.geo_id = ent:GetServerId(idx);
                    geo.luopan = pet;
                    return pet;
                end
            end
        end
    end

    if (geo.luopan ~= nil and is_luopan(ent, geo.luopan) and is_alive(ent, geo.luopan)) then
        return geo.luopan;
    end

    geo.luopan = nil;
    if (geo.geo_id == nil and AshitaCore:GetMemoryManager():GetPlayer():GetMainJob() == GEO_JOB) then
        geo.geo_id = self_id;
    end

    return nil;
end

local function auto_tagged()
    local zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    return AUTO_TAG_ZONE[zone] == true;
end

local function tag_mob(id)
    if (id == nil or id == 0) then return; end

    local ent = entity();
    local index = index_of(id);
    if (index ~= nil and ent:GetServerId(index) == id) then
        local flags = ent:GetSpawnFlags(index);
        if (bit.band(flags, 0x01) ~= 0 or bit.band(flags, 0x10) == 0) then return; end
        if (geo.party_index[index] or is_luopan(ent, index)) then return; end
    end

    geo.tagged[id] = os.clock();
    geo.missing[id] = nil;
end

local function untag_mob(id)
    geo.tagged[id] = nil;
    geo.missing[id] = nil;
    geo.dying[id] = nil;

    for _, mobs in pairs(geo.hate) do
        mobs[id] = nil;
    end
end

local function note_hate(ally_id, mob_id)
    if (ally_id == nil or mob_id == nil or ally_id == 0 or mob_id == 0) then return; end

    local list = geo.hate[ally_id];
    if (list == nil) then
        list = { };
        geo.hate[ally_id] = list;
    end

    list[mob_id] = true;
end

local function tag_from_ally_hate(ally_id)
    local list = geo.hate[ally_id];
    if (list == nil) then return; end

    for mob_id in pairs(list) do
        tag_mob(mob_id);
    end
end

-- A single 0-HP frame is common on entity updates, so both death and vanishing
-- are confirmed over time before a tag is dropped.
local function prune_tags()
    local ent = entity();
    local now = os.clock();

    for id in pairs(geo.tagged) do
        local index = index_of(id);
        if (index == nil or ent:GetServerId(index) ~= id) then
            geo.dying[id] = nil;
            geo.id_index[id] = nil;
            if (geo.missing[id] == nil) then
                geo.missing[id] = now;
            elseif (now - geo.missing[id] > GONE_GRACE) then
                untag_mob(id);
            end
        elseif (not is_alive(ent, index)) then
            if (geo.dying[id] == nil) then
                geo.dying[id] = now;
            elseif (now - geo.dying[id] > DEAD_CONFIRM) then
                untag_mob(id);
            end
        else
            geo.missing[id] = nil;
            geo.dying[id] = nil;
        end
    end

    for ally_id, mobs in pairs(geo.hate) do
        for mob_id in pairs(mobs) do
            if (geo.tagged[mob_id] == nil) then
                local index = index_of(mob_id);
                if (index == nil or ent:GetServerId(index) ~= mob_id) then
                    geo.id_index[mob_id] = nil;
                    if (geo.missing[mob_id] == nil) then
                        geo.missing[mob_id] = now;
                    elseif (now - geo.missing[mob_id] > GONE_GRACE) then
                        mobs[mob_id] = nil;
                        geo.missing[mob_id] = nil;
                    end
                elseif (not is_alive(ent, index)) then
                    mobs[mob_id] = nil;
                    geo.missing[mob_id] = nil;
                else
                    geo.missing[mob_id] = nil;
                end
            end
        end
        if (next(mobs) == nil) then
            geo.hate[ally_id] = nil;
        end
    end
end

--------------------------------------------------------------------------------
-- GEO bubble rings -- ring list
--------------------------------------------------------------------------------
local function push_ring(ent, index, green)
    if (geo.count >= cfg.geo_cap) then return; end

    geo.count = geo.count + 1;
    local slot = geo.rings[geo.count];
    if (slot == nil) then
        slot = { };
        geo.rings[geo.count] = slot;
    end

    slot.index = index;
    slot.id = ent:GetServerId(index);
    slot.radius = ring_radius(ent, index);
    slot.color = green and GEO_GREEN or GEO_RED;
end

-- Buff bubbles ring the geomancer's party instead of the enemies around it.
-- origin is the luopan for Geo-, or the carrier for Indi-/Entrust.
local function ring_party_near(ent, origin, radius, marked)
    local party = AshitaCore:GetMemoryManager():GetParty();
    local list = { };

    for i = 0, 5 do
        if (party:GetMemberIsActive(i) ~= 0) then
            local index = party:GetMemberTargetIndex(i);
            if (index ~= 0 and not is_luopan(ent, index) and is_alive(ent, index)) then
                local id = ent:GetServerId(index);
                local within, dist = in_aura(ent, origin, index, radius);
                if (within) then
                    if (not marked[index]) then
                        marked[index] = true;
                        list[#list + 1] = { index = index, dist = dist, id = id };
                    end
                end
            end
        end
    end

    table.sort(list, function (a, b)
        if (a.dist ~= b.dist) then return a.dist < b.dist; end
        return a.id < b.id;
    end);

    for i = 1, #list do
        push_ring(ent, list[i].index, true);
    end
end

local function build_buff_rings(ent, luopan, radius, marked)
    ring_party_near(ent, luopan, radius, marked);
end

-- Indi- sits on the caster, Entrust on its target; neither follows the luopan.
local function build_indi_rings(ent, marked)
    if (geo.indi_id ~= nil and geo.indi_buff) then
        local index = index_of(geo.indi_id);
        if (index ~= nil and geo.party6[index] and is_alive(ent, index)) then
            ring_party_near(ent, index, widened_radius(geo.wide_indi), marked);
        end
    end

    for id, e in pairs(geo.entrust) do
        if (e.buff) then
            local index = index_of(id);
            if (index ~= nil and geo.party6[index] and is_alive(ent, index)) then
                ring_party_near(ent, index, widened_radius(e.wide), marked);
            end
        end
    end
end

-- Debuff bubbles ring only mobs inside the bubble: green when the geomancer
-- already has enmity on them, red when it still needs a tag.
local function build_debuff_rings(ent, luopan, radius)
    geo.auto_tag = auto_tagged();
    local list = { };
    local scan = cfg.geo_scan;

    for index = 0, MAX_INDEX - 1 do
        if (is_mob(ent, index)) then
            local id = ent:GetServerId(index);
            if (id ~= 0) then
                geo.id_index[id] = index;
                if (dist3(ent, luopan, index) <= scan) then
                    local within, dist = in_aura(ent, luopan, index, radius);
                    if (within) then
                        list[#list + 1] = {
                            index = index,
                            id = id,
                            green = geo.tagged[id] ~= nil or geo.auto_tag,
                            dist = dist,
                        };
                    end
                end
            end
        end
    end

    table.sort(list, function (a, b)
        if (a.green ~= b.green) then return a.green and not b.green; end
        if (a.dist ~= b.dist) then return a.dist < b.dist; end
        return a.id < b.id;
    end);

    for i = 1, #list do
        push_ring(ent, list[i].index, list[i].green);
    end
end

-- true = Colure Active seen, false = seen without it, nil = no data for this carrier.
local function colure_state(ent, id, cast_at, now)
    if (now - cast_at < COLURE_GRACE) then return true; end

    local self_index = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
    if (self_index ~= 0 and ent:GetServerId(self_index) == id) then
        return has_buff(BUFF_COLURE);
    end

    return geo.colure[id];
end

function dur.self_id()
    local index = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
    if (index == 0) then return 0; end
    return entity():GetServerId(index);
end

function dur.jp_rank()
    local rank = dur.jp or cfg.geo_indi_jp;
    if (type(rank) ~= 'number' or rank < 0) then return 0; end
    return rank;
end

function dur.total(flat, pct)
    return (INDI_BASE + flat + dur.jp_rank() * INDI_JP_STEP) * (1.0 + pct / 100.0);
end

function dur.duration()
    if (dur.best >= 0) then return dur.best; end
    return dur.total(0, 0);
end

-- Gear seconds come from the client's own item description text.
function dur.desc_flat(id)
    local res = AshitaCore:GetResourceManager():GetItemById(id);
    if (res == nil) then return 0, 0; end

    local text = nil;
    for i = 1, 3 do
        local ok, d = pcall(function () return res.Description[i]; end);
        if (ok and type(d) == 'string' and #d > 0) then text = d; break; end
    end
    if (text == nil) then return 0, 0; end

    local flat, pct = 0, 0;
    for n, mark in text:lower():gmatch('indicolure[^%+\r\n]-duration[%s"]*%+(%d+)(%%?)') do
        if (mark == '%') then
            pct = pct + tonumber(n);
        else
            flat = flat + tonumber(n);
        end
    end
    return flat, pct;
end

-- Oseem-style augments: 11-bit id, 5-bit value, value + 1 for this id.
function dur.augment_pct(extra)
    if (type(extra) ~= 'string' or #extra < 12) then return 0; end

    local kind, flag = extra:byte(1), extra:byte(2);
    if (kind ~= 2 and kind ~= 3) then return 0; end
    if (bit.band(flag, 0xA8) ~= 0) then return 0; end

    local count = (bit.band(flag, 0x40) ~= 0) and 4 or 5;
    local pct = 0;
    for i = 1, count do
        local lo, hi = extra:byte(i * 2 + 1, i * 2 + 2);
        local word = lo + hi * 256;
        if (bit.band(word, 0x7FF) == AUG_INDI_DUR) then
            pct = pct + bit.rshift(word, 11) + 1;
        end
    end
    return pct;
end

function dur.item_bonus(item)
    local extra = (type(item.Extra) == 'string') and item.Extra or '';
    local key = tostring(item.Id) .. extra;
    local hit = dur.cache[key];
    if (hit == nil) then
        local flat, pct = dur.desc_flat(item.Id);
        hit = { flat, pct + dur.augment_pct(extra) };
        dur.cache[key] = hit;
    end
    return hit[1], hit[2];
end

function dur.equip(index, slot, container)
    if (index == nil or slot == nil or container == nil or slot > 15) then return; end
    dur.live[slot] = { container, index, os.clock() };
end

function dur.slot_item(inv, slot, now)
    local container, index;
    local e = dur.live[slot];
    if (e ~= nil and now - e[3] <= LIVE_TTL) then
        container, index = e[1], e[2];
    else
        local eq = inv:GetEquippedItem(slot);
        if (eq == nil) then return nil; end
        index = bit.band(eq.Index, 0xFF);
        container = bit.rshift(bit.band(eq.Index, 0xFF00), 8);
    end
    if (index == 0) then return nil; end

    local item = inv:GetContainerItem(container, index);
    if (item == nil or item.Id == 0 or item.Count == 0) then return nil; end
    return item;
end

function dur.push()
    if (dur.mode == 'self' and dur.self_at ~= nil) then
        dur.self_exp = dur.self_at + dur.best;
    elseif (dur.mode == 'entrust' and dur.land_id ~= nil and dur.land_at ~= nil) then
        local e = geo.entrust[dur.land_id];
        if (e ~= nil) then e.exp = dur.land_at + dur.best; end
    end
end

function dur.sample()
    if (dur.until_at == nil) then return; end

    local now = os.clock();
    if (now > dur.until_at) then
        dur.until_at = nil;
        return;
    end

    local inv = AshitaCore:GetMemoryManager():GetInventory();
    local flat, pct = 0, 0;
    for slot = 0, 15 do
        local item = dur.slot_item(inv, slot, now);
        if (item ~= nil) then
            local f, p = dur.item_bonus(item);
            flat = flat + f;
            pct = pct + p;
        end
    end

    local total = dur.total(flat, pct);
    if (total > dur.best) then
        dur.best, dur.flat, dur.pct = total, flat, pct;
        dur.push();
    end
end

function dur.begin()
    dur.until_at = os.clock() + SAMPLE_WINDOW;
    dur.best, dur.flat, dur.pct = -1, 0, 0;
    dur.sample();
end

function dur.landed()
    local now = os.clock();
    if (dur.until_at == nil) then
        dur.best, dur.flat, dur.pct = -1, 0, 0;
    end
    dur.until_at = now + LAND_TAIL;
    return now;
end

function dur.clear()
    dur.live = { };
    dur.until_at = nil;
    dur.self_at = nil;
    dur.self_exp = nil;
    dur.land_id = nil;
    dur.land_at = nil;
    dur.mode = nil;
end

local function prune_colures(ent)
    local now = os.clock();

    if (geo.indi_id ~= nil) then
        local up = colure_state(ent, geo.indi_id, geo.indi_at, now);
        local timed_out = geo.indi_id == dur.self_id() and dur.self_exp ~= nil and now > dur.self_exp;
        if (timed_out or up == false or (up == nil and now - geo.indi_at > ENTRUST_LIFE)) then
            geo.indi_id = nil;
            geo.indi_buff = false;
        end
    end

    for id, e in pairs(geo.entrust) do
        local drop;
        if (e.exp ~= nil) then
            -- Our own cast: the timer always ends it. Trusts do not reliably drop
            -- Colure Active in 0x076, so only PCs also need the buff present.
            drop = now > e.exp or (not e.npc and colure_state(ent, id, e.at, now) == false);
        else
            local up = colure_state(ent, id, e.at, now);
            drop = up == false or (up == nil and now - e.at > ENTRUST_LIFE);
        end
        if (drop) then
            geo.entrust[id] = nil;
        end
    end
end

-- Boundary circles: the luopan's bubble, the Indi carrier's, and one per
-- Entrust. Radius comes from the Widened flag captured when each was cast.
local function push_bubble(index, radius, element)
    if (index == nil or index == 0 or radius == nil or radius <= 0.0) then return; end

    geo.bubble_n = geo.bubble_n + 1;
    local slot = geo.bubbles[geo.bubble_n];
    if (slot == nil) then
        slot = { };
        geo.bubbles[geo.bubble_n] = slot;
    end

    slot.index = index;
    slot.id = entity():GetServerId(index);
    slot.radius = radius;
    slot.color = ELEMENT_COLOR[element or 6] or ELEMENT_COLOR[6];
end

local function build_bubbles(ent, luopan)
    geo.bubble_n = 0;
    if (not cfg.geo_bubble) then return; end

    if (luopan ~= nil) then
        push_bubble(luopan, current_radius(), geo.element);
    end

    if (geo.indi_id ~= nil) then
        local index = index_of(geo.indi_id);
        if (index ~= nil and is_alive(ent, index)) then
            push_bubble(index, widened_radius(geo.wide_indi), geo.indi_elem);
        else
            geo.indi_id = nil;
        end
    end

    for id, e in pairs(geo.entrust) do
        local index = index_of(id);
        if (index ~= nil and is_alive(ent, index)) then
            push_bubble(index, widened_radius(e.wide), e.element);
        end
    end
end

local function update_geo()
    local now = os.clock();
    if (now < geo.next_tick) then return; end
    geo.next_tick = now + GEO_TICK;

    geo.count = 0;
    geo.bubble_n = 0;

    local ent = entity();
    refresh_party(ent);

    local job = AshitaCore:GetMemoryManager():GetPlayer():GetMainJob();
    if (job ~= 0) then
        if (geo.job ~= nil and job ~= geo.job) then
            geo.tagged = { };
            geo.hate = { };
            geo.missing = { };
            geo.dying = { };
            geo.spell = nil;
            geo.element = nil;
            geo.is_buff = false;
            geo.luopan = nil;
            geo.wide_luopan = false;
            dur.live = { };
        end
        geo.job = job;
    end

    if (not cfg.geo) then
        geo.status = 'off';
        return;
    end

    prune_tags();

    local luopan = resolve_bubble(ent);
    local radius = current_radius();
    prune_colures(ent);
    build_bubbles(ent, luopan);

    local marked = { };
    if (cfg.geo_buffs) then
        build_indi_rings(ent, marked);
    end

    -- Mob rings only exist while a luopan does; tags are kept for the next one.
    if (luopan == nil) then
        geo.status = (geo.count > 0) and 'indi buff' or 'no bubble';
        return;
    end

    if (geo.is_buff) then
        if (cfg.geo_buffs) then
            build_buff_rings(ent, luopan, radius, marked);
        end
        geo.status = ('buff %s r%.1f'):fmt(geo.spell or 'bubble', radius);
    else
        build_debuff_rings(ent, luopan, radius);
        geo.status = ('%s r%.1f'):fmt(geo.spell or 'bubble', radius);
    end
end

local function draw_geo_rings(pass)
    if (not cfg.geo or (geo.count == 0 and geo.bubble_n == 0)) then return; end

    local ent = tr.ent;
    local pulse = tr.pulse;

    -- Bubble boundaries use the finer slice table; they are wide enough that a
    -- 24-segment circle would read as a polygon.
    if (pass == 'fill') then
        for i = 1, geo.bubble_n do
            local b = geo.bubbles[i];
            if (is_rendered(ent, b.index) and ent:GetServerId(b.index) == b.id) then
                local x, h, z = ring_position(ent, b.index);
                if (x ~= nil) then
                    set_hub(x, h, z, b.radius);
                    ground_ring(x, z, h, b.radius, b.radius * BUBBLE_BAND,
                        scale_alpha(b.color, BUBBLE_ALPHA * pulse), tr.cosv, tr.sinv, cfg.slices);
                end
            end
        end
    end

    for i = 1, geo.count do
        local ring = geo.rings[i];

        -- Revalidated every frame: the scan tick is 4Hz, and a mob that dies or
        -- despawns between ticks must not leave a ring hanging in mid-air.
        if (is_rendered(ent, ring.index)
            and ent:GetServerId(ring.index) == ring.id
            and is_alive(ent, ring.index)) then

            local x, h, z = ring_position(ent, ring.index);

            if (x ~= nil) then
                local radius = ring.radius;
                set_hub(x, h, z, radius);

                if (pass == 'fill') then
                    if (cfg.range_geo and in_range(ent, ring.index)) then
                        ground_disc(x, z, h, radius * FILL_SCALE,
                            scale_alpha(ring.color, cfg.range_fill * pulse), tr.gcos, tr.gsin, cfg.geo_slices);
                    end
                else
                    ground_ring(x, z, h, radius * GEO_GLOW_MUL, radius * GEO_GLOW_BAND,
                        scale_alpha(ring.color, GLOW_ALPHA * pulse), tr.gcos, tr.gsin, cfg.geo_slices);
                    ground_ring(x, z, h, radius, radius * GEO_MAIN_BAND,
                        scale_alpha(ring.color, 0.95 * pulse), tr.gcos, tr.gsin, cfg.geo_slices);
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- GEO bubble rings -- packets
--------------------------------------------------------------------------------
-- 0x028 action packet (XiPackets GP_SERV_COMMAND_BATTLE2, Reversing.md).
-- Read straight off data_raw: the bitreader lib hex-encoded and re-parsed the
-- whole packet for every action in the zone. Only actor, category, param, the
-- target ids and the first result value are used, so each result is skipped by
-- its fixed width (miss 3, kind 2, sub_kind 12, info 5, scale 5, value 17,
-- message 10, bit 31 = 85) plus the optional proc (37) and react (34) blocks.
local function parse_action(e)
    local raw = e.data_raw;
    local max = e.size * 8;
    if (max < 150) then return nil; end

    local act = { };
    act.actor = unpack_bits(raw, 0, 40, 32);
    local target_count = unpack_bits(raw, 0, 72, 6);
    act.category = unpack_bits(raw, 0, 82, 4);
    act.param = unpack_bits(raw, 0, 86, 32);

    local pos = 150;                    -- past info (32)
    act.targets = { };
    for t = 1, target_count do
        if (pos + 36 > max) then return nil; end
        act.targets[t] = unpack_bits(raw, 0, pos, 32);
        local results = unpack_bits(raw, 0, pos + 32, 4);
        pos = pos + 36;

        for _ = 1, results do
            if (pos + 87 > max) then return nil; end
            if (act.value == nil) then act.value = unpack_bits(raw, 0, pos + 27, 17); end
            pos = pos + 85;

            local has_proc = unpack_bits(raw, 0, pos, 1);
            pos = pos + 1;
            if (has_proc ~= 0) then pos = pos + 37; end

            if (pos + 1 > max) then return nil; end
            local has_react = unpack_bits(raw, 0, pos, 1);
            pos = pos + 1;
            if (has_react ~= 0) then pos = pos + 34; end
        end
    end

    return act;
end

-- Remember which mobs already have a given ally on their hate list, so a Cure
-- on that ally can tag the right mobs. Party membership is a server-id set
-- lookup, so most zone traffic (actor neither ally nor mob) costs no index scan
-- and a mob's targets are never resolved to indexes at all.
local function record_party_hate(ent, act)
    local actor_is_ally = geo.party_ids[act.actor] == true;
    if (actor_is_ally) then
        for i = 1, #act.targets do
            local tid = act.targets[i];
            local tindex = index_of(tid);
            if (tindex ~= nil and is_mob(ent, tindex)) then
                note_hate(act.actor, tid);
            end
        end
        return;
    end

    local actor_index = index_of(act.actor);
    if (actor_index == nil or not is_mob(ent, actor_index)) then return; end

    for i = 1, #act.targets do
        local tid = act.targets[i];
        if (geo.party_ids[tid]) then
            note_hate(tid, act.actor);
        end
    end
end

local function apply_action_tags(act)
    local ent = entity();
    record_party_hate(ent, act);

    local spell_id = nil;
    if (act.category == 4) then
        spell_id = act.param;
    elseif (act.category == 8 and act.param == MAGIC_GEO_START) then
        spell_id = act.value;
    end
    local name = (spell_id ~= nil) and spell_name(spell_id) or nil;
    local is_geo_spell = (name ~= nil) and (name:sub(1, 4) == 'Geo-');
    local is_indi = (name ~= nil) and (name:sub(1, 5) == 'Indi-');
    local now = os.clock();

    -- Only Indi- casts and Geomancy interrupts read 'ours'; skip the lookup otherwise.
    local ours = (is_indi or (act.category == 8 and act.param == MAGIC_GEO_INTERRUPT))
        and act.actor == dur.self_id();

    -- Category 8 is the start of the cast. Widened Compass is sampled here
    -- because the bubble keeps whatever radius it was born with, even if the
    -- buff falls off a second later.
    if (act.category == 8) then
        if (is_geo_spell or is_indi) then
            geo.pending = caster_widened(act.actor);
            geo.pending_by = act.actor;
            geo.pending_at = now;
            if (is_indi and ours) then
                local tid = act.targets[1];
                if (tid ~= nil and tid ~= 0 and tid ~= act.actor) then
                    dur.mode, dur.land_id, dur.land_at = 'entrust', tid, nil;
                else
                    dur.mode = 'self';
                end
                dur.begin();
            end
        elseif (act.param == MAGIC_GEO_INTERRUPT) then
            if (geo.pending_by == act.actor) then
                geo.pending = nil;
                geo.pending_by = nil;
            end
            if (ours) then
                dur.until_at = nil;
            end
        end
        return;
    end

    local function committed_wide()
        local fresh = (now - geo.pending_at) < 8.0 and geo.pending_by == act.actor;
        local wide = (geo.pending ~= nil and fresh) and geo.pending or caster_widened(act.actor);
        geo.pending = nil;
        geo.pending_by = nil;
        return wide;
    end

    -- Anyone finishing a Geo- spell is the geomancer to watch.
    if (is_geo_spell) then
        geo.spell = name;
        local buff = colure_is_buff(name);
        geo.is_buff = (buff == true);
        geo.geo_id = act.actor;
        geo.element = spell_element(act.param);
        geo.wide_luopan = committed_wide();
    elseif (is_indi) then
        local tid = act.targets[1];
        local wide = committed_wide();
        local buff = (colure_is_buff(name) == true);

        -- A different target means Entrust; the bubble rides that ally or NPC.
        if (tid ~= nil and tid ~= 0 and tid ~= act.actor) then
            local tindex = index_of(tid);
            local e = {
                element = spell_element(act.param),
                wide = wide,
                at = now,
                buff = buff,
                npc = tindex ~= nil and bit.band(ent:GetSpawnFlags(tindex), 0x01) == 0,
            };
            geo.entrust[tid] = e;
            if (ours) then
                dur.mode = 'entrust';
                dur.land_id, dur.land_at = tid, dur.landed();
                e.exp = dur.land_at + dur.duration();
                dur.sample();
            end
        else
            geo.indi_id = act.actor;
            geo.indi_elem = spell_element(act.param);
            geo.wide_indi = wide;
            geo.indi_at = now;
            geo.indi_buff = buff;
            if (ours) then
                dur.mode = 'self';
                dur.self_at = dur.landed();
                dur.self_exp = dur.self_at + dur.duration();
                dur.sample();
            end
        end
    end

    if (geo.geo_id == nil) then return; end
    if (not TAG_CATEGORY[act.category]) then return; end

    if (act.actor == geo.geo_id) then
        if (act.category == 6 and LUOPAN_JA[act.param]) then
            geo.luopan = nil;
            geo.wide_luopan = false;
            geo.bubble_n = 0;
            return;
        end

        -- A debuff Geo- tags the mob it was cast on.
        if (is_geo_spell) then
            if (colure_is_buff(name) ~= true) then
                for i = 1, #act.targets do
                    local tindex = index_of(act.targets[i]);
                    if (tindex ~= nil and is_mob(ent, tindex)) then
                        tag_mob(act.targets[i]);
                    end
                end
            end
            return;
        end

        local is_cure = cfg.geo_cure and is_cure_name(name);

        -- The target list is every entity the action affected (XiPackets
        -- 0x028 trg_sum; one log line per entry), so Cura/Curaga splash is
        -- already in it: no radius guess needed.
        for i = 1, #act.targets do
            local tid = act.targets[i];
            if (is_cure and geo.party_ids[tid]) then
                tag_from_ally_hate(tid);
            else
                local tindex = index_of(tid);
                if (tindex ~= nil and is_mob(ent, tindex)) then
                    tag_mob(tid);
                end
            end
        end

        return;
    end

    -- A mob acting on the geomancer puts the geomancer on its hate list.
    for i = 1, #act.targets do
        if (act.targets[i] == geo.geo_id) then
            tag_mob(act.actor);
            return;
        end
    end
end

local function u32_le(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3);
    if (d == nil) then return 0; end
    return a + b * 0x100 + c * 0x10000 + d * 0x1000000;
end

function M.packet_in(e)
    if (e.id == 0x08D) then
        -- jobpoint_t: u16 index:5 job_no:11, u16 next:10 level:6 (XiPackets).
        for k = 0, 63 do
            local o = 5 + k * 4;
            local a1, a2, b1, b2 = e.data:byte(o, o + 3);
            if (b2 == nil) then break; end
            local a = a1 + a2 * 256;
            if (bit.band(a, 0x1F) == GEO_JP_INDI and bit.rshift(a, 5) == GEO_JOB) then
                local rank = bit.rshift(b1 + b2 * 256, 10);
                dur.jp = rank;
                if (cfg.geo_indi_jp ~= rank) then
                    cfg.geo_indi_jp = rank;
                    settings.save('ring');
                end
            end
        end
        return;
    end

    if (not cfg.geo) then return; end

    if (e.id == 0x028) then
        local ok, act = pcall(parse_action, e);
        if (ok and act ~= nil) then
            pcall(apply_action_tags, act);
        end
    elseif (e.id == 0x00E) then
        -- HP and status bytes are only meaningful when mask bit 0x04 is set.
        local mask = e.data:byte(11) or 0;
        if (bit.band(mask, 0x04) ~= 0) then
            local hpp = e.data:byte(31) or 0;
            local status = e.data:byte(32) or 0;
            if (hpp == 0 or status == 2 or status == 3) then
                untag_mob(u32_le(e.data, 5));
            end
        end
    elseif (e.id == 0x076) then
        geo.widened = { };
        geo.colure = { };
        for k = 0, 4 do
            local pid = u32_le(e.data, k * 48 + 5);
            if (pid ~= 0) then
                local widened, colure = false, false;
                for n = 1, 32 do
                    local low = e.data:byte(k * 48 + 5 + 16 + n - 1) or 0;
                    local high = e.data:byte(k * 48 + 5 + 8 + math.floor((n - 1) / 4)) or 0;
                    local id = low + 256 * (math.floor(high / 4 ^ ((n - 1) % 4)) % 4);
                    if (id == BUFF_WIDENED) then widened = true; end
                    if (id == BUFF_COLURE) then colure = true; end
                end
                geo.widened[pid] = widened;
                geo.colure[pid] = colure;
            end
        end
    elseif (e.id == 0x00A) then
        geo.tagged = { };
        geo.hate = { };
        geo.missing = { };
        geo.dying = { };
        geo.id_index = { };
        geo.id_miss = { };
        geo.id_miss_n = 0;
        geo.entrust = { };
        geo.count = 0;
        geo.bubble_n = 0;
        geo.luopan = nil;
        geo.indi_id = nil;
        geo.wide_luopan = false;
        geo.wide_indi = false;
        geo.pending = nil;
        geo.pending_by = nil;
        geo.indi_buff = false;
        geo.colure = { };
        dur.clear();
    end
end

function M.packet_out(e)
    if (not cfg.geo) then return; end

    if (e.id == 0x050) then
        dur.equip(e.data:byte(5, 7));
        dur.sample();
    elseif (e.id == 0x051) then
        local n = math.min(e.data:byte(5) or 0, 16);
        for i = 0, n - 1 do
            local o = 9 + i * 4;
            dur.equip(e.data:byte(o, o + 2));
        end
        dur.sample();
    end
end

--------------------------------------------------------------------------------
-- Visibility
--------------------------------------------------------------------------------
-- The client's own "interface is hidden" flag; it covers the UI toggle and the
-- letterboxed part of cutscenes. Ashita's pointer manager has no entry for it
-- (the old Get('gInterfaceHidden') always returned 0), so scan for it the way
-- HXUI does: mov ecx, <object> at +10, flag byte at object + 0xB4.
local INTERFACE_HIDDEN = ashita.memory.find('FFXiMain.dll', 0,
    '8B4424046A016A0050B9????????E8????????F6D81BC040C3', 0, 0);

local function interface_hidden()
    if (INTERFACE_HIDDEN == nil or INTERFACE_HIDDEN == 0) then return false; end

    local ptr = ashita.memory.read_uint32(INTERFACE_HIDDEN + 10);
    if (ptr == 0) then return false; end

    return ashita.memory.read_uint8(ptr + 0xB4) == 1;
end

-- Name of the menu that currently holds focus, if any.
local function menu_name()
    local ptr = AshitaCore:GetPointerManager():Get('menu');
    if (ptr == nil or ptr == 0) then return nil; end

    ptr = ashita.memory.read_uint32(ptr);
    if (ptr == 0) then return nil; end

    ptr = ashita.memory.read_uint32(ptr);
    if (ptr == 0) then return nil; end

    ptr = ashita.memory.read_uint32(ptr + 0x04);
    if (ptr == 0) then return nil; end

    return ashita.memory.read_string(ptr + 0x46, 16);
end

local ui_memo = { name = nil, blocked = false };

local function ui_blocks_rings()
    if (interface_hidden()) then return true; end

    local name = menu_name();
    if (type(name) ~= 'string' or #name == 0) then return false; end

    -- Same menu as last frame: reuse verdict, skip lower() + 3 finds.
    if (name == ui_memo.name) then return ui_memo.blocked; end

    local low = name:lower();

    -- Map, and the expanded chat log, both take focus as menus.
    local blocked = low:find('map', 1, true) ~= nil
        or low:find('log', 1, true) ~= nil
        or low:find('chat', 1, true) ~= nil;

    ui_memo.name, ui_memo.blocked = name, blocked;
    return blocked;
end

--------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------------------
function M.render()
    if (not cfg.enabled and not cfg.geo) then return; end

    local mm = AshitaCore:GetMemoryManager();
    local player = mm:GetPlayer();
    if (player == nil or player:GetIsZoning() ~= 0) then return; end

    local party = mm:GetParty();
    local self_index = party:GetMemberTargetIndex(0);
    if (self_index == 0) then return; end
    local ent = mm:GetEntity();
    if (ent:GetStatus(self_index) == 4) then return; end
    tr.ent = ent;
    tr.self_index = self_index;

    -- Gear sampling throttled to 20Hz; outgoing 0x050/0x051 still sample instantly.
    if (dur.until_at ~= nil) then
        local snow = os.clock();
        if (snow >= (dur.next_at or 0)) then
            dur.next_at = snow + 0.05;
            pcall(dur.sample);
        end
    end

    local ok, blocked = pcall(ui_blocks_rings);
    if (ok and blocked) then return; end

    update_geo();

    local index = 0;
    local index_sub = nil;

    if (cfg.enabled) then
        local target = mm:GetTarget();
        local is_sub = target:GetIsSubTargetActive();
        if (target:GetIsActive(is_sub) ~= 0) then
            index = target:GetTargetIndex(is_sub);
            if (is_sub == 1) then
                index_sub = target:GetTargetIndex(0);
                if (index_sub == index) then index_sub = nil; end
            end
        end
    end

    local has_target = (index ~= 0 or index_sub ~= nil);
    local has_geo = (cfg.geo and (geo.count > 0 or geo.bubble_n > 0));
    if (not has_target and not has_geo) then return; end
    if (not update_matrices()) then return; end

    tr.count = 0;
    tr.pulse = ring_pulse();
    begin_state();

    -- Fills first, under a normal alpha blend. Additive fill vanished against
    -- bright terrain, which made the in-range wash unreadable outdoors.
    dev:SetRenderState(C.D3DRS_DESTBLEND, C.D3DBLEND_INVSRCALPHA);

    if (has_geo) then
        draw_geo_rings('fill');
    end

    if (has_target) then
        draw_ring(index_sub, 'fill');
        draw_ring(index, 'fill');
    end

    flush();

    -- Bands stay additive so they glow on dark ground.
    dev:SetRenderState(C.D3DRS_DESTBLEND, C.D3DBLEND_ONE);

    if (has_geo) then
        draw_geo_rings('band');
    end

    if (has_target) then
        draw_ring(index_sub, 'band');
        draw_ring(index, 'band');
    end

    flush();
    end_state();
end

local function status_line()
    return ('targethud ring: %s | depth %s | scale %.2f | slices %d | arrow %s | runes %s | fade %s | flip %s | geo %s | range %s'):fmt(
        cfg.enabled and 'on' or 'off',
        cfg.depth and 'on' or 'off',
        cfg.scale,
        cfg.slices,
        cfg.arrow and 'on' or 'off',
        cfg.runes and 'on' or 'off',
        cfg.fade and 'on' or 'off',
        cfg.flip and 'on' or 'off',
        cfg.geo and 'on' or 'off',
        cfg.range and 'fill' or 'off');
end

-- args[1] is ignored (was /tring); args[2..] are the old sub-commands.
function M.command(args)
    local sub = (#args >= 2) and args[2]:lower() or 'status';

    if (sub == 'range') then
        local opt = (#args >= 3) and args[3]:lower() or 'status';
        local val = tonumber(args[4]);

        if (opt == 'on') then
            cfg.range = true;
        elseif (opt == 'off') then
            cfg.range = false;
            tr.in_range = { };
        elseif (opt == 'geo') then
            cfg.range_geo = not cfg.range_geo;
        elseif (opt == 'hitbox') then
            cfg.range_hitbox = not cfg.range_hitbox;
        elseif (opt == 'base' and val ~= nil) then
            cfg.range_base = math.max(1.0, math.min(50.0, val));
        elseif (opt == 'fill' and val ~= nil) then
            cfg.range_fill = math.max(0.02, math.min(0.60, val));
        end

        settings.save('ring');
        print(('targethud range: %s | base %.1f | fill %.2f | hitbox %s | geo %s'):fmt(
            cfg.range and 'fill' or 'off',
            cfg.range_base, cfg.range_fill,
            cfg.range_hitbox and 'on' or 'off',
            cfg.range_geo and 'on' or 'off'));
        return;
    end

    if (sub == 'geo') then
        local opt = (#args >= 3) and args[3]:lower() or 'status';
        local val = tonumber(args[4]);

        if (opt == 'on') then
            cfg.geo = true;
        elseif (opt == 'off') then
            cfg.geo = false;
            geo.count = 0;
        elseif (opt == 'buffs') then
            cfg.geo_buffs = not cfg.geo_buffs;
        elseif (opt == 'cure') then
            cfg.geo_cure = not cfg.geo_cure;
        elseif (opt == 'bubble') then
            cfg.geo_bubble = not cfg.geo_bubble;
            geo.bubble_n = 0;
        elseif (opt == 'radius' and val ~= nil) then
            cfg.geo_radius = math.max(1.0, math.min(40.0, val));
        elseif (opt == 'cap' and val ~= nil) then
            cfg.geo_cap = math.max(1, math.min(50, math.floor(val)));
        elseif (opt == 'scan' and val ~= nil) then
            cfg.geo_scan = math.max(5.0, math.min(60.0, val));
        elseif (opt == 'slices' and val ~= nil) then
            cfg.geo_slices = val;
            build_slices();
        elseif (opt == 'clear') then
            geo.tagged = { };
            geo.hate = { };
            geo.count = 0;
        end

        geo.next_tick = 0.0;
        settings.save('ring');

        print('targethud ' .. M.geo_status());
        return;
    end

    if (sub == 'on') then
        cfg.enabled = true;
    elseif (sub == 'off') then
        cfg.enabled = false;
    elseif (sub == 'depth') then
        cfg.depth = not cfg.depth;
    elseif (sub == 'arrow') then
        cfg.arrow = not cfg.arrow;
    elseif (sub == 'runes') then
        cfg.runes = not cfg.runes;
    elseif (sub == 'fade') then
        cfg.fade = not cfg.fade;
    elseif (sub == 'flip') then
        cfg.flip = not cfg.flip;
    elseif (sub == 'scale' and args[3] ~= nil) then
        cfg.scale = math.max(0.1, math.min(8.0, tonumber(args[3]) or 1.0));
    elseif (sub == 'slices' and args[3] ~= nil) then
        cfg.slices = tonumber(args[3]) or 48;
        build_slices();
    end

    settings.save('ring');
    print(status_line());
end


function M.geo_status()
    local tags = 0;
    for _ in pairs(geo.tagged) do tags = tags + 1; end

    local indi_left = (dur.self_exp ~= nil) and math.max(0, dur.self_exp - os.clock()) or 0;
    return ('geo: %s | %s | rings %d | bubbles %d | tagged %d | radius %.1f | cap %d | scan %.0f | buffs %s | cure %s | jp %s | indi %d:%02d | last %.0fs (+%d, %d%%)'):fmt(
        cfg.geo and 'on' or 'off',
        geo.status,
        geo.count,
        geo.bubble_n,
        tags,
        current_radius(),
        cfg.geo_cap,
        cfg.geo_scan,
        cfg.geo_buffs and 'on' or 'off',
        cfg.geo_cure and 'on' or 'off',
        (dur.jp ~= nil or (tonumber(cfg.geo_indi_jp) or -1) >= 0) and tostring(dur.jp_rank()) or '?',
        math.floor(indi_left / 60), math.floor(indi_left % 60),
        dur.duration(), dur.flat, dur.pct);
end

-- Settings lib hands a NEW table on every character switch; keep that exact
-- table (the lib saves it by reference).
function M.set_cfg(t)
    cfg = t;
    build_slices();
    tr.in_range = { };
    geo.next_tick = 0.0;
end

-- Side effects for a GUI edit of cfg[key] (mirrors the old commands).
function M.on_change(key)
    if (key == 'range' and not cfg.range) then
        tr.in_range = { };
    elseif (key == 'geo' and not cfg.geo) then
        geo.count = 0;
    elseif (key == 'geo_bubble') then
        geo.bubble_n = 0;
    elseif (key == 'slices' or key == 'geo_slices') then
        build_slices();
    end
    geo.next_tick = 0.0;
end

function M.clear_tags()
    geo.tagged = { };
    geo.hate = { };
    geo.count = 0;
    geo.next_tick = 0.0;
end

M.status_line = status_line;

return M;
