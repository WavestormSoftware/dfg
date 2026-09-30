-- Wavestorm Git: editor.ui dialog builders.
-- All functions here must only be called from a command's `run` handler
-- (long-running context). They throw if `editor` is unavailable.
local M = {}

local function require_core()
	local ok, core = pcall(require, "wavestorm_git.git_core")
	if ok then return core end
	-- Fallback: script placed at project root or different folder.
	ok, core = pcall(require, "git_core")
	if ok then return core end
	error("wavestorm_git.git_core not found: " .. tostring(core))
end

local function ui()
	assert(type(editor) == "table" and type(editor.ui) == "table",
		"editor.ui is only available inside the Defold editor")
	return editor.ui
end

function M.info_dialog(title, text)
	local u = ui()
	return u.show_dialog(u.dialog({
		title = title,
		content = u.vertical({
			padding = u.PADDING.LARGE,
			spacing = u.SPACING.MEDIUM,
			children = {
				u.paragraph({ text = tostring(text or "") }),
			},
		}),
		buttons = {
			u.dialog_button({ text = "Close", default = true, cancel = true, result = true }),
		},
	}))
end

function M.error_dialog(title, text)
	local u = ui()
	return u.show_dialog(u.dialog({
		title = title,
		content = u.vertical({
			padding = u.PADDING.LARGE,
			spacing = u.SPACING.MEDIUM,
			children = {
				u.paragraph({ text = tostring(text or "") }),
			},
		}),
		buttons = {
			u.dialog_button({ text = "Close", default = true, cancel = true, result = false }),
		},
	}))
end

function M.confirm_dialog(title, question, ok_label)
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

-- Generic single-line input dialog. Returns string or nil.
function M.input_dialog(title, label_text, initial, ok_label)
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

