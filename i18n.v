module main

// Backend messages are produced as language-neutral codes (msg(key, args...)) and translated
// per request (X-Lang header / Accept-Language). Codes are also what the worker stores in
// players.last_error, so the admin sees them in their own language.

const msg_mark = '\x01'
const msg_sep = '\x1f'

const messages = {
	'login_required':    ['wymagane logowanie', 'login required']
	'admin_local_only':  ['panel admina jest dostępny tylko z localhost',
		'the admin panel is only available from localhost']
	'login_blocked':     ['za dużo błędnych haseł — spróbuj ponownie za %1 s',
		'too many wrong passwords — try again in %1 s']
	'bad_password_left': ['złe hasło (pozostało prób: %1)', 'wrong password (%1 attempts left)']
	'missing_header':    ['brak nagłówka X-A2T', 'missing X-A2T header']
	'bad_json':          ['nieprawidłowy JSON', 'invalid JSON']
	'bad_password':      ['złe hasło', 'wrong password']
	'need_char_server':  ['podaj nick w grze i serwer', 'enter the character name and server']
	'bad_color':         ['nieprawidłowy kolor', 'invalid color']
	'bad_avatar':        ['nieprawidłowy obrazek avatara', 'invalid avatar image']
	'char_exists':       ['ta postać już jest na liście', 'this character is already on the list']
	'no_player':         ['nie ma takiego gracza', 'player not found']
	'file_too_big':      ['plik za duży (max %1 MB)', 'file too large (max %1 MB)']
	'bad_field':         ['nieprawidłowe pole', 'invalid field']
	'queue_full':        ['kolejka pełna, spróbuj za chwilę',
		'queue is full, try again in a moment']
	'need_team':         ['podaj nazwę i kolor teamu', 'enter a team name and color']
	'team_exists':       ['team o tej nazwie już istnieje', 'a team with this name already exists']
	'bad_mode':          ['nieprawidłowy tryb', 'invalid mode']
	'need_name':         ['podaj nick', 'enter a name']
	'api_error':         ['API AION 2: %1', 'AION 2 API: %1']
	'empty_file':        ['pusty plik', 'empty file']
	'bad_format':        [
		'nieobsługiwany format obrazka (obsługiwane: PNG, JPG, GIF, BMP)',
		'unsupported image format (supported: PNG, JPG, GIF, BMP)',
	]
	'bad_size':          ['nieprawidłowy rozmiar obrazka %1×%2', 'invalid image size %1×%2']
	'encode_failed':     ['nie udało się zakodować obrazka', 'could not encode the image']
	'not_sqlite':        ['to nie jest plik bazy SQLite', 'this is not an SQLite database file']
	'cant_open_import':  ['nie można otworzyć importowanej bazy: %1',
		'cannot open the imported database: %1']
	'missing_table':     [
		'importowana baza nie ma tabeli "%1" — to nie jest baza tego trackera',
		'the imported database has no "%1" table — it is not a tracker database',
	]
	'char_not_found':    ['nie znaleziono postaci "%1" na serwerze %2',
		'character "%1" not found on server %2']
	'empty_info':        ['pusta odpowiedź API (info)', 'empty API response (info)']
	'cycle_result':      ['%1 ok, %2 błędów', '%1 ok, %2 errors']
	'not_data_url':      ['to nie jest data URL', 'not a data URL']
}

// msg builds a translatable message code: msg('char_not_found', name, server).
fn msg(key string, args ...string) string {
	mut s := msg_mark + key
	for a in args {
		s += msg_sep + a
	}
	return s
}

// tr translates a message code (or returns plain text unchanged). Arguments that are
// message codes themselves are translated too.
fn tr(lang string, s string) string {
	if !s.starts_with(msg_mark) {
		return s
	}
	parts := s[1..].split(msg_sep)
	texts := messages[parts[0]] or { return parts.join(' ') }
	mut out := if lang == 'en' { texts[1] } else { texts[0] }
	for i, a in parts[1..] {
		out = out.replace('%${i + 1}', tr(lang, a))
	}
	return out
}

fn norm_lang(l string) string {
	return if l.to_lower().starts_with('en') {
		'en'
	} else if l.to_lower().starts_with('pl') {
		'pl'
	} else {
		''
	}
}

// lang picks the response language: X-Lang header (sent by our pages), then Accept-Language.
fn (ctx &Context) lang() string {
	if l := ctx.req.header.get_custom('X-Lang') {
		n := norm_lang(l)
		if n != '' {
			return n
		}
	}
	al := ctx.req.header.get(.accept_language) or { '' }
	return if norm_lang(al) == 'en' { 'en' } else { 'pl' }
}

// class_of_pc maps the search API's pcId (class × gender/race variants) to a class name.
fn class_of_pc(pc int) string {
	return match pc {
		2, 5, 6, 7, 8 { 'Gladiator' }
		3, 9, 10, 11, 12 { 'Templar' }
		4, 13, 14, 15, 16 { 'Ranger' }
		17, 18, 19, 20 { 'Assassin' }
		21, 22, 23, 24 { 'Spiritmaster' }
		25, 26, 27, 28 { 'Sorcerer' }
		29, 30, 31, 32 { 'Cleric' }
		33, 34, 35, 36 { 'Chanter' }
		45, 46, 47, 48 { 'Brawler' }
		else { '' }
	}
}
