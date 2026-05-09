local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local TextViewer = require("ui/widget/textviewer")
local Device = require("device")
local DataStorage = require("datastorage")
local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template
local lfs = require("libs/libkoreader-lfs")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Screen = Device.screen

local CloudLibraryPlugin = WidgetContainer:extend {
    is_doc_only = false,
}

CloudLibraryPlugin.default_settings = {
    last_sync = "Never",
    metadata_naming_mode = "metadata",
    auto_sync_enabled = false,
    auto_upload_on_annotate = false,
    auto_upload_on_close = false,
    auto_upload_on_suspend = false,
    auto_download_on_open = false,
    auto_download_mode = "merge",
    auto_sync_notify = true,
    upload_json = false,
    use_notemark_format = false,
    sync_log_enabled = false,
    book_naming_mode = "title",
    book_download_dir = nil,
    override_keep_local_settings = true,
    book_cloud_dir = nil,
    book_cloud_type = nil,
    book_cloud_address = nil,
    book_cloud_username = nil,
    book_cloud_password = nil,
}


function CloudLibraryPlugin:init()
    self.VERSION = "v1.3"
    logger.info("CloudLibrary: init 开始, 版本 " .. self.VERSION)
    
    self.ui.menu:registerToMainMenu(self)
    
    local utils = require("utils")
    utils.insert_after_statistics(self.plugin_id)
    self:onDispatcherRegisterActions()
    
    self.settings = G_reader_settings:readSetting(self.plugin_id, self.default_settings)
    
    local AutoSync = require("auto_sync")
    local ManualSync = require("manual_sync")
    local Hooks = require("hooks")
    
    if not CloudLibraryPlugin._auto_sync then
        self.auto_sync = AutoSync:new(self, self.settings)
        CloudLibraryPlugin._auto_sync = self.auto_sync
    else
        self.auto_sync = CloudLibraryPlugin._auto_sync
        self.auto_sync.settings = self.settings
        self.auto_sync.plugin = self
    end
    
    self.manual_sync = ManualSync:new(self, self.auto_sync)
    self.hooks = Hooks:new(self, self.auto_sync)
    
    if self.ui then
        self.ui.CloudLibrary = self
    end
    
    if not CloudLibraryPlugin._global_hooks_registered then
        self.hooks:hookAnnotationModified()
        self.hooks:hookOnReaderReady()
        CloudLibraryPlugin._global_hooks_registered = true
    end
    
    self.hooks:hookOnClose()
    self.hooks:hookOnSuspend()

    G_reader_settings:saveSetting("cloudlibrary_skip_auto_download", false)
    
    logger.info("CloudLibrary: 插件初始化完成")
end

function CloudLibraryPlugin:addToMainMenu(menu_items)
    menu_items.cloud_library_plugin = {
        text = _("云端书库"),
        sorting_hint = "tools",
        sub_item_table = self:buildMenuItems(),
    }
end

function CloudLibraryPlugin:buildMenuItems()
    local utils = require("utils")
    local items = {
        {
            text = _("设置"),
            sub_item_table = self:buildSettingsMenu(),
            separator = true,
        },
        {
            text = _("元数据同步"),
            sub_item_table = self:buildMetadataSyncMenu(),
        },
        {
            text = _("书籍同步"),
            sub_item_table = self:buildBookSyncMenu(),
        },
        {
            text = _("查看同步记录"),
            callback = function()
                self:viewSyncLog()
            end,
        },
        {
            text = _("插件说明"),
            callback = function()
                self:showPluginInfo()
            end,
        },
        {
            text = _("检查更新") .. "  (作者：gytwo  当前版本: " .. self.VERSION .. ")",
            callback = function()
                local update = require("update")
                update.check_for_updates(false, self)
            end
        },
        {
            enabled = false,
            text_func = function()
                local last_sync = self.settings.last_sync
                if last_sync == "Never" then
                    return T(_("最后同步：%1"), last_sync)
                end
                local time_part = last_sync:match("(.+) %(") or last_sync
                local action_part = last_sync:match("%((.+)%)") or ""
                if action_part ~= "" then
                    return string.format("最后同步：%s\n(%s)", time_part, action_part)
                else
                    return T(_("最后同步：%1"), last_sync)
                end
            end
        },
    }
    return items
end

