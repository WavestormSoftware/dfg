-- Wavestorm Git v2: git CLI wrapper for Defold editor scripts.
--
-- Every operation returns a result table:
--   { ok = true,  data = ... }
--   { ok = false, kind = "...", message = "...", hint = "..."?, exit = N? }
--
-- Kinds: not_a_repo, empty_repo, no_upstream, no_remote, conflict,
--        network, nothing_to_commit, invalid_branch, busy, io, unknown.
--
-- Works inside the Defold editor (editor.execute) and outside it
-- (io.popen fallback) so parsers and operations are testable with plain Lua.
--
-- Status parsing uses `git status --porcelain=v2 --branch -z`: NUL-separated
-- records, no path quoting, explicit unmerged records — unambiguous by
-- construction (unlike porcelain v1 regex parsing used by v1).
local M = {}

local unpack_fn = table.unpack or unpack

-- ---------------------------------------------------------------------------
-- Backend
-- ---------------------------------------------------------------------------

local CONFIG_ARGS = { "-c", "core.quotepath=off" }

-- Optional working directory override (tests point this at throwaway repos;
-- in the editor git already runs from the project root).
local dir_override = nil

function M.set_dir(dir)
	dir_override = dir
end

local function trim(s)
	if type(s) ~= "string" then return s end
	return (s:match("^%s*(.-)%s*$"))
end

M.trim = trim

-- Shell-escape one argument for the io.popen fallback (POSIX-ish).
local function shquote(arg)
	arg = tostring(arg)
	if arg == "" then return "''" end
	if arg:match("^[A-Za-z0-9_@%%+=:,./%-]+$") then return arg end
	return "'" .. arg:gsub("'", "'\\''") .. "'"
end

M.shquote = shquote

