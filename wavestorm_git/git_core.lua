-- Wavestorm Git: core git wrapper for Defold editor scripts.
-- Works inside the Defold editor (via editor.execute) and outside it
-- (via io.popen) so the pure parsing logic can be unit tested with plain lua.
local M = {}

-- ---------------------------------------------------------------------------
-- Execution backend
-- ---------------------------------------------------------------------------

local function trim(s)
	if type(s) ~= "string" then return s end
	return (s:match("^%s*(.-)%s*$"))
end

M.trim = trim

-- Shell-escape a single argument for the io.popen fallback.
local function shell_escape(arg)
	arg = tostring(arg)
	if arg == "" then return "''" end
	if arg:match("^[A-Za-z0-9_@%%+=:,./%-]+$") then
		return arg
	end
	return "'" .. arg:gsub("'", "'\\''") .. "'"
end

M.shell_escape = shell_escape

-- Low-level runner. Returns ok, output_or_error.
-- args: array of strings, e.g. {"status", "--porcelain=v1", "-b"}
-- opts: { reload = false } -> passes reload_resources=false in editor.
function M.exec(args, opts)
	opts = opts or {}
	local reload_resources = false
	if opts.reload == true then
		reload_resources = true
	end
	-- Inside Defold editor.
	if type(editor) == "table" and type(editor.execute) == "function" then
		local exec_args = { "git" }
		for i = 1, #args do
			exec_args[#exec_args + 1] = tostring(args[i])
		end
		exec_args[#exec_args + 1] = { reload_resources = reload_resources, out = "capture", err = "stdout" }
		local unpack_fn = table.unpack or unpack
		local ok, res = pcall(editor.execute, unpack_fn(exec_args))
		if ok then
			return true, res or ""
		else
			return false, tostring(res)
		end
	else
		-- Standalone fallback (tests / CLI): io.popen.
		local parts = { "git" }
		for i = 1, #args do
			parts[#parts + 1] = shell_escape(args[i])
		end
		parts[#parts + 1] = "2>&1"
		local cmd = table.concat(parts, " ")
		local handle = io.popen(cmd)
		if not handle then
			return false, "io.popen failed for: " .. cmd
		end
		local out = handle:read("*a") or ""
		-- handle:close() differs per Lua version:
		-- 5.2+: true on success, nil + exit code on failure.
		-- 5.1: numeric exit status.
		local ok_close, _, code = handle:close()
		if ok_close == true or code == 0 then
			return true, trim(out)
		end
		if type(ok_close) == "number" then
			if ok_close == 0 then
				return true, trim(out)
			end
			return false, trim(out)
		end
		return false, trim(out)
	end
end

-- ---------------------------------------------------------------------------
-- Pure parsers (fully testable without git)
-- ---------------------------------------------------------------------------

local STATUS_LABELS = {
	M = "modified",
	A = "added",
	D = "deleted",
	R = "renamed",
	C = "copied",
	U = "conflict",
	T = "typechange",
}

-- Parse `git status --porcelain=v1 -b` output.
-- Returns table: { branch, upstream, ahead, behind, files={}, conflicts={} }
function M.parse_status(output)
	local res = {
		branch = "",
		upstream = "",
		ahead = 0,
		behind = 0,
		files = {},
		conflicts = {},
	}
	if output == nil or output == "" then
		return res
	end
	for line in (tostring(output) .. "\n"):gmatch("([^\n]*)\n") do
		if line:sub(1, 2) == "##" then
			-- e.g. "## main...origin/main [ahead 1, behind 2]"
			local header = trim(line:sub(3))
			local branch_part = header:match("^([^%.%s]+)") or header
			res.branch = branch_part:match("^([^%.]+)") or ""
			-- No branch (detached / initial)
			if header:match("No commits yet on") then
				res.branch = header:match("No commits yet on%s+(%S+)") or res.branch
			end
			local up = header:match("%.%.%.(%S+)")
			if up then
				up = up:gsub("%s*%[.*$", "")
				res.upstream = up
			end
			local ahead = header:match("ahead (%d+)")
			local behind = header:match("behind (%d+)")
			res.ahead = tonumber(ahead) or 0
			res.behind = tonumber(behind) or 0
		else
			local x = line:sub(1, 1)
			local y = line:sub(2, 2)
			if x ~= "" and line:len() >= 4 then
				local rest = line:sub(4)
				local path, orig = rest, nil
				-- Renames: "R  old -> new"
				local o, n = rest:match("^(.-)%s+->%s+(.-)%s*$")
				if o and n and (x == "R" or y == "R" or x == "C" or y == "C") then
					orig, path = trim(o), trim(n)
				else
					path = trim(rest)
					-- Strip quotes git adds around paths with spaces.
					if path:sub(1, 1) == '"' then
						path = path:gsub('^"(.*)"$', "%1")
					end
				end
				-- Untracked
				if x == "?" and y == "?" then
					res.files[#res.files + 1] = {
						xy = "??", path = path, status = "untracked",
						staged = false, unstaged = true, conflict = false,
					}
				elseif x == "!" and y == "!" then
					-- ignored, skip
				else
					local conflict = (x == "U" or y == "U" or (x == "A" and y == "A") or (x == "D" and y == "D"))
					local staged = (x ~= " " and x ~= "?" and x ~= "!")
					local unstaged = (y ~= " " and y ~= "?" and y ~= "!")
					local key = (staged and x or y)
					if key == " " then key = x ~= " " and x or y end
					local entry = {
						xy = x .. y, path = path, orig = orig,
						status = STATUS_LABELS[key] or "modified",
						staged = staged, unstaged = unstaged,
						conflict = conflict,
					}
					res.files[#res.files + 1] = entry
					if conflict then
						res.conflicts[#res.conflicts + 1] = entry
					end
				end
			end
		end
	end
	return res
end

-- Parse `git branch --format` style or plain `git branch` / `git branch -r`.
-- Expects lines; current branch marked with "* ".
function M.parse_branches(output)
	local branches = { current = "", local_branches = {}, remote_branches = {}, all = {} }
	if output == nil or output == "" then return branches end
	for line in (tostring(output) .. "\n"):gmatch("([^\n]*)\n") do
		local t = trim(line)
		if t ~= "" then
			local is_current = false
			if t:sub(1, 1) == "*" then
				is_current = true
				t = trim(t:sub(2))
			end
			-- strip tracking info "main abc123 [origin/main] msg"
			local name = t:match("^(%S+)") or t
			if is_current then branches.current = name end
			if name:sub(1, 8) == "remotes/" then
				name = name:sub(9)
				branches.remote_branches[#branches.remote_branches + 1] = name
			elseif not is_current and name:match("^origin/") then
				branches.remote_branches[#branches.remote_branches + 1] = name
			else
				-- Current branch and plain names (incl. feature/x) are local.
				branches.local_branches[#branches.local_branches + 1] = name
			end
			branches.all[#branches.all + 1] = { name = name, current = is_current }
		end
	end
	return branches
end

-- Parse `git remote -v` into { name = url } (fetch urls only).
function M.parse_remotes(output)
	local remotes = {}
	if output == nil or output == "" then return remotes end
	for line in (tostring(output) .. "\n"):gmatch("([^\n]*)\n") do
		local name, url, kind = line:match("^(%S+)%s+(%S+)%s+%((%a+)%)")
		if name and url and kind == "fetch" then
			remotes[name] = url
		end
	end
	return remotes
end

-- Parse custom log format: %H%x1f%h%x1f%an%x1f%ad%x1f%s%x1e
function M.parse_log(output)
	local commits = {}
	if output == nil or output == "" then return commits end
	for record in (tostring(output) .. "\30"):gmatch("(.-)\30") do
		if trim(record) ~= "" then
			local sha, short, author, date, subject = record:match("^(.-)\31(.-)\31(.-)\31(.-)\31(.*)$")
			if sha then
				commits[#commits + 1] = {
					sha = trim(sha), short = trim(short),
					author = trim(author), date = trim(date),
					subject = trim(subject),
				}
			end
		end
	end
	return commits
end

function M.format_file_entry(f)
	local tag = "[" .. f.xy .. "]"
	if f.conflict then tag = "[!! conflict]" end
	if f.orig then
		return string.format("%s %s -> %s (%s)", tag, f.orig, f.path, f.status)
	end
	return string.format("%s %s (%s)", tag, f.path, f.status)
end

function M.summary(status)
	local n = #status.files
	local parts = {}
	if status.branch ~= "" then
		parts[#parts + 1] = "branch: " .. status.branch
	else
		parts[#parts + 1] = "branch: (unknown)"
	end
	if status.upstream ~= "" then
		parts[#parts + 1] = "upstream: " .. status.upstream
	end
	if status.ahead > 0 or status.behind > 0 then
		parts[#parts + 1] = string.format("ahead %d / behind %d", status.ahead, status.behind)
	end
	parts[#parts + 1] = string.format("%d changed file(s)", n)
	if #status.conflicts > 0 then
		parts[#parts + 1] = string.format("%d conflict(s) - resolve externally", #status.conflicts)
	end
	return table.concat(parts, "  |  ")
end

-- ---------------------------------------------------------------------------
-- High-level git operations (need a repo; return ok, data_or_err)
-- ---------------------------------------------------------------------------

function M.is_repo()
	local ok, out = M.exec({ "rev-parse", "--is-inside-work-tree" })
	if not ok then return false, out end
	return trim(out) == "true", trim(out)
end

function M.current_branch()
	local ok, out = M.exec({ "rev-parse", "--abbrev-ref", "HEAD" })
	if not ok then return nil, out end
	out = trim(out)
	if out == "" or out == "HEAD" then return nil, "detached HEAD" end
	return out, nil
end

function M.status()
	local ok, out = M.exec({ "status", "--porcelain=v1", "-b" })
	if not ok then return nil, out end
	return M.parse_status(out), nil
end

function M.branches()
	local ok, out = M.exec({ "branch", "--no-color", "--list" })
	if not ok then return nil, out end
	local local_b = M.parse_branches(out)
	local ok2, out2 = M.exec({ "branch", "--no-color", "-r" })
	if ok2 then
		for line in (tostring(out2) .. "\n"):gmatch("([^\n]*)\n") do
			local t = trim(line)
			if t ~= "" and not t:match("HEAD %->") then
				local_b.remote_branches[#local_b.remote_branches + 1] = t
				local_b.all[#local_b.all + 1] = { name = t, current = false }
			end
		end
	end
	return local_b, nil
end

function M.remotes()
	local ok, out = M.exec({ "remote", "-v" })
	if not ok then return nil, out end
	return M.parse_remotes(out), nil
end

function M.log(count, path)
	count = tonumber(count) or 25
	local args = { "log", "--pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1e", "--date=short", "-n", tostring(count) }
	if path and path ~= "" then
		args[#args + 1] = "--"
		args[#args + 1] = path
	end
	local ok, out = M.exec(args)
	if not ok then return nil, out end
	return M.parse_log(out), nil
end

function M.diff(path, staged)
	local args = { "diff", "--no-color" }
	if staged then args[#args + 1] = "--cached" end
	if path and path ~= "" then
		args[#args + 1] = "--"
		args[#args + 1] = path
	end
	return M.exec(args)
end

function M.add(paths)
	if type(paths) == "string" then paths = { paths } end
	if #paths == 0 then return false, "nothing to stage" end
	local args = { "add", "--" }
	for i = 1, #paths do args[#args + 1] = paths[i] end
	local ok, out = M.exec(args, { reload = true })
	return ok, out or ""
end

function M.add_all()
	return M.exec({ "add", "-A" }, { reload = true })
end

function M.commit(message, amend)
	if not message or trim(message) == "" then
		return false, "commit message is empty"
	end
	local args = { "commit", "-m", message }
	if amend then args[#args + 1] = "--amend" end
	return M.exec(args, { reload = true })
end

function M.push(remote, branch, set_upstream)
	remote = remote or "origin"
	local args
	if branch and branch ~= "" then
		args = { "push", remote, branch }
		if set_upstream then
			args = { "push", "-u", remote, branch }
		end
	else
		args = { "push", remote }
	end
	return M.exec(args, { reload = true })
end

function M.pull(remote, branch)
	remote = remote or "origin"
	local args
	if branch and branch ~= "" then
		args = { "pull", remote, branch }
	else
		args = { "pull", remote }
	end
	return M.exec(args, { reload = true })
end

function M.fetch(remote)
	remote = remote or "origin"
	if remote == "--all" then
		return M.exec({ "fetch", "--all" }, { reload = false })
	end
	return M.exec({ "fetch", remote }, { reload = false })
end

function M.checkout(branch, create)
	if not branch or trim(branch) == "" then return false, "no branch given" end
	if create then
		return M.exec({ "checkout", "-b", branch }, { reload = true })
	end
	return M.exec({ "checkout", branch }, { reload = true })
end

function M.revert_path(path)
	if not path or path == "" then return false, "no path given" end
	-- Restore tracked modifications; delete untracked files via clean.
	local ok, out = M.exec({ "status", "--porcelain=v1", "--", path })
	if not ok then return false, out end
	if out:match("^%?%?") then
		return M.exec({ "clean", "-f", "--", path }, { reload = true })
	end
	return M.exec({ "checkout", "--", path }, { reload = true })
end

function M.blame(path)
	if not path or path == "" then return false, "no path given" end
	return M.exec({ "blame", "--", path })
end

function M.user_config()
	local ok1, name = M.exec({ "config", "user.name" })
	local ok2, email = M.exec({ "config", "user.email" })
	return {
		name = ok1 and trim(name) or "",
		email = ok2 and trim(email) or "",
	}
end

return M
