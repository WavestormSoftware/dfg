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
local function collect_git_data(old)
	local git = require("wavestorm_git.lib.git")
	local status = git.status()
	local data = {
		status_res = status,
		st = status.ok and status.data or nil,
		remotes_res = git.remotes(),
		branches_res = git.branches(),
		log_res = {},
		activity_res = {},
		incoming_res = {},
		stash_res = {},
		busy = false,
		result = nil, -- { text = ..., color = ... }
		-- auto-fetch state survives refreshes
		last_fetch = old and old.last_fetch or nil,
		fetch_state = old and old.fetch_state or nil, -- "ok" | "failed" | nil
	}
	local log = git.log(prefs_get("wavestorm_git.history_count", 25))
	if log.ok then data.log_res = log.data end
	local act = git.activity(8)
	if act.ok then data.activity_res = act.data end
	local inc = git.incoming(15)
	if inc.ok then data.incoming_res = inc.data end
	local stash = git.stash_list()
	if stash.ok then data.stash_res = stash.data end
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

	-- Fetch once on open. This runs in the command's long-running context;
	-- it must NOT run during panel rendering, which is an immediate context
	-- where editor.execute is forbidden.
	if prefs_get("wavestorm_git.auto_fetch", true) then
		local git0 = require("wavestorm_git.lib.git")
		local remotes = data.remotes_res
		if remotes and remotes.ok and next(remotes.data) ~= nil then
			local remote = prefs_get("wavestorm_git.default_remote", "origin")
			local res = git0.fetch(remote)
			data.last_fetch_at = os.time()
			data.last_fetch = os.date("%H:%M")
			data.fetch_state = res.ok and "ok" or "failed"
			if res.ok then
				data = collect_git_data(data)
			end
		end
	end

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
			data = collect_git_data(data)
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
			act(function()
				local res = git.fetch(user.selected_remote)
				data.last_fetch = os.date("%H:%M")
				data.fetch_state = res.ok and "ok" or "failed"
				return res
			end)
		end

		local function do_stash_push()
			save()
			act(function()
				local res = git.stash_push(user.stash_message)
				if res.ok then user.stash_message = "" end
				return res
			end)
		end

		local function do_stash_pop(ref)
			save()
			act(function() return git.stash_pop(ref) end)
		end

		local function do_stash_drop(ref)
			if not dialogs.confirm("Git: Drop stash?",
				"Permanently drop " .. tostring(ref) .. "?\n\nThis cannot be undone.", "Drop") then
				return
			end
			act(function() return git.stash_drop(ref) end)
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

		local function row_button(text, on_pressed, enabled, tooltip)
			return u.button({
				text = text,
				on_pressed = on_pressed,
				enabled = enabled ~= false and not data.busy,
				tooltip = tooltip,
			})
		end

		local STATUS_GLYPH = {
			modified = "M", added = "+", deleted = "-", renamed = "R",
			copied = "C", typechange = "T", untracked = "?", conflict = "!",
		}
		local STATUS_COLOR = {
			conflict = u.COLOR.ERROR, deleted = u.COLOR.WARNING,
			untracked = u.COLOR.HINT,
		}

		local function file_row(f, mode)
			local glyph = STATUS_GLYPH[f.status] or "M"
			local color = STATUS_COLOR[f.status] or u.COLOR.TEXT
			local label_text = f.orig and (f.orig .. "  ->  " .. f.path) or f.path
			local children = {
				u.label({ text = glyph, color = color, alignment = u.ALIGNMENT.CENTER }),
				u.label({
					text = label_text,
					grow = true,
					alignment = u.ALIGNMENT.LEFT,
					tooltip = f.status,
				}),
				row_button("Open", function() open_file(f.path) end, true, "Open in the editor"),
			}
			if mode == "staged" then
				children[#children + 1] = row_button("Diff", function() show_diff(f) end)
				children[#children + 1] = row_button("Unstage", function() do_unstage(f.path) end)
			elseif mode == "changes" then
				children[#children + 1] = row_button("Diff", function() show_diff(f) end)
				children[#children + 1] = row_button("Stage", function() do_stage(f.path) end)
				children[#children + 1] = row_button("Discard", function() do_discard(f) end, true,
					"Throw away these changes (cannot be undone)")
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
			-- The message field reports its value only on Enter/focus-loss and
			-- does not re-render the panel, so the buttons cannot be gated on
			-- the message text — they would stay disabled forever. Whether a
			-- message was typed is checked inside do_commit instead.
			local can_commit = (count_staged(data.st) > 0 or user.amend) and #sec.conflicts == 0
			local total_changes = #sec.staged + #sec.changes

			local summary_text
			local summary_color = u.COLOR.HINT
			if #sec.conflicts > 0 then
				summary_text = string.format("%d merge conflict(s) — resolve these before committing", #sec.conflicts)
				summary_color = u.COLOR.ERROR
			elseif total_changes == 0 then
				summary_text = "Working tree clean — nothing to commit"
			else
				summary_text = string.format("%d staged   ·   %d unstaged change(s)", #sec.staged, #sec.changes)
				summary_color = u.COLOR.TEXT
			end

			return u.vertical({
				spacing = u.SPACING.MEDIUM,
				children = {
					u.paragraph({ text = summary_text, color = summary_color }),
					u.scroll({
						grow = true,
						content = u.vertical({
							spacing = u.SPACING.MEDIUM,
							children = {
								#sec.conflicts > 0
									and list_section("Conflicts — resolve in an external client",
										sec.conflicts, "conflict", "")
									or false,
								list_section("Staged for commit", sec.staged, "staged", "Nothing staged yet."),
								list_section("Changes", sec.changes, "changes", "No unstaged changes."),
							},
						}),
					}),
					u.separator({}),
					u.horizontal({
						spacing = u.SPACING.SMALL,
						children = {
							row_button("Stage all", function()
								act(function() return git.add_all() end)
							end, #sec.changes > 0, "Stage every change"),
							row_button("Unstage all", function()
								act(function() return git.unstage(".") end)
							end, #sec.staged > 0, "Move everything back out of the commit"),
						},
					}),
					u.label({ text = "Commit message  —  first line is the summary" }),
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
								tooltip = "Add to the last commit instead of creating a new one",
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
								tooltip = "Push to the remote right after the commit succeeds",
								value = user.push_after,
								on_value_changed = function(v) user.push_after = v == true end,
							}),
						},
					}),
					u.horizontal({
						spacing = u.SPACING.SMALL,
						children = {
							row_button("Commit staged", function() do_commit(false) end,
								can_commit, "Commit the staged files"),
							row_button("Commit & Push", function() do_commit(true) end,
								can_commit, "Commit and push in one step"),
							row_button("Stage all & Commit", function() do_stage_all_and_commit() end,
								#sec.conflicts == 0, "Stage everything, then commit"),
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
			local st = data.st

			-- Sync status banner: the one line that answers "am I up to date?"
			local banner_text, banner_color
			if not has_remote then
				banner_text = "No remote configured — this project is local only"
				banner_color = u.COLOR.WARNING
			elseif st and not st.upstream then
				banner_text = "This branch has never been pushed — Push sets up tracking"
				banner_color = u.COLOR.WARNING
			elseif st and ((st.behind or 0) > 0) then
				banner_text = string.format("%d commit(s) from teammates waiting — Pull to get them", st.behind)
				banner_color = u.COLOR.WARNING
			elseif st and ((st.ahead or 0) > 0) then
				banner_text = string.format("You are %d commit(s) ahead — Push to share your work", st.ahead)
				banner_color = u.COLOR.TEXT
			elseif st then
				banner_text = "In sync with " .. tostring(st.upstream)
				banner_color = u.COLOR.HINT
			end

			-- Incoming commits: who pushed what.
			local incoming = data.incoming_res or {}
			local incoming_children = {
				u.heading({
					text = #incoming > 0
						and ("Incoming from teammates (" .. #incoming .. ")")
						or "Incoming from teammates",
					style = u.HEADING_STYLE.H4,
				}),
			}
			if #incoming == 0 then
				incoming_children[#incoming_children + 1] = u.paragraph({
					text = (st and (st.behind or 0) == 0)
						and "Nothing new — you have everything your teammates pushed."
						or "Fetch to check what teammates have pushed.",
					color = u.COLOR.HINT,
				})
			else
				for i = 1, math.min(#incoming, 8) do
					local c = incoming[i]
					incoming_children[#incoming_children + 1] = u.label({
						text = string.format("%s   %s   ·   %s   ·   %s",
							c.short or "", c.subject or "", c.author or "", c.ago or ""),
						color = u.COLOR.TEXT,
					})
				end
				if #incoming > 8 then
					incoming_children[#incoming_children + 1] = u.paragraph({
						text = string.format("... and %d more", #incoming - 8),
						color = u.COLOR.HINT,
					})
				end
			end

			local fetch_note = false
			if data.last_fetch then
				fetch_note = u.paragraph({
					text = data.fetch_state == "failed"
						and ("Last fetch FAILED at " .. data.last_fetch .. " — check network or credentials")
						or ("Last fetched at " .. data.last_fetch),
					color = data.fetch_state == "failed" and u.COLOR.ERROR or u.COLOR.HINT,
				})
			end

			return u.vertical({
				spacing = u.SPACING.MEDIUM,
				children = {
					banner_text and u.paragraph({ text = banner_text, color = banner_color }) or false,
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
							{ u.label({ text = "Branch:", alignment = u.ALIGNMENT.RIGHT }),
								u.string_field({
									grow = true,
									value = user.branch_field,
									tooltip = "Leave empty to use the current branch",
									on_value_changed = function(v) user.branch_field = v or "" end,
									enabled = not data.busy,
								}) },
						},
					}),
					u.horizontal({
						spacing = u.SPACING.SMALL,
						children = {
							row_button("Fetch", do_fetch, has_remote,
								"Download teammates' commits without changing your files"),
							row_button("Pull", do_pull, has_remote,
								"Fetch and merge teammates' commits into your branch"),
							row_button("Push", do_push, has_remote,
								"Upload your commits so teammates can pull them"),
							u.check_box({
								text = "pull: fast-forward only",
								tooltip = "Refuse the pull instead of creating a merge commit",
								value = user.ff_only,
								on_value_changed = function(v) user.ff_only = v == true end,
							}),
						},
					}),
					fetch_note,
					u.separator({}),
					u.scroll({
						grow = true,
						content = u.vertical({ spacing = u.SPACING.SMALL, children = incoming_children }),
					}),
					has_remote and false or u.paragraph({
						text = "Add a remote in a terminal:  git remote add origin <url>",
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
					text = "Detached HEAD — you are not on a branch. Switch to one or your next commit may be hard to find.",
					color = u.COLOR.WARNING,
				})
			elseif st and st.head_state == "initial" then
				head_hint = u.paragraph({ text = "No commits yet — make the first one on the Status tab.", color = u.COLOR.HINT })
			end

			-- Stash shelf: park work to switch branches safely.
			local stashes = data.stash_res or {}
			local stash_children = {
				u.heading({ text = "Stashes  —  park work to switch branches", style = u.HEADING_STYLE.H4 }),
				u.horizontal({
					spacing = u.SPACING.SMALL,
					children = {
						u.string_field({
							grow = true,
							value = user.stash_message or "",
							tooltip = "Optional note for the stash",
							on_value_changed = function(v) user.stash_message = v or "" end,
							enabled = not data.busy,
						}),
						row_button("Stash changes", do_stash_push, true,
							"Shelve all current changes (including untracked files) so you can switch branches"),
					},
				}),
			}
			if #stashes == 0 then
				stash_children[#stash_children + 1] = u.paragraph({
					text = "No stashes. Stash your changes before switching branches when you are mid-task.",
					color = u.COLOR.HINT,
				})
			else
				for i = 1, #stashes do
					local s = stashes[i]
					local ref = s.ref
					stash_children[#stash_children + 1] = u.horizontal({
						spacing = u.SPACING.SMALL,
						children = {
							u.label({ text = ref .. "   " .. (s.subject or ""), grow = true }),
							row_button("Pop", function() do_stash_pop(ref) end, true,
								"Restore these changes into the working tree"),
							row_button("Drop", function() do_stash_drop(ref) end, true,
								"Delete this stash permanently"),
						},
					})
				end
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
							row_button("Switch", do_switch, true, "Check out the selected branch"),
							row_button("Delete", do_delete_branch, true,
								"Delete the selected branch (refuses if it has unmerged commits)"),
							u.check_box({
								text = "force delete",
								tooltip = "Delete even if the branch has commits not merged into the current one",
								value = user.force_delete,
								on_value_changed = function(v) user.force_delete = v == true end,
							}),
						},
					}),
					head_hint,
					u.separator({}),
					u.label({ text = "New branch from current HEAD:" }),
					u.horizontal({
						spacing = u.SPACING.SMALL,
						children = {
							u.string_field({
								grow = true,
								value = user.new_branch,
								tooltip = "letters, digits, - _ / .",
								on_value_changed = function(v) user.new_branch = v or "" end,
								enabled = not data.busy,
							}),
							row_button("Create & switch", do_create_branch),
						},
					}),
					u.separator({}),
					u.scroll({
						grow = true,
						content = u.vertical({ spacing = u.SPACING.SMALL, children = stash_children }),
					}),
				},
			})
		end

		local function history_tab()
			local commits = data.log_res or {}
			local activity = data.activity_res or {}

			-- Team activity feed: who did what, and how recently.
			local feed = {
				u.heading({ text = "Recent activity", style = u.HEADING_STYLE.H4 }),
			}
			if #activity == 0 then
				feed[#feed + 1] = u.paragraph({ text = "No commits yet.", color = u.COLOR.HINT })
			else
				for i = 1, #activity do
					local c = activity[i]
					feed[#feed + 1] = u.label({
						text = string.format("%-14s  %s   ·   %s",
							c.ago or "", c.subject or "", c.author or ""),
						tooltip = c.short or "",
					})
				end
			end

			local rows = {
				u.vertical({ spacing = u.SPACING.SMALL, children = feed }),
				u.separator({}),
				u.heading({ text = "All commits", style = u.HEADING_STYLE.H4 }),
			}
			if #commits == 0 then
				rows[#rows + 1] = u.paragraph({ text = "No commits yet.", color = u.COLOR.HINT })
			else
				for i = 1, #commits do
					local c = commits[i]
					rows[#rows + 1] = u.horizontal({
						spacing = u.SPACING.SMALL,
						children = {
							u.label({
								text = string.format("%s   %s   %s   ·   %s",
									c.short or "", c.date or "", c.author or "", c.subject or ""),
								grow = true,
							}),
							row_button("Diff", function()
								act(function()
									local res = git.commit_show(c.sha)
									if res.ok then
										dialogs.text("Git: " .. tostring(c.short) .. " — "
											.. tostring(c.subject), res.data)
									end
									return res
								end)
							end, true, "Show what this commit changed"),
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

		-- Header: branch on the left, sync badge on the right.
		local branch_text
		local status_failed = false
		if not st then
			branch_text = "Git problem — click for details"
			status_failed = true
		elseif st.head_state == "detached" then
			branch_text = "detached HEAD"
		elseif st.head_state == "initial" then
			branch_text = (st.branch or "main") .. "  ·  no commits yet"
		else
			branch_text = st.branch or "(unknown branch)"
		end

		local badge_text, badge_color = "local only", u.COLOR.HINT
		if st and #st.conflicts > 0 then
			badge_text = string.format("%d CONFLICTS", #st.conflicts)
			badge_color = u.COLOR.ERROR
		elseif st and st.upstream then
			local ahead, behind = st.ahead or 0, st.behind or 0
			if behind > 0 and ahead > 0 then
				badge_text = string.format("%d behind · %d ahead", behind, ahead)
				badge_color = u.COLOR.WARNING
			elseif behind > 0 then
				badge_text = string.format("%d behind — pull", behind)
				badge_color = u.COLOR.WARNING
			elseif ahead > 0 then
				badge_text = string.format("%d ahead — push", ahead)
				badge_color = u.COLOR.TEXT
			else
				badge_text = "in sync"
				badge_color = u.COLOR.HINT
			end
		elseif st and st.head_state == "normal" then
			badge_text = "not pushed yet"
			badge_color = u.COLOR.WARNING
		end

		local fetch_label = false
		if data.last_fetch then
			fetch_label = u.label({
				text = data.fetch_state == "failed" and "fetch failed" or ("fetched " .. data.last_fetch),
				color = data.fetch_state == "failed" and u.COLOR.ERROR or u.COLOR.HINT,
			})
		end

		local result_footer = false
		if data.result and data.result.text ~= "" and data.result.text ~= "Done." then
			result_footer = u.paragraph({ text = data.result.text, color = data.result.color })
		end

		return u.dialog({
			title = "Git — Wavestorm",
			modal = force_modal,
			resizable = true,
			width = 860,
			height = 680,
			content = u.vertical({
				padding = u.PADDING.LARGE,
				spacing = u.SPACING.MEDIUM,
				children = {
					u.horizontal({
						spacing = u.SPACING.MEDIUM,
						children = {
							u.heading({
								text = branch_text,
								style = u.HEADING_STYLE.H3,
								color = status_failed and u.COLOR.ERROR or u.COLOR.TEXT,
								grow = true,
								tooltip = status_failed and dialogs.result_text(data.status_res) or nil,
							}),
							u.heading({
								text = badge_text,
								style = u.HEADING_STYLE.H4,
								color = badge_color,
							}),
							fetch_label,
							row_button("Refresh", function()
								act(function()
									-- Auto-fetch rides along with Refresh: rendering is an
									-- immediate context where git cannot run, so fetching
									-- has to happen inside a button handler.
									if prefs_get("wavestorm_git.auto_fetch", true) then
										local interval = tonumber(prefs_get("wavestorm_git.auto_fetch_minutes", 5)) or 5
										local due = data.last_fetch_at == nil
											or (os.time() - data.last_fetch_at) >= interval * 60
										if due then
											local res = git.fetch(user.selected_remote)
											data.last_fetch_at = os.time()
											data.last_fetch = os.date("%H:%M")
											data.fetch_state = res.ok and "ok" or "failed"
											if not res.ok then return res end
										end
									end
									return nil
								end)
							end, true, "Re-read git status (and fetch when due)"),
						},
					}),
					u.separator({}),
					status_failed and u.paragraph({
						text = dialogs.result_text(data.status_res),
						color = u.COLOR.ERROR,
					}) or false,
					u.tabs({
						grow = true,
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
