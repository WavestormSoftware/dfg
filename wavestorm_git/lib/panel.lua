-- Wavestorm Git v2: the Git panel.
-- A non-modal, resizable dialog (Defold 1.13+); falls back to a modal
-- variant on older editors (feature-probed at runtime).
--
-- Architecture: git data lives in upvalue tables re-queried after every
-- action; user input (message, amend, pickers) lives in a separate upvalue
-- so refreshes never wipe in-progress input. One use_state counter drives
-- re-renders (buttons are suspendable, so git calls are allowed in them).
local M = {}

local dialogs = require("wavestorm_git.lib.dialogs")

local open_flag = false

local function ui()
	assert(type(editor) == "table" and type(editor.ui) == "table",
		"editor.ui is only available inside the Defold editor")
	return editor.ui
end

local function prefs_get(key, fallback)
	if type(editor) == "table" and type(editor.prefs) == "table" then
		local okk, v = pcall(editor.prefs.get, key)
		if okk and v ~= nil then return v end
	end
	return fallback
end

local function supports_non_modal()
	local okk = pcall(ui().dialog, { title = "_wavestorm_probe", modal = false })
	return okk
end

-- Git-side data; never contains user input state.
local function collect_git_data()
	local git = require("wavestorm_git.lib.git")
	local status = git.status()
	local data = {
		status_res = status,
		st = status.ok and status.data or nil,
		remotes_res = git.remotes(),
		branches_res = git.branches(),
		log_res = {},
		busy = false,
		result = nil, -- { text = ..., color = ... }
	}
	local log = git.log(prefs_get("wavestorm_git.history_count", 25))
	if log.ok then data.log_res = log.data end
	return data
end

