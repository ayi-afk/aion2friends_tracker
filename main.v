module main

import veb
import db.sqlite
import flag
import os
import json
import time
import rand
import strings
import net.http

const app_version = '1.0.0'

const index_html = $embed_file('web/index.html').to_string()
const admin_html = $embed_file('web/admin.html').to_string()

const valid_modes = ['cp', 'ilvl', 'dv', 'god', 'weapon', 'stigma', 'level']

pub struct Context {
	veb.Context
}

// Brute-force protection for the admin login: after login_max_fails wrong passwords from one
// IP, that IP is blocked for login_block_sec seconds.
const login_max_fails = 5
const login_block_sec = 60

struct LoginFails {
mut:
	count         int
	blocked_until i64
}

pub struct App {
mut:
	db          sqlite.DB
	blobs       BlobDB // avatars (binary) go through a raw connection, see avatar.v
	password    string
	interval    int
	sessions    map[string]i64 // token -> expiry
	login_fails map[string]LoginFails
	trigger     chan int
	servers     []ServerOut
	servers_at  i64
}

fn main() {
	default_db := os.join_path(os.dir(os.executable()), 'aion2tracker.db')
	mut fp := flag.new_flag_parser(os.args)
	fp.application('aion2tracker')
	fp.version(app_version)
	fp.description(
		'AION 2 stream tracker: co kilka minut zbiera Combat Power, Item Level, Daevanion,\n' +
		'statystyki bogów, broń i stigmy wybranych postaci i pokazuje je na żywym wykresie.\n' +
		'Strona główna (/) jest publiczna (tylko odczyt). Panel /admin/: z hasłem działa z każdego adresu\n' +
		'(5 złych haseł = 1 min blokady IP), bez hasła tylko z localhost.')
	fp.skip_executable()
	port := fp.int('port', `p`, 8080, 'port HTTP (domyślnie 8080)')
	password_flag := fp.string('password', 0, '', 'hasło do panelu /admin/ (albo zmienna środowiskowa A2T_PASSWORD); bez hasła panel działa tylko z localhost')
	db_path := fp.string('db', 0, default_db, 'ścieżka do pliku bazy SQLite (domyślnie obok exe)')
	interval := fp.int('interval', 0, 15, 'co ile minut zbierać dane (domyślnie 15)')
	host := fp.string('host', 0, '0.0.0.0', 'adres nasłuchu (domyślnie 0.0.0.0 = wszystkie interfejsy)')
	fp.finalize() or {
		eprintln(err)
		println(fp.usage())
		exit(1)
	}
	// the password may also come from the environment (docker / compose secrets)
	password := if password_flag != '' { password_flag } else { os.getenv('A2T_PASSWORD') }
	if port < 1 || port > 65535 {
		eprintln('nieprawidłowy port: ${port}')
		exit(1)
	}
	if interval < 1 {
		eprintln('--interval musi być >= 1')
		exit(1)
	}

	db := open_db(db_path) or {
		eprintln('nie można otworzyć bazy ${db_path}: ${err}')
		exit(1)
	}
	trigger := chan int{cap: 64}
	spawn worker_loop(WorkerCfg{
		db_path:      db_path
		interval_min: interval
		trigger:      trigger
	})

	println('AION 2 tracker v${app_version}')
	println('  baza:      ${db_path}')
	println('  interwał:  ${interval} min')
	println('  strona:    http://localhost:${port}/')
	if password != '' {
		println('  admin:     http://<host>:${port}/admin/  (hasło; ${login_max_fails} złych prób = ${login_block_sec} s blokady IP)')
	} else {
		println('  admin:     http://localhost:${port}/admin/  (tylko z localhost)')
		println('  UWAGA: brak hasła (--password / A2T_PASSWORD) — panel admina działa tylko z localhost, bez logowania.')
	}
	blobs := open_blob_db(db_path) or {
		eprintln('nie można otworzyć bazy ${db_path}: ${err}')
		exit(1)
	}
	mut app := &App{
		db:       db
		blobs:    blobs
		password: password
		interval: interval
		trigger:  trigger
	}
	veb.run_at[App, Context](mut app,
		host:                 host
		port:                 port
		family:               .ip
		show_startup_message: false
		timeout_in_seconds:   120
	) or {
		eprintln('nie można uruchomić serwera: ${err}')
		exit(1)
	}
}

