local ButtonTable = require("ui/widget/buttontable")
local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local FFIUtil = require("ffi/util")
local Geom = require("ui/geometry")
local GetText = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = GetText
local T = FFIUtil.template

local STATE = {
    enabled = false,
    enable_save_original_button = true,
    save_dir = nil,
}

local PATCH = {
    installed = false,
    original_imageviewer_init = nil,
}

local Imagesave = WidgetContainer:extend{
    name = "imagesave",
    is_doc_only = false,
    updated = false,
}

local function _ko_i18n_file_exists(path)
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    f:close()
    return true
end

local function _ko_i18n_plugin_root()
    return (debug.getinfo(1, "S").source or ""):match("@?(.*/)")
end

local function normalizeDir(path)
    if not path then
        return nil
    end
    path = path:gsub("/+$", "")
    if path == "" then
        return "/"
    end
    return path
end

local function getDefaultSaveDir()
    local Screenshoter = require("ui/widget/screenshoter")
    return normalizeDir(Screenshoter:getScreenshotDir())
end

local function getEffectiveSaveDir()
    return normalizeDir(STATE.save_dir) or getDefaultSaveDir()
end

local function ensureDirectory(path)
    if not path then
        return false
    end
    return util.makePath(path)
end

local function makeUniquePath(dir, base_name, ext)
    local candidate = string.format("%s/%s.%s", dir, base_name, ext)
    if not lfs.attributes(candidate, "mode") then
        return candidate
    end
    local idx = 1
    while true do
        candidate = string.format("%s/%s_%d.%s", dir, base_name, idx, ext)
        if not lfs.attributes(candidate, "mode") then
            return candidate
        end
        idx = idx + 1
    end
end

local function showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

local function getActiveUI()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager and FileManager.instance then
        return FileManager.instance
    end
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI and ReaderUI.instance then
        return ReaderUI.instance
    end
end

local function showSavedPathDialog(path)
    local ui = getActiveUI()
    local file = ui and ui.document and ui.document.file

    local dialog
    local buttons = {
        {
            {
                text = _("Delete"),
                callback = function()
                    os.remove(path)
                    dialog:onClose()
                end,
            },
            {
                text = _("Set as book cover"),
                enabled = file and ui and ui.bookinfo and ui.bookinfo.setCustomCoverFromImage and true or false,
                callback = function()
                    ui.bookinfo:setCustomCoverFromImage(file, path)
                    os.remove(path)
                    dialog:onClose()
                end,
            },
        },
        {
            {
                text = _("View"),
                callback = function()
                    local ImageViewer = require("ui/widget/imageviewer")
                    local image_viewer = ImageViewer:new{
                        file = path,
                        modal = true,
                        with_title_bar = false,
                        buttons_visible = true,
                    }
                    UIManager:show(image_viewer)
                end,
            },
        },
    }
    if Device:supportsScreensaver() then
        table.insert(buttons[2], {
            text = _("Set as wallpaper"),
            callback = function()
                G_reader_settings:saveSetting("screensaver_type", "document_cover")
                G_reader_settings:saveSetting("screensaver_document_cover", path)
                dialog:onClose()
            end,
        })
    end

    dialog = ButtonDialog:new{
        title = _("Screenshot saved to:") .. "\n\n" .. BD.filepath(path) .. "\n",
        modal = true,
        buttons = buttons,
        tap_close_callback = function()
            local current_path = ui and ui.file_chooser and ui.file_chooser.path
            if current_path and current_path .. "/" == path:match(".*/") then
                ui.file_chooser:refreshPath()
            end
        end,
    }
    UIManager:show(dialog)
    UIManager:setDirty(nil, "full")
end

local function saveOriginalImage(viewer)
    local dir = getEffectiveSaveDir()
    if not ensureDirectory(dir) then
        showInfo(T(_("Unable to create save folder:\n%1"), dir))
        return true
    end

    local source_file = viewer.file
    if source_file and lfs.attributes(source_file, "mode") == "file" then
        local _, source_name = util.splitFilePathName(source_file)
        source_name = util.getSafeFilename(source_name ~= "" and source_name or "image", dir)
        local source_stem, source_ext = util.splitFileNameSuffix(source_name)
        source_ext = source_ext ~= "" and source_ext:lower() or "png"
        local target = makeUniquePath(dir, source_stem, source_ext)
        local ok = pcall(FFIUtil.copyFile, source_file, target)
        if ok and lfs.attributes(target, "mode") == "file" then
            showSavedPathDialog(target)
        else
            showInfo(T(_("Unable to copy image file.\n%1"), source_file))
        end
        return true
    end

    local bb = viewer.image
    if not bb then
        showInfo(_("Original image unavailable."))
        return true
    end

    local base_name = os.date("ImageSave_%Y-%m-%d_%H%M%S")
    local target = makeUniquePath(dir, base_name, "png")
    local ok = false
    if bb.writeToFile then
        local call_ok, wrote = pcall(bb.writeToFile, bb, target, "png")
        ok = call_ok and wrote ~= false
    elseif bb.writePNG then
        local call_ok, wrote = pcall(bb.writePNG, bb, target)
        ok = call_ok and wrote ~= false
    end

    if ok and lfs.attributes(target, "mode") == "file" then
        showSavedPathDialog(target)
    else
        showInfo(T(_("Failed to save image.\n%1"), target))
    end
    return true