function CloudLibraryPlugin:buildSettingsMenu()
    local utils = require("utils")
    return {
        {
            text = _("云端目录"),
            sub_item_table = self:buildCloudDirMenu(),
            separator = true,
        },
        {
            text = _("云端命名方式"),
            sub_item_table = self:buildNamingModeMenu(),
            separator = true,
        },
        {
            text_func = function()
                local dir = self.settings.book_download_dir
                if dir and dir ~= "" then
                    return _("书籍下载目录: ") .. dir
                else
                    return _("设置书籍下载目录")
                end
            end,
            callback = function()
                self:chooseBookLocalDir()
            end,
        },
        {
            text = _("元数据下载模式（手动）"),
            sub_item_table = {
                {
                    text = _("覆盖更新"),
                    checked_func = function()
                        return self.settings.auto_download_mode == "override"
                    end,
                    callback = function()
                        self.settings.auto_download_mode = "override"
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(_("元数据下载模式（手动）：覆盖更新"))
                    end
                },
                {
                    text = _("合并更新"),
                    checked_func = function()
                        return self.settings.auto_download_mode == "merge"
                    end,
                    callback = function()
                        self.settings.auto_download_mode = "merge"
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(_("元数据下载模式（手动）：合并更新"))
                    end
                },
            },
        },
        {
            text = _("自动同步设置（仅元数据）"),
            sub_item_table = self:buildAutoSyncMenu(),
            separator = true,
        },
        {
            text = _("元数据额外备份JSON"),
            sub_item_table = {
                {
                    text = _("保持原有格式（默认）"),
                    checked_func = function()
                        return self.settings.upload_json == true and self.settings.use_notemark_format == false
                    end,
                    callback = function()
                        if self.settings.upload_json and not self.settings.use_notemark_format then
                            self.settings.upload_json = false
                            self.settings.use_notemark_format = false
                        else
                            self.settings.upload_json = true
                            self.settings.use_notemark_format = false
                        end
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(self.settings.upload_json and "已开启：原始格式" or "已关闭额外备份JSON")
                    end
                },
                {
                    text = _("使用NoteMarkData格式（标注转换）"),
                    checked_func = function()
                        return self.settings.upload_json == true and self.settings.use_notemark_format == true
                    end,
                    help_text = _("开启后：将标注转换为NoteMarkData格式"),
                    callback = function()
                        if self.settings.upload_json and self.settings.use_notemark_format then
                            self.settings.upload_json = false
                            self.settings.use_notemark_format = false
                        else
                            self.settings.upload_json = true
                            self.settings.use_notemark_format = true
                        end
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(self.settings.upload_json and "已开启：NoteMarkData格式" or "已关闭额外备份JSON")
                    end
                },
            },
        },
        {
            text = _("覆盖更新时保留本地文档设置"),
            checked_func = function()
                return self.settings.override_keep_local_settings == true
            end,
            help_text = _("开启后：覆盖更新时保留本地的字体、边距等设置，仅同步标注和进度"),
            callback = function()
                self.settings.override_keep_local_settings = not self.settings.override_keep_local_settings
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                utils.show_msg(self.settings.override_keep_local_settings and 
                    "已开启：覆盖更新时保留本地文档设置" or 
                    "已关闭：覆盖更新时完全使用云端文件")
            end
        },
        {
            text = _("开启记录云同步"),
            checked_func = function()
                return self.settings.sync_log_enabled == true
            end,
            help_text = _("开启后：自动上传本地记录至云端或从云端合并同步记录至本地"),
            callback = function()
                self.settings.sync_log_enabled = not self.settings.sync_log_enabled
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                
                if self.settings.sync_log_enabled then
                    local sync_log = require("sync_log")
                    sync_log.sync_log()
                    utils.show_msg(_("已开启记录云同步"))
                else
                    utils.show_msg(_("已关闭记录云同步"))
                end
            end
        },
        {
            text = _("清空云端同步记录"),
            help_text = _("清空云端存储的所有同步记录，不会影响本地记录"),
            callback = function()
                self:confirmClearCloudLog()
            end,
            separator = true,
        },
    }
end

function CloudLibraryPlugin:buildCloudDirMenu()
    return {
        {
            text_func = function()
                local remote = require("remote")
                local server = remote.get_server()
                if server and server.url then
                    return _("元数据云端目录: ") .. server.url
                else
                    return _("设置元数据云端目录")
                end
            end,
            callback = function()
                local SyncService = require("apps/cloudstorage/syncservice")
                local remote = require("remote")
                local sync_service = SyncService:new{}
                sync_service.onConfirm = function(server)
                    remote.save_server_settings(server)
                end
                UIManager:show(sync_service)
            end
        },
        {
            text_func = function()
                local book_dir = self.settings.book_cloud_dir
                if book_dir and book_dir ~= "" then
                    return _("书籍云端目录: ") .. book_dir
                else
                    return _("设置书籍云端目录（默认与元数据相同）")
                end
            end,
            callback = function()
                self:chooseBookCloudDir()
            end,
        },
    }
end

function CloudLibraryPlugin:chooseBookCloudDir()
    local SyncService = require("apps/cloudstorage/syncservice")
    local remote = require("remote")
    
    local current_server = remote.get_server()
    
    local sync_service = SyncService:new{
        server_type = current_server and current_server.type or nil,
        server_address = current_server and current_server.address or nil,
        server_username = current_server and current_server.username or nil,
        server_password = current_server and current_server.password or nil,
        server_url = self.settings.book_cloud_dir or (current_server and current_server.url or nil),
    }
    
    sync_service.onConfirm = function(server)
        self.settings.book_cloud_dir = server.url
        self.settings.book_cloud_type = server.type
        self.settings.book_cloud_address = server.address
        self.settings.book_cloud_username = server.username
        self.settings.book_cloud_password = server.password
        G_reader_settings:saveSetting(self.plugin_id, self.settings)
    end
    
    UIManager:show(sync_service)
