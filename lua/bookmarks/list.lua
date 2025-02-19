local md5 = require("bookmarks.md5")
local w = require("bookmarks.window")
local data = require("bookmarks.data")
local m = require("bookmarks.marks")
local api = vim.api

local M = {}

function M.setup()
    local os_name = vim.loop.os_uname().sysname
    data.is_windows = os_name == "Windows" or os_name == "Windows_NT"
    if data.is_windows then
        data.path_sep = "\\"
    end
    M.load_data()
end

function M.add_bookmark(line, buf, rows)
    local bufs_pairs = w.open_add_win(line)
    vim.keymap.set("n", "<ESC>",
        function() w.close_add_win(bufs_pairs.pairs.buf, bufs_pairs.border_pairs.buf) end,
        { silent = true, buffer = bufs_pairs.pairs.buf }
    )
    vim.keymap.set("i", "<CR>",
        function() M.handle_add(line, bufs_pairs.pairs.buf, bufs_pairs.border_pairs.buf, buf, rows) end,
        { silent = true, noremap = true, buffer = bufs_pairs.pairs.buf }
    )
end

function M.handle_add(line, buf1, buf2, buf, rows)
    local filename = api.nvim_buf_get_name(buf)
    if filename == nil or filename == "" then
        return
    end

    local input_line = vim.fn.line(".")
    local description = api.nvim_buf_get_lines(buf1, input_line - 1, input_line, false)[1] or ""
    if description ~= "" then
        local content = api.nvim_buf_get_lines(buf, line - 1, line, true)[1]
        M.add(filename, line, md5.sumhexa(content),
            description, rows)
    end
    w.close_add_win(buf1, buf2)
    m.set_marks(0, M.get_buf_bookmark_lines(0))
    vim.cmd("stopinsert")
end