end

local function rebuildImageViewerButtons(viewer)
    local save_button = {
        id = "imagesave_viewport_save",
        text = _("Save"),
        callback = function()
            viewer:onSaveImageView()
        end,
    }
    if STATE.enable_save_original_button then
        save_button.hold_callback = function()
            return saveOriginalImage(viewer)
        end
    end

    local buttons = {
        {
            {
                id = "scale",
                text = viewer._scale_to_fit and _("Original size") or _("Scale"),
                callback = function()
                    viewer.scale_factor = viewer._scale_to_fit and 1 or 0
                    viewer._scale_to_fit = not viewer._scale_to_fit
                    viewer._center_x_ratio = 0.5
                    viewer._center_y_ratio = 0.5
                    viewer:update()
                end,
            },
            {
                id = "rotate",
                text = viewer.rotated and _("No rotation") or _("Rotate"),
                callback = function()
                    viewer.rotated = not viewer.rotated and true or false
                    viewer:update()
                end,
            },
            save_button,
            {
                id = "close",
                text = _("Close"),
                callback = function()
                    viewer:onClose()
                end,
            },
        },
    }

    if viewer.button_container and viewer.button_container.free then
        viewer.button_container:free()
    end

    viewer.button_table = ButtonTable:new{
        width = viewer.width - 2 * viewer.button_padding,
        buttons = buttons,
        zero_sep = true,
        show_parent = viewer,
    }
    viewer.button_container = CenterContainer:new{
        dimen = Geom:new{
            w = viewer.width,
            h = viewer.button_table:getSize().h,
        },
        viewer.button_table,
    }
end

local function installImageViewerPatch()
    if PATCH.installed then
        return
    end

    local ImageViewer = require("ui/widget/imageviewer")
    PATCH.original_imageviewer_init = ImageViewer.init
    ImageViewer.init = function(viewer, ...)
        PATCH.original_imageviewer_init(viewer, ...)
        if not STATE.enabled then
            return
        end
        if viewer.button_table and viewer.button_table:getButtonById("imagesave_viewport_save") then
            return
        end
        rebuildImageViewerButtons(viewer)
        viewer:update()
    end
    PATCH.installed = true
end

function Imagesave:setupPluginLocalization()
    local lang = G_reader_settings and G_reader_settings:readSetting("language") or "C"
    if not lang or lang == "" or lang == "C" then
        return false
    end
    lang = lang:gsub("%..*$", "")

    local plugin_root = _ko_i18n_plugin_root()
    if not plugin_root then
        return false
    end

    local locales = { lang, lang:match("^([a-z][a-z])[_-]") }
    for _, locale in ipairs(locales) do
        if locale and locale ~= "" then
            local mo_path = string.format(plugin_root .. "l10n/%s/LC_MESSAGES/imagesave.mo", locale)
            if _ko_i18n_file_exists(mo_path) then
                if GetText.loadMO(mo_path) then
                    return true
                end
            end
        end
    end
    return false
end

function Imagesave:syncRuntimeState()
    self.enabled = self.settings:isTrue("enable")
    self.enable_save_original_button = self.settings:nilOrTrue("enable_save_original_button")
    self.save_dir = normalizeDir(self.settings:readSetting("save_dir"))
    STATE.enabled = self.enabled
    STATE.enable_save_original_button = self.enable_save_original_button
    STATE.save_dir = self.save_dir
end

function Imagesave:init()
    self:setupPluginLocalization()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/imagesave.lua")
    self:syncRuntimeState()
    installImageViewerPatch()
    self.ui.menu:registerToMainMenu(self)
end

function Imagesave:addToMainMenu(menu_items)
    menu_items.imagesave = {
        text = _("Image save"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Image save"),
                checked_func = function()
                    return self.enabled
                end,
                callback = function()
                    self.enabled = not self.enabled
                    self.settings:saveSetting("enable", self.enabled)
                    STATE.enabled = self.enabled
                    self.updated = true
                end,
            },
            {
                text = _("Save original"),
                checked_func = function()
                    return self.enable_save_original_button
                end,
                callback = function()
                    self.enable_save_original_button = not self.enable_save_original_button
                    self.settings:saveSetting("enable_save_original_button", self.enable_save_original_button)
                    STATE.enable_save_original_button = self.enable_save_original_button
                    if self.enable_save_original_button then
                        showInfo(_("Long press \"Save\" in image viewer to save original image."))
                    end
                    self.updated = true
                end,
            },
            {
                text_func = function()
                    return T(_("Save folder: %1"), getEffectiveSaveDir())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local default_path = getDefaultSaveDir()
                    local current_path = getEffectiveSaveDir()
                    filemanagerutil.showChooseDialog(_("Current image save folder:"), function(path)
                        path = normalizeDir(path)
                        if path == default_path then
                            self.settings:delSetting("save_dir")
                            self.save_dir = nil
                        else
                            self.settings:saveSetting("save_dir", path)
                            self.save_dir = path
                        end
                        STATE.save_dir = self.save_dir
                        self.updated = true
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end, current_path, default_path)
                end,
            },
        },
    }
end

function Imagesave:onFlushSettings()
    if self.updated and self.settings then
        self.settings:flush()
        self.updated = false
    end
end

return Imagesave