end

function CloudLibraryPlugin:confirmClearCloudLog()
    UIManager:show(ConfirmBox:new{
        text = _("确定要清空云端的同步记录吗？\n\n此操作不会影响本地的同步记录，但其他设备将无法同步到已清空的记录。"),
        ok_text = _("清空"),
        cancel_text = _("取消"),
        ok_callback = function()
            self:doClearCloudLog()
        end
    })
end

function CloudLibraryPlugin:doClearCloudLog()
    local utils = require("utils")
    local NetworkMgr = require("ui/network/manager")
    
    if not NetworkMgr:isOnline() then
        utils.show_msg(_("无网络连接，无法清空"))
        return
    end
    
    utils.show_msg(_("正在清空云端同步记录..."))
    
    UIManager:scheduleIn(0, function()
        local sync_log = require("sync_log")
        local success, msg = sync_log.clear_cloud_log()
        
        if success then
            utils.show_msg(_("云端同步记录已清空"))
        else
            utils.show_msg(_("清空失败: ") .. msg)
        end
    end)
end

function CloudLibraryPlugin:buildNamingModeMenu()
    local utils = require("utils")
    return {
        {
            text = _("元数据命名方式"),
            sub_item_table = {
                {
                    text = _("使用文件名"),
                    checked_func = function()
                        return self.settings.metadata_naming_mode == "filename"
                    end,
                    callback = function()
                        self.settings.metadata_naming_mode = "filename"
                        utils.show_msg(_("元数据使用文件名命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("使用书籍标题（默认）"),
                    checked_func = function()
                        return self.settings.metadata_naming_mode == "metadata"
                    end,
                    callback = function()
                        self.settings.metadata_naming_mode = "metadata"
                        utils.show_msg(_("元数据使用书籍标题命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("使用标题_作者"),
                    checked_func = function()
                        return self.settings.metadata_naming_mode == "title_author"
                    end,
                    callback = function()
                        self.settings.metadata_naming_mode = "title_author"
                        utils.show_msg(_("元数据使用「标题_作者」格式命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
            },
        },
        {
            text = _("书籍命名方式"),
            sub_item_table = {
                {
                    text = _("使用文件名"),
                    checked_func = function()
                        return self.settings.book_naming_mode == "filename"
                    end,
                    callback = function()
                        self.settings.book_naming_mode = "filename"
                        utils.show_msg(_("书籍使用文件名命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("使用书籍标题（默认）"),
                    checked_func = function()
                        return self.settings.book_naming_mode == "title"
                    end,
                    callback = function()
                        self.settings.book_naming_mode = "title"
                        utils.show_msg(_("书籍使用书籍标题命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("使用标题_作者"),
                    checked_func = function()
                        return self.settings.book_naming_mode == "title_author"
                    end,
                    callback = function()
                        self.settings.book_naming_mode = "title_author"
                        utils.show_msg(_("书籍使用「标题_作者」格式命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
            },
        },
    }
end

function CloudLibraryPlugin:chooseBookLocalDir()
    local DownloadMgr = require("ui/downloadmgr")
    local current_dir = self.settings.book_download_dir
    
    DownloadMgr:new{
        title = _("选择书籍下载目录"),
        onConfirm = function(path)
            if path and path ~= "" then
                self.settings.book_download_dir = path
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                UIManager:show(Notification:new{
                    text = string.format(_("本地下载目录已设置: %s"), path),
                    timeout = 2
                })
            end
        end,
    }:chooseDir(current_dir)
end

function CloudLibraryPlugin:buildMetadataSyncMenu()
    return {
        {
            text = _("上传当前书籍元数据"),
            enabled = self.ui and self.ui.document,
            callback = function()
                self.manual_sync:syncCurrentBook(true)
            end
        },
        {
            text = _("下载当前书籍元数据"),
            sub_item_table = {
                {
                    text = _("覆盖更新"),
                    callback = function()
                        self.manual_sync:syncCurrentBook(false)
                    end
                },
                {
                    text = _("合并更新"),
                    callback = function()
                        self.manual_sync:syncCurrentBookMerge()
                    end
                },
            },
        },
        {
            text = _("批量上传选中书籍元数据"),
            callback = function()
                self.manual_sync:batchSyncWithFMSelection(true, false)
            end,
        },
        {
            text = _("批量下载选中书籍元数据"),
            sub_item_table = {
                {
                    text = _("覆盖更新"),
                    callback = function()
                        self.manual_sync:batchSyncWithFMSelection(false, false)
                    end
                },
                {
                    text = _("合并更新"),
                    callback = function()
                        self.manual_sync:batchSyncWithFMSelection(false, true)
                    end
                },
            },
        },
    }
end

function CloudLibraryPlugin:buildBookSyncMenu()
    local BookSync = require("book_sync")
    return {
        {
            text = _("批量上传选中书籍"),
            callback = function()
                BookSync.batchUploadWithFMSelection(self)
            end
        },
        {
            text = _("批量下载/删除云端书籍"),
            callback = function()
                self:batchDownloadBooks()
            end
        },
    }
end

function CloudLibraryPlugin:buildAutoSyncMenu()
    local utils = require("utils")
    return {
        {
            text = _("自动上传备份"),
            enabled = true,
            sub_item_table = {
                {
                    text = _("编辑标注时自动上传"),
                    checked_func = function()
                        return self.settings.auto_upload_on_annotate == true
                    end,
                    callback = function()
                        self.settings.auto_upload_on_annotate = not self.settings.auto_upload_on_annotate
                        self:updateAutoSyncSettings()
                        utils.show_msg(self.settings.auto_upload_on_annotate and "已开启：编辑标注时自动上传" or "已关闭：编辑标注时自动上传")
                    end,
                },
                {
                    text = _("关闭书籍时自动上传"),
                    checked_func = function()
                        return self.settings.auto_upload_on_close == true
                    end,
                    callback = function()
                        self.settings.auto_upload_on_close = not self.settings.auto_upload_on_close
                        self:updateAutoSyncSettings()
                        utils.show_msg(self.settings.auto_upload_on_close and "已开启：关闭书籍时自动上传" or "已关闭：关闭书籍时自动上传")
                    end,
                },
                {
                    text = _("设备休眠时自动上传"),
                    checked_func = function()
                        return self.settings.auto_upload_on_suspend == true
                    end,
                    callback = function()
                        self.settings.auto_upload_on_suspend = not self.settings.auto_upload_on_suspend
                        self:updateAutoSyncSettings()
                        utils.show_msg(self.settings.auto_upload_on_suspend and "已开启：休眠时自动上传" or "已关闭：休眠时自动上传")
                    end,
                },
            },
        },
        {
            text = _("自动下载更新"),
            enabled = true,
            sub_item_table = {
                {
                    text = _("打开书籍时自动下载（覆盖更新）"),
                    checked_func = function()
                        return self.settings.auto_download_on_open and self.settings.auto_download_mode == "override"
                    end,
                    callback = function()
                        if self.settings.auto_download_on_open and self.settings.auto_download_mode == "override" then
                            self.settings.auto_download_on_open = false
                        else
                            self.settings.auto_download_on_open = true
                            self.settings.auto_download_mode = "override"
                        end
                        self:updateAutoSyncSettings()
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        local utils = require("utils")
                        utils.show_msg(self.settings.auto_download_on_open and self.settings.auto_download_mode == "override" and 
                            "已开启：打开书籍时自动下载（覆盖更新）" or "已关闭：打开书籍时自动下载（覆盖更新）")
                    end,
                },
                {
                    text = _("打开书籍时自动下载（合并更新）"),
                    checked_func = function()
                        return self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge"
                    end,
                    callback = function()
                        if self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge" then
                            self.settings.auto_download_on_open = false
                        else
                            self.settings.auto_download_on_open = true
                            self.settings.auto_download_mode = "merge"
                        end
                        self:updateAutoSyncSettings()
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        local utils = require("utils")
                        utils.show_msg(self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge" and 
                            "已开启：打开书籍时自动下载元数据" or "已关闭：打开书籍时自动下载元数据")
                    end,
                },
            },
        },
        {
            text = _("自动同步时显示通知"),
            checked_func = function()
                return self.settings.auto_sync_notify == true
            end,
            callback = function()
                self.settings.auto_sync_notify = not self.settings.auto_sync_notify
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                utils.show_msg(self.settings.auto_sync_notify and "已开启：自动同步通知" or "已关闭：自动同步通知")
            end,
        },
    }
end

function CloudLibraryPlugin:batchDownloadBooks()
    local utils = require("utils")
    local download_dir = self.settings.book_download_dir
    if not download_dir or download_dir == "" then
        utils.show_msg(_("请先在设置中设置书籍下载目录"))
        return
    end
    
    local BookSync = require("book_sync")
    BookSync.show_cloud_book_dialog(function(book_names)
        UIManager:show(ConfirmBox:new{
            text = string.format("确定要下载 %d 本书籍吗？", #book_names),
            ok_text = _("下载"),
            cancel_text = _("取消"),
            ok_callback = function()
                BookSync.batchDownloadBooks(book_names, self.settings, self)
            end,
        })
    end, self)
end

function CloudLibraryPlugin:updateAutoSyncSettings()
    local has_upload = self.settings.auto_upload_on_annotate or 
                      self.settings.auto_upload_on_close or 
                      self.settings.auto_upload_on_suspend
    local has_download = self.settings.auto_download_on_open
    
    self.settings.auto_sync_enabled = has_upload or has_download
    
    G_reader_settings:saveSetting(self.plugin_id, self.settings)
end

function CloudLibraryPlugin:viewSyncLog()
    local utils = require("utils")
    local log_path = utils.get_log_path()
    
    local realpath = require("ffi/util").realpath
    local absolute_path = log_path
    if realpath then
        local resolved = realpath(log_path)
        if resolved then
            absolute_path = resolved
        end
    end
    
    local f = io.open(log_path, "r")
    if not f then
        utils.show_msg(_("没有同步记录"))
        return
    end
    local content = f:read("*all")
    f:close()
    
    if content == "" or not content then
        utils.show_msg(_("没有同步记录"))
        return
    end
    
    local header = string.format("同步记录文件路径: %s\n\n", absolute_path)
    local full_content = header .. content
    
    local textviewer
    local buttons = {
        {
            {
                text = _("查找"),
                callback = function()
                    if textviewer then
                        textviewer:findDialog()
                    end
                end,
            },
            {
                text = _("复制"),
                callback = function()
                    if Device:hasClipboard() then
                        Device.input.setClipboardText(full_content)
                        utils.show_msg(_("同步记录已复制到剪贴板"))
                    else
                        local temp_file = DataStorage:getDataDir() .. "sync_log_backup.txt"
                        local out_f = io.open(temp_file, "w")
                        if out_f then
                            out_f:write(full_content)
                            out_f:close()
                            utils.show_msg(string.format(_("同步记录已保存到 %s"), temp_file))
                        else
                            utils.show_msg(_("复制失败"))
                        end
                    end
                end,
            },
            {
                text = _("清空"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("确定要清空所有同步记录吗？"),
                        ok_text = _("清空"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            local out_f = io.open(log_path, "w")
                            if out_f then
                                out_f:write("")
                                out_f:close()
                            end
                            if textviewer then
                                UIManager:close(textviewer)
                            end
                            utils.show_msg(_("同步记录已清空"))
                        end,
                    })
                end,
            },
            {
                text = "⇱",
                callback = function()
                    if textviewer and textviewer.scroll_text_w then
                        textviewer.scroll_text_w:scrollToTop()
                    end
                end,
            },
            {
                text = "⇲",
                callback = function()
                    if textviewer and textviewer.scroll_text_w then
                        textviewer.scroll_text_w:scrollToBottom()
                    end
                end,
            },
        },
    }
    
    textviewer = TextViewer:new{
        title = _("同步记录"),
        text = full_content,
        justified = false,
        buttons_table = buttons,
    }
    UIManager:show(textviewer)
end

function CloudLibraryPlugin:showPluginInfo()
    local DataStorage = require("datastorage")
    local data_dir = DataStorage:getFullDataDir()
    
    local readme_path = data_dir .. "/plugins/cloudlibrary.koplugin/README.md"
    
    local f = io.open(readme_path, "r")
    local content = nil
    if f then
        content = f:read("*all")
        f:close()
    end
    
    if not content or content == "" then
        content = _("未找到 README.md 文件")
    end
    
    local TextViewer = require("ui/widget/textviewer")
    local textviewer = TextViewer:new{
        title = _("云端书库 插件说明"),
        text = content,
        justified = false,
    }
    UIManager:show(textviewer)
end

function CloudLibraryPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("cloudlibrary_reader", {
        category = "none",
        event = "CloudLibraryReader",
        title = _("云端书库-快捷操作"),
        reader = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_filemanager", {
        category = "none",
        event = "CloudLibraryFileManager",
        title = _("云端书库-快捷操作"),
        filemanager = true,
    })

    Dispatcher:registerAction("cloudlibrary_settings_reader", {
        category = "none",
        event = "CloudLibrarySettingsReader",
        title = _("云端书库-快捷设置"),
        reader = true,
    })

    Dispatcher:registerAction("cloudlibrary_settings_filemanager", {
        category = "none",
        event = "CloudLibrarySettingsFileManager",
        title = _("云端书库-快捷设置"),
        filemanager = true,
    })

    Dispatcher:registerAction("cloudlibrary_upload_current", {
        category = "none",
        event = "CloudLibraryUploadCurrent",
        title = _("云端书库-上传当前书籍元数据"),
        reader = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_download_current", {
        category = "none",
        event = "CloudLibraryDownloadCurrent",
        title = _("云端书库-下载当前书籍元数据（智能模式）"),
        reader = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_autosync_reader", {
        category = "none",
        event = "CloudLibraryAutoSyncReader",
        title = _("云端书库-元数据省心同步模式"),
        reader = true,
    })

    Dispatcher:registerAction("cloudlibrary_autosync_filemanager", {
        category = "none",
        event = "CloudLibraryAutoSyncFileManager",
        title = _("云端书库-元数据省心同步模式"),
        filemanager = true,
    })

    Dispatcher:registerAction("cloudlibrary_batch_upload_metadata", {
        category = "none",
        event = "CloudLibraryBatchUploadMetadata",
        title = _("云端书库-批量上传选中书籍元数据"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_batch_download_metadata_smart", {
        category = "none",
        event = "CloudLibraryBatchDownloadMetadataSmart",
        title = _("云端书库-批量下载元数据（智能模式）"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_batch_upload_books", {
        category = "none",
        event = "CloudLibraryBatchUploadBooks",
        title = _("云端书库-批量上传选中书籍文件"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_batch_download_books", {
        category = "none",
        event = "CloudLibraryBatchDownloadBooks",
        title = _("云端书库-批量下载/删除云端书籍文件"),
        filemanager = true,
    })
end

function CloudLibraryPlugin:onCloudLibraryReader()
    self:showSyncDialog("reader")
end

function CloudLibraryPlugin:onCloudLibraryFileManager()
    self:showSyncDialog("filemanager")
end

function CloudLibraryPlugin:showSyncDialog(context)
    local buttons = {}
    local BookSync = require("book_sync")
    local mode_text = (self.settings.auto_download_mode == "merge") and "合并更新" or "覆盖更新"
    
    if context == "reader" then
        buttons = {
            { 
                { text = _("上传当前书籍元数据"), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    self.manual_sync:syncCurrentBook(true)
                end } 
            },
            { 
                { text = string.format(_("下载当前书籍元数据（%s）"), mode_text), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    if self.settings.auto_download_mode == "merge" then
                        self.manual_sync:syncCurrentBookMerge()
                    else
                        self.manual_sync:syncCurrentBook(false)
                    end
                end } 
            },
            { 
                { text = _("查看同步记录"), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    self:viewSyncLog()
                end } 
            },
        }
    else
        buttons = {
            { 
                { text = _("批量上传选中书籍元数据"), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    self.manual_sync:batchSyncWithFMSelection(true, false)
                end } 
            },
            { 
                { text = string.format(_("批量下载选中书籍元数据（%s）"), mode_text), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    local is_merge = (self.settings.auto_download_mode == "merge")
                    self.manual_sync:batchSyncWithFMSelection(false, is_merge)
                end } 
            },
            { 
                { text = _("批量上传选中书籍"), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    BookSync.batchUploadWithFMSelection(self)
                end } 
            },
            { 
                { text = _("批量下载/删除云端书籍"), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    self:batchDownloadBooks()
                end } 
            },
            { 
                { text = _("查看同步记录"), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    self:viewSyncLog()
                end } 
            },
        }
    end
    
    local dialog = ButtonDialog:new{
        title = _("云端书库-快捷操作"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.6),
    }
    self._current_dialog = dialog
    UIManager:show(dialog)
end

function CloudLibraryPlugin:onCloudLibraryUploadCurrent()
    if self.ui and self.ui.document then
        self.manual_sync:syncCurrentBook(true)
    end
end

function CloudLibraryPlugin:onCloudLibraryDownloadCurrent()
    if self.ui and self.ui.document then
        if self.settings.auto_download_mode == "merge" then
            self.manual_sync:syncCurrentBookMerge()
        else
            self.manual_sync:syncCurrentBook(false)
        end
    end
end

function CloudLibraryPlugin:onCloudLibrarySettingsReader()
    self:showSettingsDialog("reader")
end

function CloudLibraryPlugin:onCloudLibrarySettingsFileManager()
    self:showSettingsDialog("filemanager")
end

function CloudLibraryPlugin:showSettingsDialog(context)
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local _ = require("gettext")
    
    local self_ref = self
    
    local function rebuildAndShow()
        if self_ref._current_settings_dialog then
            UIManager:close(self_ref._current_settings_dialog)
            self_ref._current_settings_dialog = nil
        end
        self_ref:showSettingsDialog(context)
    end
    
    local buttons = {}
    
    table.insert(buttons, {
        {
            text_func = function()
                local remote = require("remote")
                local server = remote.get_server()
                if server and server.url then
                    return _("元数据云端目录: ") .. server.url
                else
                    return _("设置元数据云端目录")
                end
            end,
            callback = function()
                local SyncService = require("apps/cloudstorage/syncservice")
                local remote = require("remote")
                local sync_service = SyncService:new{}
                sync_service.onConfirm = function(server)
                    remote.save_server_settings(server)
                end
                UIManager:show(sync_service)
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                local book_dir = self.settings.book_cloud_dir
                if book_dir and book_dir ~= "" then
                    return _("书籍云端目录: ") .. book_dir
                else
                    return _("设置书籍云端目录（默认与元数据相同）")
                end
            end,
            callback = function()
                self:chooseBookCloudDir()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {})
    
    local metadata_naming_mode = self.settings.metadata_naming_mode or "metadata"
    local metadata_naming_text = ""
    if metadata_naming_mode == "filename" then
        metadata_naming_text = "使用文件名"
    elseif metadata_naming_mode == "metadata" then
        metadata_naming_text = "使用书籍标题"
    elseif metadata_naming_mode == "title_author" then
        metadata_naming_text = "使用标题_作者"
    end
    
    table.insert(buttons, {
        {
            text = _("元数据命名方式: ") .. metadata_naming_text,
            callback = function()
                self:showMetadataNamingModeDialog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    local book_naming_mode = self.settings.book_naming_mode or "title"
    local book_naming_text = ""
    if book_naming_mode == "filename" then
        book_naming_text = "使用文件名"
    elseif book_naming_mode == "title" then
        book_naming_text = "使用书籍标题"
    elseif book_naming_mode == "title_author" then
        book_naming_text = "使用标题_作者"
    end
    
    table.insert(buttons, {
        {
            text = _("书籍命名方式: ") .. book_naming_text,
            callback = function()
                self:showBookNamingModeDialog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                local dir = self.settings.book_download_dir
                if dir and dir ~= "" then
                    return _("书籍下载目录: ") .. dir
                else
                    return _("设置书籍下载目录")
                end
            end,
            callback = function()
                self:chooseBookLocalDir()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    local download_mode_text = (self.settings.auto_download_mode == "merge") and "合并更新" or "覆盖更新"
    table.insert(buttons, {
        {
            text = _("元数据下载模式（手动）: ") .. download_mode_text,
            callback = function()
                self:showManualDownloadModeDialog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {})
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_upload_on_annotate and "✓ " or "  ") .. _("编辑标注时自动上传元数据")
            end,
            callback = function()
                self.settings.auto_upload_on_annotate = not self.settings.auto_upload_on_annotate
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_upload_on_close and "✓ " or "  ") .. _("关闭书籍时自动上传元数据")
            end,
            callback = function()
                self.settings.auto_upload_on_close = not self.settings.auto_upload_on_close
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_upload_on_suspend and "✓ " or "  ") .. _("设备休眠时自动上传元数据")
            end,
            callback = function()
                self.settings.auto_upload_on_suspend = not self.settings.auto_upload_on_suspend
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    table.insert(buttons, {
        {
            text_func = function()
                local enabled = self.settings.auto_download_on_open and self.settings.auto_download_mode == "override"
                return (enabled and "✓ " or "  ") .. _("打开书籍时自动下载元数据（覆盖更新）")
            end,
            callback = function()
                if self.settings.auto_download_on_open and self.settings.auto_download_mode == "override" then
                    self.settings.auto_download_on_open = false
                else
                    self.settings.auto_download_on_open = true
                    self.settings.auto_download_mode = "override"
                end
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                local enabled = self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge"
                return (enabled and "✓ " or "  ") .. _("打开书籍时自动下载元数据（合并更新）")
            end,
            callback = function()
                if self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge" then
                    self.settings.auto_download_on_open = false
                else
                    self.settings.auto_download_on_open = true
                    self.settings.auto_download_mode = "merge"
                end
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.upload_json and not self.settings.use_notemark_format and "✓ " or "  ") .. _("额外备份JSON文件（原始格式）")
            end,
            callback = function()
                if self.settings.upload_json and not self.settings.use_notemark_format then
                    self.settings.upload_json = false
                    self.settings.use_notemark_format = false
                else
                    self.settings.upload_json = true
                    self.settings.use_notemark_format = false
                end
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.upload_json and self.settings.use_notemark_format and "✓ " or "  ") .. _("额外备份JSON文件（NoteMarkData格式）")
            end,
            callback = function()
                if self.settings.upload_json and self.settings.use_notemark_format then
                    self.settings.upload_json = false
                    self.settings.use_notemark_format = false
                else
                    self.settings.upload_json = true
                    self.settings.use_notemark_format = true
                end
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.override_keep_local_settings and "✓ " or "  ") .. _("覆盖更新时保留本地文档设置")
            end,
            callback = function()
                self.settings.override_keep_local_settings = not self.settings.override_keep_local_settings
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.sync_log_enabled and "✓ " or "  ") .. _("开启记录云同步")
            end,
            callback = function()
                self.settings.sync_log_enabled = not self.settings.sync_log_enabled
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                if self.settings.sync_log_enabled then
                    local sync_log = require("sync_log")
                    sync_log.sync_log()
                end
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_sync_notify and "✓ " or "  ") .. _("自动同步时显示通知")
            end,
            callback = function()
                self.settings.auto_sync_notify = not self.settings.auto_sync_notify
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    table.insert(buttons, {
        {
            text = _("查看同步记录"),
            callback = function()
                self:viewSyncLog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {
        {
            text = _("清空云端同步记录"),
            callback = function()
                self:confirmClearCloudLog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {
        {
            text = _("插件说明"),
            callback = function()
                self:showPluginInfo()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {
        {
            text = _("检查更新") .. "  (作者：gytwo  当前版本: " .. self.VERSION .. ")",
            callback = function()
                local update = require("update")
                update.check_for_updates(false, self)
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    local dialog = ButtonDialog:new{
        title = _("云端书库-快捷设置"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
        max_height = math.floor(Screen:getHeight() * 0.5),
    }
    self._current_settings_dialog = dialog
    UIManager:show(dialog)
end

function CloudLibraryPlugin:showMetadataNamingModeDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local _ = require("gettext")
    
    local current_mode = self.settings.metadata_naming_mode or "metadata"
    
    local dialog
    local buttons = {
        {
            {
                text = (current_mode == "filename" and "✓ " or "  ") .. _("使用文件名"),
                callback = function()
                    self.settings.metadata_naming_mode = "filename"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("元数据使用文件名命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "metadata" and "✓ " or "  ") .. _("使用书籍标题（默认）"),
                callback = function()
                    self.settings.metadata_naming_mode = "metadata"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("元数据使用书籍标题命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "title_author" and "✓ " or "  ") .. _("使用标题_作者"),
                callback = function()
                    self.settings.metadata_naming_mode = "title_author"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("元数据使用「标题_作者」格式命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {},
        {
            {
                text = _("返回"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        }
    }
    
    dialog = ButtonDialog:new{
        title = _("元数据命名方式"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(dialog)
end

function CloudLibraryPlugin:showBookNamingModeDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local _ = require("gettext")
    
    local current_mode = self.settings.book_naming_mode or "title"
    
    local dialog
    local buttons = {
        {
            {
                text = (current_mode == "filename" and "✓ " or "  ") .. _("使用文件名"),
                callback = function()
                    self.settings.book_naming_mode = "filename"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("书籍使用文件名命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "title" and "✓ " or "  ") .. _("使用书籍标题（默认）"),
                callback = function()
                    self.settings.book_naming_mode = "title"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("书籍使用书籍标题命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "title_author" and "✓ " or "  ") .. _("使用标题_作者"),
                callback = function()
                    self.settings.book_naming_mode = "title_author"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("书籍使用「标题_作者」格式命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {},
        {
            {
                text = _("返回"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        }
    }
    
    dialog = ButtonDialog:new{
        title = _("书籍命名方式"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(dialog)
end

function CloudLibraryPlugin:showManualDownloadModeDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local _ = require("gettext")
    
    local current_mode = self.settings.auto_download_mode or "merge"
    
    local dialog
    local buttons = {
        {
            {
                text = (current_mode == "override" and "✓ " or "  ") .. _("覆盖更新"),
                callback = function()
                    self.settings.auto_download_mode = "override"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("元数据下载模式（手动）：覆盖更新"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "merge" and "✓ " or "  ") .. _("合并更新"),
                callback = function()
                    self.settings.auto_download_mode = "merge"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("元数据下载模式（手动）：合并更新"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {},
        {
            {
                text = _("返回"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        }
    }
    
    dialog = ButtonDialog:new{
        title = _("元数据下载模式（手动）"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(dialog)
end

function CloudLibraryPlugin:onCloudLibraryBatchUploadMetadata()
    self.manual_sync:batchSyncWithFMSelection(true, false)
end

function CloudLibraryPlugin:onCloudLibraryBatchDownloadMetadataSmart()
    local is_merge = (self.settings.auto_download_mode == "merge")
    self.manual_sync:batchSyncWithFMSelection(false, is_merge)
end

function CloudLibraryPlugin:onCloudLibraryBatchUploadBooks()
    local BookSync = require("book_sync")
    BookSync.batchUploadWithFMSelection(self)
end

function CloudLibraryPlugin:onCloudLibraryBatchDownloadBooks()
    self:batchDownloadBooks()
end

function CloudLibraryPlugin:onCloudLibraryAutoSyncReader()
    self:toggleAutoSyncQuick()
end

function CloudLibraryPlugin:onCloudLibraryAutoSyncFileManager()
    self:toggleAutoSyncQuick()
end

function CloudLibraryPlugin:toggleAutoSyncQuick()
    local is_auto_mode = self.settings.auto_upload_on_close and 
                         self.settings.auto_upload_on_suspend and 
                         self.settings.auto_download_on_open
    
    if is_auto_mode then
        self.settings.auto_upload_on_annotate = false
        self.settings.auto_upload_on_close = false
        self.settings.auto_upload_on_suspend = false
        self.settings.auto_download_on_open = false
        self.settings.auto_download_mode = "merge"
        
        self:updateAutoSyncSettings()
        G_reader_settings:saveSetting(self.plugin_id, self.settings)
        
        local utils = require("utils")
        utils.show_msg(_("云端书库: 已关闭所有元数据自动同步"))
    else
        self.settings.auto_upload_on_annotate = false
        self.settings.auto_upload_on_close = true
        self.settings.auto_upload_on_suspend = true
        self.settings.auto_download_on_open = true
        self.settings.auto_download_mode = "merge"
        
        self:updateAutoSyncSettings()
        G_reader_settings:saveSetting(self.plugin_id, self.settings)
        
        local utils = require("utils")
        utils.show_msg(_("云端书库: 已开启元数据省心同步模式 (关闭书籍/设备休眠自动上传 + 打开书籍自动合并更新)"))
    end
end

return CloudLibraryPlugin