-- Derived Status-tab sections.
local function sections(data)
	local st = data and data.st
	local out = { staged = {}, changes = {}, conflicts = {} }
	if not st then return out end
	for i = 1, #st.files do
		local f = st.files[i]
		if f.conflict then
			out.conflicts[#out.conflicts + 1] = f
		else
			if f.staged then out.staged[#out.staged + 1] = f end
			if f.unstaged or f.untracked then out.changes[#out.changes + 1] = f end
		end
	end
	return out
end

local function count_staged(st)
	local n = 0
	if not st then return 0 end
	for i = 1, #st.files do
		if st.files[i].staged and not st.files[i].conflict then n = n + 1 end
	end
	return n
end

function M.open()
	if open_flag then
		dialogs.info("Git", "The Git panel is already open.")
		return
	end
	open_flag = true

	local u = ui()
	local git = require("wavestorm_git.lib.git")

	if prefs_get("wavestorm_git.auto_save", true) then
		pcall(editor.save)
	end

	local data = collect_git_data()
	local user = {
		message = "",
		amend = false,
		push_after = prefs_get("wavestorm_git.push_after_commit", false) == true,
		ff_only = prefs_get("wavestorm_git.pull_ff_only", false) == true,
		force_delete = false,
		selected_remote = prefs_get("wavestorm_git.default_remote", "origin"),
		branch_field = "",
		new_branch = "",
		picked_branch = nil,
	}

	local force_modal = not supports_non_modal()

	local comp = u.component(function(_props)
		local _tick, set_tick = u.use_state(0)

		local function refresh(res)
			data = collect_git_data()
			if res ~= nil then
				local text = dialogs.result_text(res)
				if text == "" or text == "nil" then text = "Done." end
				data.result = {
					text = text,
					color = res.ok and u.COLOR.TEXT or u.COLOR.ERROR,
				}
			end
			set_tick(function(old) return old + 1 end)
		end

		-- Run a git action; errors never break the panel.
		local function act(run_fn)
			if data.busy then return end
			data.busy = true
			set_tick(function(old) return old + 1 end)
			local okk, res = pcall(run_fn)
			data.busy = false
			if not okk then
				res = { ok = false, kind = "script", message = tostring(res) }
			end
			refresh(res)
		end

		local function save()
			if prefs_get("wavestorm_git.auto_save", true) then
				pcall(editor.save)
			end
		end

		-- Actions ------------------------------------------------------------

		local function do_stage(path)
			act(function() return git.add(path) end)
		end

		local function do_unstage(path)
			act(function() return git.unstage(path) end)
		end

		local function do_discard(f)
			if prefs_get("wavestorm_git.confirm_discard", true) then
				local extra = f.untracked
					and "\n\nThe untracked file will be deleted." or ""
				if not dialogs.confirm("Git: Discard changes?",
					"Discard ALL changes to:\n\n" .. f.path .. extra
					.. "\n\nThis cannot be undone in the editor.", "Discard") then
					return
				end
			end
			save()
			act(function() return git.discard(f.path, f.untracked) end)
		end

		local function show_diff(f)
			if f.untracked then
				dialogs.info("Git: Diff — " .. f.path,
					"Untracked file: git has no diff for it yet. Stage it to include it in the next commit.")
				return
			end
			act(function()
				local res = git.diff(f.path, f.staged and not f.unstaged)
				if res.ok and res.data ~= "" then
					dialogs.text("Git: Diff — " .. f.path, res.data)
				elseif res.ok then
					dialogs.info("Git: Diff — " .. f.path, "No diff for this file.")
				end
				return res
			end)
		end

		local function open_file(path)
			local okk, err = pcall(u.open_resource, "/" .. path)
			if not okk then
				dialogs.error("Git: Open file", "Could not open /" .. path .. "\n\n" .. tostring(err))
			end
		end

		local function push_after_commit(fallback_res)
			local st = git.status()
			local branch = st.ok and st.data.branch or nil
			local set_upstream = st.ok and st.data.upstream == nil and branch ~= nil
			local pres = git.push(user.selected_remote, branch, set_upstream)
			if pres.ok then
				return { ok = true, data = dialogs.result_text(fallback_res) .. "\n" .. dialogs.result_text(pres) }
			end
			return {
				ok = false, kind = pres.kind,
				message = "Commit succeeded, but push failed:\n" .. dialogs.result_text(pres),
				hint = pres.hint,
			}
		end

		local function do_commit(and_push)
			local sec = sections(data)
			if #sec.conflicts > 0 then
				dialogs.error("Git: Commit blocked",
					string.format("%d unmerged file(s). Resolve conflicts first (listed in the panel).", #sec.conflicts))
				return
			end
			if (user.message or ""):match("%S") == nil then
				dialogs.error("Git: Commit", "Write a commit message first.")
				return
			end
			if count_staged(data.st) == 0 and not user.amend then
				dialogs.error("Git: Commit", "Nothing is staged. Stage files (or tick Amend).")
				return
			end
			save()
			act(function()
				local res = git.commit(user.message, user.amend)
				if res.ok then
					user.message = ""
					user.amend = false
					if and_push or user.push_after then
						return push_after_commit(res)
					end
				end
				return res
			end)
		end

		local function do_stage_all_and_commit()
			local sec = sections(data)
			if #sec.conflicts > 0 then
				dialogs.error("Git: Commit blocked",
					string.format("%d unmerged file(s). Resolve conflicts first.", #sec.conflicts))
				return
			end
			if (user.message or ""):match("%S") == nil then
				dialogs.error("Git: Commit", "Write a commit message first.")
				return
			end
			save()
			act(function()
				local res = git.add_all()
				if res.ok then
					res = git.commit(user.message, false)
					if res.ok then
						user.message = ""
						if user.push_after then
							return push_after_commit(res)
						end
					end
				end
				return res
			end)
		end

		local function do_push()
			save()
			act(function()
				local branch = (user.branch_field or ""):match("%S")
				if not branch then
					local st = data.st
					branch = st and st.branch or nil
				end
				local st = data.st
				local set_upstream = st and st.upstream == nil and branch ~= nil
				local res = git.push(user.selected_remote, branch, set_upstream)
				if res.ok and (res.data == nil or res.data == "") then
					res = { ok = true, data = "Pushed to " .. tostring(user.selected_remote) .. "." }
				end
				return res
			end)
		end

		local function do_pull()
			save()
			act(function()
				local branch = (user.branch_field or ""):match("%S")
				return git.pull(user.selected_remote, branch, user.ff_only)
			end)
		end

		local function do_fetch()
			act(function() return git.fetch(user.selected_remote) end)
		end

		local function do_switch()
			local picked = user.picked_branch or (data.st and data.st.branch) or ""
			if picked == "" then return end
			save()
			act(function() return git.checkout(picked) end)
		end

		local function do_create_branch()
			local name = (user.new_branch or ""):match("^%s*(.-)%s*$")
			if name == "" then
				dialogs.error("Git: New branch", "Enter a branch name first.")
				return
			end
			save()
			act(function() return git.create_branch(name) end)
		end

		local function do_delete_branch()
			local picked = user.picked_branch or ""
			if picked == "" then
				dialogs.error("Git: Delete branch", "Pick a branch to delete first.")
				return
			end
			local current = data.st and data.st.branch or nil
			if current ~= nil and picked == current then
				dialogs.error("Git: Delete branch", "Cannot delete the checked-out branch. Switch away first.")
				return
			end
			if not user.force_delete then
				if not dialogs.confirm("Git: Delete branch?", "Delete branch '" .. picked .. "'?", "Delete") then
					return
				end
			end
			act(function() return git.delete_branch(picked, current, user.force_delete) end)
		end

		-- UI builders ----------------------------------------------------------

		local function row_button(text, on_pressed, enabled)
			return u.button({
				text = text,
				on_pressed = on_pressed,
				enabled = enabled ~= false and not data.busy,
			})
		end

		local function file_row(f, mode)
			local children = {
				u.label({
					text = git.format_file_entry(f),
					grow = true,
					alignment = u.ALIGNMENT.LEFT,
				}),
				row_button("Open", function() open_file(f.path) end),
			}
			if mode == "staged" then
				children[#children + 1] = row_button("Diff", function() show_diff(f) end)
				children[#children + 1] = row_button("Unstage", function() do_unstage(f.path) end)
			elseif mode == "changes" then
				children[#children + 1] = row_button("Diff", function() show_diff(f) end)
				children[#children + 1] = row_button("Stage", function() do_stage(f.path) end)
				children[#children + 1] = row_button("Discard", function() do_discard(f) end)
			end
			return u.horizontal({ spacing = u.SPACING.SMALL, children = children })
		end

		local function list_section(title_text, files, mode, empty_text)
			local children = { u.heading({ text = title_text, style = u.HEADING_STYLE.H4 }) }
			if #files == 0 then
				children[#children + 1] = u.paragraph({ text = empty_text, color = u.COLOR.HINT })
			else
				for i = 1, #files do
					children[#children + 1] = file_row(files[i], mode)
				end
			end
			return u.vertical({ spacing = u.SPACING.SMALL, children = children })
		end

		local function status_tab()
			local sec = sections(data)
			local has_message = (user.message or ""):match("%S") ~= nil
			local can_commit = (count_staged(data.st) > 0 or user.amend) and #sec.conflicts == 0

			return u.vertical({
				spacing = u.SPACING.MEDIUM,
				children = {
					u.scroll({
						grow = true,
						content = u.vertical({
							spacing = u.SPACING.MEDIUM,
							children = {
								#sec.conflicts > 0
									and list_section("Merge conflicts (" .. #sec.conflicts
										.. ") — resolve in an external client", sec.conflicts, "conflict", "")
									or false,
								list_section("Staged", sec.staged, "staged", "Nothing staged."),
								list_section("Changes", sec.changes, "changes", "Working tree is clean."),
							},
						}),
					}),
					u.separator({}),
					u.horizontal({
						spacing = u.SPACING.SMALL,
						children = {
							row_button("Stage all", function()
								act(function() return git.add_all() end)
							end),
							row_button("Unstage all", function()
								act(function() return git.unstage(".") end)
							end),
						},
					}),
					u.label({ text = "Commit message (first line = summary):" }),
					u.string_field({
						grow = true,
						value = user.message,
						on_value_changed = function(v) user.message = v or "" end,
						enabled = not data.busy,
					}),
					u.horizontal({
						spacing = u.SPACING.MEDIUM,
						children = {
							u.check_box({
								text = "Amend previous commit",
								value = user.amend,
								on_value_changed = function(v)
									local want = v == true
									if want and (user.message or ""):match("%S") == nil then
										local lm = git.last_commit_message()
										if lm.ok and lm.data ~= "" then
											user.message = (lm.data:gsub("%s+$", ""))
										end
									end
									user.amend = want
									set_tick(function(old) return old + 1 end)
								end,
							}),
							u.check_box({
								text = "Push after commit",
								value = user.push_after,
								on_value_changed = function(v) user.push_after = v == true end,
							}),
						},
					}),
					u.horizontal({
						spacing = u.SPACING.SMALL,
						children = {
							row_button("Commit staged", function() do_commit(false) end,
								can_commit and has_message),
							row_button("Commit & Push", function() do_commit(true) end,
								can_commit and has_message),
							row_button("Stage all & Commit", function() do_stage_all_and_commit() end,
								has_message and #sec.conflicts == 0),
						},
					}),
				},
			})
		end

		local function sync_tab()
			local remotes = {}
			local rres = data.remotes_res
			if rres.ok then
				for name, _ in pairs(rres.data) do remotes[#remotes + 1] = name end
			end
			table.sort(remotes)
			if #remotes == 0 then remotes = { "origin" } end
			local has_remote = rres.ok and next(rres.data) ~= nil

			local result_component = false
			if data.result then
				result_component = u.paragraph({
					text = data.result.text,
					color = data.result.color,
				})
			end

			return u.vertical({
				spacing = u.SPACING.MEDIUM,
				children = {
					u.grid({
						columns = { {}, { grow = true } },
						spacing = u.SPACING.SMALL,
						children = {
							{ u.label({ text = "Remote:", alignment = u.ALIGNMENT.RIGHT }),
								u.select_box({
									value = user.selected_remote,
									options = remotes,
									on_value_changed = function(v) user.selected_remote = tostring(v) end,
									enabled = not data.busy,
								}) },
							{ u.label({ text = "Branch (empty = current):", alignment = u.ALIGNMENT.RIGHT }),
								u.string_field({
									grow = true,
									value = user.branch_field,
									on_value_changed = function(v) user.branch_field = v or "" end,
									enabled = not data.busy,
								}) },
						},
					}),
					u.horizontal({
						spacing = u.SPACING.SMALL,
						children = {
							row_button("Push", do_push, has_remote),
							row_button("Pull", do_pull, has_remote),
							row_button("Fetch", do_fetch, has_remote),
							u.check_box({
								text = "ff-only pull",
								value = user.ff_only,
								on_value_changed = function(v) user.ff_only = v == true end,
							}),
						},
					}),
					u.separator({}),
					result_component,
					has_remote and false or u.paragraph({
						text = "No remotes configured. Add one in a terminal:\n  git remote add origin <url>",
						color = u.COLOR.WARNING,
					}),
				},
			})
		end

		local function branches_tab()
			local locals = {}
			local bres = data.branches_res
			if bres.ok then locals = bres.data.local_branches end
			if #locals == 0 then locals = { (data.st and data.st.branch) or "main" } end
			if user.picked_branch == nil or user.picked_branch == "" then
				user.picked_branch = (data.st and data.st.branch) or locals[1]
			end

			local st = data.st
			local head_hint = false
			if st and st.head_state == "detached" then
				head_hint = u.paragraph({
					text = "Detached HEAD: commit or switch to a branch to keep changes.",
					color = u.COLOR.WARNING,
				})
			elseif st and st.head_state == "initial" then
				head_hint = u.paragraph({ text = "No commits yet.", color = u.COLOR.HINT })
			end

			return u.vertical({
				spacing = u.SPACING.MEDIUM,
				children = {
					u.label({ text = "Local branches:" }),
					u.select_box({
						value = user.picked_branch,
						options = locals,
						on_value_changed = function(v) user.picked_branch = tostring(v) end,
						enabled = not data.busy,
					}),
					u.horizontal({
						spacing = u.SPACING.SMALL,
						children = {
							row_button("Switch", do_switch),
							row_button("Delete", do_delete_branch),
							u.check_box({
								text = "force delete",
								value = user.force_delete,
								on_value_changed = function(v) user.force_delete = v == true end,
							}),
						},
					}),
					head_hint,
					u.separator({}),
					u.label({ text = "Create a new branch:" }),
					u.string_field({
						grow = true,
						value = user.new_branch,
						on_value_changed = function(v) user.new_branch = v or "" end,
						enabled = not data.busy,
					}),
					row_button("Create & switch", do_create_branch),
				},
			})
		end

		local function history_tab()
			local commits = data.log_res or {}
			local rows = {
				row_button("Refresh history", function()
					act(function()
						local res = git.log(prefs_get("wavestorm_git.history_count", 25))
						data.log_res = res.ok and res.data or {}
						return { ok = true, data = "" }
					end)
				end, true),
			}
			if #commits == 0 then
				rows[#rows + 1] = u.paragraph({ text = "No commits yet.", color = u.COLOR.HINT })
			else
				for i = 1, #commits do
					local c = commits[i]
					rows[#rows + 1] = u.vertical({
						spacing = u.SPACING.SMALL,
						children = {
							u.paragraph({
								text = string.format("%s  %s  %s\n    %s",
									c.short or "", c.date or "", c.author or "", c.subject or ""),
							}),
							row_button("View diff", function()
								act(function()
									local res = git.commit_show(c.sha)
									if res.ok then
										dialogs.text("Git: " .. tostring(c.short) .. " — "
											.. tostring(c.subject), res.data)
									end
									return res
								end)
							end),
						},
					})
				end
			end
			return u.scroll({
				grow = true,
				content = u.vertical({ spacing = u.SPACING.MEDIUM, children = rows }),
			})
		end

		-- Header + assembly ----------------------------------------------------

		local st = data.st
		local header_text = st and git.summary(st)
			or dialogs.result_text(data.status_res)
		local header_color = (st and #st.conflicts > 0) and u.COLOR.ERROR or u.COLOR.TEXT

		local result_footer = false
		if data.result then
			result_footer = u.paragraph({ text = data.result.text, color = data.result.color })
		end

		return u.dialog({
			title = "Git — Wavestorm",
			modal = force_modal,
			resizable = true,
			width = 800,
			height = 640,
			content = u.vertical({
				padding = u.PADDING.LARGE,
				spacing = u.SPACING.MEDIUM,
				children = {
					u.horizontal({
						spacing = u.SPACING.MEDIUM,
						children = {
							u.heading({
								text = header_text,
								style = u.HEADING_STYLE.H4,
								color = header_color,
								grow = true,
							}),
							row_button("Refresh", function()
								act(function() return { ok = true, data = "" } end)
							end),
						},
					}),
					u.separator({}),
					u.tabs({
						tabs = {
							u.tab({ text = "Status", content = status_tab() }),
							u.tab({ text = "Sync", content = sync_tab() }),
							u.tab({ text = "Branches", content = branches_tab() }),
							u.tab({ text = "History", content = history_tab() }),
						},
					}),
					result_footer,
				},
			}),
			buttons = {
				u.dialog_button({ text = "Close", cancel = true, default = true, result = "close" }),
			},
		})
	end)

	u.show_dialog(comp({}))
	open_flag = false
end

return M
