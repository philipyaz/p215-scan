# Canon imageFORMULA P-215II — SCSI scan sequence, ported from SANE `canon_dr`

**Source of truth:** `backend/canon_dr.c`, `backend/canon_dr-cmd.h`, `backend/canon_dr.h`,
`backend/canon_dr.conf.in` from `sane-project/backends` @ `master`, fetched and read in full.
All line numbers below refer to that `master` checkout (canon_dr.c = 9418 lines, v65-era).

**Device path taken:** `init_model()` at `canon_dr.c:1676`:

```c
else if (strstr (s->model_name, "P-215") || strstr (s->model_name,"DR-P215")){
    s->color_interlace[SIDE_FRONT] = COLOR_INTERLACE_rRgGbB;   /* 6 */
    s->color_interlace[SIDE_BACK]  = COLOR_INTERLACE_RRGGBB;   /* 5 */
    s->gray_interlace[SIDE_FRONT]  = GRAY_INTERLACE_gG;        /* 2 */
    s->duplex_interlace            = DUPLEX_INTERLACE_FBfb;    /* 2 */
    s->duplex_offset_side          = SIDE_BACK;
    s->need_ccal = 1;  s->invert_tly = 1;  s->unknown_byte2 = 0x88;
    s->rgb_format = 1; s->has_ssm_pay_head_len = 1;
    s->ppl_mod = 8;    s->ccal_version = 3;
    s->can_read_sensors = 1; s->has_card = 1;
}
```

`"P-215II"` contains `"P-215"`, so `strstr` matches — confirmed, this is the block.

### Flags NOT set here — and it matters

