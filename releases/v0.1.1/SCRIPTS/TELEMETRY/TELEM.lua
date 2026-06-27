-- RMpocketHUD v0.1.1  --  FPV Quad Telemetry HUD  --  RadioMaster Pocket 128x64
-- Betaflight + ExpressLRS (CRSF telemetry)
-- Press ENTER to cycle pages
--
-- P1: Home / HUD      P2: Alt Graph      P3: GPS / Nav
-- P4: Power           P5: Signal         P6: Flight Stats
-- P7: Radar           P8: Channels       P9: Find My Quad
--
-- Install:  SD:/SCRIPTS/TELEMETRY/TELEM.lua
-- Activate: Model > Telemetry > Screens > Script > TELEM

local SOLID  = SOLID  or 0
local DOTTED = DOTTED or 1

local HUD_NAME    = "RMpocketHUD"
local HUD_VERSION = "v0.1.1"

-- ============================================================
-- CONFIG  (edit these if behaviour is wrong for your setup)
-- ============================================================
-- Betaflight appends * to FM when disarmed on some versions
-- (permanent Airmode = "AIR*" disarmed, "AIR" armed).
-- Set true  if armed = asterisk present in FM string.
-- Set false if armed = NO asterisk in FM string.
local ARM_STAR_MEANS_ARMED = false

-- Minimum satellites required before locking home position.
local HOME_MIN_SATS = 5

-- Save last known GPS position to SD on arm, disarm, and every 60s while flying.
-- File: /LOGS/QUAD_POS.txt  (overwritten, paste first line into Google Maps)
local GPS_SAVE = true
-- Battery pack capacity in mAh. Set to 0 for auto-detect by cell count.
-- Or override manually: 300=1S whoop, 650=2S, 1300=4S, 3500=6S 7-inch
local PACK_MAH = 0
local PACK_MAH_AUTO = {300, 650, 850, 1300, 2000, 3500}  -- 1S..6S defaults
-- Per-cell voltage below this triggers an emergency position save + fast 10s saves.
-- 3.5=conservative, 3.4=low, 3.3=critical
local BAT_WARN_V  = 3.4
-- Link quality below this triggers an emergency position save (sudden drop = crashing).
local LQ_WARN_PCT = 30
-- ============================================================

local page      = 1
local NUM_PAGES = 9

-- ============================================================
-- SESSION STATE
-- ============================================================
local home_gps      = nil
local max_alt       = nil
local max_spd       = nil
local min_bat       = nil
local max_dist      = 0
local tot_dist      = 0
local last_gps      = nil
local flt_secs      = 0
local arm_tick      = nil
local was_armed     = false
local last_fix_gps  = nil
local last_fix_alt  = nil
local last_fix_tick = nil
local last_fix_hdg  = nil
local last_fix_spd  = nil

local crumbs       = {}     -- breadcrumb trail (last 5 position saves)
local CRUMB_MAX    = 5
local pos_tick     = 0
local pos_interval = 6000   -- ticks between periodic saves; drops to 1000 on low bat
local crumb_tick   = 0
local CRUMB_INTERVAL = 3000  -- auto-save crumb every 30s when GPS is active
local low_bat_trig = false
local low_lq_trig  = false

local cur_armed  = false
local arm_count  = 0
local reset_tick = 0

local ALT_HIST_MAX = 100          -- 100 samples * 1.5s = ~2.5 min of history
local alt_hist     = {}
local alt_hist_n   = 0
local alt_hist_tick = 0
local ALT_HIST_INT  = 150         -- ticks between altitude samples (1.5 seconds)

local TRACK_MAX  = 60
local track      = {}
local track_n    = 0
local last_trk_x = 0
local last_trk_y = 0

-- ============================================================
-- SENSOR HELPERS
-- ============================================================
local function get(name)
  local v = getValue(name)
  if type(v) == "number" then return v end
  return nil
end

local function getBat()
  for _, name in ipairs({"RxBt","Bat","VFAS","Cels"}) do
    local v = get(name)
    if v and v > 2.0 then return v end
  end
  return nil
end

-- Returns pct (0-100) and cell count detected from pack voltage (1S-6S)
local function batInfo(v)
  if not v then return nil, nil end
  local cells
  if     v < 5.0  then cells = 1
  elseif v < 9.5  then cells = 2
  elseif v < 13.5 then cells = 3
  elseif v < 18.0 then cells = 4
  elseif v < 22.2 then cells = 5
  else                  cells = 6 end
  local pct = math.floor((v/cells - 3.5) / 0.7 * 100 + 0.5)
  return math.max(0, math.min(100, pct)), cells
end

local function getGPS()
  local v = getValue("GPS")
  if type(v) == "table" and type(v.lat) == "number" and (v.lat ~= 0 or v.lon ~= 0) then return v end
  return nil
end

-- Returns: mode_str, is_failsafe, is_armed
-- Betaflight appends * to FM string when armed (e.g. "AIR" disarmed, "AIR*" armed)
local function getMode()
  local v = getValue("FM")
  if type(v) ~= "string" or v == "" then return "---", false, false end
  if string.find(v, "FAIL") or string.find(v, "!FS!") then return "FAIL!", true,  true  end
  -- GPS rescue: treat as armed + warning so title bar blinks
  if string.find(v, "RESC") or string.find(v, "RTHS") then return "RESC!", false, true  end
  local has_star = string.find(v, "%*") ~= nil
  local armed    = ARM_STAR_MEANS_ARMED and has_star or not has_star
  if string.find(v, "DISA") then armed = false end
  local name
  if     string.find(v, "ANGL") or string.find(v, "STAB") then name = "ANGLE"
  elseif string.find(v, "HOR")                             then name = "HOR"
  elseif string.find(v, "POSH") or string.find(v, "PHLD") then name = "PH"
  elseif string.find(v, "ALTH") or string.find(v, "AHLD") then name = "AH"
  elseif string.find(v, "TRTL") or string.find(v, "TURT") then name = "TRTL"
  elseif string.find(v, "AIR")                             then name = "AIR"
  elseif string.find(v, "ACRO")                            then name = "ACRO"
  elseif string.find(v, "DISA")                            then name = "DISA"
  else name = string.sub(v, 1, 6) end
  return name, false, armed
end

-- Add a position snapshot to the in-memory breadcrumb trail
local function addCrumb(gps_p, alt_p, bat_p, hdg_p, spd_p)
  if not gps_p then return end
  local ft = flt_secs
  if arm_tick then ft = ft + (getTime() - arm_tick) / 100 end
  local entry = {gps=gps_p, alt=alt_p, bat=bat_p,
                 hdg=hdg_p, spd=spd_p, ft=ft, tick=getTime()}
  local n = #crumbs
  if n < CRUMB_MAX then
    crumbs[n + 1] = entry
  else
    for j = 1, CRUMB_MAX-1 do crumbs[j] = crumbs[j+1] end
    crumbs[CRUMB_MAX] = entry
  end
end

