module main

import net.http
import net.urllib
import json
import time

// Official AION 2 (global) web API — the same endpoints shugo.gg proxies.
const api_base = 'https://aion2.plaync.com'
const search_base = 'https://api-search.plaync.com/aion2global/search/v2/character'
const api_lang = 'en-US'
const regions = ['eu', 'nae', 'naw', 'la', 'as']

// region_of maps a global server id (e.g. 2305) to its region code; the 2nd digit is the region.
fn region_of(server_id int) string {
	s := server_id.str()
	if s.len != 4 || (s[0] != `1` && s[0] != `2`) {
		return 'eu'
	}
	return match s[1] {
		`1` { 'nae' }
		`2` { 'naw' }
		`3` { 'eu' }
		`4` { 'la' }
		`5` { 'as' }
		else { 'eu' }
	}
}

// ---------- raw API shapes (only the fields we use) ----------

struct ApiServer {
	race_id     int    @[json: 'raceId']
	server_id   int    @[json: 'serverId']
	server_name string @[json: 'serverName']
}

struct ApiServerList {
	server_list []ApiServer @[json: 'serverList']
}

struct ApiSearchHit {
pub mut:
	character_id      string @[json: 'characterId']
	name              string
	race              int
	pc_id             int @[json: 'pcId']
	level             int
	server_id         int    @[json: 'serverId']
	server_name       string @[json: 'serverName']
	profile_image_url string @[json: 'profileImageUrl']
	region            string
	class_name        string @[json: 'className']
}

struct ApiSearch {
	list []ApiSearchHit
}

struct ApiProfile {
	character_id    string @[json: 'characterId']
	character_level int    @[json: 'characterLevel']
	character_name  string @[json: 'characterName']
	class_name      string @[json: 'className']
	combat_power    i64    @[json: 'combatPower']
	profile_image   string @[json: 'profileImage']
	server_name     string @[json: 'serverName']
}

struct ApiStat {
	name  string
	typ   string @[json: 'type']
	value int
}

struct ApiStatWrap {
	stat_list []ApiStat @[json: 'statList']
}

struct ApiBoard {
	id               int
	name             string
	open_node_count  int @[json: 'openNodeCount']
	total_node_count int @[json: 'totalNodeCount']
}

struct ApiDaevanion {
	board_list []ApiBoard @[json: 'boardList']
}

struct ApiInfo {
	profile   ApiProfile
	stat      ApiStatWrap
	daevanion ApiDaevanion
}

struct ApiEquip {
	id            i64
	name          string
	grade         string
	enchant_level int    @[json: 'enchantLevel']
	exceed_level  int    @[json: 'exceedLevel']
	slot_pos      int    @[json: 'slotPos']
	slot_pos_name string @[json: 'slotPosName']
}

struct ApiEquipWrap {
	equipment_list []ApiEquip @[json: 'equipmentList']
}

struct ApiSkill {
	category    string
	name        string
	skill_level int @[json: 'skillLevel']
	equip       int
	acquired    int
}

struct ApiSkillWrap {
	skill_list []ApiSkill @[json: 'skillList']
}

struct ApiEquipment {
	equipment ApiEquipWrap
	skill     ApiSkillWrap
}

struct ApiItemStat {
	id    string
	name  string
	value string
	extra string
}

struct ApiItem {
	max_enchant_level int           @[json: 'maxEnchantLevel']
	main_stats        []ApiItemStat @[json: 'mainStats']
}

// ---------- HTTP ----------

fn api_get(url string) !string {
	mut last_err := ''
	for attempt in 0 .. 3 {
		if attempt > 0 {
			time.sleep(time.second * (3 * attempt))
		}
		mut req := http.new_request(.get, url, '')
		req.add_header(.user_agent, 'aion2tracker/1.0 (+stream CP tracker)')
		req.add_header(.accept, 'application/json')
		req.read_timeout = 20 * time.second
		req.write_timeout = 20 * time.second
		resp := req.do() or {
			last_err = err.msg()
			continue
		}
		if resp.status_code == 200 {
			return resp.body
		}
		if resp.status_code == 429 || resp.status_code >= 500 {
			last_err = 'HTTP ${resp.status_code}'
			continue
		}
		return error('HTTP ${resp.status_code}')
	}
	return error(last_err)
}

fn fetch_servers(region string) ![]ApiServer {
	body := api_get('${api_base}/en-us/api/gameinfo/servers?lang=${api_lang}&region=${region}')!
	return json.decode(ApiServerList, body)!.server_list
}

fn strip_tags(s string) string {
	mut out := []u8{cap: s.len}
	mut in_tag := false
	for c in s {
		if c == `<` {
			in_tag = true
		} else if c == `>` {
			in_tag = false
		} else if !in_tag {
			out << c
		}
	}
	return out.bytestr()
}

