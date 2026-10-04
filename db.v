module main

import db.sqlite
import time
import os

// Schema v3: plain columns, no JSON. A sample row is only written when something changed,
// detail tables (boards / gods / weapon / stigmas) only when that part changed; readers take
// the latest detail set at or before a sample's time.
const schema_version = 3

const schema_v3 = [
	"CREATE TABLE IF NOT EXISTS meta (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL DEFAULT ''
	) WITHOUT ROWID",
	"CREATE TABLE IF NOT EXISTS teams (
		id    INTEGER PRIMARY KEY AUTOINCREMENT,
		name  TEXT NOT NULL UNIQUE COLLATE NOCASE,
		color TEXT NOT NULL DEFAULT '#4f9cf9',
		sort  INTEGER NOT NULL DEFAULT 0
	)",
	"CREATE TABLE IF NOT EXISTS players (
		id            INTEGER PRIMARY KEY AUTOINCREMENT,
		display_name  TEXT NOT NULL,
		char_name     TEXT NOT NULL COLLATE NOCASE,
		server_id     INTEGER NOT NULL,
		server_name   TEXT NOT NULL DEFAULT '',
		character_id  TEXT NOT NULL DEFAULT '',
		team_id       INTEGER REFERENCES teams(id) ON DELETE SET NULL,
		color         TEXT NOT NULL DEFAULT '',
		avatar_ver    INTEGER NOT NULL DEFAULT 0,
		profile_image TEXT NOT NULL DEFAULT '',
		class_name    TEXT NOT NULL DEFAULT '',
		level         INTEGER NOT NULL DEFAULT 0,
		active        INTEGER NOT NULL DEFAULT 1,
		visible       INTEGER NOT NULL DEFAULT 1,
		sort          INTEGER NOT NULL DEFAULT 0,
		last_ok_at    INTEGER NOT NULL DEFAULT 0,
		last_try_at   INTEGER NOT NULL DEFAULT 0,
		last_error    TEXT NOT NULL DEFAULT '',
		created_at    INTEGER NOT NULL DEFAULT 0,
		UNIQUE(server_id, char_name)
	)",
	// kind 0 = uploaded, 1 = in-game portrait; data = PNG/JPEG bytes (192x192)
	"CREATE TABLE IF NOT EXISTS avatars (
		player_id  INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
		kind       INTEGER NOT NULL,
		mime       TEXT NOT NULL,
		data       BLOB NOT NULL,
		src        TEXT NOT NULL DEFAULT '',
		fetched_at INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY(player_id, kind)
	)",
	'CREATE TABLE IF NOT EXISTS samples (
		player_id    INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
		ts           INTEGER NOT NULL,
		cp           INTEGER NOT NULL,
		item_level   INTEGER NOT NULL,
		level        INTEGER NOT NULL,
		dv_total     INTEGER NOT NULL,
		god_total    INTEGER NOT NULL,
		w_enchant    INTEGER NOT NULL,
		w_exceed     INTEGER NOT NULL,
		stigma_total INTEGER NOT NULL,
		PRIMARY KEY(player_id, ts)
	) WITHOUT ROWID',
	'CREATE TABLE IF NOT EXISTS boards (
		id    INTEGER PRIMARY KEY,
		name  TEXT NOT NULL UNIQUE,
		total INTEGER NOT NULL DEFAULT 0
	)',
	'CREATE TABLE IF NOT EXISTS sample_boards (
		player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
		ts        INTEGER NOT NULL,
		board_id  INTEGER NOT NULL REFERENCES boards(id),
		open      INTEGER NOT NULL,
		PRIMARY KEY(player_id, ts, board_id)
	) WITHOUT ROWID',
	'CREATE TABLE IF NOT EXISTS sample_gods (
		player_id   INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
		ts          INTEGER NOT NULL,
		justice     INTEGER NOT NULL,
		freedom     INTEGER NOT NULL,
		illusion    INTEGER NOT NULL,
		life        INTEGER NOT NULL,
		time        INTEGER NOT NULL,
		destruction INTEGER NOT NULL,
		death       INTEGER NOT NULL,
		wisdom      INTEGER NOT NULL,
		destiny     INTEGER NOT NULL,
		space       INTEGER NOT NULL,
		PRIMARY KEY(player_id, ts)
	) WITHOUT ROWID',
	"CREATE TABLE IF NOT EXISTS sample_weapon (
		player_id   INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
		ts          INTEGER NOT NULL,
		item_id     INTEGER NOT NULL,
		name        TEXT NOT NULL,
		grade       TEXT NOT NULL,
		enchant     INTEGER NOT NULL,
		exceed      INTEGER NOT NULL,
		max_enchant INTEGER NOT NULL,
		attack      TEXT NOT NULL DEFAULT '',
		PRIMARY KEY(player_id, ts)
	) WITHOUT ROWID",
	'CREATE TABLE IF NOT EXISTS skills (
		id   INTEGER PRIMARY KEY,
		name TEXT NOT NULL UNIQUE
	)',
	'CREATE TABLE IF NOT EXISTS sample_stigmas (
		player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
		ts        INTEGER NOT NULL,
		skill_id  INTEGER NOT NULL REFERENCES skills(id),
		level     INTEGER NOT NULL,
		equipped  INTEGER NOT NULL,
		PRIMARY KEY(player_id, ts, skill_id)
	) WITHOUT ROWID',
]