// admin_denied tells why the admin panel is refused for this request (none = allowed).
// With a password the panel is reachable from anywhere (login + brute-force limit protect it);
// without one it is restricted to loopback connections.
fn (app &App) admin_denied(ctx &Context) ?string {
	if app.password == '' && !ctx.is_local() {
		return msg('admin_local_only')
	}
	return none
}

// client_ip identifies the client for the login limiter: the socket peer, or — when the peer is a
// reverse proxy on this machine — the last X-Forwarded-For entry (the one the proxy appended;
// earlier entries can be forged by the client).
fn (ctx &Context) client_ip() string {
	ip := ctx.conn.peer_ip() or { return '?' }
	if is_loopback(ip) {
		if xff := ctx.req.header.get_custom('X-Forwarded-For') {
			last := xff.all_after_last(',').trim_space()
			if last != '' {
				return last
			}
		}
	}
	return ip
}

// ---------------------------------------------------------------- helpers

fn jstr(s string) string {
	mut sb := strings.new_builder(s.len + 2)
	sb.write_u8(`"`)
	for r in s.runes() {
		match r {
			`"` {
				sb.write_string('\\"')
			}
			`\\` {
				sb.write_string('\\\\')
			}
			`\n` {
				sb.write_string('\\n')
			}
			`\r` {
				sb.write_string('\\r')
			}
			`\t` {
				sb.write_string('\\t')
			}
			`<` {
				sb.write_string('\\u003c')
			}
			else {
				if r < 0x20 {
					sb.write_string('\\u00' + u8(r).hex())
				} else {
					sb.write_string(r.str())
				}
			}
		}
	}
	sb.write_u8(`"`)
	return sb.str()
}

fn (mut ctx Context) json_raw(status http.Status, body string) veb.Result {
	ctx.res.set_status(status)
	ctx.set_header(.cache_control, 'no-store')
	return ctx.send_response_to_client('application/json; charset=utf-8', body)
}

fn (mut ctx Context) fail(status http.Status, message string) veb.Result {
	return ctx.json_raw(status, '{"error":${jstr(tr(ctx.lang(), message))}}')
}

fn (mut ctx Context) ok_json(body string) veb.Result {
	return ctx.json_raw(.ok, body)
}

fn is_loopback(ip string) bool {
	return ip == '::1' || ip.starts_with('127.') || ip.starts_with('::ffff:127.')
}

// is_local checks the *socket* peer (not spoofable headers). Requests that went through a
// reverse proxy on the same machine carry forwarding headers and are treated as remote.
fn (ctx &Context) is_local() bool {
	ip := ctx.conn.peer_ip() or { return false }
	if !is_loopback(ip) {
		return false
	}
	for h in ['X-Forwarded-For', 'X-Real-Ip', 'Forwarded', 'CF-Connecting-IP', 'True-Client-IP'] {
		if v := ctx.req.header.get_custom(h) {
			if v != '' {
				return false
			}
		}
	}
	return true
}

fn (mut app App) is_authed(ctx &Context) bool {
	if app.password == '' {
		return true
	}
	token := ctx.get_cookie('a2t_admin') or { return false }
	exp := app.sessions[token] or { return false }
	if exp < now_unix() {
		app.sessions.delete(token)
		return false
	}
	return true
}

// admin_guard returns an error message when the request may not use the admin API.
// Mutating admin calls must carry the custom X-A2T header, which a cross-site form cannot set.
fn (mut app App) admin_guard(mut ctx Context, need_auth bool) ?string {
	if denied := app.admin_denied(ctx) {
		return denied
	}
	if ctx.req.method == .post {
		hv := ctx.req.header.get_custom('X-A2T') or { '' }
		if hv != '1' {
			return msg('missing_header')
		}
	}
	if need_auth && !app.is_authed(ctx) {
		return 'unauthorized'
	}
	return none
}

fn (mut app App) guard_fail(mut ctx Context, message string) veb.Result {
	if message == 'unauthorized' {
		return ctx.fail(.unauthorized, msg('login_required'))
	}
	return ctx.fail(.forbidden, message)
}