-- Write all breadcrumbs to SD card as plain text (newest first)
-- Paste any coord line into Google Maps search to find the quad
-- Tries /LOGS/ first, falls back to SD root
local function savePosToSD()
  if not GPS_SAVE or #crumbs == 0 then return end
  local f = io.open("/LOGS/QUAD_POS.txt", "w")
  if not f then f = io.open("/QUAD_POS.txt", "w") end
  if not f then return end
  for i = #crumbs, 1, -1 do
    local c = crumbs[i]
    local m = math.floor(c.ft / 60)
    local s = math.floor(c.ft % 60)
    io.write(f, string.format("%.5f,%.5f  alt:%+.0fm  bat:%.2fV  t=%d:%02d\n",
      c.gps.lat, c.gps.lon, c.alt or 0, c.bat or 0, m, s))
  end
  io.close(f)
end

local DIRS = {"N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"}
local function hdgDir(d)
  if not d then return "---" end
  return DIRS[math.floor(((d%360)+11.25)/22.5)%16+1]
end

-- ============================================================
-- GPS MATH
-- ============================================================
-- x = east (right on screen), y = north-up (negative = up on screen)
local function gpsToXY(hlat, hlon, lat, lon)
  local x = (lon - hlon) * 111320 * math.cos(math.rad(hlat))
  local y = -(lat - hlat) * 111320
  return x, y
end

local function gpsBear(lat1, lon1, lat2, lon2)
  local dlon = math.rad(lon2 - lon1)
  local y = math.sin(dlon) * math.cos(math.rad(lat2))
  local x = math.cos(math.rad(lat1)) * math.sin(math.rad(lat2))
          - math.sin(math.rad(lat1)) * math.cos(math.rad(lat2)) * math.cos(dlon)
  return (math.deg(math.atan2(y, x)) + 360) % 360
end

-- ============================================================
-- DRAW HELPERS
-- ============================================================
local function drawCircle(cx, cy, r)
  local x, y, e = r, 0, 0
  while x >= y do
    lcd.drawPoint(cx+x,cy+y); lcd.drawPoint(cx+y,cy+x)
    lcd.drawPoint(cx-y,cy+x); lcd.drawPoint(cx-x,cy+y)
    lcd.drawPoint(cx-x,cy-y); lcd.drawPoint(cx-y,cy-x)
    lcd.drawPoint(cx+y,cy-x); lcd.drawPoint(cx+x,cy-y)
    y=y+1; e=e+2*y+1
    if e>2*x then x=x-1; e=e-2*x+1 end
  end
end

-- House icon centered at cx,cy with half-size sz (full icon = 2*sz+1 wide/tall)
local function drawHome(cx, cy, sz)
  lcd.drawLine(cx,    cy-sz, cx-sz, cy,    SOLID, 0)
  lcd.drawLine(cx,    cy-sz, cx+sz, cy,    SOLID, 0)
  lcd.drawLine(cx-sz, cy,    cx-sz, cy+sz, SOLID, 0)
  lcd.drawLine(cx+sz, cy,    cx+sz, cy+sz, SOLID, 0)
  lcd.drawLine(cx-sz, cy+sz, cx+sz, cy+sz, SOLID, 0)
  if sz >= 3 then
    lcd.drawLine(cx-1, cy+1, cx+1, cy+1, SOLID, 0)
    lcd.drawLine(cx-1, cy+1, cx-1, cy+sz, SOLID, 0)
    lcd.drawLine(cx+1, cy+1, cx+1, cy+sz, SOLID, 0)
  end
end

-- Arrow pointing in hdg_deg direction (north=up), sz = shaft length
local function drawArrow(cx, cy, hdg_deg, sz)
  local a  = math.rad((hdg_deg % 360) - 90)
  local tx = math.floor(cx + math.cos(a)*sz + 0.5)
  local ty = math.floor(cy + math.sin(a)*sz + 0.5)
  lcd.drawLine(cx, cy, tx, ty, SOLID, 0)
  local bl = math.max(2, math.floor(sz*0.65 + 0.5))
  local ba = a + math.rad(145)
  local bb = a - math.rad(145)
  lcd.drawLine(tx, ty,
    math.floor(tx + math.cos(ba)*bl + 0.5),
    math.floor(ty + math.sin(ba)*bl + 0.5), SOLID, 0)
  lcd.drawLine(tx, ty,
    math.floor(tx + math.cos(bb)*bl + 0.5),
    math.floor(ty + math.sin(bb)*bl + 0.5), SOLID, 0)
end

-- home_bear: absolute bearing to home; drawn as a filled dot on the compass ring
local function drawCompass(cx, cy, r, hdg, home_bear)
  drawCircle(cx, cy, r)
  lcd.drawLine(cx,cy-r,   cx,cy-r+2,   SOLID, 0)
  lcd.drawLine(cx,cy+r-2, cx,cy+r,     SOLID, 0)
  lcd.drawLine(cx-r,cy,   cx-r+2,cy,   SOLID, 0)
  lcd.drawLine(cx+r-2,cy, cx+r,cy,     SOLID, 0)
  lcd.drawText(cx-2, cy-r-5, "N", SMLSIZE)
  if home_bear then
    local ha = math.rad((home_bear%360)-90)
    local hx = math.floor(cx + math.cos(ha)*(r-1) + 0.5)
    local hy = math.floor(cy + math.sin(ha)*(r-1) + 0.5)
    lcd.drawPoint(hx, hy); lcd.drawPoint(hx+1, hy)
    lcd.drawPoint(hx, hy+1)
  end
  if hdg then
    local a = math.rad((hdg%360)-90)
    lcd.drawLine(cx, cy,
      math.floor(cx + math.cos(a)*(r-2) + 0.5),
      math.floor(cy + math.sin(a)*(r-2) + 0.5), SOLID, 0)
  end
  lcd.drawPoint(cx,cy); lcd.drawPoint(cx+1,cy+1)
end

local function drawRadar(cx, cy, r, gps, hdg)
  drawCircle(cx, cy, r)
  lcd.drawText(cx-2, cy-r-6, "N", SMLSIZE)
  -- Cardinal tick marks
  lcd.drawPoint(cx, cy-r); lcd.drawPoint(cx, cy+r)
  lcd.drawPoint(cx-r, cy); lcd.drawPoint(cx+r, cy)
  -- Home crosshair at center
  lcd.drawLine(cx-2, cy, cx+2, cy, SOLID, 0)
  lcd.drawLine(cx, cy-2, cx, cy+2, SOLID, 0)

  if gps and home_gps and max_dist > 0 then
    local range = math.max(max_dist * 1.1, 20)
    local dx, dy = gpsToXY(home_gps.lat, home_gps.lon, gps.lat, gps.lon)
    local rx = dx * (r-3) / range
    local ry = dy * (r-3) / range
    local mag = math.sqrt(rx*rx + ry*ry)
    if mag > r-3 then
      local s = (r-3) / mag
      rx, ry = rx*s, ry*s
    end
    rx = math.floor(rx+0.5)
    ry = math.floor(ry+0.5)
    -- Drone arrow (points in heading direction)
    if hdg then
      drawArrow(cx+rx, cy+ry, hdg, 3)
    else
      lcd.drawPoint(cx+rx,   cy+ry)
      lcd.drawPoint(cx+rx+1, cy+ry)
      lcd.drawPoint(cx+rx,   cy+ry+1)
      lcd.drawPoint(cx+rx+1, cy+ry+1)
    end
    -- Range label
    lcd.drawText(cx-14, cy+r+2, string.format("%dm", math.floor(range)), SMLSIZE)
  end
