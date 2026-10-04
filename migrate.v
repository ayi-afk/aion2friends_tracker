module main

import db.sqlite
import json

// Shapes of the JSON columns used by schema v1/v2 (only read during migration).
struct LegacyBoard {
	n string
	o int
	t int
}

struct LegacyGod {
	n string // "Justice [Nezekan]"
	v int
}

struct LegacyStigma {
	n string
	l int
	e int
}

struct LegacyAvatar {
	player_id int
	kind      int
	data_url  string
	src       string
}

// migrate_to_v3 converts a v1/v2 database (JSON columns, a row every 15 min, base64 avatars in
// the players table) to v3: plain columns, change-only rows, avatars as BLOBs.
fn migrate_to_v3(mut db sqlite.DB, path string) ! {
	println('[db] migracja bazy do schematu v3 (bez JSON, zapis tylko zmian)…')
	pcols := q(db, "SELECT name FROM pragma_table_info('players')")!.map(it.vals[0])
	q(db, 'PRAGMA foreign_keys=OFF')!
	q(db, 'BEGIN IMMEDIATE')!
	mut committed := false
	defer {
		if !committed {
			db.exec_none('ROLLBACK')
		}
		db.exec_none('PRAGMA foreign_keys=ON')
	}

	// meta becomes WITHOUT ROWID
	q(db, 'ALTER TABLE meta RENAME TO meta_v2')!
	q(db, 'ALTER TABLE samples RENAME TO samples_v2')!
	for s in schema_v3 {
		q(db, s)!
	}
	q(db, 'INSERT OR REPLACE INTO meta(key,value) SELECT key,value FROM meta_v2')!
	q(db, 'DROP TABLE meta_v2')!

	// samples: rebuild the full state per row, keep only rows where something changed
	mut kept := 0
	mut total := 0
	mut spikes := 0
	for pr in q(db, 'SELECT DISTINCT player_id FROM samples_v2')! {
		pid := pr.vals[0].int()
		mut prev := ?State(none)
		mut streak := 0
		for r in q(db, 'SELECT ts,cp,item_level,level,dv_json,god_json,w_name,w_grade,w_enchant,w_exceed,w_max_enchant,w_attack,stigma_json FROM samples_v2 WHERE player_id=? ORDER BY ts',
			pid.str())! {
			v := r.vals
			total++
			mut st := State{
				cp:         v[1].i64()
				item_level: v[2].int()
				level:      v[3].int()
				gods:       []int{len: god_cols.len}
				weapon:     WeaponVal{
					name:        v[6]
					grade:       v[7]
					enchant:     v[8].int()
					exceed:      v[9].int()
					max_enchant: v[10].int()
					attack:      v[11]
				}
			}
			for b in json.decode([]LegacyBoard, v[4]) or { []LegacyBoard{} } {
				st.boards << BoardVal{b.n, b.o, b.t}
			}
			for g in json.decode([]LegacyGod, v[5]) or { []LegacyGod{} } {
				idx := god_cols.index(g.n.all_before(' [').to_lower())
				if idx >= 0 {
					st.gods[idx] = g.v
				}
			}
			for x in json.decode([]LegacyStigma, v[12]) or { []LegacyStigma{} } {
				if x.l > 0 {
					st.stigmas << StigmaVal{x.n, x.l, x.e == 1}
				}
			}
			st.stigmas.sort(a.name < b.name)
			// drop PvP-event CP spikes from the history too
			prev_cp := if p := prev { p.cp } else { i64(0) }
			if is_cp_spike(prev_cp, st.cp) && streak + 1 < cp_spike_accept_after {
				streak++
				spikes++
				continue
			}
			streak = 0
			if save_state(mut db, pid, v[0].i64(), st, prev)! {
				kept++
			}
			prev = st
		}
	}
	q(db, 'DROP TABLE samples_v2')!

	// avatars: base64 data URLs in players -> BLOB rows (written after the commit)
	mut avatars := []LegacyAvatar{}
	if 'avatar' in pcols {
		for r in q(db, "SELECT id, avatar FROM players WHERE avatar<>''")! {
			avatars << LegacyAvatar{r.vals[0].int(), 0, r.vals[1], ''}
		}
	}
	if 'game_avatar' in pcols {
		for r in q(db, "SELECT id, game_avatar, game_avatar_src FROM players WHERE game_avatar<>''")! {
			avatars << LegacyAvatar{r.vals[0].int(), 1, r.vals[1], r.vals[2]}
		}
	}
	for c in ['avatar', 'game_avatar', 'game_avatar_src', 'game_avatar_at'] {
		if c in pcols {
			q(db, 'ALTER TABLE players DROP COLUMN ${c}')!
		}
	}
	q(db, 'PRAGMA user_version=${schema_version}')!
	q(db, 'COMMIT')!
	committed = true

	if avatars.len > 0 {
		mut bdb := open_blob_db(path)!
		for a in avatars {
			raw := decode_data_url(a.data_url) or { continue }
			mime := a.data_url.all_after('data:').all_before(';')
			bdb.avatar_put(a.player_id, a.kind, mime, raw, a.src) or {
				eprintln('[db] avatar ${a.player_id}: ${err}')
			}
		}
		bdb.close()
	}
	db.exec_none('VACUUM')
	println('[db] migracja gotowa: próbek ${total} -> ${kept} (zapisane tylko zmiany), usunięte spike CP: ${spikes}, avatary: ${avatars.len}')
}
