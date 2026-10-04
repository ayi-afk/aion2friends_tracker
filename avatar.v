module main

import stbi
import encoding.base64
import net.http
import time

// Avatars are decoded, center-cropped to a square, resized and re-encoded server-side,
// then stored in the database as a data URL — whatever was uploaded never reaches viewers as-is.
const avatar_size = 192
const avatar_max_upload = 15 * 1024 * 1024
const avatar_max_side = 8000

fn C.stbi_info_from_memory(buffer &u8, len int, x &int, y &int, comp &int) int
fn C.stbi_write_png_to_func(func voidptr, context voidptr, w int, h int, comp int, data voidptr, stride_in_bytes int) int
fn C.stbi_write_jpg_to_func(func voidptr, context voidptr, w int, h int, comp int, data voidptr, quality int) int

fn write_to_buf(context voidptr, data voidptr, size int) {
	mut buf := unsafe { &[]u8(context) }
	unsafe { buf.push_many(data, size) }
}

// make_avatar turns any PNG/JPG/GIF/BMP/TGA/PSD bytes into a square avatar: (mime, image bytes).
fn make_avatar(raw []u8) !(string, []u8) {
	if raw.len == 0 {
		return error(msg('empty_file'))
	}
	if raw.len > avatar_max_upload {
		return error(msg('file_too_big', (avatar_max_upload / 1024 / 1024).str()))
	}
	mut w, mut h, mut comp := 0, 0, 0
	if C.stbi_info_from_memory(raw.data, raw.len, &w, &h, &comp) == 0 {
		return error(msg('bad_format'))
	}
	if w < 8 || h < 8 || w > avatar_max_side || h > avatar_max_side {
		return error(msg('bad_size', w.str(), h.str()))
	}
	img := stbi.load_from_memory(raw.data, raw.len, desired_channels: 4)!
	defer {
		img.free()
	}
	// center crop to a square
	side := if img.width < img.height { img.width } else { img.height }
	x0 := (img.width - side) / 2
	y0 := (img.height - side) / 2
	mut crop := []u8{len: side * side * 4}
	for y in 0 .. side {
		unsafe {
			vmemcpy(&crop[y * side * 4], img.data + ((y0 + y) * img.width + x0) * 4, side * 4)
		}
	}
	src := stbi.Image{
		width:       side
		height:      side
		nr_channels: 4
		ok:          true
		data:        crop.data
	}
	size := if side < avatar_size { side } else { avatar_size }
	out := stbi.resize_uint8(&src, size, size)!
	defer {
		out.free()
	}
	pixels := unsafe { out.data.vbytes(size * size * 4) }

	mut opaque := true
	for i := 3; i < pixels.len; i += 4 {
		if pixels[i] != 255 {
			opaque = false
			break
		}
	}
	mut png := []u8{cap: 64 * 1024}
	if C.stbi_write_png_to_func(voidptr(write_to_buf), &png, size, size, 4, out.data,
		size * 4) == 0 {
		return error(msg('encode_failed'))
	}
	if opaque && png.len > 24 * 1024 {
		// photos compress far better as JPEG; transparency is only kept for PNG
		mut rgb := []u8{len: size * size * 3}
		for i in 0 .. size * size {
			rgb[i * 3] = pixels[i * 4]
			rgb[i * 3 + 1] = pixels[i * 4 + 1]
			rgb[i * 3 + 2] = pixels[i * 4 + 2]
		}
		mut jpg := []u8{cap: 32 * 1024}
		if C.stbi_write_jpg_to_func(voidptr(write_to_buf), &jpg, size, size, 3, rgb.data, 90) != 0
			&& jpg.len < png.len {
			return 'image/jpeg', jpg
		}
	}
	return 'image/png', png
}

// fetch_bytes downloads a binary resource (following redirects), e.g. the in-game portrait.
fn fetch_bytes(url string) ![]u8 {
	mut req := http.new_request(.get, url, '')
	req.add_header(.user_agent, 'aion2tracker/1.0 (+stream CP tracker)')
	req.read_timeout = 20 * time.second
	req.write_timeout = 20 * time.second
	resp := req.do()!
	if resp.status_code != 200 {
		return error('HTTP ${resp.status_code}')
	}
	return resp.body.bytes()
}