-- Low-level runner.
-- args: array of strings AFTER "git", e.g. { "status", "--porcelain=v2", "-b" }
-- opts: { reload = bool }  (true -> editor reloads resources afterwards)
-- Returns: ok:boolean, output:string?, err:table?
--   In the editor, stderr goes to the editor console (err = "pipe");
--   captured output is stdout only. On failure the captured output is
--   discarded by editor.execute, so callers classify errors themselves.
--   The io.popen fallback merges stderr (2>&1) and reports the real exit code.
function M.exec(args, opts)
	opts = opts or {}
	local reload = opts.reload == true
	local op = tostring(args[1] or "git")
	if type(editor) == "table" and type(editor.execute) == "function" then
		local call = { "git" }
		if dir_override then
			call[#call + 1] = "-C"
			call[#call + 1] = dir_override
		end
		for i = 1, #CONFIG_ARGS do call[#call + 1] = CONFIG_ARGS[i] end
		for i = 1, #args do call[#call + 1] = tostring(args[i]) end
		-- "stdout" merges stderr into the captured output: the editor throws
		-- the output away on failure, but on success git's diagnostics survive
		-- in the returned string. (err only accepts discard/stdout/pipe.)
		call[#call + 1] = { reload_resources = reload, out = "capture", err = "stdout" }
		local ok_exec, res = pcall(editor.execute, unpack_fn(call))
		if ok_exec then
			return true, trim(res or ""), nil
		end
		local msg = tostring(res)
		local exit = tonumber(msg:match("exited with code (%-?%d+)")) or -1
		return false, nil, { op = op, exit = exit, message = msg }
	else
		local parts = { "git" }
		if dir_override then
			parts[#parts + 1] = shquote("-C")
			parts[#parts + 1] = shquote(dir_override)
		end
		for i = 1, #CONFIG_ARGS do parts[#parts + 1] = shquote(CONFIG_ARGS[i]) end
		for i = 1, #args do parts[#parts + 1] = shquote(args[i]) end
		-- Merge stderr for diagnostics; append an exit-code sentinel because
		-- io.popen close() semantics differ across Lua versions (5.1/LuaJIT
		-- report no reliable exit code).
		parts[#parts + 1] = "2>&1"
		parts[#parts + 1] = "; printf '__WSEXIT__%d' $?"
		local cmd = table.concat(parts, " ")
		local handle = io.popen(cmd)
		if not handle then
			return false, nil, { op = op, exit = -1, message = "io.popen failed" }
		end
		local out = handle:read("*a") or ""
		handle:close()
		local exit = tonumber(out:match("__WSEXIT__(%d+)%s*$")) or -1
		out = trim((out:gsub("__WSEXIT__%-?%d+%s*$", "")))
		if exit == 0 then
			return true, out, nil
		end
		return false, nil, { op = op, exit = exit, message = out, output = out }
	end
end

local function ok(data) return { ok = true, data = data } end
local function fail(kind, message, hint)
	return { ok = false, kind = kind, message = message, hint = hint }
end
M.ok = ok
M.fail = fail

-- ---------------------------------------------------------------------------
-- Pure parsers (unit-tested with captured real git 2.55 output)
-- ---------------------------------------------------------------------------

local STATUS_LABELS = {
	M = "modified", A = "added", D = "deleted", R = "renamed",
	C = "copied", T = "typechange", U = "conflict",
}

local function entry(xy, path, orig)
	local x = xy:sub(1, 1)
	local y = xy:sub(2, 2)
	local conflict = (x == "U" or y == "U" or x == "A" and y == "A" or x == "D" and y == "D")
	local key = (x ~= "." and x) or (y ~= "." and y) or "M"
	return {
		xy = xy,
		path = path,
		orig = orig,
		status = conflict and "conflict" or (STATUS_LABELS[key] or "modified"),
		staged = x ~= "." and x ~= "?",
		unstaged = y ~= "." and y ~= "?",
		untracked = xy == "??",
		conflict = conflict,
	}
end

-- Split a NUL-separated payload. Plain string.find (not patterns) so this
-- also works on Lua 5.1 / LuaJIT, whose patterns cannot contain NUL bytes.
local function split_nul(s)
	local toks = {}
	local pos = 1
	while pos <= #s do
		local n = s:find("\0", pos, true)
		if not n then
			local last = s:sub(pos)
			if last ~= "" then toks[#toks + 1] = last end
			break
		end
		toks[#toks + 1] = s:sub(pos, n - 1)
		pos = n + 1
	end
	return toks
end

-- Parse `git status --porcelain=v2 --branch -z` output.
-- Record shapes (confirmed on git 2.55):
--   "# branch.oid <sha>| (initial)"
--   "# branch.head <name>| (detached)"          (name IS shown when unborn)
--   "# branch.upstream <upstream>"
--   "# branch.ab +<ahead> -<behind>"
--   "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>"
--   "2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>"  followed by
--     a second NUL token holding <origPath>
--   "u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>"
--   "? <path>"   untracked
--   "! <path>"   ignored (skipped)
function M.parse_status(output)
	local res = {
		branch = nil,
		head_state = "normal",   -- "normal" | "initial" | "detached"
		oid = nil,
		upstream = nil,
		ahead = nil,
		behind = nil,
		files = {},
		conflicts = {},
	}
	if type(output) ~= "string" or output == "" then return res end
	local toks = split_nul(output)
	local i = 1
	while i <= #toks do
		local rec = toks[i]
		i = i + 1
		if rec ~= "" then
			local tag = rec:sub(1, 2)
			if tag == "# " then
				local key, val = rec:match("^# ([%w%.]+) (.+)$")
				if key == "branch.oid" then
					res.oid = val
					if val == "(initial)" then res.head_state = "initial" end
				elseif key == "branch.head" then
					if val == "(detached)" then
						res.head_state = "detached"
						res.branch = nil
					else
						res.branch = val
					end
				elseif key == "branch.upstream" then
					res.upstream = val
				elseif key == "branch.ab" then
					res.ahead = tonumber(val:match("+(%d+)")) or 0
					res.behind = tonumber(val:match("%-(%d+)")) or 0
				end
			elseif tag == "1 " then
				local xy, _, _, _, _, _, _, path = rec:sub(3)
					:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.+)$")
				if xy and path then
					local e = entry(xy, trim(path))
					res.files[#res.files + 1] = e
				end
			elseif tag == "2 " then
				local xy, _, _, _, _, _, _, _, path = rec:sub(3)
					:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.+)$")
				local orig = toks[i]
				i = i + 1 -- rename records consume a second NUL token (origPath)
				if xy and path then
					local e = entry(xy, trim(path), orig and trim(orig) or nil)
					e.renamed = true
					res.files[#res.files + 1] = e
				end
			elseif tag == "u " then
				local xy, _, _, _, _, _, _, _, _, path = rec:sub(3)
					:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.+)$")
				if xy and path then
					local e = entry(xy, trim(path))
					res.files[#res.files + 1] = e
					res.conflicts[#res.conflicts + 1] = e
				end
			elseif tag == "? " then
				local e = entry("??", trim(rec:sub(3)))
				e.status = "untracked"
				res.files[#res.files + 1] = e
			elseif tag == "! " then
				-- ignored, skip
			end
		end
	end
	return res
end

-- Parse `git remote -v` (fetch URLs only): { name = url }
function M.parse_remotes(output)
	local remotes = {}
	if type(output) ~= "string" then return remotes end
	for line in (output .. "\n"):gmatch("([^\n]*)\n") do
		local name, url, kind = line:match("^(%S+)%s+(%S+)%s+%((%a+)%)$")
		if name and url and kind == "fetch" then
			remotes[name] = url
		end
	end
	return remotes
end

-- Parse custom log format: records NUL-separated, fields: sha short author date subject
function M.parse_log(output)
	local commits = {}
	if type(output) ~= "string" or output == "" then return commits end
	local toks = split_nul(output)
	local n = #toks - (#toks % 5) -- ignore trailing partial record
	for i = 1, n, 5 do
		local sha, short, author, date, subject =
			toks[i], toks[i + 1], toks[i + 2], toks[i + 3], toks[i + 4]
		if sha and sha ~= "" and short then
			commits[#commits + 1] = {
				sha = sha, short = short,
				author = author, date = date, subject = subject,
			}
		end
	end
	return commits
end

function M.format_file_entry(f)
	if f.conflict then
		return string.format("[conflict] %s", f.path)
	end
	if f.orig then
		return string.format("[%s] %s -> %s (%s)", f.xy, f.orig, f.path, f.status)
	end
	return string.format("[%s] %s (%s)", f.xy, f.path, f.status)
end

-- One-line human summary of a status snapshot.
function M.summary(st)
	local parts = {}
	if st.head_state == "detached" then
		parts[#parts + 1] = "detached HEAD"
	elseif st.branch then
		parts[#parts + 1] = "branch: " .. st.branch
	else
		parts[#parts + 1] = "branch: (unknown)"
	end
	if st.upstream then
		parts[#parts + 1] = "upstream: " .. st.upstream
	end
	if st.ahead and (st.ahead > 0 or (st.behind or 0) > 0) then
		parts[#parts + 1] = string.format("ahead %d / behind %d", st.ahead, st.behind or 0)
	end
	parts[#parts + 1] = string.format("%d changed file(s)", #st.files)
	if #st.conflicts > 0 then
		parts[#parts + 1] = string.format("%d conflict(s)", #st.conflicts)
	end
	return table.concat(parts, "  |  ")
end

-- ---------------------------------------------------------------------------
-- Repo context
-- ---------------------------------------------------------------------------

local NOT_A_REPO_HINT = "Open Project > Git: Setup / Doctor... to verify (or run 'git init')."

-- Turn a raw exec failure into a classified result. Git's own stderr is the
-- source of truth — never guess "not a repo" from an exit code alone.
local function classify(err, fallback)
	local text = err and err.message or ""
	local low = text:lower()
	if low:find("not a git repository", 1, true) or low:find("not a git working tree", 1, true) then
		return fail("not_a_repo", "Not inside a git working tree.", NOT_A_REPO_HINT)
	end
	if text == "" then text = fallback or "git command failed." end
	return fail("unknown", text)
end

function M.is_repo()
	local okk, out, err = M.exec({ "rev-parse", "--is-inside-work-tree" })
	if okk then
		return ok(trim(out) == "true")
	end
	return classify(err, "Could not run git.")
end

local function require_repo()
	local res = M.is_repo()
	if res.ok and res.data == true then return nil end
	return res
end

-- Full snapshot: everything the panel header needs, from ONE status call.
function M.status()
	local okk, out, err = M.exec({ "status", "--porcelain=v2", "--branch", "-z" })
	if not okk then
		return classify(err, "git status failed.")
	end
	return ok(M.parse_status(out))
end

function M.current_branch()
	local repo = require_repo()
	if repo then return repo end
	local st = M.status()
	if not st.ok then return st end
	if st.data.head_state == "detached" then
		return ok({ branch = nil, head_state = "detached" })
	end
	return ok({ branch = st.data.branch, head_state = st.data.head_state })
end

function M.remotes()
	local repo = require_repo()
	if repo then return repo end
	local okk, out = M.exec({ "remote", "-v" })
	if not okk then return ok({}) end
	return ok(M.parse_remotes(out))
end

function M.branches()
	local repo = require_repo()
	if repo then return repo end
	local local_branches = {}
	local remote_branches = {}
	local okk, out = M.exec({ "branch", "--format=%(refname:short)" })
	if okk then
		for line in (tostring(out) .. "\n"):gmatch("([^\n]*)\n") do
			local t = trim(line)
			if t ~= "" then local_branches[#local_branches + 1] = t end
		end
	end
	local ok2, out2 = M.exec({ "branch", "-r", "--format=%(refname:short)" })
	if ok2 then
		for line in (tostring(out2) .. "\n"):gmatch("([^\n]*)\n") do
			local t = trim(line)
			if t ~= "" and not t:find("/HEAD$", 1, true) then
				remote_branches[#remote_branches + 1] = t
			end
		end
	end
	return ok({ local_branches = local_branches, remote_branches = remote_branches })
end

function M.git_version()
	local okk, out = M.exec({ "--version" })
	if not okk then return fail("unknown", "git not found on PATH.") end
	return ok(out)
end

-- Verify porcelain v2 support (git >= 2.19).
function M.supports_v2()
	local okk, out = M.exec({ "status", "--porcelain=v2", "--branch", "-z" })
	if okk then
		local first = (out or ""):match("^(#%s*branch%.[%w%.]+)")
		return ok(first ~= nil)
	end
	return fail("unsupported", "This git version does not support status --porcelain=v2.", "Please update git (2.19+).")
end

function M.user_config()
	local ok1, name = M.exec({ "config", "user.name" })
	local ok2, email = M.exec({ "config", "user.email" })
	return ok({
		name = ok1 and trim(name) or "",
		email = ok2 and trim(email) or "",
	})
end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

function M.log(count, path)
	local repo = require_repo()
	if repo then return repo end
	local st = M.status()
	if not st.ok then return st end
	if st.data.head_state == "initial" then return ok({}) end
	count = tonumber(count) or 25
	local args = {
		"log", "--pretty=format:%H%x00%h%x00%an%x00%ad%x00%s%x00",
		"--date=short", "-n", tostring(count),
	}
	if path and path ~= "" then
		args[#args + 1] = "--"
		args[#args + 1] = path
	end
	local okk, out = M.exec(args)
	if not okk then
		return fail("unknown", "git log failed (exit " .. tostring(err and err.exit) .. ").")
	end
	return ok(M.parse_log(out))
end

function M.commit_show(sha)
	local repo = require_repo()
	if repo then return repo end
	local okk, out = M.exec({ "show", "--no-color", "--format=medium", sha })
	if not okk then
		return fail("unknown", "git show failed (exit " .. tostring(err and err.exit) .. ").")
	end
	return ok(out)
end

function M.last_commit_message()
	local repo = require_repo()
	if repo then return repo end
	local okk, out = M.exec({ "log", "-1", "--pretty=%B" })
	if not okk then return ok("") end
	return ok(out or "")
end

-- Recent commits with relative dates ("2 hours ago") for the activity feed.
function M.activity(count)
	local repo = require_repo()
	if repo then return repo end
	local st = M.status()
	if not st.ok then return st end
	if st.data.head_state == "initial" then return ok({}) end
	local args = {
		"log", "--pretty=format:%h%x00%an%x00%ar%x00%s%x00",
		"-n", tostring(tonumber(count) or 8),
	}
	local okk, out = M.exec(args)
	if not okk then return fail("unknown", "git log failed.") end
	local commits = {}
	local toks = split_nul(out or "")
	local n = #toks - (#toks % 4)
	for i = 1, n, 4 do
		if toks[i] ~= "" then
			commits[#commits + 1] = {
				short = toks[i], author = toks[i + 1],
				ago = toks[i + 2], subject = toks[i + 3],
			}
		end
	end
	return ok(commits)
end

-- Commits on the upstream that are not in the local branch yet.
function M.incoming(count)
	local repo = require_repo()
	if repo then return repo end
	local st = M.status()
	if not st.ok then return st end
	if not st.data.upstream then return ok({}) end
	local args = {
		"log", "--pretty=format:%h%x00%an%x00%ar%x00%s%x00",
		"-n", tostring(tonumber(count) or 15),
		"HEAD.." .. st.data.upstream,
	}
	local okk, out = M.exec(args)
	if not okk then return ok({}) end
	local commits = {}
	local toks = split_nul(out or "")
	local n = #toks - (#toks % 4)
	for i = 1, n, 4 do
		if toks[i] ~= "" then
			commits[#commits + 1] = {
				short = toks[i], author = toks[i + 1],
				ago = toks[i + 2], subject = toks[i + 3],
			}
		end
	end
	return ok(commits)
end

function M.blame(path)
	local repo = require_repo()
	if repo then return repo end
	if not path or path == "" then return fail("unknown", "No file selected.") end
	local okk, out = M.exec({ "blame", "--", path })
	if not okk then
		return fail("unknown", "git blame failed (exit " .. tostring(err and err.exit) .. ").")
	end
	return ok(out)
end

-- Stash -------------------------------------------------------------------

function M.stash_list()
	local repo = require_repo()
	if repo then return repo end
	local okk, out = M.exec({ "stash", "list", "--pretty=format:%gd%x00%gs%x00" })
	if not okk then return ok({}) end
	local stashes = {}
	local toks = split_nul(out or "")
	for i = 1, #toks - (#toks % 2), 2 do
		if toks[i] ~= "" then
			stashes[#stashes + 1] = { ref = toks[i], subject = toks[i + 1] }
		end
	end
	return ok(stashes)
end

function M.stash_push(message)
	local repo = require_repo()
	if repo then return repo end
	local args = { "stash", "push", "--include-untracked" }
	if message and trim(message) ~= "" then
		args[#args + 1] = "-m"
		args[#args + 1] = message
	end
	local okk, _, err = M.exec(args, { reload = true })
	if not okk then
		return fail("unknown", "git stash failed (exit " .. tostring(err and err.exit) .. ").")
	end
	return ok(nil)
end

function M.stash_pop(ref)
	local repo = require_repo()
	if repo then return repo end
	local args = { "stash", "pop" }
	if ref and ref ~= "" then args[#args + 1] = ref end
	local okk, _, err = M.exec(args, { reload = true })
	if not okk then
		local st = M.status()
		if st.ok and #st.data.conflicts > 0 then
			return fail("conflict", "Stash pop stopped: conflicts in the working tree.",
				"Resolve the conflicts listed in the panel, then commit.")
		end
		return fail("unknown", "git stash pop failed (exit " .. tostring(err and err.exit) .. ").")
	end
	return ok(nil)
end

function M.stash_drop(ref)
	local repo = require_repo()
	if repo then return repo end
	if not ref or ref == "" then return fail("unknown", "No stash selected.") end
	local okk, _, err = M.exec({ "stash", "drop", ref }, { reload = false })
	if not okk then
		return fail("unknown", "git stash drop failed (exit " .. tostring(err and err.exit) .. ").")
	end
	return ok(nil)
end

-- ---------------------------------------------------------------------------
-- Diff
-- ---------------------------------------------------------------------------

function M.diff(path, staged)
	local repo = require_repo()
	if repo then return repo end
	local args = { "diff", "--no-color" }
	if staged then args[#args + 1] = "--cached" end
	if path and path ~= "" then
		args[#args + 1] = "--"
		args[#args + 1] = path
	end
	local okk, out = M.exec(args)
	if not okk then
		return fail("unknown", "git diff failed (exit " .. tostring(err and err.exit) .. ").")
	end
	return ok(out)
end

-- ---------------------------------------------------------------------------
-- Mutating operations
-- ---------------------------------------------------------------------------

function M.add(paths)
	local repo = require_repo()
	if repo then return repo end
	if type(paths) == "string" then paths = { paths } end
	if #paths == 0 then return fail("nothing_to_stage", "Nothing selected to stage.") end
	local args = { "add", "--" }
	for i = 1, #paths do args[#args + 1] = paths[i] end
	local okk, _, err = M.exec(args, { reload = true })
	if not okk then
		return fail("unknown", "git add failed (exit " .. tostring(err and err.exit) .. ").",
			"See editor console for details.")
	end
	return ok(nil)
end

function M.add_all()
	local repo = require_repo()
	if repo then return repo end
	local okk, _, err = M.exec({ "add", "-A" }, { reload = true })
	if not okk then
		return fail("unknown", "git add -A failed (exit " .. tostring(err and err.exit) .. ").")
	end
	return ok(nil)
end

-- Unstage a path (or "." for everything). Handles the unborn-branch case
-- where `restore --staged` cannot resolve HEAD.
function M.unstage(path)
	local repo = require_repo()
	if repo then return repo end
	path = path or "."
	local st = M.status()
	if not st.ok then return st end
	local args
	if st.data.head_state == "initial" then
		args = { "rm", "--cached", "-q", "--", path }
	else
		args = { "restore", "--staged", "--", path }
	end
	local okk, _, err = M.exec(args, { reload = true })
	if not okk then
		return fail("unknown", "git unstage failed (exit " .. tostring(err and err.exit) .. ").",
			"See editor console for details.")
	end
	return ok(nil)
end

-- Discard worktree changes for one path. Untracked files are removed via
-- clean; tracked ones restored from the index. Renames: pass the NEW path.
function M.discard(path, is_untracked)
	local repo = require_repo()
	if repo then return repo end
	if not path or path == "" then return fail("unknown", "No file selected.") end
	local args
	if is_untracked then
		args = { "clean", "-f", "--", path }
	else
		args = { "checkout", "--", path }
	end
	local okk, _, err = M.exec(args, { reload = true })
	if not okk then
		return fail("unknown", "Discarding failed (exit " .. tostring(err and err.exit) .. ").")
	end
	return ok(nil)
end

function M.commit(message, amend)
	local repo = require_repo()
	if repo then return repo end
	if not message or trim(message) == "" then
		return fail("unknown", "Commit message is empty.")
	end
	local st = M.status()
	if not st.ok then return st end
	local data = st.data
	if #data.conflicts > 0 then
		return fail("conflict",
			string.format("%d unmerged file(s) - resolve conflicts before committing.", #data.conflicts),
			"Conflicted files are listed in the panel's Status tab.")
	end
	local staged_count = 0
	for i = 1, #data.files do
		if data.files[i].staged then staged_count = staged_count + 1 end
	end
	if not amend and staged_count == 0 then
		return fail("nothing_to_commit", "Nothing is staged to commit.",
			"Stage files in the panel first (or use Stage all).")
	end
	local args = { "commit", "-m", message }
	if amend then args[#args + 1] = "--amend" end
	local okk, out, err = M.exec(args, { reload = true })
	if not okk then
		-- Identify missing identity: probe config.
		local cfg = M.user_config()
		if cfg.ok and (cfg.data.name == "" or cfg.data.email == "") then
			return fail("no_identity",
				"git user.name / user.email are not configured.",
				"Run in a terminal:\n  git config --global user.name \"Your Name\"\n  git config --global user.email \"you@example.com\"")
		end
		return fail("unknown", "git commit failed (exit " .. tostring(err and err.exit) .. ").",
			"See editor console for details.")
	end
	return ok(out)
end

local function remote_exists(remote)
	local okk = M.exec({ "config", "--get", "remote." .. tostring(remote) .. ".url" })
	return okk
end

function M.push(remote, branch, set_upstream)
	local repo = require_repo()
	if repo then return repo end
	remote = remote or "origin"
	if not remote_exists(remote) then
		return fail("no_remote",
			"Remote '" .. tostring(remote) .. "' is not configured.",
			"Add one in a terminal: git remote add origin <url>")
	end
	local args
	if branch and branch ~= "" then
		if set_upstream then
			args = { "push", "-u", remote, branch }
		else
			args = { "push", remote, branch }
		end
	else
		args = { "push", remote }
	end
	local okk, out, err = M.exec(args, { reload = false })
	if not okk then
		-- Distinguish "rejected (non-fast-forward)" from network/auth issues:
		-- fetch is cheap and needs no auth for most hosts.
		local f = M.exec({ "fetch", "--quiet", remote })
		if f[1] then
			return fail("network",
				"Push rejected (exit " .. tostring(err and err.exit) .. ").",
				"The remote is reachable but refused the push. Someone pushed meanwhile? Fetch/Pull first, or you lack write access.")
		end
		return fail("network",
			"Push failed (exit " .. tostring(err and err.exit) .. ").",
			"Check network and credentials (SSH keys / token). Run git in a terminal for the full error.")
	end
	-- push progress goes to stderr; stdout may be empty. Report branch if known.
	return ok(branch and branch ~= "" and ("Pushed " .. branch .. " to " .. remote) or ("Pushed to " .. remote))
end

function M.pull(remote, branch, ff_only)
	local repo = require_repo()
	if repo then return repo end
	remote = remote or "origin"
	if not remote_exists(remote) then
		return fail("no_remote",
			"Remote '" .. tostring(remote) .. "' is not configured.",
			"Add one in a terminal: git remote add origin <url>")
	end
	local args = { "pull" }
	if ff_only then args[#args + 1] = "--ff-only" end
	args[#args + 1] = remote
	if branch and branch ~= "" then args[#args + 1] = branch end
	local okk, out, err = M.exec(args, { reload = true })
	if not okk then
		local exit = err and err.exit or -1
		-- Conflicts? Check status.
		local st = M.status()
		if st.ok and #st.data.conflicts > 0 then
			return fail("conflict",
				string.format("Pull stopped: %d conflicted file(s).", #st.data.conflicts),
				"Resolve in an external client (or Defold's Changed Files pane), then commit from the panel.")
		end
		if ff_only then
			return fail("network",
				"Pull failed (exit " .. tostring(exit) .. ").",
				"Possible non-fast-forward. Untick ff-only to allow a merge, or pull in a terminal.")
		end
		return fail("network", "Pull failed (exit " .. tostring(exit) .. ").",
			"Check network and credentials. Run git in a terminal for the full error.")
	end
	return ok(out ~= "" and out or "Already up to date.")
end

function M.fetch(remote)
	local repo = require_repo()
	if repo then return repo end
	local args
	if remote == "--all" or remote == nil then
		args = { "fetch", "--all", "--quiet" }
	else
		if not remote_exists(remote) then
			return fail("no_remote", "Remote '" .. tostring(remote) .. "' is not configured.",
				"Add one in a terminal: git remote add origin <url>")
		end
		args = { "fetch", "--quiet", remote }
	end
	local okk, _, err = M.exec(args, { reload = false })
	if not okk then
		return fail("network", "Fetch failed (exit " .. tostring(err and err.exit) .. ").",
			"Check network and credentials.")
	end
	return ok(nil)
end

-- ---------------------------------------------------------------------------
-- Branches
-- ---------------------------------------------------------------------------

local BRANCH_NAME_PATTERN = "^[%w%-%_%./%+]+$"

local function valid_branch_name(name)
	return type(name) == "string" and name:match("%S") ~= nil and name:match(BRANCH_NAME_PATTERN) ~= nil
end

function M.checkout(branch)
	local repo = require_repo()
	if repo then return repo end
	if not valid_branch_name(branch) then return fail("invalid_branch", "Invalid branch name.") end
	local okk, _, err = M.exec({ "checkout", branch }, { reload = true })
	if not okk then
		return fail("unknown",
			"Switching to '" .. tostring(branch) .. "' failed (exit " .. tostring(err and err.exit) .. ").",
			"Commit or discard local changes first (they may conflict).")
	end
	return ok(branch)
end

function M.create_branch(name)
	local repo = require_repo()
	if repo then return repo end
	if not valid_branch_name(name) then
		return fail("invalid_branch",
			"Invalid branch name '" .. tostring(name) .. "'.",
			"Use letters, digits, '-', '_', '/', '.'.")
	end
	local st = M.status()
	if st.ok and #st.data.conflicts > 0 then
		return fail("conflict", "Resolve merge conflicts before creating a branch.")
	end
	local okk, _, err = M.exec({ "checkout", "-b", name }, { reload = true })
	if not okk then
		return fail("unknown",
			"Creating branch '" .. tostring(name) .. "' failed (exit " .. tostring(err and err.exit) .. ").",
			"A branch with that name may already exist.")
	end
	return ok(name)
end

-- Delete a local branch. Refuses the current branch and, unless force, an
-- unmerged branch (probed with merge-base before any destructive call).
function M.delete_branch(name, current_branch, force)
	local repo = require_repo()
	if repo then return repo end
	if not valid_branch_name(name) then return fail("invalid_branch", "Invalid branch name.") end
	if current_branch ~= nil and name == current_branch then
		return fail("invalid_branch",
			"Cannot delete the checked-out branch '" .. tostring(name) .. "'.",
			"Switch to another branch first.")
	end
	if not force then
		local merged_ok, _, merged_err = M.exec({ "merge-base", "--is-ancestor", name, "HEAD" })
		if not merged_ok then
			local exit = merged_err and merged_err.exit or -1
			if exit == 1 then
				return fail("unmerged_branch",
					"Branch '" .. tostring(name) .. "' has commits not in the current branch.",
					"Tick 'force delete' in the panel to delete anyway.")
			end
			return fail("unknown", "Branch '" .. tostring(name) .. "' does not exist (probe exit " .. tostring(exit) .. ").")
		end
	end
	local okk, _, err = M.exec({ "branch", "-D", name }, { reload = true })
	if not okk then
		return fail("unknown", "Deleting branch failed (exit " .. tostring(err and err.exit) .. ").")
	end
	return ok(name)
end

return M