end

-- ============================================================
-- ARTIFICIAL HORIZON
-- ============================================================
local HCX, HCY = 64, 25
local HLEN = 42
local PS   = 1.4

-- Compressed horizon for P9 top half (box x=23..101, y=9..33)
local HCX9, HCY9 = 62, 21
local HLEN9 = 33
local PS9   = 0.55

local function drawHorizonMini(roll, pitch)
  local r    = math.rad(roll or 0)
  local poff = (pitch or 0) * PS9
  local cr   = math.cos(r)
  local sr   = math.sin(r)
  lcd.drawLine(
    math.floor(HCX9 - HLEN9*cr - poff*sr + 0.5),
    math.floor(HCY9 - HLEN9*sr + poff*cr + 0.5),
    math.floor(HCX9 + HLEN9*cr - poff*sr + 0.5),
    math.floor(HCY9 + HLEN9*sr + poff*cr + 0.5),
    SOLID, 0)
  for _, deg in ipairs({-10, 10}) do
    local toff = poff - deg*PS9
    local tlen = 7
    local ty1  = math.floor(HCY9 - tlen*sr + toff*cr + 0.5)
    local ty2  = math.floor(HCY9 + tlen*sr + toff*cr + 0.5)
    if ty1>10 and ty1<32 and ty2>10 and ty2<32 then
      lcd.drawLine(
        math.floor(HCX9 - tlen*cr - toff*sr + 0.5), ty1,
        math.floor(HCX9 + tlen*cr - toff*sr + 0.5), ty2,
        SOLID, 0)
    end
  end
  lcd.drawLine(HCX9-8, HCY9, HCX9-4, HCY9, SOLID, 0)
  lcd.drawLine(HCX9+4, HCY9, HCX9+8, HCY9, SOLID, 0)
  lcd.drawLine(HCX9-1, HCY9+1, HCX9+1, HCY9+1, SOLID, 0)
  lcd.drawPoint(HCX9, HCY9-1)
end

local function drawHorizon(roll, pitch)
  local r    = math.rad(roll or 0)
  local poff = (pitch or 0) * PS
  local cr   = math.cos(r)
  local sr   = math.sin(r)
  lcd.drawLine(
    math.floor(HCX - HLEN*cr - poff*sr + 0.5),
    math.floor(HCY - HLEN*sr + poff*cr + 0.5),
    math.floor(HCX + HLEN*cr - poff*sr + 0.5),
    math.floor(HCY + HLEN*sr + poff*cr + 0.5),
    SOLID, 0)
  for _, deg in ipairs({-20,-10,10,20}) do
    local toff = poff - deg*PS
    local tlen = math.abs(deg)==20 and 12 or 8
    local ty1  = math.floor(HCY - tlen*sr + toff*cr + 0.5)
    local ty2  = math.floor(HCY + tlen*sr + toff*cr + 0.5)
    if ty1>9 and ty1<41 and ty2>9 and ty2<41 then
      lcd.drawLine(
        math.floor(HCX - tlen*cr - toff*sr + 0.5), ty1,
        math.floor(HCX + tlen*cr - toff*sr + 0.5), ty2,
        SOLID, 0)
    end
  end
  lcd.drawLine(HCX-14, HCY,   HCX-4,  HCY,    SOLID, 0)
  lcd.drawLine(HCX+4,  HCY,   HCX+14, HCY,    SOLID, 0)
  lcd.drawLine(HCX-3,  HCY+2, HCX+3,  HCY+2,  SOLID, 0)
  lcd.drawPoint(HCX, HCY-1)
  lcd.drawPoint(HCX, HCY)
end

-- ============================================================
-- TITLE BAR
-- ============================================================
local function drawTitle(mode, is_warn, lq, pg, armd)
  lcd.drawFilledRectangle(0, 0, 128, 8, FORCE)
  lcd.drawText(1, 1, "P"..pg.."/"..NUM_PAGES, SMLSIZE+INVERS)
  local mf  = is_warn and (SMLSIZE+INVERS+BLINK) or (SMLSIZE+INVERS)
  local lbl = armd and (mode.."[A]") or mode
  lcd.drawText(30, 1, lbl, mf)
  if not lq or lq == 0 then
    lcd.drawText(82, 1, "NO LINK", SMLSIZE+INVERS+BLINK)
  else
    lcd.drawText(82, 1, string.format("LQ%3d%%", math.floor(lq)), SMLSIZE+INVERS)
  end
end

-- ============================================================
-- PAGE 1: ALTITUDE GRAPH
-- Filled altitude profile over time. Left strip shows live values.
-- ============================================================
local function drawPage1(lq, bat, curr, roll, ptch, yaw, alt, vspd, hdg, gspd, sats, gps)
  -- Left data strip (x=0..24)
  lcd.drawText(0,  9,  alt  and string.format("%+.0fm", alt)  or "--m",  SMLSIZE)
  lcd.drawText(0, 16,  vspd and string.format("%+.1f", vspd)  or "--",   SMLSIZE)
  lcd.drawText(0, 22,  "m/s",                                              SMLSIZE)
  lcd.drawLine(0, 28, 24, 28, SOLID, 0)
  lcd.drawText(0, 30,  "MX",                                               SMLSIZE)
  lcd.drawText(0, 36,  max_alt and string.format("%+.0fm", max_alt) or "--", SMLSIZE)
  lcd.drawLine(0, 43, 24, 43, SOLID, 0)
  lcd.drawText(0, 45,  bat  and string.format("%.1fV", bat)   or "--V",  SMLSIZE)
  lcd.drawText(0, 51,  curr and string.format("%.1fA", curr)  or "--A",  SMLSIZE)
  lcd.drawText(0, 57,  gspd and string.format("%.1f",  gspd)  or "--",   SMLSIZE)

  -- Vertical divider
  lcd.drawLine(25, 9, 25, 63, SOLID, 0)

  -- Graph area: x=26..127 (102px wide), y=9..62 (53px tall)
  local GX, GW, GY, GH = 26, 102, 9, 53
  local bot = GY + GH - 1   -- baseline y = 61

  lcd.drawLine(GX, bot, GX+GW-1, bot, SOLID, 0)   -- baseline

  if alt_hist_n == 0 then
    lcd.drawText(GX+8, 32, "NO ALT DATA", SMLSIZE)
    return
  end

  -- Scale to the highest recorded altitude (floor at 20m so bars are visible)
  local peak = math.max(max_alt or 20, 20)

  -- Draw filled area: vertical bars from baseline upward
  local n_draw = math.min(alt_hist_n, GW)
  for i = 1, n_draw do
    local idx = alt_hist_n - n_draw + i
    local a   = math.max(0, alt_hist[idx] or 0)
    local h   = math.floor(a / peak * (GH-2) + 0.5)
    if h > GH-2 then h = GH-2 end
    if h > 0 then
      lcd.drawLine(GX + (i-1), bot-1, GX + (i-1), bot-h, SOLID, 0)
    end
  end

  -- Scale labels
  lcd.drawText(GX+2, GY+1, string.format("%.0fm", peak), SMLSIZE)  -- peak at top
  lcd.drawText(GX+2, bot-6, "0",                          SMLSIZE)  -- zero at baseline