fn (app &App) setting(key string, def string) string {
	return meta_get(app.db, key, def)
}

// ---------------------------------------------------------------- public pages

@['/']
pub fn (mut app App) index(mut ctx Context) veb.Result {
	ctx.set_header(.cache_control, 'no-cache')
	return ctx.html(page(index_html, 'index.html'))
}

@['/favicon.ico']
pub fn (mut app App) favicon(mut ctx Context) veb.Result {
	ctx.set_header(.cache_control, 'public, max-age=86400')
	return ctx.send_response_to_client('image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#0b0f17"/><path d="M4 24 L11 16 L17 19 L28 7" stroke="#f5a623" stroke-width="3" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>')
}

struct StatePlayer {
	id        int
	name      string
	char      string
	server    string
	server_id int
	cls       string
	level     int
	team      int
	color     string
	avatar    string
	active    bool
	last_ok   i64
}

struct StateOut {
	title         string
	version       string
	now           i64
	interval      int
	next_cycle    i64
	last_cycle    i64
	default_mode  string
	default_range string
	default_lang  string
	teams         []Team
	players       []StatePlayer
}

fn avatar_url(p Player) string {
	if p.has_avatar || p.has_game_avatar {
		return '/avatar/${p.id}?v=${p.avatar_ver}'
	}
	return p.profile_image
}

@['/api/state']
pub fn (mut app App) api_state(mut ctx Context) veb.Result {
	players := list_players(app.db, true)
	out := StateOut{
		title:         app.setting('title', 'AION 2 — Stream Race')
		version:       app_version
		now:           now_unix()
		interval:      app.interval * 60
		next_cycle:    app.setting('worker_next_cycle', '0').i64()
		last_cycle:    app.setting('worker_last_cycle_end', '0').i64()
		default_mode:  app.setting('default_mode', 'cp')
		default_range: app.setting('default_range', '86400')
		default_lang:  app.setting('default_lang', 'auto')
		teams:         list_teams(app.db)
		players:       players.map(StatePlayer{
			id:        it.id
			name:      it.display_name
			char:      it.char_name
			server:    it.server_name
			server_id: it.server_id
			cls:       it.class_name
			level:     it.level
			team:      it.team_id
			color:     it.color
			avatar:    avatar_url(it)
			active:    it.active
			last_ok:   it.last_ok_at
		})
	}
	return ctx.ok_json(json.encode(out))
}

// sample_json writes one sample. Detail sets (boards / gods / weapon / stigmas) are only present
// on samples where they changed (and on the first one); the client carries them forward.
fn sample_json(mut sb strings.Builder, s SampleRow) {
	sb.write_string('{"t":${s.ts},"cp":${s.cp},"il":${s.item_level},"lv":${s.level},"dvt":${s.dv_total},"gt":${s.god_total},"we":${s.w_enchant},"wx":${s.w_exceed},"st":${s.stigma_total}')
	if boards := s.boards {
		sb.write_string(',"dv":[')
		for i, b in boards {
			if i > 0 {
				sb.write_u8(`,`)
			}
			sb.write_string('{"n":${jstr(b.name)},"o":${b.open},"t":${b.total}}')
		}
		sb.write_u8(`]`)
	}
	if gods := s.gods {
		sb.write_string(',"g":[')
		for i, v in gods {
			if i > 0 {
				sb.write_u8(`,`)
			}
			sb.write_string('{"n":${jstr(god_labels[i])},"v":${v}}')
		}
		sb.write_u8(`]`)
	}
	if st := s.stigmas {
		sb.write_string(',"sj":[')
		for i, x in st {
			if i > 0 {
				sb.write_u8(`,`)
			}
			eq := if x.equipped { 1 } else { 0 }
			sb.write_string('{"n":${jstr(x.name)},"l":${x.level},"e":${eq}}')
		}
		sb.write_u8(`]`)
	}
	if w := s.weapon {
		sb.write_string(',"wn":${jstr(w.name)},"wg":${jstr(w.grade)},"wm":${w.max_enchant},"wa":${jstr(w.attack)}')
	}
	sb.write_u8(`}`)
}