The P-215 block does **not** set `fcal_src` or `fcal_dest`. Both stay `0`
(`FCAL_SRC_NONE` / `FCAL_DEST_NONE`, `canon_dr.h:228-234`). Compare the P-208
block immediately above (`canon_dr.c:1658-1675`) which *does* set
`FCAL_SRC_SCAN` / `FCAL_DEST_SW` (added in v60: *"enable fine calibration for
P-208 (per @sashacmc in !546)"*, changelog line 348).

**Consequence: the P-215 does no fine calibration at all.** See §6.

Other relevant defaults, all from `init_model()` head (`canon_dr.c:1392-1425`) and
`init_user()` (`canon_dr.c:2126`), none overridden by the P-215 block:

| field | value | effect |
|---|---|---|
| `always_op` | 1 | OBJECT POSITION is issued on every page |
| `has_ssm` | 1, `has_ssm2` = 0 | uses SET SCAN MODE `0xd6`, never `0xe5` |
| `has_df` | 1 | SSM double-feed page is sent |
| `has_btc` | 1 | brightness/threshold/contrast go in the window |
| `has_adf`, `has_duplex`, `has_buffer` | 1 | — |
| `can_read_panel`, `can_write_panel` | 1 | — |
| `reverse_by_mode[]` | LA=1, HT=1, **GS=0, COLOR=0** | no inversion in gray/colour |
| `rif`, `padding` | 0 (never assigned anywhere) | window byte 0x1d bits 7 and 2-0 = 0 |
| `bg_color` | 0xee | fill colour for short pages |
| `fixed_width` | 0 | window is centred, not forced full-width |
| `even_Bpl`, `hwcrop`, `sw_lut`, `has_comp_JPEG` | 0 | — |
| `threshold` | 90 (0x5a) | window byte 0x17 |
| `brightness`, `contrast` | 0 → written as 128 (0x80) | window bytes 0x16, 0x18 |
| `buffer_size` | 2 MiB (`canon_dr.c:475`) | READ chunk size — matches your window |
| `duplex_offset` | **see §5.5 — config-file artifact** | |

**Max CDB length used on the P-215 path is 10 bytes** (SET WINDOW, READ, SEND,
OBJECT POSITION, COR CAL). The 12-byte `SET/GET SCAN MODE 2` commands are only
reached when `has_ssm2` is set, which the P-215 never sets. Your 12-byte CDB
limit is not a constraint.

**Largest data-out on the P-215 path is 52 bytes** (SET WINDOW). Everything else
is ≤ 40 bytes. Your small-data-out limit is not a constraint either — *provided*
you do not try to implement `FCAL_DEST_HW` fine calibration, which the P-215
does not use anyway (that one would be `width*2+4` ≈ 5 KB).

---

## 1. Initialisation sequence

### 1.1 What `canon_dr` actually sends, in order

Two phases: **attach** (once, `attach_one()` at `canon_dr.c:932`) and **open**
(`sane_open()` at `canon_dr.c:2225`, which is just `connect_fd()`).

| # | Where | Command | CDB (hex) | Data | Required? |
|---|---|---|---|---|---|
| 1 | `connect_fd`→`wait_scanner` (`8917`) | TEST UNIT READY | `00 00 00 00 00 00` | — | **REQUIRED** |
| 2 | `init_inquire` (`1138`) | INQUIRY std | `12 00 00 00 30 00` | in 0x30 | informational |
| 3 | `init_vpd` (`1222`) | INQUIRY EVPD page 0xF0 | `12 01 F0 00 1E 00` | in 0x1e | informational* |
| 4 | `init_imprinters`→`detect_imprinter` (`5341`) | READ imprinter | `28 00 96 00 00 00 00 00 20 00` | in 0x20 | optional (fails harmlessly) |
| 5 | `init_panel`→`read_panel` (`4708`) | READ panel | `28 00 84 00 00 00 00 00 08 00` | in 0x08 | optional |
| 6 | `init_panel`→`send_panel` (`4770`) | SEND panel | `2A 00 84 00 00 00 00 00 08 00` | out 8 | optional |
| 7 | `init_counters`→`read_counters` (`4609`) | READ counters | `28 00 8C 00 00 00 00 00 80 00` | in 0x80 | optional |

\* VPD is only "informational" in the sense that the scanner doesn't require it.
The *host* needs `max_x`, `max_y`, `basic_x_res` and the `std_res_*` bitmap from
it to compute the window (`canon_dr.c:1346-1350`). You can hardcode these once
you've read them.

`sane_open()` then re-runs `connect_fd()` → another TEST UNIT READY.

### 1.2 Commands that `canon_dr` NEVER sends

These are **defined in `canon_dr-cmd.h` but have zero call sites in `canon_dr.c`.**
I grepped for each; all returned nothing:

- **RESERVE UNIT `0x16`** — never sent. You do not need it.
- **RELEASE UNIT `0x17`** — never sent. You do not need it.
- **GET SCAN MODE `0xd5`** — never sent. (`GET_SCAN_MODE_code` has no call site.)
- **GET WINDOW `0x25`** — never sent.
- **MODE SELECT `0x15` / MODE SENSE `0x1a`** — not even defined. Canon uses the
  vendor `0xd6` SET SCAN MODE instead.
- **SEND LUT (`0x2a` datatype `0x03`)** — defined (`S_LUT_*`), no call site.

So: the answer to *"does the P-215 need RESERVE UNIT / GET SCAN MODE / MODE
SELECT before a scan?"* is **no**. SANE never issues them and scans work.

### 1.3 `wait_scanner()` — the TUR retry ritual (`canon_dr.c:8917`)

Worth copying verbatim, it exists because these devices are flaky after an
unclean close:

1. TUR with `runRS=0`
2. on failure: TUR again
3. on failure: TUR again
4. on failure: TUR **with `runRS=1`** (i.e. follow with REQUEST SENSE — this is
   what wakes a sleeping unit)
5. on failure: TUR again

Called from `connect_fd()` (`1117`), after the initial eject in `sane_start()`
(`5450`), and after the page-feed OBJECT POSITION (`5574`).

### 1.4 Strictly required before a scan will succeed

From `sane_start()` (`canon_dr.c:5412`), the batch-start block, in order:

| Step | Function | Command | REQUIRED? |
|---|---|---|---|
| 1 | `object_position(FALSE)` `5445` | OBJECT POSITION discharge | recommended (clears leftover paper) |
| 2 | `wait_scanner` `5450` | TEST UNIT READY | **REQUIRED** |
| 3 | `load_lut` `5457` | — (host-side) | not a command |
| 4 | `calibrate_AFE` `5464` | COR CAL `0xe1` ×4 + 3 cal scans | **see §6** |
| 5 | `calibrate_fine` `5471` | — | **no-op on P-215** |
| 6 | `send_panel` `5488` | SEND panel `0x2a`/`0x84` | OPTIONAL |
| 7 | `update_params` `5503` | — (host-side) | not a command |
| 8 | `set_window` `5510` | SET WINDOW `0x24` | **REQUIRED** |
| 9 | `ssm_buffer` `5517` | SET SCAN MODE `0xd6` page 0x32 | **REQUIRED** (see note) |
| 10 | `ssm_do` `5524` | SET SCAN MODE `0xd6` page 0x36 | skipped in colour |
| 11 | `ssm_df` `5531` | SET SCAN MODE `0xd6` page 0x30 | OPTIONAL |
| 12 | `ssm2_hw_enhancement` `5537` | — | no-op (`has_ssm2`=0, `4373`) |
| 13 | `object_position(TRUE)` `5567` | OBJECT POSITION feed | **REQUIRED** for ADF |
| 14 | `wait_scanner` `5574` | TEST UNIT READY | **REQUIRED** |
| 15 | `start_scan` `5582` | SCAN `0x1b` | **REQUIRED** |
| 16 | `get_pixelsize` `5588` | READ `0x80` | no-op (`hwcrop`=0, `4832`) |

Note on step 9: `ssm_buffer` is what tells the scanner simplex-vs-duplex and
buffered-vs-not. For a **simplex** scan its payload is all-default, so it is
arguably skippable — but `calibrate_AFE` forces duplex and calls `ssm_buffer`
itself (`7200`), so if you calibrate you *must* send it again afterwards to
return to simplex. Treat it as required.

`ssm_do` (dropout colour) returns immediately when `s.mode == MODE_COLOR`
(`canon_dr.c:4425-4428`). Skip it for colour scans.

### 1.5 SET SCAN MODE (`0xd6`) exact bytes

CDB is 6 bytes (`SET_SCAN_MODE_len`):

```
[0] = 0xD6
[1] = 0x10          set_SSM_pf(cmd,1) = setbitfield(cmd+1, 1, 4, 1)
[2] = 0x00
[3] = 0x00
[4] = 0x14          set_SSM_pay_len = payload length (SSM_PAY_len = 0x14 = 20)
[5] = 0x00
```

Payload is 20 bytes (`SSM_PAY_len`). Offsets from `canon_dr-cmd.h:366-399`:

```
[0x00] 0x00
[0x01] 0x13         set_SSM_pay_head_len — ONLY because has_ssm_pay_head_len=1
[0x02] 0x00
[0x03] 0x00
[0x04] page code    0x32 = buffer, 0x30 = double-feed, 0x36 = dropout
[0x05] 0x0E         SSM_PAGE_len
[0x06] flags        buffer page: bit1 = duplex
[0x07] flags        buffer page: BUFF_unk (always 0); DF page: bit5 deskew-roll,
                                bit4 staple, bit2 thick, bit0 length
[0x08] 0x00
[0x09] 0x00
[0x0A] flags        buffer page: bit6 = async(buffermode), bit5 = ald,
                                bit4 = flatbed, bit3 = card
[0x0B..0x13] 0x00
```

`set_SSM_pay_head_len` writing to payload byte `[1]` is P-215/P-208/P-150-specific
(`has_ssm_pay_head_len`, `canon_dr.c:4162, 4256, 4444`). Older Canons leave it 0.

**Buffer page, simplex ADF, non-buffered (the one you want):**
```
CDB:     D6 10 00 00 14 00
Payload: 00 13 00 00 32 0E 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

**Buffer page, duplex (needed for calibration):**
```
CDB:     D6 10 00 00 14 00
Payload: 00 13 00 00 32 0E 02 00 00 00 00 00 00 00 00 00 00 00 00 00
                              ^^ bit1 = duplex
```

**Double-feed page, all detection off (optional):**
```
CDB:     D6 10 00 00 14 00
Payload: 00 13 00 00 30 0E 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

---

## 2. SET WINDOW (`0x24`)

`set_window()` at `canon_dr.c:5832`.

### 2.1 CDB — 10 bytes

```
[0]     0x24                    SET_WINDOW_code
[1..5]  0x00
[6..8]  parameter list length, 3 bytes BIG-ENDIAN
        set_SW_xferlen(cmd,len) = putnbyte(cmd+0x06, len, 3)
        = SW_header_len(8) + SW_desc_len(0x2c) = 52 = 0x000034
[9]     0x00                    control
```

→ `24 00 00 00 00 00 00 00 34 00`

### 2.2 Payload — 8-byte header + 0x2c descriptor = 52 bytes

**Header (8 bytes), `canon_dr.c:5856`:**

| off | width | value | meaning |
|---|---|---|---|
| 0x00–0x05 | 6 | `00` | reserved |
| 0x06–0x07 | 2, **BE** | `00 2C` | window descriptor block length (`set_WPDB_wdblen`, `cmd.h:551`) |

**Descriptor (0x2c = 44 bytes).** All multi-byte fields are **big-endian**
(`putnbyte`, `cmd.h:51`). Macros at `canon_dr-cmd.h:555-657`.

| off | w | endian | units | macro | P-215 value @300dpi/24bit/Letter/simplex |
|---|---|---|---|---|---|
| 0x00 | 1 | — | — | `set_WD_wid` | **0x00** front (`0x01` = back) |
| 0x01 | 1 | — | — | `set_WD_auto` (bit0) | 0x00 — never set by canon_dr |
| 0x02 | 2 | BE | dpi | `set_WD_Xres` | **0x012C** = 300 |
| 0x04 | 2 | BE | dpi | `set_WD_Yres` | **0x012C** = 300 |
| 0x06 | 4 | BE | 1/1200 in | `set_WD_ULX` | **see 2.3** — `0x00000000` if `max_x == page_x` |
| 0x0A | 4 | BE | 1/1200 in | `set_WD_ULY` | **0xFFFFFFFF** — see `invert_tly`, 2.5 |
| 0x0E | 4 | BE | 1/1200 in | `set_WD_width` | **0x000027C0** = 10176 — see `ppl_mod`, 2.4 |
| 0x12 | 4 | BE | 1/1200 in | `set_WD_length` | **0x00003390** = 13200 |
| 0x16 | 1 | — | 0–255 | `set_WD_brightness` | **0x80** = `s->brightness + 128`, default 0→128 |
| 0x17 | 1 | — | 0–255 | `set_WD_threshold` | **0x5A** = 90 (`init_user`, `2171`) |
| 0x18 | 1 | — | 0–255 | `set_WD_contrast` | **0x80** = `s->contrast + 128` |
| 0x19 | 1 | — | enum | `set_WD_composition` | **0x05** — see 2.6 |
| 0x1A | 1 | — | bits | `set_WD_bitsperpixel` | **0x08** — 24bpp colour writes **8**, not 24 |
| 0x1B | 1 | — | enum | `set_WD_ht_type` | 0x00 — canon_dr leaves it 0, code commented out (`5914`) |
| 0x1C | 1 | — | — | `set_WD_ht_pattern` | 0x00 |
| 0x1D | 1 | — | bitfield | rif / rgb / padding | **0x10** — see 2.7 |
| 0x1E | 2 | BE | — | `set_WD_bitorder` | `0x0000` — never set by canon_dr |
| 0x20 | 1 | — | enum | `set_WD_compress_type` | **0x00** = `WD_cmp_NONE` |
| 0x21 | 1 | — | — | `set_WD_compress_arg` | **0x00** |
| 0x22–0x29 | 8 | — | — | reserved | `00` |
| **0x2A** | 1 | — | — | **`set_WD_reserved2`** | **0x88** ← this is where `unknown_byte2` lands |
| 0x2B | 1 | — | — | vendor unique | `00` |

**`unknown_byte2 = 0x88` goes to descriptor offset 0x2A**, i.e. absolute payload
offset `8 + 0x2A = 0x32` (byte 50 of 52). From `canon_dr-cmd.h:656`:
`#define set_WD_reserved2(sb, val)  sb[0x2a] = val`, called at `canon_dr.c:5924`.

### 2.3 ULX (0x06) — window centring

`canon_dr.c:5870-5885`. Three branches; P-215 takes the **third** (`fixed_width`
= 0, source is ADF not flatbed):

```c
set_WD_ULX (desc1, (s->max_x - s->s.page_x) / 2 + s->s.tl_x);
set_WD_width (desc1, s->s.width * 1200/s->s.dpi_x);
```

`max_x` comes from VPD (`canon_dr.c:1346`). `init_model` sets `valid_x = max_x`
(`1419`); `init_user` sets `page_x = min(8.5*1200, valid_x)` (`2154-2157`).

- If VPD `max_x` ≤ 10200 → `page_x == max_x` → **ULX = tl_x = 0**.
- If VPD `max_x` > 10200 → ULX = `(max_x - 10200)/2`.

**Simplification for your driver:** set `tl_x = 0`, `page_x = br_x = max_x` and
ULX is unconditionally 0. Read `max_x` from your VPD page 0xF0 (`get_IN_window_width`
at VPD offset 0x14, 4 bytes BE, scaled `* 1200 / basic_x_res`).

### 2.4 `ppl_mod = 8` — pixels-per-line rounding

Applied twice in `update_params()`:

```c
s->u.width -= s->u.width % s->ppl_mod;   /* canon_dr.c:4996 */
...
s->s.width -= s->s.width % s->ppl_mod;   /* canon_dr.c:5078 */
```

The **pixel** width is rounded **down** to a multiple of 8, and *then* converted
back to 1/1200-inch units for the window's width field:

```c
set_WD_width (desc1, s->s.width * 1200 / s->s.dpi_x);   /* canon_dr.c:5884 */
```

Worked example, Letter width, 300 dpi:
```
br_x - tl_x            = 10200  (1/1200 in)
width_px raw           = 10200 * 300 / 1200 = 2550
ppl_mod round-down     = 2550 - (2550 % 8) = 2550 - 6 = 2544 px
window width field     = 2544 * 1200 / 300  = 10176 = 0x27C0
Bpl                    = 2544 * 24 / 8      = 7632 bytes/line
```

So you send **10176, not 10200**. Getting this wrong desynchronises every line
of the image. Note the ordering matters: for lineart there is *also* a
`width -= width % 8` byte-boundary round *before* the ppl_mod round
(`canon_dr.c:4992, 5074`).

### 2.5 `invert_tly = 1` — ULY (0x0A)

`canon_dr.c:5887-5891`:

```c
if(s->invert_tly)
    set_WD_ULY (desc1, ~s->s.tl_y);
else
    set_WD_ULY (desc1, s->s.tl_y);
```

`~` is a C bitwise NOT on a 32-bit `int`, then `putnbyte(...,4)` writes the low
4 bytes big-endian. Equivalent to `(uint32)(-(tl_y) - 1)`.

| `tl_y` (1/1200 in) | value written | bytes at 0x0A |
|---|---|---|
| 0 | 0xFFFFFFFF | `FF FF FF FF` |
| 1200 (1 inch) | 0xFFFFFB4F | `FF FF FB 4F` |
| 600 | 0xFFFFFDA7 | `FF FF FD A7` |

For a full-page scan `tl_y = 0` → **`FF FF FF FF`**. This looks wrong and is
exactly the kind of thing that makes people "fix" it into a jam. Don't. Note
`set_WD_length` (0x12) is **not** inverted.

### 2.6 Composition (0x19)

`set_WD_composition(desc1, s->s.mode)` — `s.mode` *is* the wire value, because
`canon_dr.h:508-511` defines the modes as the wire constants:

| host mode | `#define` | wire value at 0x19 |
|---|---|---|
| `MODE_LINEART` | `WD_comp_LA` | **0** |
| `MODE_HALFTONE` | `WD_comp_HT` | **1** |
| `MODE_GRAYSCALE` | `WD_comp_GS` | **2** |
| `MODE_COLOR` | `WD_comp_CG` | **5** |

**Colour is 5, not 3.** `WD_comp_CL`(3) and `WD_comp_CH`(4) exist in the header
but canon_dr never uses them.

Paired with 0x1A (`set_WD_bitsperpixel`, `canon_dr.c:5909-5912`):
```c
if(s->s.bpp == 24) set_WD_bitsperpixel (desc1, 8);
else               set_WD_bitsperpixel (desc1, s->s.bpp);
```
So colour → `0x19 = 0x05`, `0x1A = 0x08`. Gray → `0x02` / `0x08`. Lineart → `0x00` / `0x01`.

### 2.7 Byte 0x1D — rif / rgb / padding

Three bitfields in one byte (`canon_dr-cmd.h:625-630`):

```
bit 7      rif        set_WD_rif      s->rif      = 0
bits 6-5-4 rgb        set_WD_rgb      s->rgb_format = 1   →  0x10
bits 2-1-0 padding    set_WD_padding  s->padding  = 0
```

`s->padding` is **never assigned anywhere in canon_dr.c** (only read at `5921`),
so it is always 0. `s->rif` is a user option, default 0.

**P-215 value: `0x1D = 0x10`.**

This is where `rgb_format = 1` lives. It is a *request* to the scanner for a
particular colour data layout; the matching *decoder* on the host is
`color_interlace[]` (§5). They must agree — `rgb_format=1` + `rRgGbB`/`RRGGBB`
is the tested pair for this model.

### 2.8 Complete 52-byte payload, 300 dpi / 24-bit colour / Letter / simplex front

Assuming VPD `max_x` ≤ 10200 so ULX = 0:

```
offset 0x00  header
  00 00 00 00 00 00 00 2C

offset 0x08  descriptor
  00          0x00  wid = front
  00          0x01  auto
  01 2C       0x02  Xres  = 300
  01 2C       0x04  Yres  = 300
  00 00 00 00 0x06  ULX   = 0
  FF FF FF FF 0x0A  ULY   = ~0        (invert_tly)
  00 00 27 C0 0x0E  width = 10176     (2544 px, ppl_mod 8)
  00 00 33 90 0x12  length= 13200     (3300 lines)
  80          0x16  brightness = 128
  5A          0x17  threshold  = 90
  80          0x18  contrast   = 128
  05          0x19  composition = WD_comp_CG
  08          0x1A  bits per pixel
  00          0x1B  halftone type
  00          0x1C  halftone pattern
  10          0x1D  rif=0 rgb=1 padding=0
  00 00       0x1E  bit ordering
  00          0x20  compression = none
  00          0x21  compression arg
  00 00 00 00 00 00 00 00   0x22-0x29 reserved
  88          0x2A  unknown_byte2      <<< 0x88 lands HERE
  00          0x2B
```

Flat hex (52 bytes):
```
00 00 00 00 00 00 00 2C 00 00 01 2C 01 2C 00 00
00 00 FF FF FF FF 00 00 27 C0 00 00 33 90 80 5A
80 05 08 00 00 10 00 00 00 00 00 00 00 00 00 00
00 00 88 00
```

### 2.9 Duplex

`canon_dr.c:5947-5955`: when the source is duplex, `set_window` sends the **same
payload twice**, second time with byte 0x08+0x00 (descriptor `wid`) changed to
`0x01`. Two separate SET WINDOW commands, not one two-descriptor payload.

---

## 3. Starting the scan

### 3.1 OBJECT POSITION (`0x31`) — `canon_dr.c:5966`

10-byte CDB. Only byte 1 carries information (`set_OP_autofeed` =
`setbitfield(cmd+1, 0x07, 0, val)` — bits 2-0):

```
Feed (load next page):   31 01 00 00 00 00 00 00 00 00
Discharge (eject):       31 00 00 00 00 00 00 00 00 00
```

No data phase in either direction. Returns immediately; you **must** follow a
feed with TEST UNIT READY to wait for the paper to be in position
(`canon_dr.c:5574`). A feed with an empty hopper returns CHECK CONDITION →
sense key 3 ASC 0x3A ASCQ 0x00 (or key 5/0x3A/0x00) → *no more documents*.

### 3.2 SCAN (`0x1b`) — `canon_dr.c:6013`

**Yes, SCAN carries a data-out payload.** It is a list of window ids, 1 byte
each, and the CDB's byte 4 is the transfer length = number of ids.

```
[0]     0x1B
[1..3]  0x00
[4]     transfer length = number of window-id bytes  (set_SC_xfer_length)
[5]     0x00
```

| scan | CDB | payload | length |
|---|---|---|---|
| simplex front | `1B 00 00 00 01 00` | `00` | 1 |
| simplex back | `1B 00 00 00 01 00` | `01` | 1 |
| **duplex** | `1B 00 00 00 02 00` | `00 01` | 2 |
| cal, lamp off (black) | `1B 00 00 00 02 00` | `FF FF` | 2 |
| cal, lamp on (white) | `1B 00 00 00 02 00` | `FE FE` | 2 |

The logic (`canon_dr.c:6020-6036`): the payload starts as `{WD_wid_front,
WD_wid_back}` = `{0x00, 0x01}`, length 2. If `type != 0` (calibration) **both**
bytes are overwritten with `type`. If the source is not duplex, the length is
decremented to 1, and if the source is ADF_BACK the single byte becomes `0x01`.

### 3.3 Order

```
OBJECT POSITION feed   (31 01 ...)
TEST UNIT READY        (00 ...)         <-- wait for paper
SCAN                   (1B 00 00 00 01 00) + payload {00}
[READ loop]
```

For calibration scans specifically there is **no OBJECT POSITION** — see §6.3.
The cal scans run against the internal reference with no paper loaded.

---

## 4. The READ loop (`0x28`)

`read_from_scanner()` at `canon_dr.c:6150`,
`read_from_scanner_duplex()` at `canon_dr.c:6322`.

### 4.1 CDB — 10 bytes

Macros at `canon_dr-cmd.h:232-235`:

```
[0]     0x28                READ_code
[1]     0x00
[2]     datatype code       set_R_datatype_code  ← 0x00 = image
[3]     0x00
[4]     transfer uid        set_R_xfer_uid       ← 0 for image
[5]     transfer lid        set_R_xfer_lid       ← 0 for image
[6..8]  transfer length     set_R_xfer_length, 3 bytes BIG-ENDIAN
[9]     0x00                control
```

Datatype codes (`canon_dr-cmd.h:216-225`):

| code | meaning | uid/lid | length |
|---|---|---|---|
| **0x00** | **image** | 0 / 0 | chunk size |
| 0x80 | pixel size | 0 / 0x02 | 0x10 |
| 0x84 | panel | 0 / 0 | 0x08 |
| **0x8B** | **sensors** | 0 / 0 | 0x01 |
| 0x8C | counters | 0 / 0 | 0x80 |
| 0x90 | fine offset | 0 / dpi/10 | width*2 |
| 0x91 | fine gain | channel / dpi/10 | width*2 |
| 0x96 | imprinters | 0 / 0 | 0x20 |

Cross-check against your working code: READ sensors is
`28 00 8B 00 00 00 00 00 01 00`. If that's what you're sending, your CDB layout
understanding already matches this table.

### 4.2 How much to ask for each iteration

`canon_dr.c:6160-6177`:

```c
size_t bytes  = s->buffer_size;                     /* 2 MiB default */
size_t remain = s->s.bytes_tot[side] - s->s.bytes_sent[side];

bytes -= (bytes % s->s.Bpl);        /* must end on a scanline boundary */
if(bytes % 2) bytes -= s->s.Bpl;    /* and be an even byte count       */

if(exact && bytes > remain) bytes = remain;   /* only for calibration  */
```

Key point: **for image reads (`exact = 0`) the host deliberately over-asks.** It
does not clamp to `remain`. It keeps requesting a full chunk and relies on the
scanner returning short + CHECK CONDITION to signal end of page. Only calibration
reads use `exact = 1`.

Worked example, 300 dpi colour Letter, `Bpl = 7632`, `buffer_size = 2 MiB`:

```
2097152 % 7632 = 5984
bytes = 2097152 - 5984 = 2091168   (= 274 full lines, even)
2091168 = 0x1FE8A0

CDB: 28 00 00 00 00 00 1F E8 A0 00
```

That's ~2.0 MiB — sits inside your 2 MiB data-in window with room to spare.
`bytes_tot = 7632 * 3300 = 25,185,600`, so a full page is ~13 READs.

For duplex the alignment is to the **double-wide** line
(`bytes -= bytes % (Bpl*2)`, `canon_dr.c:6339`).

### 4.3 Detecting end of page

The scanner ends a page by returning **fewer bytes than requested** plus a
CHECK CONDITION whose sense is:

> **sense key = 0, ILI = 1**, `information` field = **residue** (bytes not transferred)

`sense_handler()` `canon_dr.c:8267-8276`:

```c
case 0:
  if (ili == 1) {
    s->rs_info = info;                 /* get_RS_information(b) = getnbyte(b+0x03,4) */
    return SANE_STATUS_EOF;
  }
  return SANE_STATUS_GOOD;
```

`do_scsi_cmd()` then reconciles (`canon_dr.c:8543-8547`):

```c
if(ret == SANE_STATUS_EOF)
    *inLen -= s->rs_info;              /* actual = requested - residue */
```

So: **actual valid bytes = requested_length − RS_information**.

On the USB path the same thing is done more defensively
(`canon_dr.c:8747-8755`): if the bulk read already returned *fewer* bytes than
`requested − residue`, the residue is ignored; if it returned *more*, it is
truncated to `requested − residue`. Port the defensive version.

Then (`canon_dr.c:6270-6272`) the host additionally chops anything beyond what
it still needs:
```c
if(inLen > remain) inLen = remain;
```

`SANE_STATUS_EOF` is converted to end-of-page at `canon_dr.c:6291-6308`:
`fill_image()` pads the remainder of the buffer with `bg_color` (0xEE through the
LUT) — this is how a short page (e.g. a receipt in a Letter-sized window) gets a
full-height image.

### 4.4 REQUEST SENSE and the sense map

CDB — 6 bytes (`canon_dr-cmd.h:89-93`):
```
03 00 00 00 0E 00        (RS_return_size = 0x0e = 14)
```

Response field offsets (`canon_dr-cmd.h:96-107`):

| off | bits | field |
|---|---|---|
| 0x00 | 7 | information valid |
| 0x00 | 6-0 | error code |
| 0x02 | 7 | filemark |
| 0x02 | **6** | **EOM** |
| 0x02 | **5** | **ILI** |
| 0x02 | 3-0 | **sense key** |
| 0x03–0x06 | — | **information (residue), 4 bytes BE** |
| 0x07 | — | additional length |
| 0x0C | — | **ASC** |
| 0x0D | — | **ASCQ** |
| 0x0F | 7 | SKSV |
| 0x0F–0x11 | — | SKSB |

Full map from `sense_handler()` (`canon_dr.c:8245-8480`). The ones that matter:

| key | ASC | ASCQ | meaning | your action |
|---|---|---|---|---|
| **0** | — | — | **ILI=1 → END OF MEDIUM / end of page.** residue in 0x03-0x06 | short read, page done |
| 0 | — | — | ILI=0 | normal GOOD |
| 1 | 0x37 | 0x00 | recovered: parameter rounded | continue |
| **2** | 0x04 | 0x01 | **not ready: previous command unfinished** | **DEVICE_BUSY → retry** |
| 2 | any | any | not ready (default) | DEVICE_BUSY → retry |
| 3 | 0x36 | 0x00 | medium: no cartridge | IO error |
| **3** | **0x3A** | **0x00** | **medium: hopper empty → NO MORE DOCUMENTS** | end of batch |
| 3 | 0x80 | 0x00 | medium: **paper jam** | abort |
| 3 | 0x80 | 0x01 | medium: cover open | abort |
| 3 | 0x81 | 0x01 | medium: double feed | abort |
| 3 | 0x81 | 0x02 | medium: skew detected | abort |
| 3 | 0x81 | 0x04 | medium: staple detected | abort |
| 4 | 0x60 | 0x00 | hardware: lamp error | abort |
| 4 | 0x80 | 0x01–0x04 | hardware: CPU/RAM/ROM/HW check | abort |
| 5 | 0x1A | 0x00 | illegal: parameter list error | **your SET WINDOW payload is wrong** |
| 5 | 0x20 | 0x00 | illegal: invalid command | opcode not supported |
| 5 | 0x24 | 0x00 | illegal: **invalid CDB field** | **your CDB is wrong** |
| 5 | 0x25 | 0x00 | illegal: unsupported LUN | — |
| 5 | 0x26 | 0x00 | illegal: **invalid field in parm list** | **a window byte is out of range** |
| 5 | 0x2C | 0x00 | illegal: **command sequence error** | **you skipped a required step** |
| 5 | 0x2C | 0x01 | illegal: too many windows | — |
| **5** | **0x3A** | **0x00** | **illegal: no paper → NO MORE DOCUMENTS** | end of batch |
| 5 | 0x3D | 0x00 | illegal: invalid IDENTIFY | — |
| 5 | 0x55 | 0x00 | illegal: scanner out of memory | reduce chunk |
| 6 | 0x29 | 0x00 | unit attention: device reset | treated as **GOOD**, retry |
| 6 | 0x2A | 0x00 | unit attention: param changed by 2nd initiator | treated as **GOOD** |
| 0xB | 0x00 | 0x00 | aborted: cancelled | — |
| 0xB | 0x80 | 0x00 | aborted: timeout | — |
| 0xE | 0x3B | 0x0D/0x0E | miscompare: too many/few docs | — |

### 4.5 "Temporary blank page"

**There is no such sense code in `canon_dr`.** I read `sense_handler()` end to
end (`canon_dr.c:8245-8480`); no ASC/ASCQ pair is mapped to a blank-page or
"retry, data not ready yet" condition beyond sense key 2 (DEVICE_BUSY).

If you have seen "temporary blank page" documented for Canon scanners, it is not
in this backend — you may be thinking of `fujitsu`/`epjitsu`. I'm flagging this
explicitly rather than inventing an answer.

The closest behaviour is the **DEVICE_BUSY → treat as zero-length GOOD** path
(`canon_dr.c:6209-6213`):
```c
else if (ret == SANE_STATUS_DEVICE_BUSY) {
    inLen = 0;
    ret = SANE_STATUS_GOOD;      /* got nothing, no error, just loop again */
}
```
That is the mechanism by which the host spins while the scanner is still
digitising. Implement it or you will abort on the first busy.

### 4.6 End of batch

Not a sense code on READ — it comes from the **next page's OBJECT POSITION feed**
(`canon_dr.c:5628`) returning sense 3/0x3A/0x00 or 5/0x3A/0x00 → `NO_DOCS`. The
`sane_start` error path then clears `started` and the batch ends
(`canon_dr.c:5725-5730`).

---

## 5. De-interlacing

All of this lives in `copy_simplex()` (`canon_dr.c:6444`) and `copy_duplex()`
(`canon_dr.c:6748`). Both operate on **whole scanlines** of `Bpl` bytes and
assume the input buffer is scanline-aligned — which is why the READ chunk size is
rounded down to a multiple of `Bpl`.

Notation below: `pwidth = s.width` (pixels), `bwidth = s.Bpl` (bytes/line).
For 24-bit colour `bwidth == pwidth * 3`; for 8-bit gray `bwidth == pwidth`.

### 5.1 `COLOR_INTERLACE_rRgGbB` — P-215 **front** colour

`canon_dr.c:6605-6612`. Source comment: *"one line has the following format:
`rrr...RRRggg...GGGbbb...BBB` where the 'capital' letters are the beginning of
the line"*.

The line is **three planes** (R, G, B) laid end to end, and **each plane is
stored right-to-left** — the last byte of a plane is the leftmost pixel.

```c
for (j=pwidth-1; j>=0; j--){
    line[line_next++] = buf[i+j];              /* R */
    line[line_next++] = buf[i+pwidth+j];       /* G */
    line[line_next++] = buf[i+2*pwidth+j];     /* B */
}
```

Pseudocode on a raw buffer:

```python
def deinterlace_rRgGbB(raw_line, pwidth):          # len(raw_line) == pwidth*3
    out = bytearray(pwidth * 3)
    for k in range(pwidth):                        # k = output pixel, left to right
        j = pwidth - 1 - k                         # mirror
        out[k*3 + 0] = raw_line[            j]     # R plane
        out[k*3 + 1] = raw_line[  pwidth  + j]     # G plane
        out[k*3 + 2] = raw_line[2*pwidth  + j]     # B plane
    return out
```

If you forget the mirror you get a horizontally flipped image; if you forget the
planar split you get three narrow monochrome bands.

### 5.2 `COLOR_INTERLACE_RRGGBB` — P-215 **back** colour

`canon_dr.c:6594-6601`. Same three planes, **not** mirrored:

```python
def deinterlace_RRGGBB(raw_line, pwidth):
    out = bytearray(pwidth * 3)
    for k in range(pwidth):
        out[k*3 + 0] = raw_line[            k]
        out[k*3 + 1] = raw_line[  pwidth  + k]
        out[k*3 + 2] = raw_line[2*pwidth  + k]
    return out
```

Note the P-215 and P-208 have these two **swapped** relative to each other
(compare `canon_dr.c:1678-1679` with `1660-1661`). Don't copy P-208 code.

### 5.3 `GRAY_INTERLACE_gG` — P-215 **front** gray

`canon_dr.c:6495-6500`. The whole line is simply **reversed**:

```c
for (j=bwidth-1; j>=0; j--) line[line_next++] = buf[i+j];
```

```python
def deinterlace_gG(raw_line):
    return raw_line[::-1]
```

The P-215 leaves `gray_interlace[SIDE_BACK]` at 0 (`GRAY_INTERLACE_NONE`), so
the **back gray line is a straight copy, no reversal**. Asymmetric — same
handedness quirk as the colour case.

### 5.4 `DUPLEX_INTERLACE_FBfb`

`canon_dr.c:6834-6839` — the fall-through `else` branch:

```c
for(i=0; i<len; i+=2){
    front[flen++] = buf[i];
    back[blen++]  = buf[i+1];
}
```

Plain **byte-level de-interleave over the whole block**: even byte → front, odd
byte → back. Because the READ block is aligned to `2*Bpl`, this is equivalent to
"for each double-wide line, split alternating bytes". Each output side then has
`Bpl` bytes per line.

Critically, `copy_duplex` then hands each half to `copy_simplex` with its own
side index (`canon_dr.c:6841-6842`), so **the colour/gray de-interlace of §5.1–5.3
is applied afterwards, per side**:

```python
def deinterlace_FBfb(block, Bpl, pwidth):
    front_raw = block[0::2]      # even bytes
    back_raw  = block[1::2]      # odd bytes

    front, back = [], []
    for off in range(0, len(front_raw), Bpl):
        front.append(deinterlace_rRgGbB(front_raw[off:off+Bpl], pwidth))  # FRONT
    for off in range(0, len(back_raw), Bpl):
        back.append(deinterlace_RRGGBB(back_raw[off:off+Bpl], pwidth))    # BACK
    return front, back
```

Order of operations is **byte de-interleave first, then per-side plane
de-interlace**. Reversing them produces garbage.

### 5.5 `duplex_offset_side = SIDE_BACK` and the offset

The offset is **not** applied to the raw stream. It is applied in two places in
`update_params()`:

**(a)** scan more lines than the user asked for (`canon_dr.c:5098-5100`):
```c
if((s->u.source == SOURCE_ADF_DUPLEX || ...) && s->duplex_offset && !calib)
    s->s.height = (s->u.br_y - s->u.tl_y + s->duplex_offset) * s->u.dpi_y / 1200;
```

**(b)** discard that many lines from the offset side (`canon_dr.c:5124-5125`):
```c
if(s->i.source == SOURCE_ADF_DUPLEX || ...)
    s->i.skip_lines[s->duplex_offset_side] = s->duplex_offset * s->i.dpi_y / 1200;
```

and the discard happens per line in `copy_simplex` (`canon_dr.c:6481-6485`):
```c
int lineNum = s->s.bytes_sent[side] / bwidth;
s->s.bytes_sent[side] += bwidth;
if (lineNum < s->i.skip_lines[side] || lineNum - s->i.skip_lines[side] >= s->i.height)
    continue;                              /* drop this line */
```

So with `duplex_offset_side = SIDE_BACK`: the **back** page's first
`duplex_offset * dpi_y / 1200` lines are padding and get thrown away; the front
page keeps lines from 0. Both sides emit exactly `i.height` lines. Lines past
`i.height` on either side are also dropped.

> ### ⚠ `duplex_offset` for the P-215II is a config-file accident
>
> `duplex_offset` is **not** set in `init_model`. It comes from `canon_dr.conf`
> via `global_duplex_offset` (`canon_dr.c:956`), default **0** (`canon_dr.c:481`).
>
> `default_globals()` is called **once**, before the whole config file is parsed
> (`canon_dr.c:583`), and `option duplex-offset` lines are **never reset between
> device entries**. So each `usb` line inherits the most recent `option
> duplex-offset` above it, whether or not it was meant for that model.
>
> In `canon_dr.conf.in`:
> - `# P-215` (usb `0x1083 0x1646`, line 164) — last preceding option is line 158
>   `duplex-offset 400` (intended for DR-C125) → **inherits 400**
> - `# P-215II` (usb `0x1083 0x165b`, line 209) — last preceding option is line 195
>   `duplex-offset 1640` (intended for DR-F120) → **inherits 1640**
> - `# P-208` (line 176) is the only one with a deliberate value: **260**
>
> 1640/1200 ≈ 1.37 inch of skipped back-page lines on your exact model. I'm
> fairly confident this is unintentional, but it is what the shipped config
> produces. **For your driver start with `duplex_offset = 0`** and only introduce
> a value if you observe an actual front/back vertical misregistration; P-208's
> 260 is the only empirically-derived number nearby.
>
> **For simplex this is entirely moot** — both (a) and (b) are gated on a duplex
> source.

### 5.6 What `rgb_format = 1` does — and does not do

`s->rgb_format` has exactly **one** use in the entire backend
(`canon_dr.c:5920`): `set_WD_rgb(desc1, s->rgb_format)` → window byte 0x1D bits
6-4 = 1.

It is a **request to the scanner**, not a host-side switch. The host-side decode
is entirely driven by `color_interlace[side]`. The backend's assumption — which
you inherit — is that `rgb_format = 1` is the setting under which the P-215
emits the `rRgGbB` (front) / `RRGGBB` (back) planar layouts. Set both together
or neither; changing one without the other gives you a colour-scrambled image
with no error.

### 5.7 Post-de-interlace steps in `copy_simplex`, in order

1. de-interlace into `line[]` (above)
2. invert if `reverse_by_mode[mode]` — **0 for colour and gray on P-215**
   (`canon_dr.c:1394-1395`), so skip
3. subtract `f_offset[side][]` — **P-215: `f_offset` is NULL, skipped** (§6)
4. multiply by `240/f_gain[side][]` — **P-215: NULL, skipped**
5. brightness/contrast LUT if `sw_lut` — **P-215: `sw_lut` = 0, skipped**
6. `copy_line()` → downsample/crop into the output buffer. If
   `s.width == i.width && s.dpi_x == i.dpi_x && s.mode == i.mode`
   this is a plain `memcpy` (`canon_dr.c:6884-6894`) — which is the case for a
   straightforward scan where you don't ask for a resolution the hardware can't do.

So on the P-215 with matching user/scan params, steps 2–5 all vanish. The
de-interlace **is** the whole pipeline.

---

## 6. Calibration — the critical question

### 6.1 Straight answer

**Fine calibration: not applicable. The P-215 does none, and you should
implement none.**

`fcal_src` and `fcal_dest` are never assigned in the P-215 block
(`canon_dr.c:1676-1692`), so both are 0. `calibrate_fine()` bails on the first
line (`canon_dr.c:7385-7388`):

```c
if(s->fcal_src == FCAL_SRC_NONE || s->fcal_dest == FCAL_DEST_NONE){
    DBG (10, "calibrate_fine: not required\n");
    goto cleanup;
}
```

Therefore **no `SEND 0x2a` with datatype `0x90`/`0x91`, and no `READ 0x90/0x91`,
is ever issued for a P-215.** `s->f_offset[]` and `s->f_gain[]` stay NULL, so the
per-cell offset/gain loops in `copy_simplex` (`canon_dr.c:6705-6721`) never run.

This is good news for you: the fine-cal `SEND` payload is `s.width*2 + 4` bytes
(`canon_dr.c:7760`) = **5092 bytes at 300 dpi**, which would blow your data-out
limit. You don't need it.

**Coarse calibration: yes, `canon_dr` does it, and it is cheap.**

`need_ccal = 1` → `calibrate_AFE()` runs (`canon_dr.c:7158`). `ccal_version = 3`
→ the 40-byte payload (`canon_dr.c:7891`).

### 6.2 Will a scan work if you skip calibration entirely?

**Honest answer: I cannot prove it from the source, and I won't pretend
otherwise.** What the code establishes:

- `COR CAL 0xe1` is the **only** command in the entire backend that programs the
  analogue front end (gain, black offset, per-channel exposure). Nothing else
  touches it.
- If you never send it, the scanner runs on whatever AFE state it holds from
  power-on or from whatever driver last calibrated it. What those power-on
  defaults are is a hardware fact not visible in this source.
- The `need_ccal` flag exists precisely to distinguish models that require this
  from models that don't. The P-215 is in the "requires" set. Models in the
  "doesn't require" set (most DR-xxxx) calibrate internally.

**What I'd actually recommend, and why it's the easy call:**

Implement coarse calibration. It is far cheaper than it sounds and it fits
inside your transport constraints comfortably:

- 4 × `COR CAL` with a **40-byte** data-out — trivially within your limit
- 3 calibration scans, each **8 lines duplex** = 122,112 bytes at 300 dpi —
  one READ each, well inside your 2 MiB window
- **no paper is fed** — no OBJECT POSITION before cal scans, no mechanical risk
- no user-visible page motion

That's ~10 extra commands for a guaranteed-correct AFE. Compare to the debugging
cost of chasing a dark or colour-shifted image.

**If you want to test the skip first** (reasonable — it's one experiment):
run the minimal sequence in §8 with step "calibrate" omitted and look at the
histogram. Expect one of: (a) usable but flat/dark, (b) heavily colour-cast,
(c) near-black. All three are consistent with an uncalibrated AFE; only (a)
is tolerable. **Middle path:** send **one** `COR CAL` with plausible hardcoded
values and no cal scans at all — see §6.5.

### 6.3 Coarse calibration — exactly what `canon_dr` does

`calibrate_AFE()` at `canon_dr.c:7143`. Setup (`7163-7211`):

```c
s->u.tl_y  = 0;
s->u.br_y  = 8 * 1200 / s->u.dpi_y;   /* lines = 8   → 32 @ 300dpi */
s->u.mode  = MODE_COLOR;              /* ALWAYS colour, even for a gray scan */
s->u.source= SOURCE_ADF_DUPLEX;       /* ALWAYS duplex, even for simplex     */
update_params(s, /*calib=*/1);
clean_params(s); image_buffers(s,1);
offset_buffers(s,0); gain_buffers(s,0);   /* clear fine cal */
ssm_buffer(s);                            /* -> duplex bit set */
set_window(s);                            /* -> TWO SET WINDOWs, wid 0 and 1 */
```

Then three passes:

**Pass 1 — black level (lamp off).** `canon_dr.c:7213-7245`
```c
for both sides: c_gain=1, c_offset=1, c_exposure[r,g,b]=0
write_AFE();                     /* COR CAL 0xe1 */
calibration_scan(0xff);          /* SCAN payload {FF,FF}, read whole image */
for each side i:
    min = minimum byte over buffers[i][0 .. valid_Bpl)
    c_offset[i] = min*3 - 2;
```

**Pass 2 — per-channel exposure (lamp on, deliberately overexposed).** `7247-7284`
```c
for both sides, all 3 channels: c_exposure = 0x320;
write_AFE();
calibration_scan(0xfe);          /* SCAN payload {FE,FE} */
for each side i, each channel j:
    max = maximum of buffers[i][k] for k = j, j+3, j+6, ... < valid_Bpl
    c_exposure[i][j] = c_exposure[i][j] * 102 / max;     /* colour  */
                    /* * 64 / max for gray */
```

**Pass 3 — gain (lamp on, with the offset+exposure just computed).** `7286-7317`
```c
write_AFE();
calibration_scan(0xfe);
for each side i:
    max = maximum byte over buffers[i][0 .. valid_Bpl)
    c_gain[i] = (250 - max) * 4 / 5;      /* colour; (125-max)*4/5 for gray */
    if (c_gain[i] < 1) c_gain[i] = 1;
```

**Final:** `write_AFE()` once more (`7347`) to commit.

Total: **4 × `COR CAL`, 3 × `SCAN`, 3 × read-to-EOF.**

`calibration_scan()` (`canon_dr.c:7844`) is just
`clean_params` → `start_scan(type)` → loop `read_from_scanner_duplex(exact=1)`
until both sides EOF. **`exact = 1`** here, so the READ length is clamped to
`remain` — no over-asking, no reliance on ILI.

At 300 dpi: `Bpl = 7632`, height 8, both sides → `remain` = 122,112 bytes.
`bytes = 2097152 - (2097152 % 15264) = 2091168`, clamped to 122,112. One READ:
`28 00 00 00 00 00 01 DD 00 00`.

### 6.4 `COR CAL` (`0xe1`) byte layout, version 3

**CDB — 10 bytes** (`canon_dr-cmd.h:408-412`, built at `canon_dr.c:7893-7896`):

```
[0]     0xE1                COR_CAL_code
[1..4]  0x00
[5]     0x03                set_CC_version  ← CC3_pay_ver
[6..8]  0x00 0x00 0x28      set_CC_xferlen, 3 bytes BE ← CC3_pay_len = 0x28 = 40
[9]     0x00
```

→ `E1 00 00 00 00 03 00 00 28 00`

(For `ccal_version == 0` models it would be byte 5 = `0x00` and length `0x20`.
The P-215 takes the **version-3** branch.)

**Payload — 0x28 = 40 bytes** (`canon_dr-cmd.h:441-466`, filled at `canon_dr.c:7898-7922`):

| off | w | endian | field | filled from |
|---|---|---|---|---|
| 0x00 | 1 | — | front gain R | `c_gain[FRONT]` |
| 0x01 | 1 | — | front gain G | `c_gain[FRONT]` (same value) |
| 0x02 | 1 | — | front gain B | `c_gain[FRONT]` (same value) |
| 0x03 | 1 | — | *(pad)* | 0 |
| 0x04 | 1 | — | front offset R | `c_offset[FRONT]` |
| 0x05 | 1 | — | front offset G | `c_offset[FRONT]` |
| 0x06 | 1 | — | front offset B | `c_offset[FRONT]` |
| 0x07 | 1 | — | *(pad)* | 0 |
| 0x08 | 2 | **BE** | front exposure R | `c_exposure[FRONT][0]` |
| 0x0A | 2 | **BE** | front exposure G | `c_exposure[FRONT][1]` |
| 0x0C | 2 | **BE** | front exposure B | `c_exposure[FRONT][2]` |
| 0x0E–0x13 | 6 | — | *(unused, zero)* | — |
| 0x14 | 1 | — | back gain R | `c_gain[BACK]` |
| 0x15 | 1 | — | back gain G | `c_gain[BACK]` |
| 0x16 | 1 | — | back gain B | `c_gain[BACK]` |
| 0x17 | 1 | — | *(pad)* | 0 |
| 0x18 | 1 | — | back offset R | `c_offset[BACK]` |
| 0x19 | 1 | — | back offset G | `c_offset[BACK]` |
| 0x1A | 1 | — | back offset B | `c_offset[BACK]` |
| 0x1B | 1 | — | *(pad)* | 0 |
| 0x1C | 2 | **BE** | back exposure R | `c_exposure[BACK][0]` |
| 0x1E | 2 | **BE** | back exposure G | `c_exposure[BACK][1]` |
| 0x20 | 2 | **BE** | back exposure B | `c_exposure[BACK][2]` |
| 0x22–0x27 | 6 | — | *(unused, zero)* | — |

Note gain and offset are **per-side scalars replicated across R/G/B** — the
backend never computes distinct per-channel gain/offset. Only exposure is
per-channel.

**Pass-1 payload (gain=1, offset=1, exposure=0), 40 bytes:**
```
01 01 01 00 01 01 01 00 00 00 00 00 00 00 00 00
00 00 00 00 01 01 01 00 01 01 01 00 00 00 00 00
00 00 00 00 00 00 00 00
```

**Pass-2 payload (exposure = 0x0320 everywhere, offsets from pass 1 — shown with
offset 0x2E as an example), 40 bytes:**
```
01 01 01 00 2E 2E 2E 00 03 20 03 20 03 20 00 00
00 00 00 00 01 01 01 00 2E 2E 2E 00 03 20 03 20
03 20 00 00 00 00 00 00
```

**40 bytes. Fits your data-out limit with two orders of magnitude to spare.**

### 6.5 Skipping the cal scans but still sending `COR CAL`

If you want to avoid the 3 calibration scans, send **one** `COR CAL` with
hardcoded values. Plausible ranges, derived from the formulas above:

| field | formula | plausible landing zone |
|---|---|---|
| `c_offset` | `min*3 - 2`, `min` = darkest byte with lamp off | small — roughly `0x01`–`0x20` |
| `c_exposure` | `0x320 * 102 / max`, `max` = brightest byte at exposure 0x320 | a few hundred — `0x0100`–`0x0320` |
| `c_gain` | `(250 - max) * 4 / 5`, clamped ≥ 1 | `0x01`–`0x80` |

A reasonable first guess for a single hardcoded write:
`gain = 0x40`, `offset = 0x08`, `exposure = 0x0200` on both sides, all channels:

```
CDB:     E1 00 00 00 00 03 00 00 28 00
Payload: 40 40 40 00 08 08 08 00 02 00 02 00 02 00 00 00
         00 00 00 00 40 40 40 00 08 08 08 00 02 00 02 00
         02 00 00 00 00 00 00 00
```

**This is an extrapolation from the formulas, not a value SANE ever sends.**
Treat it as a starting point to iterate from, not a known-good constant. The
real `calibrate_AFE` is only ~10 commands more and is guaranteed correct.

### 6.6 Fine calibration byte layouts (reference only — P-215 does not use these)

Included for completeness since you asked, and so you can rule them out.

**`FCAL_SRC_HW` — READ fine cal from scanner** (`calibrate_fine_src_hw`, `canon_dr.c:7431`):
```
offset: 28 00 90 00 00 <dpi/10> <len BE 3 bytes> 00       len = s.width*2
gain:   28 00 91 <uid> 00 <dpi/10> <len BE 3 bytes> 00    len = s.width*2
        uid: 0x07 gray, 0x0C red, 0x0A green, 0x09 blue, 0x14 unknown
```
Response is 2 bytes per pixel, interleaved by side: `in[j*2 + side]`.
Offsets are clamped to ≥1; gains are scaled `*3/4` and clamped ≥1
(`canon_dr.c:7511-7527, 7566-7569`).

**`FCAL_DEST_HW` — SEND fine cal to scanner** (`calibrate_fine_dest_hw`, `canon_dr.c:7746`):
```
CDB: 2A 00 <90|91> 00 00 00 <len BE 3 bytes> 00
     [0]=0x2A  [2]=datatype  [4..5]=xfer id (unused here)  [6..8]=length
payload length = s.width*2 + 4
payload[0]     = channel/side code   (set_S_FCAL_datatype)
                 0x00 f-red 0x04 f-green 0x08 f-blue
                 0x01 b-red 0x05 b-green 0x09 b-blue
                 OR with 0x40 for the GAIN variant
payload[1..3]  = 0
payload[4+k*2] = 0, payload[4+k*2+1] = value   (16-bit BE per pixel)
```
canon_dr currently hardcodes 140 for offset and 40 for gain with a `TODO`
(`canon_dr.c:7791, 7810`). **5092 bytes at 300 dpi — would not fit your data-out
limit.** Only used by DR-C225-class models (`canon_dr.c:1891`). Not the P-215.

---

## 7. Teardown

### 7.1 What `canon_dr` actually sends after a batch

**Almost nothing.** Specifically:

- **RELEASE UNIT `0x17`: never sent.** Zero call sites. Since RESERVE UNIT is
  never sent either, there is nothing to release.
- **CANCEL `0xd8`: only on an explicit cancel.** `check_for_cancel()`
  (`canon_dr.c:8093`) sends it **only** when `s->started && s->cancelled`:
  ```c
  if(s->started && s->cancelled){
      /* CDB: D8 00 00 00 00 00 */
      do_cmd(... CANCEL_code ...);
      object_position(s, SANE_FALSE);   /* then eject */
      s->started = 0;
  }
  ```
  So the sequence on abort is **CANCEL `0xd8` then OBJECT POSITION discharge**.
- **Normal end of batch** (hopper ran dry): `object_position(feed)` returns
  `NO_DOCS`, `sane_start` jumps to its error label and just clears `started`
  (`canon_dr.c:5725-5730`). **No CANCEL, no eject, no release.** The frontend's
  subsequent `sane_cancel` hits the `else if(s->cancelled)` branch
  (`canon_dr.c:8129`) which sends nothing.
- **`sane_close`** (`canon_dr.c:8149`) only closes the fd and frees host buffers.

### 7.2 So what actually cleans up?

The **next batch's** `sane_start`, whose very first action is
`object_position(s, SANE_FALSE)` — a discharge — followed by `wait_scanner()`
(`canon_dr.c:5445-5454`). The comment is explicit: `/* eject paper leftover */`.

### 7.3 What happens if you skip teardown

| skipped | consequence |
|---|---|
| CANCEL `0xd8` after aborting mid-read | scanner may still be streaming a page; next command can return sense 2/0x04/0x01 (busy) or 5/0x2C/0x00 (command sequence error). **Send it if you abort mid-page.** |
| OBJECT POSITION discharge | paper stays in the transport. Next scan ejects it, so you lose one page or get a jam. Cheap to send — do it. |
| RELEASE UNIT `0x17` | nothing. Never reserved. |
| closing the fd cleanly | this is what `wait_scanner()`'s 5-retry ritual exists to recover from (`canon_dr.c:1114-1116`: *"first generation usb scanners can get flaky if not closed properly after last use"*). |

**Recommended teardown:** `CANCEL 0xd8` (only if aborting mid-page) →
`OBJECT POSITION discharge` → `TEST UNIT READY`. Three commands, no payloads.

---

## 8. Minimal viable sequence

**Goal:** one 300 dpi, 24-bit colour, simplex page off the ADF, tolerating
imperfect colour.

**Assumptions:** VPD already read once (you have `max_x`, `max_y`); `max_x` ≤ 10200
so ULX = 0; Letter geometry → `width_px = 2544`, `Bpl = 7632`, `height = 3300`,
`bytes_tot = 25,185,600`.

Legend: **[R]** = required, **[O]** = optional.

---

### Phase A — wake up

```
A1  [R]  TEST UNIT READY
         CDB: 00 00 00 00 00 00
         (retry up to 5×; on the 4th attempt follow with REQUEST SENSE)

A2  [O]  INQUIRY std                          — skip if you already know the model
         CDB: 12 00 00 00 30 00               in: 0x30

A3  [O]  INQUIRY EVPD page 0xF0               — needed ONCE to learn max_x/max_y
         CDB: 12 01 F0 00 1E 00               in: 0x1e
```

### Phase B — coarse calibration (see §6 — strongly recommended, not strictly required)

Skip the whole phase for a first smoke test. No paper is fed here.

```
B1  [O]  SET SCAN MODE, buffer page, DUPLEX
         CDB: D6 10 00 00 14 00
         out: 00 13 00 00 32 0E 02 00 00 00 00 00 00 00 00 00 00 00 00 00

B2  [O]  SET WINDOW, front, 8 lines, colour       (length field = 8*1200/300 = 32 = 0x20)
         CDB: 24 00 00 00 00 00 00 00 34 00
         out: 00 00 00 00 00 00 00 2C 00 00 01 2C 01 2C 00 00
              00 00 FF FF FF FF 00 00 27 C0 00 00 00 20 80 5A
              80 05 08 00 00 10 00 00 00 00 00 00 00 00 00 00
              00 00 88 00

B3  [O]  SET WINDOW, back  — identical, descriptor byte 0 (payload offset 8) = 01

B4  [O]  COR CAL  pass 1 (gain=1 offset=1 exposure=0)
         CDB: E1 00 00 00 00 03 00 00 28 00
         out: 01 01 01 00 01 01 01 00 00 00 00 00 00 00 00 00
              00 00 00 00 01 01 01 00 01 01 01 00 00 00 00 00
              00 00 00 00 00 00 00 00

B5  [O]  SCAN, lamp off
         CDB: 1B 00 00 00 02 00      out: FF FF

B6  [O]  READ image, exact, 122112 bytes (= Bpl*8*2)
         CDB: 28 00 00 00 00 00 01 DD 00 00
         → de-interleave FBfb, take min over front[0..valid_Bpl) and back[...]
         → c_offset[side] = min*3 - 2

B7  [O]  COR CAL  pass 2 (exposure = 0x0320, offsets from B6)
B8  [O]  SCAN lamp on:  1B 00 00 00 02 00  out: FE FE
B9  [O]  READ image, exact, 122112 bytes
         → per channel: max over buffers[i][j], j += 3
         → c_exposure[i][j] = 0x320 * 102 / max

B10 [O]  COR CAL  pass 3 (offsets + exposures from above)
B11 [O]  SCAN lamp on:  1B 00 00 00 02 00  out: FE FE
B12 [O]  READ image, exact, 122112 bytes
         → max over whole valid_Bpl → c_gain[i] = (250-max)*4/5, clamp ≥ 1

B13 [O]  COR CAL  final commit (gain + offset + exposure)
         CDB: E1 00 00 00 00 03 00 00 28 00      out: 40 bytes
```

> **One-command alternative to all of Phase B** (§6.5): send a single
> `COR CAL` with hardcoded values, no cal scans:
> ```
> CDB: E1 00 00 00 00 03 00 00 28 00
> out: 40 40 40 00 08 08 08 00 02 00 02 00 02 00 00 00
>      00 00 00 00 40 40 40 00 08 08 08 00 02 00 02 00
>      02 00 00 00 00 00 00 00
> ```
> Extrapolated, not a SANE constant. Iterate on the three scalars.

### Phase C — configure the real scan

```
C1  [R]  SET SCAN MODE, buffer page, SIMPLEX
         CDB: D6 10 00 00 14 00
         out: 00 13 00 00 32 0E 00 00 00 00 00 00 00 00 00 00 00 00 00 00
         (REQUIRED if you ran Phase B — it left the scanner in duplex)

C2  [R]  SET WINDOW, front, full page
         CDB: 24 00 00 00 00 00 00 00 34 00
         out: 00 00 00 00 00 00 00 2C 00 00 01 2C 01 2C 00 00
              00 00 FF FF FF FF 00 00 27 C0 00 00 33 90 80 5A
              80 05 08 00 00 10 00 00 00 00 00 00 00 00 00 00
              00 00 88 00

C3  [O]  SET SCAN MODE, double-feed page, all off
         CDB: D6 10 00 00 14 00
         out: 00 13 00 00 30 0E 00 00 00 00 00 00 00 00 00 00 00 00 00 00

C4  [—]  SET SCAN MODE dropout page — SKIPPED in colour mode (canon_dr.c:4425)

C5  [O]  SEND panel (resets page counter / LED)
         CDB: 2A 00 84 00 00 00 00 00 08 00
         out: 00 00 01 00 00 00 00 00
```

### Phase D — feed and scan

```
D1  [R]  OBJECT POSITION — FEED
         CDB: 31 01 00 00 00 00 00 00 00 00
         → sense 3/0x3A/0x00 or 5/0x3A/0x00 means HOPPER EMPTY = end of batch

D2  [R]  TEST UNIT READY
         CDB: 00 00 00 00 00 00

D3  [R]  SCAN, simplex front
         CDB: 1B 00 00 00 01 00
         out: 00
```

### Phase E — READ loop

```
E   [R]  repeat until end of page:

         CDB: 28 00 00 00 00 00 1F E8 A0 00      (2,091,168 = 274 lines × 7632)

         on GOOD                 → got a full chunk, keep going
         on CHECK CONDITION:
             REQUEST SENSE: 03 00 00 00 0E 00
             key 0, ILI=1        → END OF PAGE.
                                   valid = 2091168 − information(bytes 0x03-0x06 BE)
             key 2 (any ASC)     → BUSY: treat as a 0-byte GOOD read, loop again
             key 3, ASC 0x3A     → no more documents
             key 3, ASC 0x80/81  → jam / cover / double-feed → abort
             key 5, ASC 0x2C     → you skipped a required step
             key 5, ASC 0x24/26  → your CDB or window payload is malformed

         also clamp: if bytes_received > (bytes_tot − bytes_so_far),
                     truncate to the remainder

         for each complete 7632-byte line in the chunk:
             out_line = deinterlace_rRgGbB(raw_line, pwidth=2544)   # §5.1
             append out_line to the image

         if short-read/EOF and you have fewer than 3300 lines,
             pad the remainder with 0xEE (bg_color)                 # canon_dr.c:7069
```

Expect ~13 iterations for a full Letter page.

### Phase F — teardown

```
F1  [O]  CANCEL — ONLY if you aborted mid-page
         CDB: D8 00 00 00 00 00

F2  [R]  OBJECT POSITION — DISCHARGE
         CDB: 31 00 00 00 00 00 00 00 00 00

F3  [O]  TEST UNIT READY
         CDB: 00 00 00 00 00 00

     RELEASE UNIT 0x17: never send. canon_dr never reserves.
```

### Phase G — next page in the same batch

Do **not** re-run Phase B or C. `always_op = 1` on this model, so
(`canon_dr.c:5617-5643`):

```
G1  OBJECT POSITION FEED   31 01 00 00 00 00 00 00 00 00
    → NO_DOCS = batch finished
G2  TEST UNIT READY        00 00 00 00 00 00
G3  SCAN                   1B 00 00 00 01 00  out: 00
G4  READ loop (Phase E)
```

---

## Absolute minimum, no calibration, one page

Nine commands:

```
 1.  00 00 00 00 00 00                                 TEST UNIT READY
 2.  D6 10 00 00 14 00  + 20-byte buffer page          SET SCAN MODE (simplex)
 3.  24 00 00 00 00 00 00 00 34 00 + 52-byte window    SET WINDOW
 4.  31 01 00 00 00 00 00 00 00 00                     OBJECT POSITION feed
 5.  00 00 00 00 00 00                                 TEST UNIT READY
 6.  1B 00 00 00 01 00  + {00}                         SCAN
 7.  28 00 00 00 00 00 1F E8 A0 00   (× ~13)           READ image
 8.  03 00 00 00 0E 00  (as needed)                    REQUEST SENSE
 9.  31 00 00 00 00 00 00 00 00 00                     OBJECT POSITION discharge
```

Plus host-side `deinterlace_rRgGbB` on every 7632-byte line. If the image comes
out dark or colour-cast, add the `COR CAL` from §6.5, then Phase B if that isn't
enough.

---

## Things most likely to bite you, ranked

1. **Window width must be `2544 px → 10176`, not 10200.** `ppl_mod = 8` rounds
   the *pixel* width down before conversion back to 1/1200 units. Wrong value =
   every scanline sheared.
2. **ULY = `0xFFFFFFFF` for `tl_y = 0`.** `invert_tly` is real. It looks like a
   bug; it isn't.
3. **Composition byte 0x19 = `0x05` for colour**, not 3. And byte 0x1A = `8`,
   not 24.
4. **`unknown_byte2 = 0x88` goes at descriptor offset 0x2A** = payload offset
   0x32, third-from-last byte.
5. **Front and back use *different* interlace schemes**, and the P-215 has them
   swapped relative to the P-208. Front colour is mirrored (`rRgGbB`), back is
   not (`RRGGBB`). Front gray is mirrored (`gG`), back gray is not.
6. **Sense key 2 is not an error** — it means "not ready yet", and the read loop
   must treat it as a zero-byte successful read and retry.
7. **End of page is sense key 0 with ILI=1**, and the byte count is
   `requested − information[0x03..0x06]`.
8. **Duplex de-interleave happens *before* colour de-interlace**, not after.
9. **`duplex_offset` from the shipped config is 1640 for P-215II by accident.**
   Start at 0.
10. **Don't send RESERVE UNIT, RELEASE UNIT, GET SCAN MODE, or MODE SELECT.**
    SANE never does, and 5/0x20 or 5/0x2C is a plausible response.