end

-- ============================================================
-- PAGE 2: GPS / NAVIGATION
-- All GPS data in one place. Mini radar on the right.
-- ============================================================
local function drawPage2(lq, bat, curr, roll, ptch, yaw, alt, vspd, hdg, gspd, sats, gps)
  -- Vertical divider between data and radar
  lcd.drawLine(82, 9, 82, 63, SOLID, 0)

  -- Left: GPS data (x=0..81)
  if gps then
    lcd.drawText(0, 9,  string.format("LAT:%.4f%s", math.abs(gps.lat), gps.lat>=0 and "N" or "S"), SMLSIZE)
    lcd.drawText(0, 16, string.format("LON:%.4f%s", math.abs(gps.lon), gps.lon>=0 and "E" or "W"), SMLSIZE)
  else
    lcd.drawText(0, 9,  "LAT: NO FIX", SMLSIZE)
    lcd.drawText(0, 16, "LON: NO FIX", SMLSIZE)
  end
  lcd.drawLine(0, 24, 81, 24, SOLID, 0)
  lcd.drawText(0, 26, sats and string.format("SAT: %2d",     math.floor(sats)) or "SAT: --",    SMLSIZE)
  lcd.drawText(0, 33, gspd and string.format("SPD: %.1fm/s", gspd)             or "SPD: ---",   SMLSIZE)
  lcd.drawText(0, 40, alt  and string.format("ALT: %+.1fm",  alt)              or "ALT: ---",   SMLSIZE)
  lcd.drawText(0, 47, hdg  and string.format("HDG: %3d %s",  math.floor(hdg%360), hdgDir(hdg)) or "HDG: ---", SMLSIZE)
  -- Home distance + bearing
  if gps and home_gps then
    local cx, cy = gpsToXY(home_gps.lat, home_gps.lon, gps.lat, gps.lon)
    local d = math.sqrt(cx*cx + cy*cy)
    local b = gpsBear(home_gps.lat, home_gps.lon, gps.lat, gps.lon)
    lcd.drawText(0, 54, string.format("HME:%4.0fm %s", d, hdgDir(b)), SMLSIZE)
  else
    lcd.drawText(0, 54, "HME: NO FIX", SMLSIZE)
  end

  -- Right: mini radar (center 105, 38, r=19)
  drawRadar(105, 38, 19, gps, hdg)
end

-- ============================================================
-- PAGE 3: POWER + FLIGHT STATUS
-- Battery, current, capacity, timer, signal summary.
-- ============================================================
local function drawPage3(lq, bat, curr, roll, ptch, yaw, alt, vspd, hdg, gspd, sats, gps)
  local pct, cells = batInfo(bat)
  local capa  = get("Capa")
  local rssi1 = get("1RSS")
  -- Flight time remaining estimate (auto-detect pack size by cell count)
  local pack_mah = PACK_MAH > 0 and PACK_MAH or (cells and PACK_MAH_AUTO[cells] or 0)
  local eta_str = "---"
  if capa and curr and curr > 0.1 and pack_mah > 0 then
    local remaining = pack_mah - capa
    if remaining > 0 then
      local mins_left = remaining * 0.06 / curr
      local m = math.floor(mins_left)
      local s = math.floor((mins_left - m) * 60)
      eta_str = string.format("~%d:%02d", m, s)
    else
      eta_str = "DONE"
    end
  end

  -- Battery headline + full-width bar
  if bat then
    lcd.drawText(0, 9, string.format("BAT:%.2fV %dS %2d%%", bat, cells, pct), SMLSIZE)
  else
    lcd.drawText(0, 9, "BAT: ---", SMLSIZE)
  end
  lcd.drawRectangle(0, 16, 128, 5)
  if pct and pct > 0 then
    lcd.drawFilledRectangle(1, 17, math.floor(pct*126/100), 3, FORCE)
  end

  -- Current + watts
  lcd.drawText(0,  23, curr and string.format("CUR:  %.1fA",  curr)         or "CUR:  ---", SMLSIZE)
  lcd.drawText(80, 23, (bat and curr) and string.format("%.0fW", bat*curr)  or "---W",      SMLSIZE)
  -- Capacity used + throttle
  lcd.drawText(0,  30, capa and string.format("USED: %.0fmAh", capa)         or "USED: ---", SMLSIZE)
  lcd.drawText(72, 30, "ETA:"..eta_str,                                                       SMLSIZE)

  lcd.drawLine(0, 37, 127, 37, SOLID, 0)

  -- Flight timer + arm count
  local cur_secs = flt_secs
  if arm_tick then cur_secs = cur_secs + (getTime() - arm_tick) / 100 end
  local mins_p3  = math.floor(cur_secs / 60)
  local secs_p3  = math.floor(cur_secs % 60)
  lcd.drawText(0,  39, string.format("TIMER: %02d:%02d", mins_p3, secs_p3), SMLSIZE)
  lcd.drawText(90, 39, string.format("#%d", arm_count),                      SMLSIZE)

  -- Min battery recorded this session
  local min_pct, _ = batInfo(min_bat)
  if min_bat then
    lcd.drawText(0, 46, string.format("MIN:  %.2fV  %2d%%", min_bat, min_pct), SMLSIZE)
  else
    lcd.drawText(0, 46, "MIN:  ---", SMLSIZE)
  end

  -- Compact signal summary
  lcd.drawText(0,  53, rssi1 and string.format("RSSI: %ddB",  math.floor(rssi1)) or "RSSI: ---", SMLSIZE)
  lcd.drawText(80, 53, lq    and string.format("LQ:%3d%%",    math.floor(lq))    or "LQ:  ---",  SMLSIZE)
end