// /api/series?range=<seconds> — samples of all visible players inside the window (0 = all history).
// Samples are stored only when something changed, so a value holds until the next sample.
@['/api/series']
pub fn (mut app App) api_series(mut ctx Context) veb.Result {
	now := now_unix()
	rng := (ctx.query['range'] or { '86400' }).i64()
	from := if rng <= 0 { i64(0) } else { now - rng }
	players := list_players(app.db, true)
	mut sb := strings.new_builder(64 * 1024)
	sb.write_string('{"now":${now},"from":${from},"series":{')
	for i, p in players {
		if i > 0 {
			sb.write_u8(`,`)
		}
		sb.write_string('"${p.id}":[')
		for j, s in samples_in_window(app.db, p.id, from) {
			if j > 0 {
				sb.write_u8(`,`)
			}
			sample_json(mut sb, s)
		}
		sb.write_u8(`]`)
	}
	sb.write_string('}}')
	return ctx.ok_json(sb.str())
}

@['/avatar/:id']
pub fn (mut app App) avatar(mut ctx Context, id int) veb.Result {
	// uploaded avatar first, otherwise the stored copy of the in-game portrait
	// (?game=1 forces the portrait — used by the admin preview)
	mime, data := app.blobs.avatar_get(id, (ctx.query['game'] or { '' }) == '1') or {
		return ctx.not_found()
	}
	ctx.set_header(.cache_control, 'public, max-age=31536000, immutable')
	return ctx.send_response_to_client(mime, data.bytestr())
}

// ---------------------------------------------------------------- admin page + auth

// veb matches both /admin and /admin/ here
@['/admin']
pub fn (mut app App) admin_page(mut ctx Context) veb.Result {
	if denied := app.admin_denied(ctx) {
		ctx.res.set_status(.forbidden)
		return ctx.html('<!doctype html><meta charset="utf-8"><title>403</title><body style="background:#0b0f17;color:#cfd8e6;font:16px system-ui;display:grid;place-items:center;height:100vh;margin:0"><div><h1>403</h1><p>${tr('pl',
			denied)}.<br>${tr('en', denied)}.</p><p><a style="color:#f5a623" href="/">← wykres / chart</a></p></div>')
	}
	ctx.set_header(.cache_control, 'no-store')
	return ctx.html(page(admin_html, 'admin.html'))
}

struct LoginIn {
	password string
}

@['/api/admin/login'; post]
pub fn (mut app App) admin_login(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, false) {
		return app.guard_fail(mut ctx, gerr)
	}
	ip := ctx.client_ip()
	now := now_unix()
	mut fails := app.login_fails[ip] or { LoginFails{} }
	if fails.blocked_until > now {
		ctx.set_custom_header('Retry-After', (fails.blocked_until - now).str()) or {}
		return ctx.fail(.too_many_requests, msg('login_blocked', (fails.blocked_until - now).str()))
	}
	inp := json.decode(LoginIn, ctx.req.data) or { return ctx.fail(.bad_request, msg('bad_json')) }
	if app.password != '' && !same_secret(inp.password, app.password) {
		fails.count++
		if fails.count >= login_max_fails {
			fails = LoginFails{
				blocked_until: now + login_block_sec
			}
			app.login_fails[ip] = fails
			eprintln('[admin] ${login_max_fails} złych haseł z ${ip} — blokada na ${login_block_sec} s')
			ctx.set_custom_header('Retry-After', login_block_sec.str()) or {}
			return ctx.fail(.too_many_requests, msg('login_blocked', login_block_sec.str()))
		}
		app.login_fails[ip] = fails
		app.prune_login_fails(now)
		return ctx.fail(.unauthorized, msg('bad_password_left', (login_max_fails - fails.count).str()))
	}
	app.login_fails.delete(ip)
	token := rand.uuid_v4() + rand.uuid_v4()
	app.sessions[token] = now_unix() + 30 * 86400
	ctx.set_cookie(http.Cookie{
		name:      'a2t_admin'
		value:     token
		path:      '/'
		http_only: true
		same_site: .same_site_strict_mode
		max_age:   30 * 86400
	})
	return ctx.ok_json('{"ok":true}')
}

