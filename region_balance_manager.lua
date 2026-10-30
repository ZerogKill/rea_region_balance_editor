-- @description Region Balance Manager
-- @version 1.1
-- @author Collaborative Build

local reaper = reaper

if not reaper.APIExists('ImGui_CreateContext') then
  reaper.ShowMessageBox("Для работы скрипта требуется библиотека ReaImGui.\nПожалуйста, установите её через ReaPack.", "Ошибка", 0)
  return
end

-- ============================================================================
-- 1. АВТОМАТИЧЕСКАЯ РЕГИСТРАЦИЯ В __startup.lua
-- ============================================================================
local function EnsureStartupRegistration()
  local resource_path = reaper.GetResourcePath()
  local startup_path = resource_path .. "/__startup.lua"
  local _, current_script_path = reaper.get_action_context()
  
  if not current_script_path or current_script_path == "" then return end
  local normalized_path = current_script_path:gsub("\\", "/")

  local content = ""
  local f = io.open(startup_path, "r")
  if f then
    content = f:read("*all")
    f:close()
  end

  if not content:find(normalized_path) then
    local f_out = io.open(startup_path, "a")
    if f_out then
      f_out:write("\n-- Region Balance Manager Auto-Start\n")
      f_out:write('if reaper.file_exists("' .. normalized_path .. '") then dofile("' .. normalized_path .. '") end\n')
      f_out:close()
    end
  end
end

EnsureStartupRegistration()

-- ============================================================================
-- ЕДИНСТВЕННЫЙ ЭКЗЕМПЛЯР И ПЕРЕМЕННЫЕ СОСТОЯНИЯ
-- ============================================================================
local ext_key = "REGION_BALANCE_MANAGER_RUNNING"
if reaper.GetExtState("RegionBalanceManager", ext_key) == "true" then
  -- Если скрипт уже запущен в фоне, просто активируем показ окна
  reaper.SetExtState("RegionBalanceManager", "SHOW_WINDOW", "true", false)
  return
end
reaper.SetExtState("RegionBalanceManager", ext_key, "true", false)
reaper.SetExtState("RegionBalanceManager", "SHOW_WINDOW", "true", false)

local ctx = reaper.ImGui_CreateContext('Region Balance Manager')
local EXT_SECTION = "REGION_BALANCE_MANAGER"

local regions = {}
local snapshots = {}
local active_edit_region = nil
local current_playing_region = nil

local transition_mode = 0      -- 0: Instant, 1: Gradual
local transition_time_ms = 500
local is_fading = false
local fade_start_time = 0
local fade_tracks = {}

local show_window = true
local first_run_docked = false

-- ============================================================================
-- ФУНКЦИИ РАБОТЫ С ДАННЫМИ И ПРОЕКТОМ
-- ============================================================================

local function SaveSnapshotsToProject()
  local str_parts = {}
  for r_id, tr_data in pairs(snapshots) do
    local tr_parts = {}
    for tr_guid, vol in pairs(tr_data) do
      table.insert(tr_parts, tr_guid .. ":" .. tostring(vol))
    end
    table.insert(str_parts, r_id .. "=" .. table.concat(tr_parts, ","))
  end
  local full_str = table.concat(str_parts, ";")
  reaper.SetProjExtState(0, EXT_SECTION, "SNAPSHOTS", full_str)
  reaper.MarkProjectDirty(0)
end

local function LoadSnapshotsFromProject()
  snapshots = {}
  local retval, val = reaper.GetProjExtState(0, EXT_SECTION, "SNAPSHOTS")
  if retval == 1 and val ~= "" then
    for region_block in val:gmatch("[^;]+") do
      local r_id, tr_str = region_block:match("([^=]+)=(.*)")
      if r_id and tr_str then
        snapshots[r_id] = {}
        for tr_guid, vol in tr_str:gmatch("([^:,]+):([^:,]+)") do
          snapshots[r_id][tr_guid] = tonumber(vol)
        end
      end
    end
  end
end

local function GetRegionID(reg)
  return string.format("%s_%.3f_%.3f", reg.name, reg.pos, reg.r_end)
end

local function RefreshRegions()
  regions = {}
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions
  for i = 0, total - 1 do
    local retval, isrgn, pos, r_end, name, markindex, color = reaper.EnumProjectMarkers3(0, i)
    if retval and isrgn then
      table.insert(regions, {
        idx = markindex,
        pos = pos,
        r_end = r_end,
        name = (name == "" and ("Region " .. markindex) or name),
        color = color
      })
    end
  end
  table.sort(regions, function(a, b) return a.pos < b.pos end)
end

-- ============================================================================
-- УПРАВЛЕНИЕ СНАПШОТАМИ И ФЕЙДЕРАМИ
-- ============================================================================

local function CaptureSnapshotForRegion(reg)
  if not reg then return end
  local r_id = GetRegionID(reg)
  snapshots[r_id] = {}
  
  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local tr = reaper.GetTrack(0, i)
    local guid = reaper.GetTrackGUID(tr)
    local vol = reaper.GetMediaTrackInfo_Value(tr, "D_VOL")
    snapshots[r_id][guid] = vol
  end
  SaveSnapshotsToProject()
end

local function ApplySnapshot(reg)
  if not reg then return end
  local r_id = GetRegionID(reg)
  local snap = snapshots[r_id]
  if not snap then return end

  local track_count = reaper.CountTracks(0)

  if transition_mode == 0 then
    for i = 0, track_count - 1 do
      local tr = reaper.GetTrack(0, i)
      local guid = reaper.GetTrackGUID(tr)
      if snap[guid] then
        reaper.SetMediaTrackInfo_Value(tr, "D_VOL", snap[guid])
      end
    end
    is_fading = false
  else
    fade_tracks = {}
    for i = 0, track_count - 1 do
      local tr = reaper.GetTrack(0, i)
      local guid = reaper.GetTrackGUID(tr)
      if snap[guid] then
        local current_vol = reaper.GetMediaTrackInfo_Value(tr, "D_VOL")
        table.insert(fade_tracks, {
          track = tr,
          start_vol = current_vol,
          target_vol = snap[guid]
        })
      end
    end
    fade_start_time = reaper.time_precise()
    is_fading = true
  end
  current_playing_region = r_id
