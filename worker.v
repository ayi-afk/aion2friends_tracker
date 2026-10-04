module main

import db.sqlite
import time

// Trigger values sent over the worker channel: a player id fetches just that player,
// trigger_all starts a full cycle immediately.
const trigger_all = 0

struct WorkerCfg {
	db_path      string
	interval_min int
	trigger      chan int
}

// FetchResult is what one fetch produced; results are written to the db in one transaction
// per cycle, so a cycle costs a handful of page writes instead of several commits per player.
struct FetchResult {
	player    Player
	ok        bool
	error     string
	ts        i64
	state     State
	profile   ApiProfile
	char_id   string
	server_nm string
	resolved  bool
}

struct Worker {
mut:
	db      sqlite.DB
	blobs   BlobDB
	states  map[int]State // last stored state per player (lazily loaded)
	spikes  map[int]int   // consecutive CP-spike reads per player (see is_cp_spike)
	skipped map[int]bool  // players whose last read was skipped as a spike (state cache stays)
}

fn worker_loop(cfg WorkerCfg) {
	mut w := Worker{
		db:    open_db(cfg.db_path) or {
			eprintln('[worker] cannot open db: ${err}')
			return
		}
		blobs: open_blob_db(cfg.db_path) or {
			eprintln('[worker] cannot open db: ${err}')
			return
		}
	}
	interval := i64(cfg.interval_min) * 60
	meta_set(w.db, 'interval_sec', interval.str())

	// At startup only refresh players whose data is stale, so restarts don't spam the API.
	w.run_cycle(interval - 60)
	for {
		next := (now_unix() / interval + 1) * interval // aligned to :00/:15/:30/:45
		meta_set(w.db, 'worker_next_cycle', next.str())
		mut full_now := false
		for !full_now {
			rem := next - now_unix()
			if rem <= 0 {
				break
			}
			select {
				id := <-cfg.trigger {
					if id == trigger_all {
						full_now = true
					} else if p := get_player(w.db, id) {
						res := w.fetch(p)
						w.store([res])
					}
				}
				rem * time.second {}
			}
		}
		w.run_cycle(0)
	}
}

// run_cycle fetches all active players; players with a successful fetch newer than
// `skip_fresher_than` seconds are skipped (0 = fetch everybody).
fn (mut w Worker) run_cycle(skip_fresher_than i64) {
	started := now_unix()
	meta_set(w.db, 'worker_cycle_started', started.str())
	mut results := []FetchResult{}
	for p in list_players(w.db, false).filter(it.active) {
		if skip_fresher_than > 0 && started - p.last_ok_at < skip_fresher_than {
			continue
		}
		results << w.fetch(p)
		time.sleep(1200 * time.millisecond) // be polite to the official API
	}
	changed := w.store(results)
	ok := results.filter(it.ok).len
	failed := results.len - ok
	tx(mut w.db, fn [started, ok, failed] (mut db sqlite.DB) ! {
		meta_set(db, 'worker_last_cycle', started.str())
		meta_set(db, 'worker_last_cycle_end', now_unix().str())
		meta_set(db, 'worker_last_result', msg('cycle_result', ok.str(), failed.str()))
	}) or { eprintln('[worker] meta: ${err}') }
	if results.len > 0 {
		println('[worker] ${time.now().format_ss()} cykl: ${tr('pl', msg('cycle_result',
			ok.str(), failed.str()))}, zmian zapisanych: ${changed}')
	}
}

// fetch talks to the API only (no db writes).
fn (mut w Worker) fetch(p Player) FetchResult {
	mut char_id := p.character_id
	mut server_nm := p.server_name
	mut resolved := false
	for attempt in 0 .. 2 {
		if char_id == '' {
			hit := resolve_character(p.char_name, p.server_id) or {
				return FetchResult{
					player: p
					error:  err.msg()
				}
			}
			char_id = hit.character_id
			server_nm = hit.server_name
			resolved = true
		}
		prev := w.prev_state(p.id) or { State{} }
		st, prof := fetch_state(char_id, p.server_id, prev.weapon) or {
			// 404 usually means the character id rotated (rename / transfer): re-resolve once
			if err.msg().contains('404') && !resolved && attempt == 0 {
				char_id = ''
				continue
			}
			eprintln('[worker] ${p.char_name}@${p.server_id}: ${tr('pl', err.msg())}')
			return FetchResult{
				player:    p
				error:     err.msg()
				char_id:   char_id
				server_nm: server_nm
				resolved:  resolved
			}
		}
		return FetchResult{
			player:    p
			ok:        true
			ts:        now_unix()
			state:     st
			profile:   prof
			char_id:   char_id
			server_nm: if prof.server_name != '' { prof.server_name } else { server_nm }
			resolved:  resolved
		}
	}
	return FetchResult{
		player: p
		error:  msg('char_not_found', p.char_name, p.server_id.str())
	}
}

