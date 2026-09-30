-- Wavestorm Git v2 tests.
-- Run with any of: lua, lua5.1, lua5.4, luajit
--   wavestorm_git/tests/test_git.lua
--
-- Two sections:
--   1. Pure parser tests against fixtures captured from real git 2.55 output.
--   2. Live operation tests against throwaway temp repos (io.popen fallback).
package.path = "wavestorm_git/lib/?.lua;" .. package.path

local git = require("git")

local failures = 0
local passed = 0

local function check(name, cond, extra)
	if cond then
		passed = passed + 1
		print("PASS " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (extra and (": " .. tostring(extra)) or ""))
	end
end

local function sh(cmd, dir)
	local full = "cd '" .. dir .. "' && " .. cmd .. " 2>&1"
	local h = io.popen(full)
	local out = h:read("*a") or ""
	h:close()
	return out
end

local NUL = "\0"
local function records(...)
	local t = {}
	for i = 1, select("#", ...) do
		t[#t + 1] = (select(i, ...))
	end
	return table.concat(t, NUL)
end

-- ===========================================================================
-- 1. Parser fixtures (captured from real git 2.55 output)
-- ===========================================================================

-- Mixed tree: unstaged delete (b.txt removed from worktree), staged add
-- (c.txt), staged rename + worktree modification (renamed.txt <- a.txt, "RM").
local MIXED = records(
	"# branch.oid 8a434100e3322df375ff8303f43c341f460d694c",
	"# branch.head main",
	"1 .D N... 100644 100644 0000000 587be6b 587be6b b.txt",
	"1 A. N... 000000 100644 0000000 0000000 3e75765 c.txt",
	"2 RM N... 100644 100644 100644 83db48f 83db48f R100 renamed.txt",
	"a.txt")

local s = git.parse_status(MIXED)
check("mixed branch", s.branch == "main", tostring(s.branch))
check("mixed head_state", s.head_state == "normal", tostring(s.head_state))
check("mixed no upstream", s.upstream == nil, tostring(s.upstream))
check("mixed file count", #s.files == 3, tostring(#s.files))
local by_path = {}
for i = 1, #s.files do by_path[s.files[i].path] = s.files[i] end
check("unstaged delete xy", by_path["b.txt"] ~= nil and by_path["b.txt"].xy == ".D",
	by_path["b.txt"] and by_path["b.txt"].xy)
check("unstaged delete flags",
	by_path["b.txt"] and (not by_path["b.txt"].staged) and by_path["b.txt"].unstaged, "")
check("delete label", by_path["b.txt"] and by_path["b.txt"].status == "deleted",
	by_path["b.txt"] and by_path["b.txt"].status)
check("staged add xy", by_path["c.txt"] and by_path["c.txt"].xy == "A.", "")
check("staged add flags",
	by_path["c.txt"] and by_path["c.txt"].staged and (not by_path["c.txt"].unstaged), "")
check("add label", by_path["c.txt"] and by_path["c.txt"].status == "added", "")
check("rename orig", by_path["renamed.txt"] and by_path["renamed.txt"].orig == "a.txt",
	tostring(by_path["renamed.txt"] and by_path["renamed.txt"].orig))
check("rename flags", by_path["renamed.txt"]
	and by_path["renamed.txt"].staged and by_path["renamed.txt"].unstaged, "")
check("rename label", by_path["renamed.txt"] and by_path["renamed.txt"].status == "renamed", "")
check("mixed no conflicts", #s.conflicts == 0, tostring(#s.conflicts))

-- Upstream + ahead/behind.
local s2 = git.parse_status(records(
	"# branch.oid 4d0faa21358d48248c50c67d6187ac5bac277aeb",
	"# branch.head main",
	"# branch.upstream origin/main",
	"# branch.ab +1 -0"))
check("ab upstream", s2.upstream == "origin/main", tostring(s2.upstream))
check("ab ahead", s2.ahead == 1 and s2.behind == 0, tostring(s2.ahead) .. "/" .. tostring(s2.behind))
check("ab no files", #s2.files == 0, tostring(#s2.files))

local s3 = git.parse_status(records(
	"# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -5"))
check("ab behind", s3.ahead == 2 and s3.behind == 5, tostring(s3.ahead) .. "/" .. tostring(s3.behind))

-- Unborn repo: branch.oid (initial); branch.head still carries the NAME.
local s4 = git.parse_status(records(
	"# branch.oid (initial)",
	"# branch.head main",
	"1 A. N... 000000 100644 0000000 0000000 587be6b a.txt"))
check("initial head_state", s4.head_state == "initial", tostring(s4.head_state))
check("initial branch name kept", s4.branch == "main", tostring(s4.branch))
check("initial staged file", #s4.files == 1 and s4.files[1].staged, tostring(#s4.files))
check("initial no upstream", s4.upstream == nil, "")

-- Detached HEAD.
local s5 = git.parse_status(records(
	"# branch.oid 55f6bb65c467c3431fdfa022b5a9137a4903b252",
	"# branch.head (detached)"))
check("detached state", s5.head_state == "detached" and s5.branch == nil, tostring(s5.branch))

-- Unmerged (conflict) record.
local s6 = git.parse_status(records(
	"# branch.oid 0dacd6d7",
	"# branch.head main",
	"u UU N... 100644 100644 100644 100644 de980441 097825b8 097825b8 f.txt"))
check("conflict detected", #s6.conflicts == 1 and s6.files[1].conflict, tostring(#s6.conflicts))
check("conflict xy", s6.files[1].xy == "UU", tostring(s6.files[1].xy))
check("conflict path", s6.files[1].path == "f.txt", tostring(s6.files[1].path))

-- Untracked + ignored + unstaged modify. Spaces in paths must survive.
-- NOTE porcelain v2 uses '.' for unmodified (never spaces), e.g. ".M".
local s7 = git.parse_status(records(
	"? new file.txt",
	"! ignored.bin",
	"1 .M N... 100644 100644 100644 aa bb aa m.lua"))
check("untracked entry", #s7.files == 2 and s7.files[1].untracked, tostring(#s7.files))
check("untracked label", s7.files[1].status == "untracked", tostring(s7.files[1].status))
check("spaces in path kept", s7.files[1].path == "new file.txt", tostring(s7.files[1].path))
check("ignored skipped", #s7.files == 2, tostring(#s7.files))
check("unstaged modify", s7.files[2].xy == ".M" and s7.files[2].unstaged, tostring(s7.files[2].xy))

-- Clean tree.
local s8 = git.parse_status(records(
	"# branch.head main", "# branch.upstream origin/main", "# branch.ab +0 -0"))
check("clean count", #s8.files == 0, tostring(#s8.files))
check("summary clean", git.summary(s8):find("0 changed") ~= nil, git.summary(s8))

-- Empty / nil output.
local s9 = git.parse_status(nil)
check("nil status safe", s9.branch == nil and #s9.files == 0, "")

-- parse_remotes.
local r = git.parse_remotes(
	"origin\thttps://github.com/a/b.git (fetch)\n" ..
	"origin\thttps://github.com/a/b.git (push)\n" ..
	"upstream\tgit@github.com:c/d.git (fetch)\n")
check("remotes origin", r["origin"] == "https://github.com/a/b.git", tostring(r["origin"]))
check("remotes upstream", r["upstream"] == "git@github.com:c/d.git", tostring(r["upstream"]))
check("remotes empty", next(git.parse_remotes("")) == nil, "")

-- parse_log: NUL-separated 5-tuples.
local log_out = table.concat({
	"abc123", "abc", "Jane", "2026-01-01", "First commit",
	"def456", "def", "Bob", "2026-01-02", "Second: with; punctuation",
}, NUL) .. NUL
local commits = git.parse_log(log_out)
check("log count", #commits == 2, tostring(#commits))
check("log fields", commits[1].subject == "First commit" and commits[1].author == "Jane"
	and commits[1].short == "abc" and commits[1].sha == "abc123" and commits[1].date == "2026-01-01", "")
check("log subject punctuation", commits[2].subject == "Second: with; punctuation", commits[2].subject)
check("log empty", #git.parse_log("") == 0, "")
check("log partial record ignored", #git.parse_log("a\0b\0c") == 0, "")

-- Display helpers.
check("format conflict", git.format_file_entry({ xy = "UU", path = "f", conflict = true })
	== "[conflict] f", git.format_file_entry({ xy = "UU", path = "f", conflict = true }))
check("format rename", git.format_file_entry({ xy = "RM", path = "n", orig = "o", status = "renamed" }):find("o -> n", 1, true) ~= nil, "")
check("shquote safe", git.shquote("main.lua") == "main.lua", git.shquote("main.lua"))
check("shquote spaces", git.shquote("my file.txt"):sub(1, 1) == "'", git.shquote("my file.txt"))
check("shquote injection", git.shquote("a'; rm -rf /; echo '") ~= "a'; rm -rf /; echo '", git.shquote("a'; x"))

-- ===========================================================================
-- 2. Live operation tests (throwaway repos via io.popen fallback)
-- ===========================================================================

local tmp = os.tmpname()
os.remove(tmp)
local root = tmp .. "_wstest"
sh("mkdir -p '" .. root .. "'/repo", root ~= "" and "/tmp" or "/tmp")
local repo_dir = root .. "/repo"

local function gith(cmd)
	return sh(cmd, repo_dir)
end
local function clean_commit(cmd)
	return sh(cmd .. " && git add -A && git -c user.email=t@t -c user.name=T commit -q -m msg", repo_dir)
end

-- git 2.x needs identity; set per-repo.
gith("git init -q -b main && git config user.email t@t && git config user.name T")
git.set_dir(repo_dir)

-- not_a_repo when pointed at a non-repo dir.
git.set_dir(root)
local nr = git.is_repo()
check("not a repo detected", (not nr.ok) and nr.kind == "not_a_repo", tostring(nr.kind))
local nrs = git.status()
check("status in non-repo fails", (not nrs.ok) and nrs.kind == "not_a_repo", tostring(nrs.kind))
git.set_dir(repo_dir)

-- Unborn repo: status + commit works; log empty-but-ok; unstage via rm --cached.
local st0 = git.status()
check("unborn status", st0.ok and st0.data.head_state == "initial", st0.data and tostring(st0.data.head_state))
local f = io.open(repo_dir .. "/a.txt", "w"); f:write("hello\n"); f:close()
local ad0 = git.add("a.txt")
check("unborn add", ad0.ok, tostring(ad0.message))
local lg0 = git.log(10)
check("unborn log ok+empty", lg0.ok and #lg0.data == 0, tostring(lg0.message))
local us0 = git.unstage("a.txt")
check("unborn unstage", us0.ok, tostring(us0.message))
local st1 = git.status()
check("unborn unstage resets to untracked", st1.ok and #st1.data.files == 1 and st1.data.files[1].untracked, tostring(st1.message))
-- Commit.
local ad1 = git.add("a.txt")
local c1 = git.commit("initial commit", false)
check("commit ok", c1.ok, tostring(c1.message))
local st2 = git.status()
check("clean after commit", st2.ok and #st2.data.files == 0, tostring(#st2.data.files))
local br = git.current_branch()
check("branch main", br.ok and br.data.branch == "main", tostring(br.data and br.data.branch))

-- Amend + last_commit_message.
local c2 = git.commit("amended message", true)
check("amend ok", c2.ok, tostring(c2.message))
local lm = git.last_commit_message()
check("last message", lm.ok and git.trim(lm.data) == "amended message", tostring(lm.data))

-- Empty message refused.
local c3 = git.commit("   ", false)
check("empty message refused", (not c3.ok) and c3.kind == "unknown", tostring(c3.kind))

-- Stage/unstage cycle.
f = io.open(repo_dir .. "/a.txt", "w"); f:write("hello2\n"); f:close()
local st3 = git.status()
check("modification seen", st3.ok and #st3.data.files == 1 and st3.data.files[1].unstaged, "")
local ad2 = git.add("a.txt")
check("add ok", ad2.ok, "")
local st4 = git.status()
check("staged after add", st4.ok and st4.data.files[1].staged and not st4.data.files[1].unstaged, "")
local us1 = git.unstage("a.txt")
check("unstage ok", us1.ok, "")
local st5 = git.status()
check("unstaged after unstage", st5.ok and st5.data.files[1].unstaged, "")
git.add("a.txt")
local c4 = git.commit("second", false)
check("commit second", c4.ok, tostring(c4.message))

-- Discard tracked changes; untracked removal via clean.
f = io.open(repo_dir .. "/a.txt", "w"); f:write("changed\n"); f:close()
local d1 = git.discard("a.txt", false)
check("discard tracked", d1.ok, tostring(d1.message))
local rest = io.open(repo_dir .. "/a.txt", "r"):read("*a")
check("discard restored content", rest == "hello2\n", tostring(rest))
f = io.open(repo_dir .. "/temp_untracked.txt", "w"); f:write("x\n"); f:close()
local d2 = git.discard("temp_untracked.txt", true)
check("discard untracked", d2.ok, tostring(d2.message))
local fh = io.open(repo_dir .. "/temp_untracked.txt", "r")
check("untracked removed", fh == nil, "")
if fh then fh:close() end

-- Branches: create/switch/delete.
local cb = git.create_branch("feature/x")
check("create branch", cb.ok, tostring(cb.message))
local st6 = git.status()
check("on new branch", st6.ok and st6.data.branch == "feature/x", tostring(st6.data and st6.data.branch))
local sw = git.checkout("main")
check("switch back", sw.ok, tostring(sw.message))
local dl = git.delete_branch("feature/x", "main", false)
check("delete merged branch", dl.ok, tostring(dl.message))
local bl = git.branches()
check("branches list", bl.ok and bl.data.local_branches[1] == "main", tostring(bl.data and bl.data.local_branches[1]))

-- Delete current branch refused; delete unmerged refused (no destructive call).
local dc = git.delete_branch("main", "main", false)
check("delete current refused", (not dc.ok) and dc.kind == "invalid_branch", tostring(dc.kind))
local nb = git.create_branch("unmerged")
f = io.open(repo_dir .. "/a.txt", "w"); f:write("unmerged work\n"); f:close()
git.add("a.txt")
git.commit("unmerged commit", false)
git.checkout("main")
local du = git.delete_branch("unmerged", "main", false)
check("delete unmerged refused", (not du.ok) and du.kind == "unmerged_branch", tostring(du.kind))
local df = git.delete_branch("unmerged", "main", true)
check("delete unmerged forced", df.ok, tostring(df.message))
local dn = git.delete_branch("no-such-branch", "main", false)
check("delete missing branch reported", (not dn.ok) and dn.kind == "unknown", tostring(dn.kind))

-- Invalid branch names.
local iv = git.create_branch("bad name!")
check("invalid name refused", (not iv.ok) and iv.kind == "invalid_branch", tostring(iv.kind))

-- Remotes + push + pull against a local bare remote.
sh("git init -q --bare '" .. root .. "/origin.git'", root ~= "" and "/tmp" or "/tmp")
gith("git remote add origin '" .. root .. "/origin.git'")
local rem = git.remotes()
check("remote listed", rem.ok and rem.data["origin"] ~= nil, tostring(rem.data))
local p1 = git.push("origin", "main", true)
check("push -u ok", p1.ok, tostring(p1.message))
-- Point the bare repo's HEAD at main so clones start on main.
sh("git --git-dir '" .. root .. "/origin.git' symbolic-ref HEAD refs/heads/main", root ~= "" and "/tmp" or "/tmp")

-- no_remote classification.
local p2 = git.push("nonexistent", "main", false)
check("push no_remote", (not p2.ok) and p2.kind == "no_remote", tostring(p2.kind))
local pl2 = git.pull("nonexistent", "main", false)
check("pull no_remote", (not pl2.ok) and pl2.kind == "no_remote", tostring(pl2.kind))

-- Pull fast-forward from another clone.
sh("git clone -q '" .. root .. "/origin.git' '" .. root .. "/clone'", root ~= "" and "/tmp" or "/tmp")
f = io.open(root .. "/clone/pulled.txt", "w"); f:write("from clone\n"); f:close()
sh("git add -A && git -c user.email=t@t -c user.name=T commit -q -m clone-commit && git push -q origin main", root .. "/clone")
local pl1 = git.pull("origin", "main", true)
check("pull ff ok", pl1.ok, tostring(pl1.message))
local here = io.open(repo_dir .. "/pulled.txt", "r")
check("pulled file arrived", here ~= nil and here:read("*a") == "from clone\n", "")
if here then here:close() end

-- Repo and clone diverge on DIFFERENT files so the merge is clean.
f = io.open(repo_dir .. "/a.txt", "w"); f:write("divergent-main\n"); f:close()
git.add("a.txt")
git.commit("divergent main", false)
f = io.open(root .. "/clone/c.txt", "w"); f:write("divergent-clone\n"); f:close()
sh("git add -A && git commit -q -am divergent-clone && git push -q origin main", root .. "/clone")
local pl3 = git.pull("origin", "main", true)
check("pull ff-only divergent fails", (not pl3.ok) and pl3.kind ~= "conflict", tostring(pl3.kind))
gith("git config pull.rebase false")
local pl4 = git.pull("origin", "main", false)
check("pull merge ok", pl4.ok, tostring(pl4.message))
local cfile = io.open(repo_dir .. "/c.txt", "r")
check("merge brought clone's file", cfile ~= nil, "")
if cfile then cfile:close() end

-- Conflict classification: create a real conflict, check status + commit refusal.
sh("git checkout -q -b conflict-branch && git checkout -q main", repo_dir)
f = io.open(repo_dir .. "/pulled.txt", "w"); f:write("main version\n"); f:close()
git.add("pulled.txt")
git.commit("main version", false)
sh("git checkout -q conflict-branch", repo_dir)
f = io.open(repo_dir .. "/pulled.txt", "w"); f:write("side version\n"); f:close()
git.add("pulled.txt")
git.commit("side version", false)
sh("git checkout -q main && git merge conflict-branch >/dev/null 2>&1; true", repo_dir)
local st7 = git.status()
check("conflict status", st7.ok and #st7.data.conflicts == 1, tostring(st7.data and #st7.data.conflicts))
local cc = git.commit("should not work", false)
check("commit refused on conflict", (not cc.ok) and cc.kind == "conflict", tostring(cc.kind))
local un = git.unstage(".")
check("unstage-all aborts conflict", un.ok, tostring(un.message))
sh("git merge --abort >/dev/null 2>&1; true", repo_dir)

-- no_identity commit refusal (empty local identity in a fresh repo).
sh("mkdir -p '" .. root .. "/noid' && cd '" .. root .. "/noid' && git init -q -b main", root)
git.set_dir(root .. "/noid")
f = io.open(root .. "/noid/z.txt", "w"); f:write("x\n"); f:close()
git.add("z.txt")
sh("git config user.name '' && git config user.email ''", root .. "/noid")
local cn = git.commit("no identity", false)
check("no identity detected", (not cn.ok) and cn.kind == "no_identity", tostring(cn.kind))

-- v2 support probe.
git.set_dir(repo_dir)
local v2 = git.supports_v2()
check("porcelain v2 supported", v2.ok and v2.data == true, tostring(v2.message))

-- version probe.
local gv = git.git_version()
check("git version ok", gv.ok and (gv.data):find("git version") ~= nil, tostring(gv.data))

-- Cleanup.
os.execute("rm -rf '" .. root .. "'")

print(string.format("\n%d passed, %d failed", passed, failures))
if failures > 0 then
	os.exit(1)
end