// same_secret compares in constant time (no early exit on the first differing byte).
fn same_secret(a string, b string) bool {
	if a.len != b.len {
		return false
	}
	mut diff := u8(0)
	for i in 0 .. a.len {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}

// prune_login_fails keeps the limiter map bounded: entries whose block ended are dropped
// once the map grows large.
fn (mut app App) prune_login_fails(now i64) {
	if app.login_fails.len < 1000 {
		return
	}
	for ip, f in app.login_fails.clone() {
		if f.blocked_until <= now {
			app.login_fails.delete(ip)
		}
	}
}

@['/api/admin/logout'; post]
pub fn (mut app App) admin_logout(mut ctx Context) veb.Result {
	if token := ctx.get_cookie('a2t_admin') {
		app.sessions.delete(token)
	}
	ctx.set_cookie(http.Cookie{
		name:    'a2t_admin'
		value:   ''
		path:    '/'
		max_age: -1
	})
	return ctx.ok_json('{"ok":true}')
}

@['/api/admin/me']
pub fn (mut app App) admin_me(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, false) {
		return app.guard_fail(mut ctx, gerr)
	}
	return ctx.ok_json('{"authed":${app.is_authed(ctx)},"password_set":${app.password != ''}}')
}

// ---------------------------------------------------------------- admin data

struct AdminPlayer {
	id              int
	display_name    string
	char_name       string
	server_id       int
	server_name     string
	character_id    string
	team_id         int
	color           string
	avatar          string
	has_avatar      bool
	has_game_avatar bool
	class_name      string
	level           int
	active          bool
	visible         bool
	sort            int
	last_ok_at      i64
	last_try_at     i64
	last_error      string
	samples         int
	last_cp         i64
	last_il         int
}

struct AdminStatus {
	now            i64
	interval       int
	next_cycle     i64
	last_cycle     i64
	last_cycle_end i64
	last_result    string
	cycle_started  i64
	db_path        string
	samples        int
	db_size        i64
	password_set   bool
}

struct Settings {
	title         string
	default_mode  string
	default_range string
	default_lang  string // auto | pl | en
}

struct Overview {
	status   AdminStatus
	settings Settings
	teams    []Team
	players  []AdminPlayer
}

@['/api/admin/overview']
pub fn (mut app App) admin_overview(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	mut stats := map[int][]string{}
	rows := q(app.db, 'SELECT player_id, count(*), (SELECT cp FROM samples s2 WHERE s2.player_id=s.player_id ORDER BY ts DESC LIMIT 1), (SELECT item_level FROM samples s2 WHERE s2.player_id=s.player_id ORDER BY ts DESC LIMIT 1) FROM samples s GROUP BY player_id') or {
		[]sqlite.Row{}
	}
	mut total := 0
	for r in rows {
		stats[r.vals[0].int()] = r.vals
		total += r.vals[1].int()
	}
	lang := ctx.lang()
	players := list_players(app.db, false).map(fn [stats, lang] (p Player) AdminPlayer {
		st := stats[p.id] or { ['', '0', '0', '0'] }
		return AdminPlayer{
			id:              p.id
			display_name:    p.display_name
			char_name:       p.char_name
			server_id:       p.server_id
			server_name:     p.server_name
			character_id:    p.character_id
			team_id:         p.team_id
			color:           p.color
			avatar:          avatar_url(p)
			has_avatar:      p.has_avatar
			has_game_avatar: p.has_game_avatar
			class_name:      p.class_name
			level:           p.level
			active:          p.active
			visible:         p.visible
			sort:            p.sort
			last_ok_at:      p.last_ok_at
			last_try_at:     p.last_try_at
			last_error:      tr(lang, p.last_error)
			samples:         st[1].int()
			last_cp:         st[2].i64()
			last_il:         st[3].int()
		}
	})
	db_path := app.db_file()
	out := Overview{
		status:   AdminStatus{
			now:            now_unix()
			interval:       app.interval * 60
			next_cycle:     app.setting('worker_next_cycle', '0').i64()
			last_cycle:     app.setting('worker_last_cycle', '0').i64()
			last_cycle_end: app.setting('worker_last_cycle_end', '0').i64()
			last_result:    tr(lang, app.setting('worker_last_result', ''))
			cycle_started:  app.setting('worker_cycle_started', '0').i64()
			db_path:        db_path
			samples:        total
			db_size:        os.file_size(db_path) + os.file_size(db_path + '-wal')
			password_set:   app.password != ''
		}
		settings: Settings{
			title:         app.setting('title', 'AION 2 — Stream Race')
			default_mode:  app.setting('default_mode', 'cp')
			default_range: app.setting('default_range', '86400')
			default_lang:  app.setting('default_lang', 'auto')
		}
		teams:    list_teams(app.db)
		players:  players
	}
	return ctx.ok_json(json.encode(out))
}