-- ============================================================
-- PAGE 4: SIGNAL HEALTH
-- LQ, RSSI both antennas, SNR, TX power.
-- ============================================================
local function drawPage4(lq, bat, curr, roll, ptch, yaw, alt, vspd, hdg, gspd, sats, gps)
  local rssi1 = get("1RSS")
  local rssi2 = get("2RSS")
  local rsnr  = get("RSNR") or get("SNR")
  local tsnr  = get("TSNR")
  local tpwr  = get("TPWR")
  local rfmd  = get("RFMD")
  local ant   = get("ANT")

  lcd.drawText(0,  9,  lq    and string.format("LQ:     %3d%%",   math.floor(lq))    or "LQ:     ---", SMLSIZE)
  -- RSSI 1 + active antenna (paired)
  lcd.drawText(0,  17, rssi1 and string.format("RSSI 1: %4ddBm",  math.floor(rssi1)) or "RSSI 1: ---", SMLSIZE)
  if ant then lcd.drawText(100, 17, string.format("A%d", math.floor(ant)), SMLSIZE) end
  lcd.drawText(0,  25, rssi2 and string.format("RSSI 2: %4ddBm",  math.floor(rssi2)) or "RSSI 2: ---", SMLSIZE)
  -- RX SNR + TX SNR (paired)
  lcd.drawText(0,  33, rsnr  and string.format("RXSNR: %+3ddB",   math.floor(rsnr))  or "RXSNR: ---",  SMLSIZE)
  if tsnr then lcd.drawText(76, 33, string.format("TX:%+3ddB", math.floor(tsnr)), SMLSIZE) end
  -- TX power + RF mode / packet rate (paired)
  lcd.drawText(0,  41, tpwr  and string.format("TXPWR: %4dmW",    math.floor(tpwr))  or "TXPWR: ---",  SMLSIZE)
  if rfmd then lcd.drawText(84, 41, string.format("%dHz", math.floor(rfmd)), SMLSIZE) end
  lcd.drawLine(0, 49, 127, 49, SOLID, 0)
  -- LQ bar (full width)
  lcd.drawText(0, 51, "LQ:", SMLSIZE)
  lcd.drawRectangle(18, 51, 108, 6)
  if lq and lq > 0 then
    lcd.drawFilledRectangle(19, 52, math.floor(lq*106/100), 4, FORCE)
  end
end

-- ============================================================
-- PAGE 5: FLIGHT STATS
-- Session records: timer, max values, distance.
-- ============================================================
local function drawPage5(lq, bat, curr, roll, ptch, yaw, alt, vspd, hdg, gspd, sats, gps)
  local cur_secs = flt_secs
  if arm_tick then cur_secs = cur_secs + (getTime() - arm_tick) / 100 end
  local mins = math.floor(cur_secs / 60)
  local secs = math.floor(cur_secs % 60)

  local home_dist, home_bear
  if gps and home_gps then
    local cx, cy = gpsToXY(home_gps.lat, home_gps.lon, gps.lat, gps.lon)
    home_dist = math.sqrt(cx*cx + cy*cy)
    home_bear = gpsBear(home_gps.lat, home_gps.lon, gps.lat, gps.lon)
  end

  -- Flash RESET confirmation for 2 seconds, otherwise show normal header
  if reset_tick > 0 and (getTime() - reset_tick) < 200 then
    lcd.drawText(0, 9, "*** STATS RESET ***", SMLSIZE+BLINK)
  else
    lcd.drawText(0,   9, string.format("TIMER: %02d:%02d  #%d", mins, secs, arm_count), SMLSIZE)
  end
  lcd.drawLine(0, 16, 127, 16, SOLID, 0)
  lcd.drawText(0, 18, home_dist and string.format("DIST:    %.0fm",   home_dist) or "DIST:    ---", SMLSIZE)
  lcd.drawText(0, 25, home_bear and string.format("BRG:     %3d %s", math.floor(home_bear), hdgDir(home_bear)) or "BRG:     ---", SMLSIZE)
  lcd.drawLine(0, 32, 127, 32, SOLID, 0)
  lcd.drawText(0, 34, max_alt and string.format("MAX ALT: %+.0fm",  max_alt) or "MAX ALT: ---", SMLSIZE)
  lcd.drawText(0, 41, max_spd and string.format("MAX SPD: %.1fm/s", max_spd) or "MAX SPD: ---", SMLSIZE)
  lcd.drawText(0, 48, min_bat and string.format("MIN BAT: %.2fV",   min_bat) or "MIN BAT: ---", SMLSIZE)
  lcd.drawText(0, 55, string.format("TOT DST: %.0fm  [hold=RST]", tot_dist), SMLSIZE)
end

-- ============================================================
-- PAGE 6: RADAR
-- Circular radar with drone track + data panels left and right.
-- ============================================================
local function drawPage6(lq, bat, curr, roll, ptch, yaw, alt, vspd, hdg, gspd, sats, gps)
  local rssi1 = get("1RSS")
  local home_dist, home_bear
  if gps and home_gps then
    local dx, dy = gpsToXY(home_gps.lat, home_gps.lon, gps.lat, gps.lon)
    home_dist = math.sqrt(dx*dx + dy*dy)
    home_bear = gpsBear(home_gps.lat, home_gps.lon, gps.lat, gps.lon)
  end

  -- Left data strip (x=0..27)
  lcd.drawText(0,  9,  gspd and string.format("%.1f", gspd) or "--",          SMLSIZE)
  lcd.drawText(0, 15,  "m/s",                                                   SMLSIZE)
  lcd.drawLine(0, 21, 27, 21, SOLID, 0)
  lcd.drawText(0, 23,  bat  and string.format("%.1fV", bat)  or "--V",         SMLSIZE)
  lcd.drawText(0, 30,  curr and string.format("%.1fA", curr) or "--A",         SMLSIZE)
  lcd.drawLine(0, 37, 27, 37, SOLID, 0)
  lcd.drawText(0, 39,  home_dist and string.format("%.0fm", home_dist) or "--", SMLSIZE)
  lcd.drawText(0, 46,  home_bear and hdgDir(home_bear) or "---",               SMLSIZE)
  lcd.drawLine(0, 53, 27, 53, SOLID, 0)
  lcd.drawText(0, 55,  alt and string.format("%+.0fm", alt) or "--m",          SMLSIZE)

  -- Right data strip (x=100..127)
  lcd.drawText(100,  9,  sats  and string.format("S%2d", math.floor(sats)) or "S--",   SMLSIZE)
  lcd.drawText(100, 16,  lq    and string.format("%3d%%", math.floor(lq))  or "---%",  SMLSIZE)
  lcd.drawText(100, 23,  rssi1 and string.format("%3ddB", math.floor(rssi1)) or "---", SMLSIZE)
  lcd.drawLine(100, 30, 127, 30, SOLID, 0)
  lcd.drawText(100, 32,  max_alt and string.format("^%.0f", max_alt)    or "^--",       SMLSIZE)
  lcd.drawText(100, 39,  max_spd and string.format(">%.1f", max_spd)    or ">--",       SMLSIZE)
  lcd.drawLine(100, 46, 127, 46, SOLID, 0)
  lcd.drawText(100, 48,  max_dist and string.format("D%.0fm", max_dist) or "D--",       SMLSIZE)
  lcd.drawText(100, 55,  hdg and string.format("%3d", math.floor(hdg%360)) or "---",   SMLSIZE)

  -- Vertical dividers
  lcd.drawLine(28, 9, 28, 63, SOLID, 0)
  lcd.drawLine(99, 9, 99, 63, SOLID, 0)

  -- Radar circle (cx=63, cy=37, r=23)
  local CX, CY, CR = 63, 37, 23

  if not home_gps then
    lcd.drawText(33, 28, "NO GPS",  SMLSIZE)
    lcd.drawText(33, 36, "WAITING", SMLSIZE)
    return
  end

  drawCircle(CX, CY, CR)
  lcd.drawText(CX-2, CY-CR-6, "N", SMLSIZE)
  lcd.drawLine(CX,    CY-CR,   CX,    CY-CR+2, SOLID, 0)
  lcd.drawLine(CX,    CY+CR-2, CX,    CY+CR,   SOLID, 0)
  lcd.drawLine(CX-CR, CY,      CX-CR+2, CY,    SOLID, 0)
  lcd.drawLine(CX+CR-2, CY,    CX+CR,   CY,    SOLID, 0)

  -- Home crosshair at center
  lcd.drawLine(CX-2, CY, CX+2, CY, SOLID, 0)
  lcd.drawLine(CX, CY-2, CX, CY+2, SOLID, 0)

  local range = math.max(max_dist * 1.2, 20)
  local scale = (CR-3) / range

  -- Track dots (clipped to circle)
  for i = 1, track_n do
    local sx = math.floor(CX + track[i].x * scale + 0.5)
    local sy = math.floor(CY + track[i].y * scale + 0.5)
    local ddx = sx - CX; local ddy = sy - CY
    if ddx*ddx + ddy*ddy <= (CR-1)*(CR-1) then
      lcd.drawPoint(sx, sy)
    end
  end

  -- Range label inside circle (bottom)
  lcd.drawText(CX-8, CY+CR-8, string.format("%dm", math.floor(range/2)), SMLSIZE)

  -- Current drone position arrow
  if gps then
    local dx, dy = gpsToXY(home_gps.lat, home_gps.lon, gps.lat, gps.lon)
    local sx = math.floor(CX + dx * scale + 0.5)
    local sy = math.floor(CY + dy * scale + 0.5)
    local mag = math.sqrt((sx-CX)*(sx-CX) + (sy-CY)*(sy-CY))
    if mag > CR-3 then
      local s = (CR-3) / mag
      sx = math.floor(CX + (sx-CX)*s + 0.5)
      sy = math.floor(CY + (sy-CY)*s + 0.5)
    end
    if hdg then drawArrow(sx, sy, hdg, 3)
    else
      lcd.drawPoint(sx, sy); lcd.drawPoint(sx+1, sy); lcd.drawPoint(sx, sy+1)
    end
  end