// god stat columns, in the API's order, with the labels the chart shows
const god_cols = ['justice', 'freedom', 'illusion', 'life', 'time', 'destruction', 'death', 'wisdom',
	'destiny', 'space']
const god_labels = ['Justice [Nezekan]', 'Freedom [Vaizel]', 'Illusion [Kaisinel]', 'Life [Yustiel]',
	'Time [Siel]', 'Destruction [Zikel]', 'Death [Triniel]', 'Wisdom [Lumiel]', 'Destiny [Marchutan]',
	'Space [Israphel]']

// open_db opens (and migrates) the SQLite database. Every thread uses its own connection;
// WAL + busy_timeout make the web thread and the collector thread play nicely together.
fn open_db(path string) !sqlite.DB {
	mut db := sqlite.connect(path)!
	db.busy_timeout(15000)
	db.exec_none('PRAGMA journal_mode=WAL')
	db.exec_none('PRAGMA synchronous=NORMAL')
	db.exec_none('PRAGMA foreign_keys=ON')
	migrate(mut db, path)!
	return db
}

fn migrate(mut db sqlite.DB, path string) ! {
	ver := db.q_int('PRAGMA user_version')!
	if ver >= schema_version {
		return
	}
	if ver == 0 && q(db, "SELECT 1 FROM sqlite_master WHERE name='players'")!.len == 0 {
		for s in schema_v3 {
			q(db, s)!
		}
	} else {
		// one-way migration: keep a consistent copy of the old database next to it first
		backup := '${path}.bak-v${ver}'
		if !os.exists(backup) {
			q(db, "VACUUM INTO '${backup.replace("'", "''")}'")!
			println('[db] kopia starej bazy: ${backup}')
		}
		migrate_to_v3(mut db, path)! // migrate.v
	}
	db.exec_none('PRAGMA user_version=${schema_version}')
}

fn now_unix() i64 {
	return time.now().unix()
}

// q runs a statement with bound parameters and propagates step errors
// (sqlite.DB.exec silently ignores them).
fn q(db &sqlite.DB, query string, params ...string) ![]sqlite.Row {
	return db.exec_param_many(query, params)
}

// tx runs `f` inside BEGIN IMMEDIATE / COMMIT (ROLLBACK on error).
fn tx(mut db sqlite.DB, f fn (mut db sqlite.DB) !) ! {
	q(db, 'BEGIN IMMEDIATE')!
	f(mut db) or {
		db.exec_none('ROLLBACK')
		return err
	}
	q(db, 'COMMIT')!
}

// ---------- meta ----------

fn meta_get(db &sqlite.DB, key string, def string) string {
	rows := db.exec_param('SELECT value FROM meta WHERE key=?', key) or { return def }
	if rows.len == 0 {
		return def
	}
	return rows[0].vals[0]
}

fn meta_set(db &sqlite.DB, key string, value string) {
	db.exec_param_many('INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value<>excluded.value',
		[key, value]) or { eprintln('meta_set ${key}: ${err}') }
}

// ---------- teams ----------

struct Team {
	id    int
	name  string
	color string
	sort  int
}

fn list_teams(db &sqlite.DB) []Team {
	rows := db.exec('SELECT id,name,color,sort FROM teams ORDER BY sort, name COLLATE NOCASE') or {
		return []
	}
	return rows.map(Team{
		id:    it.vals[0].int()
		name:  it.vals[1]
		color: it.vals[2]
		sort:  it.vals[3].int()
	})
}

// ---------- players ----------

struct Player {
mut:
	id              int
	display_name    string
	char_name       string
	server_id       int
	server_name     string
	character_id    string
	team_id         int
	color           string
	has_avatar      bool
	avatar_ver      i64
	profile_image   string
	class_name      string
	level           int
	active          bool
	visible         bool
	sort            int
	last_ok_at      i64
	last_try_at     i64
	last_error      string
	created_at      i64
	has_game_avatar bool
	game_avatar_src string
	game_avatar_at  i64
}

const player_cols = "id,display_name,char_name,server_id,server_name,character_id,IFNULL(team_id,0),color,
	EXISTS(SELECT 1 FROM avatars a WHERE a.player_id=players.id AND a.kind=0),avatar_ver,profile_image,class_name,level,
	active,visible,sort,last_ok_at,last_try_at,last_error,created_at,
	EXISTS(SELECT 1 FROM avatars a WHERE a.player_id=players.id AND a.kind=1),
	IFNULL((SELECT src FROM avatars a WHERE a.player_id=players.id AND a.kind=1),''),
	IFNULL((SELECT fetched_at FROM avatars a WHERE a.player_id=players.id AND a.kind=1),0)"

fn row_to_player(r sqlite.Row) Player {
	v := r.vals
	return Player{
		id:              v[0].int()
		display_name:    v[1]
		char_name:       v[2]
		server_id:       v[3].int()
		server_name:     v[4]
		character_id:    v[5]
		team_id:         v[6].int()
		color:           v[7]
		has_avatar:      v[8] == '1'
		avatar_ver:      v[9].i64()
		profile_image:   v[10]
		class_name:      v[11]
		level:           v[12].int()
		active:          v[13] == '1'
		visible:         v[14] == '1'
		sort:            v[15].int()
		last_ok_at:      v[16].i64()
		last_try_at:     v[17].i64()
		last_error:      v[18]
		created_at:      v[19].i64()
		has_game_avatar: v[20] == '1'
		game_avatar_src: v[21]
		game_avatar_at:  v[22].i64()
	}
}

fn list_players(db &sqlite.DB, only_visible bool) []Player {
	where := if only_visible { 'WHERE visible=1' } else { '' }
	rows := db.exec('SELECT ${player_cols} FROM players ${where} ORDER BY sort, display_name COLLATE NOCASE') or {
		eprintln('list_players: ${err}')
		return []
	}
	return rows.map(row_to_player(it))
}

fn get_player(db &sqlite.DB, id int) ?Player {
	rows := db.exec_param('SELECT ${player_cols} FROM players WHERE id=?', id.str()) or {
		return none
	}
	if rows.len == 0 {
		return none
	}
	return row_to_player(rows[0])
}

// ---------- character state ----------

struct BoardVal {
	name  string
	open  int
	total int
}

struct StigmaVal {
	name     string
	level    int
	equipped bool
}

struct WeaponVal {
	item_id     i64
	name        string
	grade       string
	enchant     int
	exceed      int
	max_enchant int
	attack      string
}

// State is everything we keep about a character at one point in time.
struct State {
mut:
	cp         i64
	item_level int
	level      int
	boards     []BoardVal // API order
	gods       []int      // god_cols order (10 values)
	weapon     WeaponVal
	stigmas    []StigmaVal // only learned ones (level > 0), sorted by name
}

fn (s State) dv_total() int {
	mut t := 0
	for b in s.boards {
		t += b.open
	}
	return t
}

fn (s State) god_total() int {
	mut t := 0
	for g in s.gods {
		t += g
	}
	return t
}

fn (s State) stigma_total() int {
	mut t := 0
	for x in s.stigmas {
		t += x.level
	}
	return t
}

// ---------- CP spikes ----------
// Entering some PvP events temporarily inflates the combat power the API reports
// (e.g. 100k -> 480k -> 101k a fetch later). Such reads are not stored. A spike that persists
// for cp_spike_accept_after consecutive reads (2 h at 15 min) is taken as real.
const cp_spike_ratio = 1.6
const cp_spike_min_jump = i64(30_000)
const cp_spike_accept_after = 8

fn is_cp_spike(prev_cp i64, cp i64) bool {
	return prev_cp > 0 && cp - prev_cp > cp_spike_min_jump
		&& f64(cp) > f64(prev_cp) * cp_spike_ratio
}

// ---------- writing (change-only) ----------

// save_state stores `cur` at time `ts` if it differs from `prev`: one samples row plus only
// the detail sets that changed. Returns false when nothing changed (nothing written).
// Must run inside a transaction (see tx()).
fn save_state(mut db sqlite.DB, player_id int, ts i64, cur State, prev ?State) !bool {
	mut first := true
	mut p := State{}
	if pv := prev {
		p = pv
		first = false
	}
	boards_changed := first || cur.boards != p.boards
	gods_changed := first || cur.gods != p.gods
	// weapons migrated from v2 have no item id (0): don't count the id appearing as a change
	prev_weapon := if p.weapon.item_id == 0 {
		WeaponVal{
			...p.weapon
			item_id: cur.weapon.item_id
		}
	} else {
		p.weapon
	}
	weapon_changed := first || cur.weapon != prev_weapon
	stigmas_changed := first || cur.stigmas != p.stigmas
	if !first && !boards_changed && !gods_changed && !weapon_changed && !stigmas_changed
		&& cur.cp == p.cp && cur.item_level == p.item_level && cur.level == p.level {
		return false
	}
	pid := player_id.str()
	t := ts.str()
	q(db, 'INSERT OR REPLACE INTO samples(player_id,ts,cp,item_level,level,dv_total,god_total,w_enchant,w_exceed,stigma_total) VALUES(?,?,?,?,?,?,?,?,?,?)',
		pid, t, cur.cp.str(), cur.item_level.str(), cur.level.str(), cur.dv_total().str(),
		cur.god_total().str(), cur.weapon.enchant.str(), cur.weapon.exceed.str(), cur.stigma_total().str())!
	if boards_changed {
		for b in cur.boards {
			q(db, 'INSERT INTO boards(name,total) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET total=excluded.total WHERE total<>excluded.total',
				b.name, b.total.str())!
			q(db, 'INSERT OR REPLACE INTO sample_boards(player_id,ts,board_id,open) SELECT ?,?,id,? FROM boards WHERE name=?',
				pid, t, b.open.str(), b.name)!
		}
	}
	if gods_changed && cur.gods.len == god_cols.len {
		mut args := [pid, t]
		args << cur.gods.map(it.str())
		q(db, 'INSERT OR REPLACE INTO sample_gods(player_id,ts,${god_cols.join(',')}) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
			...args)!
	}
	if weapon_changed {
		w := cur.weapon
		q(db, 'INSERT OR REPLACE INTO sample_weapon(player_id,ts,item_id,name,grade,enchant,exceed,max_enchant,attack) VALUES(?,?,?,?,?,?,?,?,?)',
			pid, t, w.item_id.str(), w.name, w.grade, w.enchant.str(), w.exceed.str(),
			w.max_enchant.str(), w.attack)!
	}
	if stigmas_changed {
		for x in cur.stigmas {
			q(db, 'INSERT OR IGNORE INTO skills(name) VALUES(?)', x.name)!
			q(db, 'INSERT OR REPLACE INTO sample_stigmas(player_id,ts,skill_id,level,equipped) SELECT ?,?,id,?,? FROM skills WHERE name=?',
				pid, t, x.level.str(), if x.equipped { '1' } else { '0' }, x.name)!
		}
	}
	return true
}

// ---------- reading ----------

// SampleRow is one stored sample; the detail fields are filled only on the samples where the
// detail set changed (and on the first sample returned), the client carries them forward.
struct SampleRow {
mut:
	ts           i64
	cp           i64
	item_level   int
	level        int
	dv_total     int
	god_total    int
	w_enchant    int
	w_exceed     int
	stigma_total int
	boards       ?[]BoardVal
	gods         ?[]int
	weapon       ?WeaponVal
	stigmas      ?[]StigmaVal
}

const sample_row_cols = 'ts,cp,item_level,level,dv_total,god_total,w_enchant,w_exceed,stigma_total'

fn row_to_sample(r sqlite.Row) SampleRow {
	v := r.vals
	return SampleRow{
		ts:           v[0].i64()
		cp:           v[1].i64()
		item_level:   v[2].int()
		level:        v[3].int()
		dv_total:     v[4].int()
		god_total:    v[5].int()
		w_enchant:    v[6].int()
		w_exceed:     v[7].int()
		stigma_total: v[8].int()
	}
}

// detail_floor = timestamp of the newest detail set at or before `ts` (0 if none)
fn detail_floor(db &sqlite.DB, table string, player_id int, ts i64) i64 {
	rows := q(db, 'SELECT IFNULL(max(ts),0) FROM ${table} WHERE player_id=? AND ts<=?',
		player_id.str(), ts.str()) or { return 0 }
	return if rows.len > 0 { rows[0].vals[0].i64() } else { 0 }
}

// samples_in_window returns the samples with ts >= from plus the last one before `from`
// (so lines start at the left edge), with detail sets attached where they changed.
fn samples_in_window(db &sqlite.DB, player_id int, from i64) []SampleRow {
	pid := player_id.str()
	mut out := []SampleRow{}
	if from > 0 {
		for r in q(db, 'SELECT ${sample_row_cols} FROM samples WHERE player_id=? AND ts<? ORDER BY ts DESC LIMIT 1',
			pid, from.str()) or { []sqlite.Row{} } {
			out << row_to_sample(r)
		}
	}
	for r in q(db, 'SELECT ${sample_row_cols} FROM samples WHERE player_id=? AND ts>=? ORDER BY ts',
		pid, from.str()) or { []sqlite.Row{} } {
		out << row_to_sample(r)
	}
	if out.len == 0 {
		return out
	}
	t0 := out[0].ts

	// boards: grouped by ts
	mut bsets := map[i64][]BoardVal{}
	mut bts := []i64{}
	for r in q(db, 'SELECT sb.ts, b.name, sb.open, b.total FROM sample_boards sb JOIN boards b ON b.id=sb.board_id WHERE sb.player_id=? AND sb.ts>=? ORDER BY sb.ts, b.id',
		pid, detail_floor(db, 'sample_boards', player_id, t0).str()) or { []sqlite.Row{} } {
		ts := r.vals[0].i64()
		if ts !in bsets {
			bts << ts
		}
		bsets[ts] << BoardVal{r.vals[1], r.vals[2].int(), r.vals[3].int()}
	}
	mut gsets := map[i64][]int{}
	mut gts := []i64{}
	for r in q(db, 'SELECT ts,${god_cols.join(',')} FROM sample_gods WHERE player_id=? AND ts>=? ORDER BY ts',
		pid, detail_floor(db, 'sample_gods', player_id, t0).str()) or { []sqlite.Row{} } {
		ts := r.vals[0].i64()
		gts << ts
		gsets[ts] = r.vals[1..].map(it.int())
	}
	mut wsets := map[i64]WeaponVal{}
	mut wts := []i64{}
	for r in q(db, 'SELECT ts,item_id,name,grade,enchant,exceed,max_enchant,attack FROM sample_weapon WHERE player_id=? AND ts>=? ORDER BY ts',
		pid, detail_floor(db, 'sample_weapon', player_id, t0).str()) or { []sqlite.Row{} } {
		v := r.vals
		ts := v[0].i64()
		wts << ts
		wsets[ts] = WeaponVal{v[1].i64(), v[2], v[3], v[4].int(), v[5].int(), v[6].int(), v[7]}
	}
	mut ssets := map[i64][]StigmaVal{}
	mut sts := []i64{}
	for r in q(db, 'SELECT ss.ts, k.name, ss.level, ss.equipped FROM sample_stigmas ss JOIN skills k ON k.id=ss.skill_id WHERE ss.player_id=? AND ss.ts>=? ORDER BY ss.ts, k.name',
		pid, detail_floor(db, 'sample_stigmas', player_id, t0).str()) or { []sqlite.Row{} } {
		ts := r.vals[0].i64()
		if ts !in ssets {
			sts << ts
		}
		ssets[ts] << StigmaVal{r.vals[1], r.vals[2].int(), r.vals[3] == '1'}
	}

	// attach each detail set to the first sample at/after it (the newest one wins)
	mut bi, mut gi, mut wi, mut si := 0, 0, 0, 0
	for mut s in out {
		mut hit := i64(-1)
		for bi < bts.len && bts[bi] <= s.ts {
			hit = bts[bi]
			bi++
		}
		if hit >= 0 {
			s.boards = bsets[hit]
		}
		hit = -1
		for gi < gts.len && gts[gi] <= s.ts {
			hit = gts[gi]
			gi++
		}
		if hit >= 0 {
			s.gods = gsets[hit]
		}
		hit = -1
		for wi < wts.len && wts[wi] <= s.ts {
			hit = wts[wi]
			wi++
		}
		if hit >= 0 {
			s.weapon = wsets[hit]
		}
		hit = -1
		for si < sts.len && sts[si] <= s.ts {
			hit = sts[si]
			si++
		}
		if hit >= 0 {
			s.stigmas = ssets[hit]
		}
	}
	return out
}

// load_state rebuilds the latest stored State of a player (none if there is no sample yet).
fn load_state(db &sqlite.DB, player_id int) ?State {
	rows := q(db, 'SELECT ts FROM samples WHERE player_id=? ORDER BY ts DESC LIMIT 1',
		player_id.str()) or { return none }
	if rows.len == 0 {
		return none
	}
	mut st := State{}
	mut found := false
	// the detail sets are attached to the samples where they changed: carry them forward
	for s in samples_in_window(db, player_id, rows[0].vals[0].i64()) {
		found = true
		st.cp = s.cp
		st.item_level = s.item_level
		st.level = s.level
		if b := s.boards {
			st.boards = b
		}
		if g := s.gods {
			st.gods = g
		}
		if w := s.weapon {
			st.weapon = w
		}
		if x := s.stigmas {
			st.stigmas = x
		}
	}
	if !found {
		return none
	}
	return st
}