-- ---------------------------------------------------------------------------
-- Main Git panel: status overview + commit + push.
-- Returns action string + data table.
-- ---------------------------------------------------------------------------
function M.commit_panel(status, opts)
	local u = ui()
	local core = require_core()
	opts = opts or {}

	local files = status.files or {}
	-- Default selection: stage all tracked modifications, not untracked.
	local selected = {}
	for i = 1, #files do
		local f = files[i]
		if f.status ~= "untracked" and not f.conflict then
			selected[f.path] = true
		else
			selected[f.path] = false
		end
	end

	local message = ""
	local amend = false
	local push_after = opts.push_after or false

	local header_text = core.summary(status)

	local comp = u.component(function(_props)
		local msg_state, set_msg = u.use_state("")
		local amend_state, set_amend = u.use_state(false)
		local push_state, set_push = u.use_state(push_after)
		local untracked_state, set_untracked = u.use_state(false)
		local sel_state, set_sel = u.use_state(0) -- bump to re-render

		-- Build file rows.
		local rows = {}
		if #files == 0 then
			rows[#rows + 1] = u.paragraph({ text = "Working tree is clean. Nothing to commit." })
		else
			for i = 1, #files do
				local f = files[i]
				local label = core.format_file_entry(f)
				if f.conflict then
					rows[#rows + 1] = u.paragraph({ text = label .. "  (resolve in external client)" })
				else
					rows[#rows + 1] = u.check_box({
						text = label,
						value = selected[f.path] == true,
						on_value_changed = function(v)
							selected[f.path] = v and true or false
							set_sel(sel_state + 1)
						end,
					})
				end
			end
		end

		local can_commit = msg_state ~= nil and msg_state:match("%S") ~= nil
		-- Count selected.
		local sel_count = 0
		for _, v in pairs(selected) do if v then sel_count = sel_count + 1 end end
		if sel_count == 0 then can_commit = false end

		return u.dialog({
			title = "Git: Status / Commit & Push",
			width = 640,
			height = 560,
			content = u.vertical({
				padding = u.PADDING.LARGE,
				spacing = u.SPACING.MEDIUM,
				children = {
					u.heading({ text = header_text }),
					u.separator({}),
					u.scroll({
						grow = true,
						content = u.vertical({
							spacing = u.SPACING.SMALL,
							children = rows,
						}),
					}),
					u.separator({}),
					u.label({ text = "Commit message (first line = summary):" }),
					u.string_field({
						grow = true,
						value = msg_state,
						on_value_changed = function(v)
							message = v or ""
							set_msg(v or "")
						end,
					}),
					u.horizontal({
						spacing = u.SPACING.MEDIUM,
						children = {
							u.check_box({
								text = "Amend previous commit",
								value = amend_state,
								on_value_changed = function(v)
									amend = v and true or false
									set_amend(amend)
								end,
							}),
							u.check_box({
								text = "Push after commit",
								value = push_state,
								on_value_changed = function(v)
									push_after = v and true or false
									set_push(push_after)
								end,
							}),
							u.check_box({
								text = "Include untracked",
								value = untracked_state,
								on_value_changed = function(v)
									local want = v and true or false
									set_untracked(want)
									if want then
										for j = 1, #files do
											if files[j].status == "untracked" then
												selected[files[j].path] = true
											end
										end
									end
									set_sel(sel_state + 1)
								end,
							}),
						},
					}),
				},
			}),
			buttons = {
				u.dialog_button({ text = "Refresh", result = "refresh" }),
				u.dialog_button({ text = "Cancel", cancel = true, result = false }),
				u.dialog_button({ text = "Commit", default = true, result = "commit", enabled = can_commit }),
				u.dialog_button({ text = "Commit & Push", result = "commit_push", enabled = can_commit }),
			},
		})
	end)

	local action = u.show_dialog(comp({}))
	if action == "commit" or action == "commit_push" then
		local paths = {}
		for i = 1, #files do
			if selected[files[i].path] and not files[i].conflict then
				paths[#paths + 1] = files[i].path
			end
		end
		return action, { message = message, paths = paths, amend = amend, push_after = (action == "commit_push") or push_after }
	elseif action == "refresh" then
		return "refresh", {}
	end
	return nil, nil
end

-- Branch manager dialog.
function M.branch_dialog(branches, current)
	local u = ui()
	local local_names = {}
	for i = 1, #branches.local_branches do
		local_names[#local_names + 1] = branches.local_branches[i]
	end
	if #local_names == 0 then local_names = { current or "main" } end

	local picked = current or local_names[1]
	local new_name = ""

	local comp = u.component(function(_props)
		local pick_state, set_pick = u.use_state(picked)
		local new_state, set_new = u.use_state("")
		return u.dialog({
			title = "Git: Branches",
			content = u.vertical({
				padding = u.PADDING.LARGE,
				spacing = u.SPACING.MEDIUM,
				children = {
					u.label({ text = "Switch to branch:" }),
					u.select_box({
						value = pick_state,
						options = local_names,
						on_value_changed = function(v)
							picked = v
							set_pick(v)
						end,
					}),
					u.separator({}),
					u.label({ text = "Or create a new branch:" }),
					u.string_field({
						grow = true,
						value = new_state,
						on_value_changed = function(v)
							new_name = v or ""
							set_new(v or "")
						end,
					}),
				},
			}),
			buttons = {
				u.dialog_button({ text = "Cancel", cancel = true, result = false }),
				u.dialog_button({ text = "Switch", result = "switch" }),
				u.dialog_button({ text = "Create + Switch", default = true, result = "create" }),
			},
		})
	end)

	local action = u.show_dialog(comp({}))
	if action == "switch" then
		return "switch", { branch = picked }
	elseif action == "create" then
		if new_name:match("%S") then
			return "create", { branch = new_name:match("^%s*(.-)%s*$") }
		else
			return "switch", { branch = picked }
		end
	end
	return nil, nil
end

-- Push / Pull dialog with remote + branch pickers.
function M.remote_dialog(title, remotes, current_branch, default_remote)
	local u = ui()
	local remote_names = {}
	for name, _ in pairs(remotes or {}) do remote_names[#remote_names + 1] = name end
	table.sort(remote_names)
	if #remote_names == 0 then remote_names = { "origin" } end

	local remote = default_remote or remote_names[1]
	local branch = current_branch or ""

	local comp = u.component(function(_props)
		local remote_state, set_remote = u.use_state(remote)
		local branch_state, set_branch = u.use_state(branch)
		return u.dialog({
			title = title,
			content = u.vertical({
				padding = u.PADDING.LARGE,
				spacing = u.SPACING.MEDIUM,
				children = {
					u.label({ text = "Remote:" }),
					u.select_box({
						value = remote_state,
						options = remote_names,
						on_value_changed = function(v)
							remote = v
							set_remote(v)
						end,
					}),
					u.label({ text = "Branch (empty = current upstream):" }),
					u.string_field({
						grow = true,
						value = branch_state,
						on_value_changed = function(v)
							branch = v or ""
							set_branch(v or "")
						end,
					}),
				},
			}),
			buttons = {
				u.dialog_button({ text = "Cancel", cancel = true, result = false }),
				u.dialog_button({ text = "Run", default = true, result = true }),
			},
		})
	end)

	local ok = u.show_dialog(comp({}))
	if ok then
		return { remote = remote, branch = (branch:match("%S") and branch:match("^%s*(.-)%s*$") or "") }
	end
	return nil
end

-- Scrollable text dialog (history / diff / blame / output).
function M.text_dialog(title, text, width, height)
	local u = ui()
	if text == nil or text == "" then text = "(empty)" end
	-- Cap dialog content; full output also goes to console.
	if #text > 20000 then
		text = text:sub(1, 20000) .. "\n\n... (truncated, see console for full output)"
	end
	return u.show_dialog(u.dialog({
		title = title,
		width = width or 720,
		height = height or 520,
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

function M.history_dialog(commits)
	local lines = {}
	if #commits == 0 then
		lines[#lines + 1] = "No commits yet."
	else
		for i = 1, #commits do
			local c = commits[i]
			lines[#lines + 1] = string.format("%s  %s  %s  <%s>\n    %s",
				c.short or "", c.date or "", c.author or "", c.sha or "", c.subject or "")
		end
	end
	return M.text_dialog("Git: History", table.concat(lines, "\n\n"))
end

return M