fn (app &App) db_file() string {
	rows := q(app.db, 'PRAGMA database_list') or { return '' }
	for r in rows {
		if r.vals.len >= 3 && r.vals[1] == 'main' {
			return r.vals[2]
		}
	}
	return ''
}

struct PlayerIn {
	id            int
	display_name  string
	char_name     string
	server_id     int
	server_name   string
	character_id  string
	team_id       int
	color         string
	active        bool
	visible       bool
	sort          int
	avatar_action string // keep | set | clear
	avatar        string // data URL when avatar_action == set
}

fn valid_color(c string) bool {
	if c == '' {
		return true
	}
	if c.len != 7 || c[0] != `#` {
		return false
	}
	for ch in c[1..] {
		if !ch.is_hex_digit() {
			return false
		}
	}
	return true
}

@['/api/admin/player/save'; post]
pub fn (mut app App) admin_player_save(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	inp := json.decode(PlayerIn, ctx.req.data) or { return ctx.fail(.bad_request, msg('bad_json')) }
	char_name := inp.char_name.trim_space()
	display := if inp.display_name.trim_space() == '' {
		char_name
	} else {
		inp.display_name.trim_space()
	}
	if char_name == '' || inp.server_id <= 0 {
		return ctx.fail(.bad_request, msg('need_char_server'))
	}
	if !valid_color(inp.color) {
		return ctx.fail(.bad_request, msg('bad_color'))
	}
	mut av_mime := ''
	mut av_data := []u8{}
	if inp.avatar_action == 'set' {
		// re-decode + resize server-side: only our own re-encoded PNG/JPEG is ever stored
		raw := decode_data_url(inp.avatar) or { return ctx.fail(.bad_request, msg('bad_avatar')) }
		av_mime, av_data = make_avatar(raw) or { return ctx.fail(.bad_request, err.msg()) }
	}
	team := if inp.team_id > 0 { inp.team_id.str() } else { '' }
	act := if inp.active { '1' } else { '0' }
	vis := if inp.visible { '1' } else { '0' }
	mut id := inp.id
	if id == 0 {
		q(app.db, "INSERT INTO players(display_name,char_name,server_id,server_name,character_id,team_id,color,active,visible,sort,created_at) VALUES(?,?,?,?,?,NULLIF(?,''),?,?,?,?,?)",
			display, char_name, inp.server_id.str(), inp.server_name, inp.character_id,
			team, inp.color, act, vis, inp.sort.str(), now_unix().str()) or {
			if err.msg().contains('UNIQUE') {
				return ctx.fail(.conflict, msg('char_exists'))
			}
			return ctx.fail(.internal_server_error, err.msg())
		}
		id = int(app.db.last_insert_rowid())
	} else {
		old := get_player(app.db, id) or { return ctx.fail(.not_found, msg('no_player')) }
		// changing name/server invalidates the resolved character id
		mut char_id := inp.character_id
		if char_id == '' && old.char_name.to_lower() == char_name.to_lower()
			&& old.server_id == inp.server_id {
			char_id = old.character_id
		}
		q(app.db, "UPDATE players SET display_name=?, char_name=?, server_id=?, server_name=?, character_id=?, team_id=NULLIF(?,''), color=?, active=?, visible=?, sort=? WHERE id=?",
			display, char_name, inp.server_id.str(), inp.server_name, char_id, team, inp.color,
			act, vis, inp.sort.str(), id.str()) or {
			if err.msg().contains('UNIQUE') {
				return ctx.fail(.conflict, msg('char_exists'))
			}
			return ctx.fail(.internal_server_error, err.msg())
		}
	}
	if inp.avatar_action == 'set' {
		app.blobs.avatar_put(id, 0, av_mime, av_data, '') or {
			return ctx.fail(.internal_server_error, err.msg())
		}
		q(app.db, 'UPDATE players SET avatar_ver=avatar_ver+1 WHERE id=?', id.str()) or {}
	} else if inp.avatar_action == 'clear' {
		q(app.db, 'DELETE FROM avatars WHERE player_id=? AND kind=0', id.str()) or {
			return ctx.fail(.internal_server_error, err.msg())
		}
		q(app.db, 'UPDATE players SET avatar_ver=avatar_ver+1 WHERE id=?', id.str()) or {}
	}
	// new / reactivated players get their first data point right away
	if inp.active {
		if p := get_player(app.db, id) {
			if p.last_ok_at == 0 || p.character_id == '' {
				app.trigger.try_push(id)
			}
		}
	}
	return ctx.ok_json('{"ok":true,"id":${id}}')
}

