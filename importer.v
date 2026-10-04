module main

import db.sqlite
import os

struct ImportResult {
	teams_added   int
	players_added int
	samples_added int
	samples_total int
}

// merge_database merges another tracker database file into `db`.
// Teams are matched by name, players by (server, character name), samples by (player, timestamp),
// so importing the same file twice is a no-op and two collectors' histories interleave by time.
fn merge_database(mut db sqlite.DB, file string) !ImportResult {
	mut f := os.open(file)!
	mut header := []u8{len: 16}
	f.read(mut header) or {}
	f.close()
	if header[..15].bytestr() != 'SQLite format 3' {
		return error(msg('not_sqlite'))
	}
	// bring an older tracker db (the uploaded temp copy) up to the current schema first
	mut idb := open_db(file) or { return error(msg('cant_open_import', err.msg())) }
	idb.close() or {}
	path := file.replace("'", "''")
	q(db, "ATTACH DATABASE '${path}' AS imp") or {
		return error(msg('cant_open_import', err.msg()))
	}
	defer {
		db.exec_none('DETACH DATABASE imp')
	}
	for t in ['players', 'samples', 'teams'] {
		n := q(db, "SELECT count(*) FROM imp.sqlite_master WHERE type='table' AND name=?",
			t)!
		if n.len == 0 || n[0].vals[0] == '0' {
			return error(msg('missing_table', t))
		}
	}
	total := q(db, 'SELECT count(*) FROM imp.samples')![0].vals[0].int()

	q(db, 'BEGIN IMMEDIATE')!
	mut committed := false
	defer {
		if !committed {
			db.exec_none('ROLLBACK')
		}
	}
	q(db, 'INSERT OR IGNORE INTO teams(name,color,sort) SELECT name,color,sort FROM imp.teams')!
	teams_added := db.get_affected_rows_count()

	q(db, 'INSERT OR IGNORE INTO players(display_name,char_name,server_id,server_name,character_id,team_id,color,avatar_ver,profile_image,class_name,level,active,visible,sort,last_ok_at,created_at)
		SELECT ip.display_name, ip.char_name, ip.server_id, ip.server_name, ip.character_id,
			(SELECT t.id FROM teams t JOIN imp.teams it ON it.name = t.name WHERE it.id = ip.team_id),
			ip.color, ip.avatar_ver, ip.profile_image, ip.class_name, ip.level,
			ip.active, ip.visible, ip.sort, ip.last_ok_at, ip.created_at
		FROM imp.players ip')!
	players_added := db.get_affected_rows_count()

	// imported player id -> local player id (same server + character name)
	map_sql := 'JOIN imp.players ip ON ip.id = x.player_id JOIN players p ON p.server_id = ip.server_id AND p.char_name = ip.char_name'

	// avatars the local db does not have yet
	q(db, 'INSERT OR IGNORE INTO avatars(player_id,kind,mime,data,src,fetched_at)
		SELECT p.id, x.kind, x.mime, x.data, x.src, x.fetched_at FROM imp.avatars x ${map_sql}')!

	// dictionaries are matched by name
	q(db, 'INSERT OR IGNORE INTO boards(name,total) SELECT name,total FROM imp.boards')!
	q(db, 'INSERT OR IGNORE INTO skills(name) SELECT name FROM imp.skills')!

	q(db, 'INSERT OR IGNORE INTO samples(player_id,ts,cp,item_level,level,dv_total,god_total,w_enchant,w_exceed,stigma_total)
		SELECT p.id, x.ts, x.cp, x.item_level, x.level, x.dv_total, x.god_total, x.w_enchant, x.w_exceed, x.stigma_total
		FROM imp.samples x ${map_sql}')!
	samples_added := db.get_affected_rows_count()

	q(db, 'INSERT OR IGNORE INTO sample_gods(player_id,ts,${god_cols.join(',')})
		SELECT p.id, x.ts, ${god_cols.map(
		'x.' + it).join(',')} FROM imp.sample_gods x ${map_sql}')!
	q(db, 'INSERT OR IGNORE INTO sample_weapon(player_id,ts,item_id,name,grade,enchant,exceed,max_enchant,attack)
		SELECT p.id, x.ts, x.item_id, x.name, x.grade, x.enchant, x.exceed, x.max_enchant, x.attack
		FROM imp.sample_weapon x ${map_sql}')!
	q(db, 'INSERT OR IGNORE INTO sample_boards(player_id,ts,board_id,open)
		SELECT p.id, x.ts, b.id, x.open FROM imp.sample_boards x ${map_sql}
		JOIN imp.boards ib ON ib.id = x.board_id JOIN boards b ON b.name = ib.name')!
	q(db, 'INSERT OR IGNORE INTO sample_stigmas(player_id,ts,skill_id,level,equipped)
		SELECT p.id, x.ts, k.id, x.level, x.equipped FROM imp.sample_stigmas x ${map_sql}
		JOIN imp.skills ik ON ik.id = x.skill_id JOIN skills k ON k.name = ik.name')!

	q(db, 'COMMIT')!
	committed = true
	return ImportResult{teams_added, players_added, samples_added, total}
}
