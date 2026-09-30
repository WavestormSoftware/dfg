-- Unit tests for wavestorm_git.git_core pure parsers.
-- Run: lua wavestorm_git/tests/test_git_core.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local function load_core()
	local chunk = assert(loadfile("wavestorm_git/git_core.lua"))
	return chunk()
end

local core = load_core()
local failures = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (extra and (": " .. tostring(extra)) or ""))
	end
end

-- 1. Status with branch tracking + mixed files
local s1 = core.parse_status("## main...origin/main [ahead 1, behind 2]\n"
	.. "M  game.project\n"
	.. " M example/example.script\n"
	.. "A  wavestorm_git/git_core.lua\n"
	.. "R  old.go -> new.go\n"
	.. "?? untracked.txt\n"
	.. "UU conflict.collection\n")
check("branch", s1.branch == "main", s1.branch)
check("upstream", s1.upstream == "origin/main", s1.upstream)
check("ahead", s1.ahead == 1, tostring(s1.ahead))
check("behind", s1.behind == 2, tostring(s1.behind))
check("file count", #s1.files == 6, tostring(#s1.files))
check("staged M", s1.files[1].staged and not s1.files[1].unstaged, s1.files[1].xy)
check("unstaged M", not s1.files[2].staged and s1.files[2].unstaged, s1.files[2].xy)
check("rename orig", s1.files[4].orig == "old.go" and s1.files[4].path == "new.go",
	(s1.files[4].orig or "?") .. "->" .. (s1.files[4].path or "?"))
check("untracked", s1.files[5].status == "untracked", s1.files[5].status)
check("conflict", #s1.conflicts == 1 and s1.files[6].conflict, tostring(#s1.conflicts))

-- 2. Initial commit header
local s2 = core.parse_status("## No commits yet on main\nA  game.project\n")
check("initial branch", s2.branch == "main", s2.branch)
check("initial files", #s2.files == 1, tostring(#s2.files))

-- 3. Empty status
local s3 = core.parse_status("## main...origin/main\n")
check("clean files", #s3.files == 0, tostring(#s3.files))
check("summary mentions clean", core.summary(s3):find("0 changed") ~= nil, core.summary(s3))

-- 4. Branches
local b = core.parse_branches("* main abc123 msg\n  feature/x def456 msg2\n  fix-y 123\n")
check("current branch", b.current == "main", b.current)
check("local count", #b.local_branches >= 2, table.concat(b.local_branches, ","))

-- 5. Remotes
local r = core.parse_remotes("origin\thttps://github.com/a/b.git (fetch)\norigin\thttps://github.com/a/b.git (push)\nupstream\tgit@github.com:c/d.git (fetch)\n")
check("origin url", r["origin"] == "https://github.com/a/b.git", tostring(r["origin"]))
check("upstream url", r["upstream"] == "git@github.com:c/d.git", tostring(r["upstream"]))

-- 6. Log
local US, RS = string.char(31), string.char(30)
local log_out = table.concat({
	"abc123" .. US .. "abc" .. US .. "Jane" .. US .. "2026-01-01" .. US .. "First commit",
	"def456" .. US .. "def" .. US .. "Bob" .. US .. "2026-01-02" .. US .. "Second commit",
}, RS) .. RS
local commits = core.parse_log(log_out)
check("log count", #commits == 2, tostring(#commits))
check("log subject", commits[1].subject == "First commit", commits[1].subject)
check("log author", commits[2].author == "Bob", commits[2].author)

-- 7. Format + summary helpers
check("format entry", core.format_file_entry({ xy = "M ", path = "a", status = "modified" }):find("a") ~= nil, "")
check("shell escape safe", core.shell_escape("main.lua") == "main.lua", core.shell_escape("main.lua"))
check("shell escape spaces", core.shell_escape("my file.txt"):sub(1, 1) == "'", core.shell_escape("my file.txt"))

-- 8. Live git smoke test in a temp repo (uses io.popen fallback)
local function live_test()
	local tmp = os.tmpname()
	os.remove(tmp)
	local ok_mkdir = os.execute('mkdir -p "' .. tmp .. '/repo"')
	if ok_mkdir ~= true and ok_mkdir ~= 0 then
		print("SKIP live git test (cannot mkdir)")
		return
	end
	local dir = tmp .. "/repo"
	local function sh(cmd)
		local h = io.popen('cd "' .. dir .. '" && ' .. cmd .. ' 2>&1; printf "__EXIT__:%d" $?')
		local out = h:read("*a") or ""
		h:close()
		local code = out:match("__EXIT__:(%d+)%s*$")
		out = out:gsub("__EXIT__:%d+%s*$", "")
		return code == "0", out
	end
	local ok, _ = sh("git init -b main")
	if not ok then print("SKIP live git test (git init failed)"); return end
	sh('git config user.email "t@t.t"')
	sh('git config user.name "T"')
	local f = io.open(dir .. "/a.txt", "w"); f:write("hello\n"); f:close()
	sh("git add -A")
	sh('git commit -m "init"')
	local f2 = io.open(dir .. "/a.txt", "w"); f2:write("hello2\n"); f2:close()
	local ok_s, out_s = sh("git status --porcelain=v1 -b")
	check("live status sees modification", out_s:find("a.txt") ~= nil, out_s)
	local parsed = core.parse_status(out_s)
	check("live parse 1 file", #parsed.files == 1, tostring(#parsed.files))
	os.execute('rm -rf "' .. tmp .. '"')
end
live_test()

if failures > 0 then
	print(failures .. " FAILURE(S)")
	os.exit(1)
else
	print("ALL TESTS PASSED")
end