end

local function ProcessFades()
  if not is_fading then return end
  local now = reaper.time_precise()
  local elapsed = (now - fade_start_time) * 1000
  local progress = elapsed / transition_time_ms

  if progress >= 1.0 then
    progress = 1.0
    is_fading = false
  end

  for _, item in ipairs(fade_tracks) do
    if reaper.ValidatePtr(item.track, "MediaTrack*") then
      local new_vol = item.start_vol + (item.target_vol - item.start_vol) * progress
      reaper.SetMediaTrackInfo_Value(item.track, "D_VOL", new_vol)
    end
  end
end

local function ToggleRegionEditMode(reg)
  if active_edit_region and (active_edit_region.pos == reg.pos and active_edit_region.r_end == reg.r_end) then
    CaptureSnapshotForRegion(active_edit_region)
    reaper.GetSet_LoopTimeRange(true, true, 0, 0, false)
    reaper.GetSetRepeat(0)
    active_edit_region = nil
  else
    if active_edit_region then
      CaptureSnapshotForRegion(active_edit_region)
    end

    active_edit_region = reg
    reaper.SetEditCurPos(reg.pos, true, true)
    reaper.GetSet_LoopTimeRange(true, true, reg.pos, reg.r_end, false)
    reaper.GetSetRepeat(1)
    ApplySnapshot(reg)
  end
end

-- ============================================================================
-- ГЛАВНЫЙ ЦИКЛ (ФОНОВЫЙ ДВИЖОК + UI)
-- ============================================================================

local function MainLoop()
  -- 1. Проверка внешнего сигнала на открытие окна (если повторно запустили скрипт)
  if reaper.GetExtState("RegionBalanceManager", "SHOW_WINDOW") == "true" then
    show_window = true
    reaper.SetExtState("RegionBalanceManager", "SHOW_WINDOW", "false", false)
  end

  -- 2. Фоновый движок воспроизведения работает всегда (даже при закрытом окне)
  ProcessFades()

  if not active_edit_region then
    local play_state = reaper.GetPlayState()
    if (play_state & 1) == 1 then
      local play_pos = reaper.GetPlayPosition()
      local current_reg = nil
      for _, reg in ipairs(regions) do
        if play_pos >= reg.pos and play_pos < reg.r_end then
          current_reg = reg
          break
        end
      end

      if current_reg then
        local r_id = GetRegionID(current_reg)
        if current_playing_region ~= r_id then
          ApplySnapshot(current_reg)
        end
      end
    end
  end

  -- 3. Отрисовка интерфейса, если окно включено
  if show_window then
    RefreshRegions()

    -- Настройка позиционирования у левой стенки при первом занесу / пустом проекте
    if not first_run_docked then
      reaper.ImGui_SetNextWindowPos(ctx, 20, 100, reaper.ImGui_Cond_FirstUseEver)
      reaper.ImGui_SetNextWindowSize(ctx, 320, 450, reaper.ImGui_Cond_FirstUseEver)
      first_run_docked = true
    end

    local visible, open = reaper.ImGui_Begin(ctx, 'Region Balance Manager', true)
    if visible then
      reaper.ImGui_Text(ctx, "Режим переходов:")
      
      if reaper.ImGui_RadioButton(ctx, "Моментальный (Instant)", transition_mode == 0) then
        transition_mode = 0
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_RadioButton(ctx, "Плавный (Gradual)", transition_mode == 1) then
        transition_mode = 1
      end

      if transition_mode == 1 then
        reaper.ImGui_SetNextItemWidth(ctx, 150)
        _, transition_time_ms = reaper.ImGui_SliderInt(ctx, "Кроссфейд (мс)", transition_time_ms, 50, 3000)
      end

      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Text(ctx, "Список регионов:")
      reaper.ImGui_Spacing(ctx)

      for _, reg in ipairs(regions) do
        local r_id = GetRegionID(reg)
        local is_editing = active_edit_region and (GetRegionID(active_edit_region) == r_id)
        local has_snapshot = snapshots[r_id] ~= nil

        local label = string.format("[%s] %s", reg.idx, reg.name)
        if has_snapshot then
          label = label .. " [Saved]"
        else
          label = label .. " [No Data]"
        end

        if is_editing then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x228B22FF)
        end

        if reaper.ImGui_Button(ctx, label, -1, 35) then
          ToggleRegionEditMode(reg)
        end

        if is_editing then
          reaper.ImGui_PopStyleColor(ctx)
        end
      end

      if active_edit_region then
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_TextColored(ctx, 0x00FF00FF, "Редактирование: " .. active_edit_region.name)
        if reaper.ImGui_Button(ctx, "Завершить и сохранить баланс", -1, 30) then
          ToggleRegionEditMode(active_edit_region)
        end
      end

      reaper.ImGui_End(ctx)
    end

    if not open then
      show_window = false -- Закрываем только окно интерфейса, фоновый движок продолжает работу
    end
  end

  reaper.defer(MainLoop)
end

-- ============================================================================
-- СТАРТ И КОРРЕКТНОЕ ЗАВЕРШЕНИЕ
-- ============================================================================
LoadSnapshotsFromProject()
reaper.atexit(function()
  reaper.SetExtState("RegionBalanceManager", ext_key, "false", false)
end)

reaper.defer(MainLoop)