end

-- ============================================================
-- GIMBAL / RADIO INTERFACE HELPERS  (used by P9)
-- ============================================================
local function swLabel(name)
  local v = getValue(name)
  if type(v) ~= "number" then return "?" end
  if v >  500 then return "v" end
  if v < -500 then return "^" end
  return "-"
end

-- Stick box with moving 3x3 dot. hv/vv range -1024..1024.
local function drawGimbal(x, y, w, h, hv, vv)
  lcd.drawRectangle(x, y, w, h)
  local cx = x + math.floor(w/2)
  local cy = y + math.floor(h/2)
  lcd.drawPoint(cx, cy)
  if type(hv) == "number" and type(vv) == "number" then
    local hw = math.floor(w/2) - 2
    local hh = math.floor(h/2) - 2
    local px = math.max(x+1, math.min(x+w-4, cx + math.floor(hv*hw/1024+0.5) - 1))
    local py = math.max(y+1, math.min(y+h-4, cy - math.floor(vv*hh/1024+0.5) - 1))
    lcd.drawFilledRectangle(px, py, 3, 3, FORCE)
  end
end

-- n ascending signal bars (like phone/radio signal strength)
local function drawSigBars(x, y, pct, n)
  local filled = math.max(0, math.min(n, math.floor((pct or 0) * n / 100 + 0.5)))
  for i = 1, n do
    local bh = i * 2
    local bx = x + (i-1) * 4
    local by = y + n*2 - bh
    if i <= filled then lcd.drawFilledRectangle(bx, by, 3, bh, FORCE)
    else                lcd.drawRectangle(bx, by, 3, bh) end
  end
end

-- ============================================================
-- PAGE 7: CHANNEL MONITOR  (ch1-ch8 center-out bars)
-- ============================================================
local CH_NAMES = {"AIL","ELE","THR","RUD","CH5","CH6","CH7","CH8"}

local function drawPage7(lq, bat, curr, roll, ptch, yaw, alt, vspd, hdg, gspd, sats, gps)
  local BAR_X  = 24
  local BAR_W  = 88
  local BAR_MX = BAR_X + math.floor(BAR_W / 2)

  for i = 1, 8 do
    local y  = 9 + math.floor((i-1) * 48 / 7)
    local ch = getValue("ch"..i)
    if type(ch) ~= "number" then ch = 0 end

    lcd.drawText(0, y, CH_NAMES[i], SMLSIZE)
    lcd.drawRectangle(BAR_X, y, BAR_W, 5)
    lcd.drawPoint(BAR_MX, y)
    lcd.drawPoint(BAR_MX, y+4)

    local fill = math.floor(math.abs(ch) * (BAR_W/2 - 1) / 1024)
    if fill > 0 then
      if ch >= 0 then
        lcd.drawFilledRectangle(BAR_MX,        y+1, fill, 3, FORCE)
      else
        lcd.drawFilledRectangle(BAR_MX - fill, y+1, fill, 3, FORCE)
      end
    end

    lcd.drawText(BAR_X+BAR_W+2, y, string.format("%4d", math.floor(ch*100/1024)), SMLSIZE)
  end
end