// Raw image upload (body = file bytes): decoded, center-cropped, resized to 192×192 and stored in the db.
@['/api/admin/player/:id/avatar'; post]
pub fn (mut app App) admin_player_avatar(mut ctx Context, id int) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	get_player(app.db, id) or { return ctx.fail(.not_found, msg('no_player')) }
	if ctx.req.data.len > avatar_max_upload {
		return ctx.fail(.request_entity_too_large, msg('file_too_big', (avatar_max_upload / 1024 / 1024).str()))
	}
	mime, data := make_avatar(ctx.req.data.bytes()) or { return ctx.fail(.bad_request, err.msg()) }
	app.blobs.avatar_put(id, 0, mime, data, '') or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	q(app.db, 'UPDATE players SET avatar_ver=avatar_ver+1 WHERE id=?', id.str()) or {}
	return ctx.ok_json('{"ok":true,"bytes":${data.len}}')
}

@['/api/admin/player/:id/delete'; post]
pub fn (mut app App) admin_player_delete(mut ctx Context, id int) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	// samples, detail sets and avatars go with it (ON DELETE CASCADE)
	q(app.db, 'DELETE FROM players WHERE id=?', id.str()) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	return ctx.ok_json('{"ok":true}')
}

struct ToggleIn {
	field string
	value bool
}

@['/api/admin/player/:id/toggle'; post]
pub fn (mut app App) admin_player_toggle(mut ctx Context, id int) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	inp := json.decode(ToggleIn, ctx.req.data) or { return ctx.fail(.bad_request, msg('bad_json')) }
	if inp.field !in ['active', 'visible'] {
		return ctx.fail(.bad_request, msg('bad_field'))
	}
	val := if inp.value { '1' } else { '0' }
	q(app.db, 'UPDATE players SET ${inp.field}=? WHERE id=?', val, id.str()) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	if inp.field == 'active' && inp.value {
		app.trigger.try_push(id)
	}
	return ctx.ok_json('{"ok":true}')
}

@['/api/admin/player/:id/fetch'; post]
pub fn (mut app App) admin_player_fetch(mut ctx Context, id int) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	if app.trigger.try_push(id) != .success {
		return ctx.fail(.service_unavailable, msg('queue_full'))
	}
	return ctx.ok_json('{"ok":true}')
}

@['/api/admin/fetch_all'; post]
pub fn (mut app App) admin_fetch_all(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	all := trigger_all
	app.trigger.try_push(all)
	return ctx.ok_json('{"ok":true}')
}

struct TeamIn {
	id    int
	name  string
	color string
	sort  int
}

@['/api/admin/team/save'; post]
pub fn (mut app App) admin_team_save(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	inp := json.decode(TeamIn, ctx.req.data) or { return ctx.fail(.bad_request, msg('bad_json')) }
	name := inp.name.trim_space()
	if name == '' || !valid_color(inp.color) || inp.color == '' {
		return ctx.fail(.bad_request, msg('need_team'))
	}
	if inp.id == 0 {
		q(app.db, 'INSERT INTO teams(name,color,sort) VALUES(?,?,?)', name, inp.color,
			inp.sort.str()) or { return ctx.fail(.conflict, msg('team_exists')) }
	} else {
		q(app.db, 'UPDATE teams SET name=?, color=?, sort=? WHERE id=?', name, inp.color,
			inp.sort.str(), inp.id.str()) or { return ctx.fail(.conflict, msg('team_exists')) }
	}
	return ctx.ok_json('{"ok":true}')
}