// search_region queries one region (the global search API refuses requests without a region).
fn search_region(name string, region string, server_id int) ![]ApiSearchHit {
	sid := if server_id > 0 { server_id.str() } else { '' }
	body := api_get('${search_base}?keyword=${urllib.query_escape(name)}&page=1&size=30&localeInfo=${api_lang}&region=${region}&serverId=${sid}')!
	mut hits := json.decode(ApiSearch, body)!.list.clone()
	for mut h in hits {
		h.name = strip_tags(h.name)
		h.character_id = urllib.query_unescape(h.character_id) or { h.character_id }
		if h.profile_image_url.starts_with('/') {
			h.profile_image_url = 'https://profileimg.plaync.com' + h.profile_image_url
		}
		if h.region == '' {
			h.region = region_of(h.server_id)
		}
		h.class_name = class_of_pc(h.pc_id)
	}
	return hits
}

// search_characters searches one server, or — with server_id == 0 — every region in parallel
// (like shugo.gg's "Global"). Exact name matches come first, then higher levels.
fn search_characters(name string, server_id int) ![]ApiSearchHit {
	if server_id > 0 {
		return search_region(name, region_of(server_id), server_id)
	}
	mut threads := []thread ![]ApiSearchHit{}
	for r in regions {
		threads << spawn search_region(name, r, 0)
	}
	mut all := []ApiSearchHit{}
	mut last_err := ''
	mut ok := 0
	for t in threads {
		hits := t.wait() or {
			last_err = err.msg()
			continue
		}
		ok++
		all << hits
	}
	if ok == 0 {
		return error(last_err)
	}
	lname := name.to_lower()
	all.sort_with_compare(fn [lname] (a &ApiSearchHit, b &ApiSearchHit) int {
		ea := a.name.to_lower() == lname
		eb := b.name.to_lower() == lname
		if ea != eb {
			return if ea { -1 } else { 1 }
		}
		return b.level - a.level
	})
	return all
}

// resolve_character finds the exact (case-insensitive) character on the given server.
fn resolve_character(name string, server_id int) !ApiSearchHit {
	hits := search_characters(name, server_id)!
	for h in hits {
		if h.server_id == server_id && h.name.to_lower() == name.to_lower() {
			return h
		}
	}
	return error(msg('char_not_found', name, server_id.str()))
}

fn char_query(character_id string, server_id int) string {
	return 'lang=${api_lang}&characterId=${urllib.query_escape(character_id)}&serverId=${server_id}&region=${region_of(server_id)}'
}

// fetch_state downloads info + equipment of one character and condenses them into a State.
// The weapon detail endpoint (max enchant + attack) is only called when the weapon changed
// compared to `prev_weapon`.
fn fetch_state(character_id string, server_id int, prev_weapon WeaponVal) !(State, ApiProfile) {
	q := char_query(character_id, server_id)
	info_body := api_get('${api_base}/api/character/info?${q}')!
	info := json.decode(ApiInfo, info_body)!
	if info.profile.character_name == '' {
		return error(msg('empty_info'))
	}
	time.sleep(400 * time.millisecond)
	eq_body := api_get('${api_base}/api/character/equipment?${q}')!
	eq := json.decode(ApiEquipment, eq_body)!

	mut s := State{
		cp:    info.profile.combat_power
		level: info.profile.character_level
		gods:  []int{len: god_cols.len}
	}
	for st in info.stat.stat_list {
		if st.typ == 'ItemLevel' {
			s.item_level = st.value
			continue
		}
		// god stats: type "Justice", name "Justice [Nezekan]"
		idx := god_cols.index(st.typ.to_lower())
		if idx >= 0 {
			s.gods[idx] = st.value
		}
	}
	for b in info.daevanion.board_list {
		s.boards << BoardVal{b.name, b.open_node_count, b.total_node_count}
	}
	for sk in eq.skill.skill_list {
		if sk.category == 'Dp' && sk.skill_level > 0 { // Dp = stigma ("specialty") skills
			s.stigmas << StigmaVal{sk.name, sk.skill_level, sk.equip == 1}
		}
	}
	s.stigmas.sort(a.name < b.name)

	for it in eq.equipment.equipment_list {
		if it.slot_pos_name != 'MainHand' && it.slot_pos != 1 {
			continue
		}
		mut max_ench := prev_weapon.max_enchant
		mut attack := prev_weapon.attack
		if it.id != prev_weapon.item_id || it.enchant_level != prev_weapon.enchant
			|| it.exceed_level != prev_weapon.exceed {
			time.sleep(400 * time.millisecond)
			item_body := api_get('${api_base}/api/character/equipment/item?id=${it.id}&enchantLevel=${it.enchant_level}&${q}&slotPos=${it.slot_pos}') or {
				''
			}
			if item := json.decode(ApiItem, item_body) {
				max_ench = item.max_enchant_level
				attack = ''
				for ms in item.main_stats {
					if ms.id == 'WeaponFixingDamage' {
						attack = if ms.extra != '' && ms.extra != '0' {
							'${ms.value} (+${ms.extra})'
						} else {
							ms.value
						}
					}
				}
			}
		}
		s.weapon = WeaponVal{
			item_id:     it.id
			name:        it.name
			grade:       it.grade
			enchant:     it.enchant_level
			exceed:      it.exceed_level
			max_enchant: max_ench
			attack:      attack
		}
		break
	}
	return s, info.profile
}