-- rows is the file line number of rows
function M.add(filename, line, line_md5, description, rows)
    local id = md5.sumhexa(string.format("%s:%s", filename, line))
    local now = os.time()
    if data.bookmarks[id] ~= nil then --update description
        if description ~= nil then
            data.bookmarks[id].description = description
            data.bookmarks[id].updated_at = now
        end
    else -- new
        data.bookmarks[id] = {
            filename = filename,
            id = id,
            line = line,
            description = description or "",
            updated_at = now,
            fre = 1,
            rows = rows,         -- for fix
            line_md5 = line_md5, -- for fix
        }

        if data.bookmarks_groupby_filename[filename] == nil then
            data.bookmarks_groupby_filename[filename] = { id }
        else
            data.bookmarks_groupby_filename[filename][#data.bookmarks_groupby_filename[filename] + 1] = id
        end
    end
end

function M.get_buf_bookmark_lines(buf)
    local filename = api.nvim_buf_get_name(buf)
    local lines = {}

    local group = data.bookmarks_groupby_filename[filename]
    if group == nil then
        return lines
    end

    local tmp = {}
    for _, each in pairs(group) do
        if data.bookmarks[each] ~= nil and tmp[data.bookmarks[each].line] == nil then
            lines[#lines + 1] = data.bookmarks[each]
            tmp[data.bookmarks[each].line] = true
        end
    end

    return lines
end

-- delete bookmark
function M.delete(line)
    if data.bookmarks_order_ids[line] ~= nil then
        data.bookmarks[data.bookmarks_order_ids[line]] = nil
        M.refresh()
    end
end

function M.delete_on_virt()
    local line = vim.fn.line(".")
    local file_name = api.nvim_buf_get_name(0)
    for k, v in pairs(data.bookmarks) do
        if v.line == line and file_name == v.filename then
            data.bookmarks[k] = nil
            m.set_marks(0, M.get_buf_bookmark_lines(0))
            return
        end
    end
end

-- mark bookmarks order by time or fre
function M.refresh(order)
    if order == true then
        if data.bookmarks_order == "time" then
            data.bookmarks_order = "fre"
        else
            data.bookmarks_order = "time"
        end
    end

    M.flush()
end

-- flush bookmarks to float window
function M.flush()
    -- for order
    local tmp_data = {}
    for _, item in pairs(data.bookmarks) do
        tmp_data[#tmp_data + 1] = item
    end

    -- sort by order mark
    if data.bookmarks_order == "time" then
        table.sort(tmp_data, function(e1, e2)
            return e1.updated_at > e2.updated_at
        end)
    else
        table.sort(tmp_data, function(e1, e2)
            return e1.fre > e2.fre
        end)
    end

    data.bookmarks_order_ids = {}
    local lines = {}
    for _, item in ipairs(tmp_data) do
        if item.filename == nil or item.filename == "" then
            goto continue
        end

        local s = item.filename:split_b("/")
        local rep1 = math.floor(data.bw * 0.3)
        local rep2 = math.floor(data.bw * 0.5)

        local icon = (require 'nvim-web-devicons'.get_icon(item.filename)) or ""

        local tmp = item.fre
        if data.bookmarks_order == "time" then
            tmp = os.date("%Y-%m-%d %H:%M:%S", item.updated_at)
            rep2 = math.floor(data.bw * 0.4)
        end

        lines[#lines + 1] = string.format("%s %s [%s]", M.padding(item.description, rep1),
            M.padding(icon .. " " .. s[#s], rep2), tmp)
        data.bookmarks_order_ids[#data.bookmarks_order_ids + 1] = item.id
        ::continue::
    end

    api.nvim_buf_set_option(data.bufb, "modifiable", true)
    -- empty
    api.nvim_buf_set_lines(data.bufb, 0, -1, false, {})
    -- flush
    api.nvim_buf_set_lines(data.bufb, 0, #lines, false, lines)
    api.nvim_buf_set_option(data.bufb, "modifiable", false)
end

-- align bookmarks display
function M.padding(str, len)
    local tmp = M.characters(str, 2)
    if tmp > len then
        return string.sub(str, 0, len)
    else
        return str .. string.rep(" ", len - tmp)
    end
end

-- jump
function M.telescope_jump_update(id)
    data.bookmarks[id].fre = data.bookmarks[id].fre + 1
    data.bookmarks[id].updated_at = os.time()
end

function M.jump(line)
    local item = data.bookmarks[data.bookmarks_order_ids[line]]

    if item == nil then
        w.close_bookmarks()
        M.restore()
        return
    end

    data.bookmarks[data.bookmarks_order_ids[line]].fre = data.bookmarks[data.bookmarks_order_ids[line]].fre + 1
    data.bookmarks[data.bookmarks_order_ids[line]].updated_at = os.time()

    local fn = function(cmd)
        vim.cmd(cmd .. item.filename)
        vim.cmd("execute  \"normal! " .. item.line .. "G;zz\"")
        vim.cmd("execute  \"normal! zz\"")
    end

    local pre_buf_name = api.nvim_buf_get_name(data.buff)
    if vim.loop.fs_stat(pre_buf_name) then
        api.nvim_set_current_win(data.bufw)
        fn("e ")
        goto continue
        return
    else
        for _, id in pairs(api.nvim_list_wins()) do
            local buf = api.nvim_win_get_buf(id)
            if vim.loop.fs_stat(api.nvim_buf_get_name(buf)) then
                api.nvim_set_current_win(id)
                fn("e ")
                goto continue
                return
            end
        end
        fn("vs ")
    end

    ::continue::
    w.close_bookmarks()
end

function M.restore()
    if vim.api.nvim_win_is_valid(data.last_win) then
        vim.api.nvim_set_current_win(data.last_win)
    end

    -- refresh virtual marks
    if vim.api.nvim_buf_is_valid(data.last_buf) then
        m.set_marks(data.last_buf, M.get_buf_bookmark_lines(data.last_buf))
    end
end

-- write bookmarks into disk file for next load
function M.persistent()
    local tpl = [[
require("bookmarks.list").load{
	_
}]]

    local str = ""
    for id, data in pairs(data.bookmarks) do
        local sub = ""
        for k, v in pairs(data) do
            if sub ~= "" then
                sub = string.format("%s\n%s", sub, string.rep(" ", 4))
            end
            if type(v) == "number" then
                sub = sub .. string.format("%s = %s,", k, v)
            else
                sub = sub .. string.format("%s = '%s',", k, v)
            end
        end
        if str == "" then
            str = string.format("%s%s", str, string.gsub(tpl, "_", sub))
        else
            str = string.format("%s\n%s", str, string.gsub(tpl, "_", sub))
        end
    end

    if data.data_filename == nil then -- lazy load,
        return
    end

    local fd = assert(io.open(data.data_filename, "w"))
    fd:write(str)
    fd:close()
end

-- restore bookmarks from disk file
function M.load_data()
    -- vim.notify("load bookmarks data", "info")
    local cwd = string.gsub(api.nvim_eval("getcwd()"), data.path_sep, "_")
    if data.cwd ~= nil and cwd ~= data.cwd then -- maybe change session
        M.persistent()
        data.bookmarks = {}
        data.loaded_data = false
    end

    if data.loaded_data == true then
        return
    end

    local data_dir = string.format("%s%sbookmarks", vim.fn.stdpath("data"), data.path_sep)
    if not vim.loop.fs_stat(data_dir) then
        assert(os.execute("mkdir " .. data_dir))
    end

    local data_filename = string.format("%s%s%s", data_dir, data.path_sep, cwd)
    if vim.loop.fs_stat(data_filename) then
        dofile(data_filename)
    end

    data.cwd = cwd
    data.loaded_data = true -- mark
    data.data_dir = data_dir
    data.data_filename = data_filename
end

function M.show_desc()
    local line = vim.fn.line(".")
    local filename = api.nvim_buf_get_name(0)
    local group = data.bookmarks_groupby_filename[filename]
    if group == nil then
        return
    end

    for _, each in pairs(group) do
        local bm = data.bookmarks[each]
        if bm ~= nil and bm.line == line then
            print(os.date("%Y-%m-%d %H:%M:%S", bm.updated_at), bm.description)
            return
        end
    end
end

-- dofile
function M.load(item)
    data.bookmarks[item.id] = item

    if data.bookmarks_groupby_filename[item.filename] == nil then
        data.bookmarks_groupby_filename[item.filename] = {}
    end

    data.bookmarks_groupby_filename[item.filename][#data.bookmarks_groupby_filename[item.filename] + 1] = item.id
end

-- fix bookmarks alignment
function M.characters(utf8Str, aChineseCharBytes)
    aChineseCharBytes = aChineseCharBytes or 2
    local i = 1
    local characterSum = 0
    while (i <= #utf8Str) do -- 编码的关系
        local bytes4Character = M.bytes4Character(string.byte(utf8Str, i))
        characterSum = characterSum + (bytes4Character > aChineseCharBytes and aChineseCharBytes or bytes4Character)
        i = i + bytes4Character
    end

    return characterSum
end

function M.bytes4Character(theByte)
    local seperate = { 0, 0xc0, 0xe0, 0xf0 }
    for i = #seperate, 1, -1 do
        if theByte >= seperate[i] then return i end
    end
    return 1
end

return M