@['/api/admin/team/:id/delete'; post]
pub fn (mut app App) admin_team_delete(mut ctx Context, id int) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	q(app.db, 'UPDATE players SET team_id=NULL WHERE team_id=?', id.str()) or {}
	q(app.db, 'DELETE FROM teams WHERE id=?', id.str()) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	return ctx.ok_json('{"ok":true}')
}

@['/api/admin/settings'; post]
pub fn (mut app App) admin_settings(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	inp := json.decode(Settings, ctx.req.data) or { return ctx.fail(.bad_request, msg('bad_json')) }
	mode := inp.default_mode.all_before(':')
	if mode !in valid_modes {
		return ctx.fail(.bad_request, msg('bad_mode'))
	}
	meta_set(app.db, 'title', inp.title.trim_space())
	meta_set(app.db, 'default_mode', inp.default_mode)
	meta_set(app.db, 'default_range', inp.default_range.i64().str())
	meta_set(app.db, 'default_lang', if inp.default_lang in ['pl', 'en'] {
		inp.default_lang
	} else {
		'auto'
	})
	return ctx.ok_json('{"ok":true}')
}

struct ServerOut {
	id     int
	name   string
	region string
	race   int
}

@['/api/admin/servers']
pub fn (mut app App) admin_servers(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	if app.servers.len == 0 || now_unix() - app.servers_at > 6 * 3600 {
		mut all := []ServerOut{}
		for r in regions {
			list := fetch_servers(r) or { continue }
			for s in list {
				all << ServerOut{s.server_id, s.server_name, r, s.race_id}
			}
		}
		if all.len > 0 {
			app.servers = all
			app.servers_at = now_unix()
		}
	}
	return ctx.ok_json(json.encode(app.servers))
}

@['/api/admin/search']
pub fn (mut app App) admin_search(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	name := (ctx.query['name'] or { '' }).trim_space()
	server := (ctx.query['server'] or { '0' }).int()
	if name.len < 1 {
		return ctx.fail(.bad_request, msg('need_name'))
	}
	hits := search_characters(name, server) or {
		return ctx.fail(.bad_gateway, msg('api_error', err.msg()))
	}
	return ctx.ok_json(json.encode(hits))
}

@['/api/admin/import'; post]
pub fn (mut app App) admin_import(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	if ctx.req.data.len < 100 {
		return ctx.fail(.bad_request, msg('empty_file'))
	}
	tmp := os.join_path(os.temp_dir(), 'a2t_import_${now_unix()}_${rand.u32()}.db')
	os.write_file(tmp, ctx.req.data) or { return ctx.fail(.internal_server_error, err.msg()) }
	defer {
		os.rm(tmp) or {}
		os.rm(tmp + '-wal') or {}
		os.rm(tmp + '-shm') or {}
	}
	res := merge_database(mut app.db, tmp) or { return ctx.fail(.bad_request, err.msg()) }
	return ctx.ok_json(json.encode(res))
}

@['/api/admin/export']
pub fn (mut app App) admin_export(mut ctx Context) veb.Result {
	if gerr := app.admin_guard(mut ctx, true) {
		return app.guard_fail(mut ctx, gerr)
	}
	tmp := os.join_path(os.temp_dir(), 'a2t_export_${now_unix()}_${rand.u32()}.db')
	q(app.db, "VACUUM INTO '${tmp.replace("'", "''")}'") or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	data := os.read_file(tmp) or { return ctx.fail(.internal_server_error, err.msg()) }
	os.rm(tmp) or {}
	stamp := time.now().custom_format('YYYYMMDD-HHmm')
	ctx.set_custom_header('Content-Disposition', 'attachment; filename="aion2tracker-${stamp}.db"') or {}
	ctx.set_header(.cache_control, 'no-store')
	return ctx.send_response_to_client('application/octet-stream', data)
}

// page returns the embedded page; for development, A2T_WEB_DIR makes it read web/*.html from disk.
fn page(embedded string, name string) string {
	dir := os.getenv('A2T_WEB_DIR')
	if dir != '' {
		return os.read_file(os.join_path(dir, name)) or { embedded }
	}
	return embedded
}
