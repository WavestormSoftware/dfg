-- Wavestorm Git v2: small modal dialogs + result formatting.
-- Only call from run/on_pressed (long-running) contexts.
local M = {}

local function ui()
	assert(type(editor) == "table" and type(editor.ui) == "table",
		"editor.ui is only available inside the Defold editor")
	return editor.ui
end

-- Format a result table (from lib/git) or a string for display.
function M.result_text(res)
	if type(res) == "string" then return res end
	if type(res) ~= "table" then return tostring(res) end
	if res.ok then
		local data = res.data
		if data == nil then return "Done." end
		return tostring(data)
	end
	local parts = { res.message or "Unknown error." }
	if res.hint and res.hint ~= "" then
		parts[#parts + 1] = "\n\n" .. res.hint
	end
	return table.concat(parts)
end

function M.info(title, text)
	local u = ui()
	return u.show_dialog(u.dialog({
		title = title,
		content = u.vertical({
			padding = u.PADDING.LARGE,
			children = { u.paragraph({ text = tostring(text or "") }) },
		}),
		buttons = {
			u.dialog_button({ text = "Close", default = true, cancel = true, result = true }),
		},
	}))
end

-- Accepts a result table (git.lua) or plain text.
function M.error(title, res)
	local u = ui()
	return u.show_dialog(u.dialog({
		title = title,
		content = u.vertical({
			padding = u.PADDING.LARGE,
			children = { u.paragraph({ text = M.result_text(res) }) },
		}),
		buttons = {
			u.dialog_button({ text = "Close", default = true, cancel = true, result = false }),
		},
	}))
end

function M.confirm(title, question, ok_label)
	local u = ui()
	local res = u.show_dialog(u.dialog({
		title = title,
		content = u.vertical({
			padding = u.PADDING.LARGE,
			children = { u.paragraph({ text = tostring(question) }) },
		}),
		buttons = {
			u.dialog_button({ text = "Cancel", cancel = true, result = false }),
			u.dialog_button({ text = ok_label or "Confirm", default = true, result = true }),
		},
	}))
	return res == true
end

-- Single-line input. Returns the trimmed-committed string or nil on cancel.
function M.input(title, label_text, initial, ok_label)
	local u = ui()
	local value = initial or ""
	local comp = u.component(function(_props)
		local text, set_text = u.use_state(initial or "")
		return u.dialog({
			title = title,
			content = u.vertical({
				padding = u.PADDING.LARGE,
				spacing = u.SPACING.MEDIUM,
				children = {
					u.label({ text = label_text }),
					u.string_field({
						grow = true,
						value = text,
						on_value_changed = function(v)
							value = v or ""
							set_text(v or "")
						end,
					}),
				},
			}),
			buttons = {
				u.dialog_button({ text = "Cancel", cancel = true }),
				u.dialog_button({ text = ok_label or "OK", default = true, result = true }),
			},
		})
	end)
	local res = u.show_dialog(comp({}))
	if res then return value end
	return nil
end

-- Scrollable monospaced-ish text (diffs, blame, doctor output, commit views).
function M.text(title, text, width, height)
	local u = ui()
	if text == nil or text == "" then text = "(empty)" end
	if #text > 24000 then
		text = text:sub(1, 24000) .. "\n\n... (truncated; full output is in the editor console)"
	end
	return u.show_dialog(u.dialog({
		title = title,
		width = width or 780,
		height = height or 560,
		content = u.vertical({
			padding = u.PADDING.LARGE,
			children = {
				u.scroll({
					grow = true,
					content = u.paragraph({ text = text }),
				}),
			},
		}),
		buttons = {
			u.dialog_button({ text = "Close", default = true, cancel = true, result = true }),
		},
	}))
end

-- Commit history dialog.
function M.history(commits, title)
	local lines = {}
	if #commits == 0 then
		lines[#lines + 1] = "No commits yet."
	else
		for i = 1, #commits do
			local c = commits[i]
			lines[#lines + 1] = string.format("%s  %s  %s\n    %s",
				c.short or "", c.date or "", c.author or "", c.subject or "")
		end
	end
	return M.text(title or "Git: History", table.concat(lines, "\n\n"))
end

return M