// decode_data_url returns the raw bytes of a base64 data URL.
fn decode_data_url(s string) ![]u8 {
	if !s.starts_with('data:') || !s.contains(';base64,') {
		return error(msg('not_data_url'))
	}
	return base64.decode(s.all_after(';base64,'))
}

// ---------- BLOB access ----------
// db.sqlite only binds text and reads text, which mangles binary data, so avatars go through
// a separate raw SQLite connection (WAL mode makes a second connection unproblematic).

fn C.sqlite3_bind_blob(&C.sqlite3_stmt, int, voidptr, int, voidptr) int
fn C.sqlite3_column_blob(&C.sqlite3_stmt, int) voidptr

const sqlite_transient = voidptr(-1) // SQLITE_TRANSIENT: sqlite copies the bound buffer

struct BlobDB {
mut:
	h &C.sqlite3 = unsafe { nil }
}

fn open_blob_db(path string) !BlobDB {
	mut h := &C.sqlite3(unsafe { nil })
	if C.sqlite3_open_v2(&char(path.str), &h, 2, unsafe { nil }) != 0 { // SQLITE_OPEN_READWRITE
		return error('cannot open ${path}')
	}
	C.sqlite3_busy_timeout(h, 15000)
	return BlobDB{h}
}

fn (b &BlobDB) close() {
	C.sqlite3_close(b.h)
}

// avatar_put stores (or replaces) an avatar image of the given kind (0 = upload, 1 = in-game).
fn (b &BlobDB) avatar_put(player_id int, kind int, mime string, data []u8, src string) ! {
	mut st := &C.sqlite3_stmt(unsafe { nil })
	query := 'INSERT OR REPLACE INTO avatars(player_id,kind,mime,data,src,fetched_at) VALUES(?,?,?,?,?,?)'
	if C.sqlite3_prepare_v2(b.h, &char(query.str), -1, &st, unsafe { nil }) != 0 {
		return error('avatar_put: prepare failed')
	}
	defer {
		C.sqlite3_finalize(st)
	}
	C.sqlite3_bind_int64(st, 1, player_id)
	C.sqlite3_bind_int64(st, 2, kind)
	C.sqlite3_bind_text(st, 3, &char(mime.str), mime.len, sqlite_transient)
	C.sqlite3_bind_blob(st, 4, data.data, data.len, sqlite_transient)
	C.sqlite3_bind_text(st, 5, &char(src.str), src.len, sqlite_transient)
	C.sqlite3_bind_int64(st, 6, now_unix())
	if C.sqlite3_step(st) != 101 { // SQLITE_DONE
		return error('avatar_put: ${unsafe { cstring_to_vstring(C.sqlite3_errmsg(b.h)) }}')
	}
}

// avatar_get returns (mime, bytes): the uploaded avatar, else the in-game one
// (only the in-game one when game_only).
fn (b &BlobDB) avatar_get(player_id int, game_only bool) ?(string, []u8) {
	mut st := &C.sqlite3_stmt(unsafe { nil })
	query := if game_only {
		'SELECT mime, data FROM avatars WHERE player_id=? AND kind=1'
	} else {
		'SELECT mime, data FROM avatars WHERE player_id=? ORDER BY kind LIMIT 1'
	}
	if C.sqlite3_prepare_v2(b.h, &char(query.str), -1, &st, unsafe { nil }) != 0 {
		return none
	}
	defer {
		C.sqlite3_finalize(st)
	}
	C.sqlite3_bind_int64(st, 1, player_id)
	if C.sqlite3_step(st) != 100 { // SQLITE_ROW
		return none
	}
	mime := unsafe { cstring_to_vstring(&char(C.sqlite3_column_text(st, 0))) }
	n := C.sqlite3_column_bytes(st, 1)
	data := unsafe { (&u8(C.sqlite3_column_blob(st, 1))).vbytes(n) }.clone()
	return mime, data
}