-- ============================================================
-- PAGE 8: FIND MY QUAD
-- Last known GPS fix for crash recovery.
-- Read coordinates and paste into Google Maps to locate quad.
-- ============================================================
local function drawPage8(lq, bat, curr, roll, ptch, yaw, alt, vspd, hdg, gspd, sats, gps)
  local c = crumbs[#crumbs]

  if not c then
    lcd.drawText(22, 10, HUD_NAME .. " " .. HUD_VERSION, SMLSIZE)
    lcd.drawLine(0, 17, 127, 17, SOLID, 0)
    lcd.drawText(14, 24, "NO GPS FIX RECORDED", SMLSIZE)
    lcd.drawText(10, 36, "Fly with GPS to log", SMLSIZE)
    lcd.drawText(10, 44, "last known position.", SMLSIZE)
    return
  end

  -- Header: age of save + flight time when saved
  local age   = math.floor((getTime() - c.tick) / 100)
  local age_m = math.floor(age / 60)
  local age_s = age % 60
  local ft_m  = math.floor(c.ft / 60)
  local ft_s  = math.floor(c.ft % 60)
  if gps and age < 5 then
    lcd.drawText(0, 9, string.format("FIX:LIVE  t=%d:%02d  #%d saves", ft_m, ft_s, #crumbs), SMLSIZE)
  else
    lcd.drawText(0, 9, string.format("FIX:%d:%02dago t=%d:%02d #%d", age_m, age_s, ft_m, ft_s, #crumbs), SMLSIZE)
  end
  lcd.drawLine(0, 16, 127, 16, SOLID, 0)

  -- Coordinates: paste into Google Maps
  lcd.drawText(0, 18, string.format("LAT:%.5f%s",
    math.abs(c.gps.lat), c.gps.lat >= 0 and "N" or "S"), SMLSIZE)
  lcd.drawText(0, 25, string.format("LON:%.5f%s",
    math.abs(c.gps.lon), c.gps.lon >= 0 and "E" or "W"), SMLSIZE)
  -- Alt + heading + speed on one compact line
  local info = string.format("ALT:%+.0fm", c.alt or 0)
  if c.hdg then info = info .. "  " .. hdgDir(c.hdg) end
  if c.spd and c.spd > 0.5 then info = info .. string.format(" %.1fm/s", c.spd) end
  lcd.drawText(0, 32, info, SMLSIZE)
  lcd.drawLine(0, 39, 127, 39, SOLID, 0)

  -- Distance and bearing from home
  if home_gps then
    local dx, dy = gpsToXY(home_gps.lat, home_gps.lon, c.gps.lat, c.gps.lon)
    local dist   = math.sqrt(dx*dx + dy*dy)
    local bear   = gpsBear(home_gps.lat, home_gps.lon, c.gps.lat, c.gps.lon)
    lcd.drawText(0, 41, string.format("HOME:%.0fm %s %d deg",
      dist, hdgDir(bear), math.floor(bear)), SMLSIZE)
  else
    lcd.drawText(0, 41, "HOME: not set (arm first)", SMLSIZE)
  end
  lcd.drawLine(0, 48, 127, 48, SOLID, 0)

  -- Previous crumb: gives direction of travel at time of crash
  local prev = crumbs[#crumbs - 1]
  if prev and prev.gps then
    lcd.drawText(0, 50, string.format("PRV:%.3f,%.3f",
      prev.gps.lat, prev.gps.lon), SMLSIZE)
    if c.bat then
      lcd.drawText(0, 57, string.format("    bat:%.2fV  #%d pts",
        c.bat, #crumbs), SMLSIZE)
    end
  elseif c.bat then
    lcd.drawText(0, 50, string.format("bat:%.2fV at save  sd:%d save",
      c.bat, #crumbs), SMLSIZE)
  end
end

-- ============================================================
-- PAGE 9: HOME / RADIO DISPLAY
-- Top: full attitude HUD (same as old P2). Bottom: slim radio controls.
-- ============================================================
local function drawPage9(lq, bat, curr, roll, ptch, yaw, alt, vspd, hdg, gspd, sats, gps)
  -- Left column: speed / battery / current / throttle  (x=0..25)
  local thr_raw = getValue("thr")
  local thr_pct_top = nil
  if type(thr_raw) == "number" then
    thr_pct_top = math.max(0, math.min(100, math.floor((thr_raw+1024)/20.48+0.5)))
  end
  lcd.drawText(0, 10, "SPD",                                                     SMLSIZE)
  lcd.drawText(0, 16, gspd and string.format("%.1f",  gspd) or "--",            SMLSIZE)
  lcd.drawText(0, 22, bat  and string.format("%.1fV", bat)  or "--V",           SMLSIZE)
  lcd.drawText(0, 28, curr and string.format("%.1fA", curr) or "--A",           SMLSIZE)
  lcd.drawText(0, 34, thr_pct_top ~= nil and string.format("T%3d%%", thr_pct_top) or "T---", SMLSIZE)

  -- Right column: altitude / vspeed / sats  (x=102..127)
  lcd.drawText(102, 10, alt  and string.format("%+.0f",  alt)  or "--",         SMLSIZE)
  lcd.drawText(102, 16, "m",                                                      SMLSIZE)
  lcd.drawText(102, 22, vspd and string.format("%+.1f", vspd)  or "--",         SMLSIZE)
  lcd.drawText(102, 28, "m/s",                                                    SMLSIZE)
  lcd.drawText(102, 35, sats and string.format("S%2d", math.floor(sats)) or "S--", SMLSIZE)

  -- Full horizon box (x=26..101, y=9..41)
  lcd.drawLine(26, 9,  26,  41, SOLID, 0)
  lcd.drawLine(101,9,  101, 41, SOLID, 0)
  lcd.drawLine(26, 9,  101, 9,  SOLID, 0)
  lcd.drawLine(26, 41, 101, 41, SOLID, 0)
  drawHorizon(roll, ptch)

  lcd.drawLine(0, 42, 127, 42, SOLID, 0)

  -- BOTTOM STRIP: slim radio controls (y=43..63, 21px)
  local ail = getValue("ail"); if type(ail) ~= "number" then ail = nil end
  local ele = getValue("ele"); if type(ele) ~= "number" then ele = nil end
  local thr = getValue("thr"); if type(thr) ~= "number" then thr = nil end
  local rud = getValue("rud"); if type(rud) ~= "number" then rud = nil end

  -- Left gimbal (10x10) | TX bars + voltage | switches | LQ number + bars | right gimbal
  -- Layout: x=0..9 | x=11..37 | x=41..87 | x=89..115 | x=117..126
  drawGimbal(0,   44, 10, 10, rud, thr)
  drawGimbal(117, 44, 10, 10, ail, ele)

  -- TX radio battery bars (n=3) + voltage on the left
  local txv = getValue("tx-voltage")
  if type(txv) ~= "number" then txv = nil end
  local tx_pct = txv and math.max(0, math.min(100, (txv - 3.3) / 0.9 * 100)) or 0
  drawSigBars(11, 44, tx_pct, 3)
  lcd.drawText(23, 44, txv and string.format("%.1f", txv) or "--", SMLSIZE)

  -- All 6 switches centered: SA SB SC (y=44), SD SE SF (y=51)
  local sws = {{"SA","sa"},{"SB","sb"},{"SC","sc"},{"SD","sd"},{"SE","se"},{"SF","sf"}}
  for i = 1, 3 do
    lcd.drawText(41 + (i-1)*16, 44, sws[i][1]..swLabel(sws[i][2]), SMLSIZE)
  end
  for i = 4, 6 do
    lcd.drawText(41 + (i-4)*16, 51, sws[i][1]..swLabel(sws[i][2]), SMLSIZE)
  end

  -- LQ connection bars (n=3) to drone on the right + percent number
  drawSigBars(105, 44, lq or 0, 3)
  lcd.drawText(89, 44, lq and string.format("%3d", math.floor(lq)) or " --", SMLSIZE)

  -- Throttle bar
  local thr_pct = thr and math.max(0, math.min(100, math.floor((thr+1024)/20.48+0.5))) or 0
  lcd.drawText(0, 58, "T:", SMLSIZE)
  lcd.drawRectangle(10, 58, 117, 4)
  if thr_pct > 0 then
    lcd.drawFilledRectangle(11, 59, math.floor(thr_pct*115/100), 2, FORCE)
  end
end

-- ============================================================
-- MAIN LOOP
-- ============================================================
local function run(event, touchState)
  if event == EVT_ENTER_BREAK then
    page = (page % NUM_PAGES) + 1
  elseif event == EVT_ENTER_LONG and page == 6 then
    max_alt    = nil
    max_spd    = nil
    min_bat    = nil
    max_dist   = 0
    tot_dist   = 0
    flt_secs   = 0
    arm_count  = 0
    track      = {}
    track_n    = 0
    last_trk_x = 0
    last_trk_y = 0
    alt_hist   = {}
    alt_hist_n = 0
    reset_tick = getTime()
  end

  lcd.clear()

  local lq   = get("RQly")
  local bat  = getBat()
  local curr = get("Curr")
  local roll = get("Roll")
  local ptch = get("Ptch") or get("Pitch")
  local yaw  = get("Yaw")
  local alt  = get("Alt")
  local vspd = get("VSpd")
  local hdg  = get("Hdg")
  local gspd = get("GSpd")
  local sats = get("Sats")
  local gps  = getGPS()
  local mode, is_warn, is_armed = getMode()

  if not hdg and yaw then hdg = (yaw+360)%360 end

  -- Update session records
  if alt  and (not max_alt or alt  > max_alt) then max_alt = alt  end
  if gspd and (not max_spd or gspd > max_spd) then max_spd = gspd end
  if bat and is_armed and (not min_bat or bat < min_bat) then min_bat = bat end

  cur_armed = is_armed

  -- Flight timer
  if is_armed and not was_armed then
    arm_tick     = getTime()
    arm_count    = arm_count + 1
    pos_interval = 6000
    low_bat_trig = false
    low_lq_trig  = false
    addCrumb(last_fix_gps, last_fix_alt, bat, last_fix_hdg, last_fix_spd)
    savePosToSD()
  elseif not is_armed and was_armed and arm_tick then
    flt_secs = flt_secs + (getTime() - arm_tick) / 100
    arm_tick  = nil
    addCrumb(last_fix_gps, last_fix_alt, bat, last_fix_hdg, last_fix_spd)
    savePosToSD()
  end
  was_armed = is_armed

  -- GPS home lock + track recording
  if gps then
    last_fix_gps  = gps
    last_fix_alt  = alt
    last_fix_tick = getTime()
    last_fix_hdg  = hdg
    last_fix_spd  = gspd
    if not home_gps and (not sats or sats >= HOME_MIN_SATS) then
      home_gps = gps
      addCrumb(gps, alt, bat, hdg, gspd)  -- first fix: seed P9 immediately
      crumb_tick = getTime()
    elseif home_gps then
      -- Periodic auto-crumb so P9 stays fresh without needing to arm
      local now_ct = getTime()
      if now_ct - crumb_tick >= CRUMB_INTERVAL then
        crumb_tick = now_ct
        addCrumb(gps, alt, bat, hdg, gspd)
      end
      local cx, cy = gpsToXY(home_gps.lat, home_gps.lon, gps.lat, gps.lon)
      local d = math.sqrt(cx*cx + cy*cy)
      if d > max_dist then max_dist = d end
      -- Total distance (filter GPS noise < 2m steps)
      if last_gps then
        local lx, ly = gpsToXY(home_gps.lat, home_gps.lon, last_gps.lat, last_gps.lon)
        local step = math.sqrt((cx-lx)*(cx-lx) + (cy-ly)*(cy-ly))
        if step >= 2 then
          tot_dist = tot_dist + step
          last_gps = gps
        end
      else
        last_gps = gps
      end
      -- Track: add point every 5m
      local ddx = cx - last_trk_x
      local ddy = cy - last_trk_y
      if ddx*ddx + ddy*ddy >= 25 then
        if track_n < TRACK_MAX then
          track_n = track_n + 1
          track[track_n] = {x=cx, y=cy}
        else
          for j = 1, TRACK_MAX-1 do track[j] = track[j+1] end
          track[TRACK_MAX] = {x=cx, y=cy}
        end
        last_trk_x, last_trk_y = cx, cy
      end
    end
  end

  -- Altitude history (sampled every 1.5s for the graph on P2)
  do
    local now_ah = getTime()
    if now_ah - alt_hist_tick >= ALT_HIST_INT then
      alt_hist_tick = now_ah
      if alt_hist_n < ALT_HIST_MAX then
        alt_hist_n = alt_hist_n + 1
        alt_hist[alt_hist_n] = alt or 0
      else
        for j = 1, ALT_HIST_MAX-1 do alt_hist[j] = alt_hist[j+1] end
        alt_hist[ALT_HIST_MAX] = alt or 0
      end
    end
  end

  -- Emergency save: low battery triggers immediate save + fast 10s periodic saves
  local _, cells_now = batInfo(bat)
  if bat and cells_now then
    local per_cell = bat / cells_now
    if per_cell < BAT_WARN_V and not low_bat_trig then
      low_bat_trig = true
      pos_interval = 1000
      addCrumb(gps or last_fix_gps, alt or last_fix_alt, bat, hdg, gspd)
      savePosToSD()
    end
    if per_cell >= BAT_WARN_V + 0.05 then low_bat_trig = false end
  end

  -- Emergency save: sudden LQ drop (going out of range / about to crash)
  if lq and lq < LQ_WARN_PCT and not low_lq_trig then
    low_lq_trig = true
    addCrumb(gps or last_fix_gps, alt or last_fix_alt, bat, hdg, gspd)
    savePosToSD()
  end
  if lq and lq >= LQ_WARN_PCT then low_lq_trig = false end

  -- Periodic position save while armed
  if is_armed then
    local now = getTime()
    if now - pos_tick >= pos_interval then
      addCrumb(gps or last_fix_gps, alt or last_fix_alt, bat, hdg, gspd)
      savePosToSD()
      pos_tick = now
    end
  end

  drawTitle(mode, is_warn, lq, page, is_armed)

  if     page == 1 then drawPage9(lq,bat,curr,roll,ptch,yaw,alt,vspd,hdg,gspd,sats,gps)
  elseif page == 2 then drawPage1(lq,bat,curr,roll,ptch,yaw,alt,vspd,hdg,gspd,sats,gps)
  elseif page == 3 then drawPage2(lq,bat,curr,roll,ptch,yaw,alt,vspd,hdg,gspd,sats,gps)
  elseif page == 4 then drawPage3(lq,bat,curr,roll,ptch,yaw,alt,vspd,hdg,gspd,sats,gps)
  elseif page == 5 then drawPage4(lq,bat,curr,roll,ptch,yaw,alt,vspd,hdg,gspd,sats,gps)
  elseif page == 6 then drawPage5(lq,bat,curr,roll,ptch,yaw,alt,vspd,hdg,gspd,sats,gps)
  elseif page == 7 then drawPage6(lq,bat,curr,roll,ptch,yaw,alt,vspd,hdg,gspd,sats,gps)
  elseif page == 8 then drawPage7(lq,bat,curr,roll,ptch,yaw,alt,vspd,hdg,gspd,sats,gps)
  elseif page == 9 then drawPage8(lq,bat,curr,roll,ptch,yaw,alt,vspd,hdg,gspd,sats,gps)
  end

  return 0
end

return { run = run }