fn (mut w Worker) prev_state(player_id int) ?State {
	if st := w.states[player_id] {
		return st
	}
	st := load_state(w.db, player_id)?
	w.states[player_id] = st
	return st
}

// store writes a batch of results in one transaction: a sample (and changed detail sets) only
// where the data changed, plus the players' status. Returns how many players had changes.
fn (mut w Worker) store(results []FetchResult) int {
	if results.len == 0 {
		return 0
	}
	mut prevs := map[int]State{}
	mut has_prev := map[int]bool{}
	for r in results {
		if r.ok {
			if st := w.prev_state(r.player.id) {
				prevs[r.player.id] = st
				has_prev[r.player.id] = true
			}
		}
	}
	changed := w.store_tx(results, prevs, has_prev) or {
		w.db.exec_none('ROLLBACK')
		eprintln('[worker] zapis do bazy: ${err}')
		return 0
	}
	for r in results {
		if r.ok {
			if !w.skipped[r.player.id] {
				w.states[r.player.id] = r.state
			}
			w.refresh_game_avatar(r.player, r.profile.profile_image)
		}
	}
	w.skipped.clear()
	return changed
}

fn (mut w Worker) store_tx(results []FetchResult, prevs map[int]State, has_prev map[int]bool) !int {
	mut changed := 0
	q(w.db, 'BEGIN IMMEDIATE')!
	for r in results {
		pid := r.player.id.str()
		if !r.ok {
			q(w.db, "UPDATE players SET last_try_at=?, last_error=?, character_id=CASE WHEN ?<>'' THEN ? ELSE character_id END WHERE id=?",
				now_unix().str(), r.error, r.char_id, r.char_id, pid)!
			continue
		}
		prev := if has_prev[r.player.id] { ?State(prevs[r.player.id]) } else { ?State(none) }
		prev_cp := if has_prev[r.player.id] { prevs[r.player.id].cp } else { i64(0) }
		streak := w.spikes[r.player.id]
		if is_cp_spike(prev_cp, r.state.cp) && streak + 1 < cp_spike_accept_after {
			w.spikes[r.player.id] = streak + 1
			w.skipped[r.player.id] = true
			println('[worker] ${r.player.char_name}: CP ${prev_cp} -> ${r.state.cp} wygląda na event (spike), pomijam odczyt (${
				streak + 1}/${cp_spike_accept_after})')
		} else {
			w.spikes.delete(r.player.id)
			if save_state(mut w.db, r.player.id, r.ts, r.state, prev)! {
				changed++
			}
		}
		q(w.db, "UPDATE players SET character_id=?, server_name=?, class_name=?, level=?, profile_image=?, last_ok_at=?, last_try_at=?, last_error='' WHERE id=?",
			r.char_id, r.server_nm, r.profile.class_name, r.profile.character_level.str(),
			r.profile.profile_image, r.ts.str(), r.ts.str(), pid)!
	}
	q(w.db, 'COMMIT')!
	return changed
}

// refresh_game_avatar keeps a resized copy of the in-game portrait in the db, so the chart
// never hotlinks the game's CDN. Refreshed when the URL changes or once a day; the version is
// only bumped (cache-busting) when the picture actually changed.
fn (mut w Worker) refresh_game_avatar(p Player, url string) {
	if url == '' || (url == p.game_avatar_src && now_unix() - p.game_avatar_at < 86400) {
		return
	}
	raw := fetch_bytes(url) or {
		eprintln('[worker] portret ${p.char_name}: ${tr('pl', err.msg())}')
		return
	}
	mime, data := make_avatar(raw) or {
		eprintln('[worker] portret ${p.char_name}: ${tr('pl', err.msg())}')
		return
	}
	if old_mime, old := w.blobs.avatar_get(p.id, true) {
		if old_mime == mime && old == data {
			// same picture: only remember that it was checked
			q(w.db, 'UPDATE avatars SET fetched_at=?, src=? WHERE player_id=? AND kind=1',
				now_unix().str(), url, p.id.str()) or {}
			return
		}
	}
	w.blobs.avatar_put(p.id, 1, mime, data, url) or {
		eprintln('[worker] portret ${p.char_name}: ${err}')
		return
	}
	q(w.db, 'UPDATE players SET avatar_ver=avatar_ver+1 WHERE id=?', p.id.str()) or {}
}
