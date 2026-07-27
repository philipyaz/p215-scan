# Canon P-215II — userspace "file tunnel" SCSI transport

Reverse-engineered from `launcher.bin` (Mach-O x86-64, `CaptureOnTouch Lite Launcher`).
Every claim below cites the instruction address that supports it. Addresses are vmaddrs;
file offset = vmaddr − 0x100000000 for this binary (`__text` addr 0x100001250 @ file offset 0x1250).

Uncertain points are called out explicitly in §7.

---

## 0. Object layout and cast of characters

### 0.1 `CCanoFileScanner` instance layout

Derived from the ctor `CCanoFileScannerC2` (0x100002e0e), `CDocScannerC2` (0x100003b16),
`OpenSession` (0x100002ff0) and the 0x438-byte allocation in `CCeiFileIOLite::LoadDevice`
(`mov edi, 0x438` @ 0x100001350).

```c
struct CCanoFileScanner {           /* size 0x438 */
/* 0x000 */ void**   vptr;                  /* __ZTV16CCanoFileScanner+0x10 = 0x10000e6a0   */
/* 0x008 */ uint32_t state;                 /* CDocScanner: 0 closed,1 open,2 scan,4 done   */
/* 0x010 */ uint32_t magic;                 /* 'elFi' = 0x69466c65, from desc[0]            */
/* 0x014 */ SScannerDesc desc;              /* 0x404 bytes, memcpy'd @0x100003b4d           */
/* 0x418 */ int      fd_indata;             /* open("…/INDATA.dat")   @0x100003073          */
/* 0x41c */ uint16_t indata_orig_mode;      /* st_mode saved          @0x1000030c1          */
/* 0x420 */ int      fd_transfer;           /* open("…/TRANSFER.dat") @0x10000312e          */
/* 0x424 */ uint16_t transfer_orig_mode;    /*                        @0x10000317a          */
/* 0x428 */ uint32_t last_device_status;    /* set @0x100003a8c, read by GetResponse         */
/* 0x42c */ uint32_t cmd_block_size;        /* = 0x18 (24)            @0x100002e27/0x100002e31 */
/* 0x430 */ uint32_t timeout_a_ms;          /* = 90000 (0x15F90)      @0x100002e27          */
/* 0x434 */ uint32_t timeout_b_ms;          /* = 90000 (0x15F90)      @0x100002e38          */
};
```

`SScannerDesc` (0x404 bytes), from `CCeiFileIOLite::LoadDevice` (0x10000128a) and
`CreateScannerList` (0x100002a20):

```c
struct SScannerDesc {           /* 0x404 bytes */
/* 0x000 */ uint32_t signature;         /* 'elFi' 0x69466c65   @0x1000012be / checked @0x100002a59 */
/* 0x004 */ char     vendor[16];        /* "CANON   "          @0x1000012c6                       */
/* 0x014 */ char     model[16];         /* "P-215II         "  strcpy @0x1000012ed                */
/* 0x024 */ uint8_t  pad[0x200];        /* never initialised — see §2.4                            */
/* 0x224 */ CFURLRef url_indata;        /* CFRetain'd @0x100002c8a                                */
/* 0x22c */ CFURLRef url_transfer;      /* CFRetain'd @0x100002c9d                                */
/* …      */
};
```

Because the descriptor is copied to `this+0x14`, `desc.url_indata` lands at `this+0x238`
and `desc.url_transfer` at `this+0x240` — exactly the two fields `OpenSession` opens
(0x100003007, 0x1000030df).

### 0.2 Virtual dispatch slots actually used

`__ZTV16CCanoFileScanner` @ 0x10000e690 (vptr = +0x10):

| slot  | method |
|-------|--------|
| +0x10 | `OpenSession` |
| +0x18 | `CloseSession` |
| +0x70 | `DecodeIOResult(uint32)` |
| +0x78 | `ReadData(void*, uint32*, uint32, uint32)` |
| +0x80 | `WriteData(void*, uint32, uint32, uint32)` |
| +0x88 | `ClearIO()` (no-op, 0x100003b0e) |
| +0x90 | `GetResponse()` |

`__ZTV14CCeiFileIOLite` @ 0x10000e600 (vptr = +0x10): +0x00 `LoadDevice`, +0x08 `UnLoadDevice`,
+0x10 `SetTransferTimeout`, +0x18 `ExecRead`, +0x20 `ExecWrite`, +0x28 `ExecNone`,
+0x30 `SetDeviceVender`, +0x38 `GetTransferLimit`, +0x40 `GetFIOError`, +0x48 `Release`.

---

## 1. The message header (answer to Q1)

All three command builders — `ExecRead` (0x100003450), `ExecWrite` (0x1000035a0),
`ExecNone` (0x100003730) and also `ExecRequestSense` (0x1000032c6) — emit the identical
8-byte constant:

```
1000034d2: 48 bb 00 00 00 14 00 01 90 00   movabs rbx, 0x90010014000000
1000034dc: 48 89 58 f4                     mov    qword ptr [rax - 0xc], rbx   ; block+0x00
1000034ec: c7 40 fc 00 00 00 00            mov    dword ptr [rax - 0x4], 0x0   ; block+0x08
1000034f9: e8 3a 7a 00 00                  call   _memcpy(block+0x0c, pCdb, cdbLen)
```

(identical at 0x100003622/0x10000362c/0x10000363c/0x100003649 in `ExecWrite`,
0x1000037ad/0x1000037b7/0x1000037c1/0x1000037cd in `ExecNone`,
0x100003347/0x100003351/0x100003354 in `ExecRequestSense`.)

Little-endian store of `0x0090_0100_1400_0000` produces the byte sequence
`00 00 00 14 | 00 01 90 00` — byte-for-byte the head of the live `transfer.dat` dump.

### 1.1 Generic 12-byte message prefix

The type-2 (data-out) block built by `ExecWrite` has the *same shape*:

```
10000367b: 41 8d 46 08     lea   eax, [r14 + 0x8]         ; r14 = data length n
10000367f: 0f c8           bswap eax                      ; big-endian
100003688: 89 43 f4        mov   dword ptr [rbx - 0xc], eax   ; block2+0x00 = BE32(n+8)
10000368b: 48 c7 43 f8 00 02 b0 00
                           mov   qword ptr [rbx - 0x8], 0xb00200
                                        ; block2+0x04..0x0B = 00 02 b0 00 00 00 00 00
1000036be: call _memcpy(block2+0x0c, pData, n)
```

So the transport uses one 12-byte prefix for both message kinds:

```c
/* everything marked BE is big-endian on the wire */
struct CeiFileMsgHeader {          /* 12 bytes */
    uint32_t be_len;    /* +0x00  BE32  payload_len + 8  ==  total_message_len - 4 */
    uint16_t be_type;   /* +0x04  BE16  1 = command (CDB), 2 = data-out            */
    uint16_t be_tag;    /* +0x06  BE16  0x9000 for type 1, 0xB000 for type 2       */
    uint32_t reserved;  /* +0x08  always written as 0                              */
};
```

Consistency check:

* type 1 — payload is a fixed **12-byte CDB field** → `be_len = 12 + 8 = 20 = 0x14`,
  total message = 24 = 0x18 (exactly what is written, see §1.3). ✔
* type 2 — payload is `n` data bytes → `be_len = n + 8`, total = `n + 12`. ✔

**Therefore `0x04-0x07` is NOT a buffer size and NOT a data length.** It is two 16-bit
big-endian fields: a *message type* selector and a constant tag/magic.
`WriteData` proves the type field is real — it dispatches on it:

```
1000038e2: 41 0f b7 45 04   movzx eax, word ptr [r13 + 0x4]   ; header+0x04 (u16 LE load)
1000038e7: 66 c1 c0 08      rol   ax, 0x8                     ; -> big-endian value
100003903: 83 f8 01         cmp   eax, 0x1                    ; type 1?
10000390c: 83 f8 02         cmp   eax, 0x2                    ; type 2?
```

`0x9000` / `0xB000` are never read back by the host; they are a constant tag the firmware
presumably uses to sanity-check the message. Reading `0x04-0x07` as a single BE32 gives
`0x00019000` (102400) for commands and `0x0002B000` (176128) for data — those numbers have
no meaning anywhere in the code, which is further evidence for the 16+16 split.

### 1.2 Command block (type 1) — written at `TRANSFER.dat` offset 0

```c
struct CeiCommandBlock {           /* exactly 24 bytes */
    struct CeiFileMsgHeader h;     /* { be_len=0x00000014, be_type=0x0001,
                                        be_tag=0x9000, reserved=0 }               */
    uint8_t cdb[12];               /* +0x0C .. +0x17, zero-padded (block is bzero'd) */
};
```

* **The CDB lives at offset 0x0C.**
* **Maximum CDB length is 12 bytes** (0x0C..0x17). This follows from `be_len = 0x14`
  (= 12-byte payload + 8) and from the fixed 24-byte `write()` at 0x10000398c–0x100003994.
  A CDB longer than 12 bytes would be silently truncated. Observed CDBs are 6 and 10 bytes.
* The whole block is zeroed before use (`movaps xmmword…, xmm0` runs 0x100003485–0x1000034ce
  over block+0 … block+0xFF), so short CDBs are naturally zero-padded.
* The redundant `mov byte ptr [rax], r9b` at 0x1000034f3 (writing `cdb[0]` before the memcpy)
  is dead code.

### 1.3 Data-out block (type 2) — written at `TRANSFER.dat` offset 0x1C

```c
struct CeiDataOutBlock {           /* 12 + n bytes */
    struct CeiFileMsgHeader h;     /* { be_len = n+8, be_type=0x0002,
                                        be_tag=0xB000, reserved=0 }               */
    uint8_t data[n];               /* payload starts at block2+0x0C
                                      => file offset 0x1C + 0x0C = 0x28           */
};
```

`ExecWrite` zero-pads the staging area out to 244 (0xF4) bytes
(`mov eax,0xf4; sub rax,r14; cmp r14,0xf3; cmovbe rsi,rax; bzero` @ 0x100003693–0x1000036b0).
The staging buffer only spans `rbp-0x224 … rbp-0x28` ≈ 508 bytes, so **`ExecWrite` is only
safe for small parameter blocks** (SET WINDOW / MODE SELECT sized). Bulk output is not
supported by this code path.

### 1.4 Where the payload begins

* **Data-out**: at `TRANSFER.dat` offset **0x28** (see §1.3).
* **Data-in**: the driver reads it from **`INDATA.dat` offset 0** — see §2.2. It does *not*
  read data-in from `transfer.dat`. The 64-byte INQUIRY response visible at
  `transfer.dat + 0x14` in the live dump is a firmware-side artefact; see §7.1.

---

## 2. File roles and the handshake (answer to Q2)

### 2.1 Which URL is which

`CreateScannerList` (0x100002a20) builds two URLs off the volume root:

```
100002b5d: lea rdx, [rip+0xc354]  ## 0x10000eeb8  -> CFSTR "INDATA.dat"
100002b64: call _CFURLCreateCopyAppendingPathComponent     -> r14  (URL #1)
100002b7a: lea rdx, [rip+0xc357]  ## 0x10000eed8  -> CFSTR "TRANSFER.dat"
100002b81: call _CFURLCreateCopyAppendingPathComponent     -> r12  (URL #2)
100002c85: CFRetain(URL #1)  -> desc+0x224   (=> this+0x238 => fd_indata)
100002c98: CFRetain(URL #2)  -> desc+0x22c   (=> this+0x240 => fd_transfer)
```

(CFString constants verified by dumping `__DATA,__cfstring` at 0x10000eeb8 / 0x10000eed8.)

| file | fd field | direction | offsets used |
|------|----------|-----------|--------------|
| `INDATA.dat`  | `this+0x418` | **host reads** device data-in | read @ 0; zero-filled 2 MiB at session open |
| `TRANSFER.dat`| `this+0x420` | **host writes** commands, data-out and the status doorbell; **host reads** the status word | write 24 B @ 0; write/read 4 B @ 0x18; write data-out @ 0x1C |

**`transfer.dat` is bidirectional but only in a narrow sense**: the host writes commands and
data-out into it and reads a 4-byte status word back out of it. Bulk data-in comes from
`INDATA.dat`. Only two `read(2)` call sites exist in the entire binary — 0x100003896
(`ReadData`, on `fd_indata`) and 0x100003a4a (status poll, on `fd_transfer`).

### 2.2 `ReadData` (0x100003862)

```
100003875: mov edi, dword ptr [rbx + 0x418]   ; fd_indata
10000387f: call _lseek(fd, 0, SEEK_SET)
100003890: mov edx, dword ptr [r15]           ; *pLen  (caller-supplied length)
100003896: call _read(fd_indata, buf, *pLen)
```

Always rewinds to 0 first. `*pLen` is **not** updated with the actual byte count, so the
transport reports no residual — the caller must trust the CDB's allocation length.
On error it tail-calls `DecodeIOResult(errno)` (0x1000038ae–0x1000038cc).

### 2.3 `OpenSession` (0x100002ff0) — exact sequence

```
100003007  url = this->desc.url_indata          ; NULL -> return 0x100
10000302d  path = CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle)
100003043  cstr = CFStringGetCStringPtr(path, 0)  (retry with system encoding @0x100003050)
10000306c  fd_indata = open(cstr, 0x82)         ; O_RDWR | O_SYNC
100003091  fcntl(fd_indata, 55 /*F_GLOBAL_NOCACHE*/, 1)
1000030ad  fstat(fd_indata, &st)                ; st_mode saved at this+0x41C
1000030d2  fchmod(fd_indata, 0)                 ; lock everyone else out
1000030e8 …0x10000318b  same five steps for TRANSFER.dat -> fd_transfer / this+0x424
100003199  buf = malloc(0x200000)               ; 2 MiB ; failure -> return 2
1000031ae  bzero(buf, 0x200000)
1000031c2  write(fd_indata, buf, 0x200000)      ; wipe the whole 2 MiB data-in window
1000031ca  free(buf)
1000031cf  this->state = 1
           return 0 (success)   /  0x100 on any failure
```

Note the wipe targets **`INDATA.dat`** (`[r13+0x418]` at 0x1000031b3), not transfer.dat,
and there is no `lseek` first — the fd is freshly opened so the offset is 0.

### 2.4 `CloseSession` (0x10000320c)

```
100003231  fchmod(fd_indata, saved_mode);  100003245 close(fd_indata)
100003263  lseek(fd_transfer, 0, SEEK_SET)
100003277  write(fd_transfer, this+0x38, 0x200)   ; 512 bytes over the command region
100003293  fchmod(fd_transfer, saved_mode); 1000032a7 close(fd_transfer)
1000032b6  this->state = 0
```

`this+0x38` is `desc+0x24` — the never-initialised middle of `SScannerDesc`. In practice this
is a 512-byte scribble that invalidates the command block. The destructor repeats it
(0x100002f18–0x100002f2c). A clean-room driver should just write 512 zero bytes there.

### 2.5 Per-transaction handshake

`ExecRead` (0x100003450):

```
1.  build 24-byte type-1 command block, CDB at +0x0C
2.  WriteData(block, cdbLen+12, t_a, t_b)          @0x100003521 (vtable+0x80)
      -> lseek(fd_transfer,0); write(24 B);        @0x100003980, 0x100003994
      -> unless opcode ∈ no-doorbell set:
           write(fd_transfer, 0xFFFFFFFF, 4)  @0x18  @0x1000039f9
           poll offset 0x18 until != 0xFFFFFFFF      @0x100003a2a-0x100003a77
    on non-zero result: return it (ExecRead) / DecodeIOResult(it) (ExecWrite/ExecNone)
3.  len = bufLen;  ReadData(pBuf, &len, t_a, t_b)  @0x100003559 (vtable+0x78)
      -> lseek(fd_indata,0); read(fd_indata, pBuf, len)
    on error: return DecodeIOResult(err)            @0x100003569
4.  return GetResponse()                            @0x100003575 (vtable+0x90)
```

`ExecNone` (0x100003730) is steps 1–2 then `GetResponse()` (0x1000037f0/0x100003810).

`ExecWrite` (0x1000035a0) is:

```
1.  type-1 command block  -> WriteData(...)   @0x100003671   (opcode is in the no-doorbell
                                                              set, so this returns at once)
2.  type-2 data block at file offset 0x1C, payload at 0x28
       -> WriteData(block2, n+12, t_a, t_b)   @0x1000036e5
       -> lseek(0x1C); write(n+12);           @0x100003923, 0x100003946
       -> lseek(0x18); write(0xFFFFFFFF,4); poll   @0x10000395f, 0x1000039f9
3.  return GetResponse()                      @0x100003722
```

Byte-level picture of `TRANSFER.dat` during a transaction:

```
offset  0x00 ┌──────────────────────────────────────────┐
             │ BE32 be_len = 0x00000014                 │
        0x04 │ BE16 type = 0x0001   BE16 tag = 0x9000   │
        0x08 │ reserved = 0x00000000                    │
        0x0C │ CDB[0..11]  (zero padded)                │
        0x18 ├──────────────────────────────────────────┤
             │ status doorbell — host writes 0xFFFFFFFF,│
             │ device replaces it (4 bytes, native LE)  │
        0x1C ├──────────────────────────────────────────┤
             │ data-out message: BE32 n+8 / BE16 0x0002 │
             │ / BE16 0xB000 / 0 / payload @0x28        │
             └──────────────────────────────────────────┘
```

---

## 3. Cache coherency (answer to Q3)

Exactly two `open(2)` call sites exist in the binary, both in `OpenSession`:

```
100003062: be 82 00 00 00   mov  esi, 0x82        ; flags
10000306c: e8 4b 7f 00 00   call _open            ; INDATA.dat
100003083: be 37 00 00 00   mov  esi, 0x37        ; cmd = 55
100003088: ba 01 00 00 00   mov  edx, 0x1         ; arg = 1
100003091: e8 24 7e 00 00   call _fcntl           ; fcntl(fd, 55, 1)
…
10000311d: be 82 00 00 00   mov  esi, 0x82        ; TRANSFER.dat, identical
100003127: e8 90 7e 00 00   call _open
100003144: be 37 00 00 00 / 100003152: call _fcntl
```

Decoding, against `<sys/fcntl.h>`:

* **`open(path, 0x82)` = `O_RDWR | O_SYNC`** (`O_RDWR`=0x0002, `O_SYNC`/`O_FSYNC`=0x0080).
  No `O_CREAT`, no `O_TRUNC`, no mode argument (`xor eax,eax` before the call).
  `O_DSYNC` (0x400000) is **not** used.
* **`fcntl(fd, 55, 1)` = `F_GLOBAL_NOCACHE` with arg 1** — not `F_NOCACHE` (48).
  `F_GLOBAL_NOCACHE` disables the unified buffer cache for the **vnode**, i.e. for every
  descriptor any process holds on that file, not just this fd. That is what makes the
  identification path (§4.1) and any concurrent reader see uncached data too.
* `fsync`, `F_FULLFSYNC` (51), `F_NODIRECT` (62), `mmap`/`msync` are **never called** — they
  are not even imported (`nm -u launcher.bin` has `fcntl`, `open`, `read`, `write`, `lseek`,
  `close`, `fchmod`, `fstat$INODE64`, `usleep`; no `fsync`, no `mmap`).
* The files are **opened once per session and kept open** — there is no re-open per
  transaction. Freshness comes purely from `O_SYNC` + `F_GLOBAL_NOCACHE`.
* Every access is `lseek(SEEK_SET)` immediately followed by a single `read`/`write`
  (0x10000387f/0x100003896, 0x100003a34/0x100003a4a, 0x100003980/0x100003994,
  0x100003923/0x100003946) — the code never relies on the implicit file position except
  for the doorbell write at 0x1000039f9, which relies on the position being 0x18 after the
  24-byte command write.
* Additional hardening: `fchmod(fd, 0)` right after opening (0x1000030d2, 0x10000318b),
  restored on close (0x100003231, 0x100003293). This makes the files mode 0000 for the
  duration of the session so Finder/Spotlight/mds cannot open them and inject stray reads.

**Reproduction recipe for a new driver:**
```c
int fd = open(path, O_RDWR | O_SYNC);         /* 0x82 */
fcntl(fd, F_GLOBAL_NOCACHE /*55*/, 1);
struct stat st; fstat(fd, &st);
fchmod(fd, 0);                                 /* restore st.st_mode at close */
```

---

## 4. Polling / completion detection (answer to Q4)

All of this is inside `WriteData` (0x1000038ce).

### 4.1 Arming the doorbell

```
1000039e7: 48 8d 75 d4          lea   rsi, [rbp - 0x2c]
1000039eb: c7 06 ff ff ff ff    mov   dword ptr [rsi], 0xffffffff
1000039f1: 41 8b 3f             mov   edi, dword ptr [r15]     ; fd_transfer
1000039f4: ba 04 00 00 00       mov   edx, 4
1000039f9: e8 3c 76 00 00       call  _write                   ; 4 bytes at offset 0x18
```

The write lands at **offset 0x18** because the preceding command-block write left the file
position there (24 bytes from 0), and the type-2 path explicitly seeks back to 0x18
(`mov esi, 0x18; lseek` @ 0x100003958–0x10000395f).

### 4.2 Poll loop

```
100003a08: call _CFAbsoluteTimeGetCurrent      ; t0, seconds (double)
100003a10: cvtsi2sd xmm1, rax                  ; timeout_ms  (r8d arg = this->timeout_b_ms)
100003a15: divsd    xmm1, [0x10000cdd8]        ; constant 1000.0  (verified by dump)
100003a1d: addsd    xmm1, xmm0                 ; deadline = t0 + timeout_ms/1000
loop:
100003a2a: lseek(fd_transfer, 0x18, SEEK_SET)
100003a4a: read (fd_transfer, &status, 4)
100003a55: cmp dword ptr [rbp-0x2c], -1
100003a5b: mov edi, 0x186a0                    ; 100000 µs
100003a60: call _usleep                        ; ONLY when status is still 0xFFFFFFFF
100003a65: now = CFAbsoluteTimeGetCurrent()
100003a6d: if (status != 0xFFFFFFFF) break
100003a72: if (now <= deadline) goto loop
100003a79: eax = (now <= deadline) ? 0 : 0xA0000
100003a8c: this->last_device_status = status
```

* **Sentinel / "busy" value: `0xFFFFFFFF`.** The host writes it; the device replaces it.
  The value is read as a native little-endian `uint32` (plain `dword` compare), **not**
  byte-swapped — unlike every field in the message header.
* **Poll interval: 100 ms** (`usleep(0x186A0)`), and only when the status is still busy.
  There is **no initial delay** — the first status read happens immediately after the
  doorbell write.
* **Timeout: `this->timeout_b_ms`, default 90000 ms (90 s)** — set by the ctor
  (`mov dword ptr [rbx+0x434], 0x15f90` @ 0x100002e38).
  `CCeiFileIOLite::SetTransferTimeout` (0x1000015d8) writes the same value into **both**
  `+0x430` and `+0x434` (0x1000015f1/0x1000015f7). **It is never called in this binary**, so
  90 s stands. `WriteData` only consumes the `+0x434` value (`mov r14d, r8d` @ 0x1000038eb);
  the `+0x430` argument is loaded into `ecx` at every call site and then discarded
  (`xor ecx,ecx` @ 0x1000038f4). `ReadData` ignores both.
* **Return: 0 on completion, `0xA0000` on timeout.**
  Edge case worth knowing: the deadline test at 0x100003a7b is applied *after* the loop
  regardless of why it exited, so a completion that arrives after the deadline is still
  reported as `0xA0000` even though `last_device_status` was updated.
* **`GetTransferLimit()`** (0x1000019d0) is a stub that prints
  `"WARNING : CCeiFileIOLite::GetTransferLimit is called"` and returns a hard-coded
  **`0x400000` (4 MiB)** (`mov eax, 0x400000` @ 0x100001a23). It is *not* consulted by any
  transfer path; `ReadToArchiveProcess` chunks at a hard-coded 1 MiB instead (§6.3).
  Note 4 MiB exceeds the 2 MiB `INDATA.dat` window, so treat 0x400000 as advisory only.

### 4.3 Opcodes that skip the doorbell entirely

```
10000396f: 45 8a 65 0c   mov   r12b, byte ptr [r13 + 0xc]      ; CDB opcode
1000039a3: 44 89 e0      mov   eax, r12d
1000039a6: 04 2a         add   al, 0x2a
1000039a8: 3c 3f         cmp   al, 0x3f
1000039aa: 0f 86 …       jbe   0x100003aa1
100003aa1: 48 b9 01 08 00 00 00 00 00 80   movabs rcx, 0x8000000000000801
100003aae: 48 0f a3 c1   bt    rcx, rax                        ; bits 0, 11, 63
1000039bb: 41 80 fc 2a   cmp   r12b, 0x2a
1000039c5: 48 b9 00 00 00 08 10 04 00 00   movabs rcx, 0x0000041008000000
1000039cf: 48 0f a3 c1   bt    rcx, rax                        ; bits 27, 36, 42
```

Solving the two bit tests:

| opcode | how it matches | standard name |
|--------|----------------|---------------|
| `0x15` | 0x15+0x2A = 0x3F → bit 63 | MODE SELECT(6) |
| `0x1B` | bit 27 of second mask | START STOP UNIT |
| `0x24` | bit 36 | SET WINDOW (SCSI scanner) |
| `0x2A` | bit 42 | WRITE(10) |
| `0xD6` | 0xD6+0x2A = 0x00 → bit 0 | vendor |
| `0xE1` | 0xE1+0x2A = 0x0B → bit 11 | vendor |

For these six opcodes `WriteData` returns 0 immediately after the 24-byte command write
(`xor eax,eax; jmp 0x100003a88`) with `last_device_status = 0` (`xor ebx,ebx` @ 0x10000397a) —
no doorbell, no poll. All except `0x1B` are data-out commands, i.e. `ExecWrite` will ring the
doorbell after the data phase. Every other opcode (TEST UNIT READY 0x00, REQUEST SENSE 0x03,
INQUIRY 0x12, the vendor flash read 0x3B, …) arms and polls.

### 4.4 `GetResponse` (0x100003ada)

```
100003ae0: cmp   dword ptr [rdi + 0x428], 0
100003ae7: setne al
100003aea: shl   eax, 0x14              ; << 20
```

Returns **`0x100000` if the device status word was non-zero, else 0**. This is the transport's
"check condition" flag; the numeric status value itself is kept in `this+0x428` and is never
otherwise inspected. Because SCSI status GOOD = 0 and CHECK CONDITION = 2, the natural reading
is that the device writes a SCSI status byte (zero-extended) into the 4-byte doorbell slot.

---

## 5. Error and sense handling (answer to Q5)

### 5.1 `ExecRequestSense` (0x1000032c6)

```
100003347  build a type-1 block: be_len=0x14, type=1, tag=0x9000, reserved=0
10000335b  block[0x0C] = 0x03     ; REQUEST SENSE opcode
10000336b  block[0x10] = 0x0E     ; CDB[4] = allocation length 14
           => CDB on the wire:  03 00 00 00 0E 00 00 00 00 00 00 00
100003372  edx = this->cmd_block_size (0x18)
100003388  WriteData(block, 0x18, timeout_a, timeout_b)      ; vtable+0x80
10000339e  *pLen = 0x0E
1000033be  ReadData(&sense, pLen, timeout_a, timeout_b)      ; vtable+0x78
1000033ca  parse (below)
100003425  GetResponse()                                      ; vtable+0x90 (result discarded)
```

The 14-byte sense buffer is a separate stack slot at `rbp-0x13E` (it is *not* inside the
zeroed 0x130-byte command block, which starts at `rbp-0x130`). Sense data therefore lands in
the normal data-in path: **`INDATA.dat`, offset 0, 14 bytes**.

Parsing (`ExecRequestSense(uint32* pSenseCode, uint8* pEom, uint32* pInformation)`):

```
1000033ca: movzx eax, byte ptr [rbp-0x13c]   ; sense[2]
1000033d1: and   eax, 0xf                    ; SENSE KEY
1000033d4: shl   eax, 0x10
1000033d7: movzx ecx, byte ptr [rbp-0x132]   ; sense[12] = ASC
1000033de: shl   ecx, 8
1000033e3: movzx eax, byte ptr [rbp-0x131]   ; sense[13] = ASCQ
1000033ec: mov   dword ptr [r12], eax        ; *pSenseCode = KEY<<16 | ASC<<8 | ASCQ
1000033f5: mov   al, byte ptr [rbp-0x13c]
1000033fb: shr   al, 6
1000033fe: and   al, 1
100003400: mov   byte ptr [r15], al          ; *pEom = sense[2] bit6 (EOM)
10000340a: test  byte ptr [rbp-0x13c], 0x20  ; ILI
100003411: mov   ecx, dword ptr [rbp-0x13b]  ; sense[3..6]
100003417: bswap ecx                         ; INFORMATION, big-endian
100003419: cmove ecx, 0                      ; only valid when ILI is set
10000341c: mov   dword ptr [r14], ecx        ; *pInformation
```

So it is a **standard fixed-format SCSI sense buffer**: `sense[2]` = FILEMARK/EOM/ILI/KEY,
`sense[3..6]` = INFORMATION (BE32, delivered only when ILI=1 — i.e. the residual byte count),
`sense[12]` = ASC, `sense[13]` = ASCQ. Only 14 bytes are requested, so `sense[7]`
(additional length) and anything past ASCQ are ignored.

Callers: `CCeiFileIOLite::ExecRead` @0x10000171b and `::ExecNone` @0x100001963, both as
`ExecRequestSense(&senseCode, NULL, &info)` (`xor edx,edx` supplies the NULL `pEom`), then
`fprintf(stderr, "CCeiFileIOLite::ExecRead sense code %x, invalid len = %x", senseCode, info)`
(format strings at 0x10000c254 and 0x10000c31c).

### 5.2 `CCanoFileScanner::DecodeIOResult(uint32 e)` (0x100003838)

Argument is a POSIX `errno` (fed from `__error()` at 0x1000038b5 / 0x100003ac7):

| errno | → transport code |
|-------|------------------|
| 0 | 0 |
| 60 (`ETIMEDOUT`) | `0xA0000` |
| 16 (`EBUSY`) | `0x200` |
| anything else | `0x100` |

`CDocScanner::DecodeIOResult` (0x100003be2), the base-class default, maps any non-zero to
`0xF0000`.

⚠ **Double-decode bug.** `ReadData`/`WriteData` already return *decoded* codes on error
(they tail-call `DecodeIOResult(errno)`), yet `ExecRead` (0x100003569),
`ExecWrite` (0x1000036f8) and `ExecNone` (0x100003805) call `DecodeIOResult` **again** on that
result. Since 0x100/0x200/0xA0000 are none of {0, 0x3C, 0x10}, every I/O error collapses to
`0x100` at that point. `ExecRead` avoids this for the *write* leg only, using
`cmp eax,0/cmovs` at 0x100003527–0x100003530.

### 5.3 Transport code → Win32 error (`CCeiFileIOLite::ConvertError`, 0x10000150a)

The same table is inlined in `LoadDevice` (0x1000013ee), `UnLoadDevice` (0x100001579),
`ExecRead` (0x10000167b), `ExecWrite` (0x10000179f) and `ExecNone` (0x1000018c3).

| transport code | Win32 code | name | source |
|---|---|---|---|
| `0x00000002` | `8` (0x08) | `ERROR_NOT_ENOUGH_MEMORY` | `OpenSession` malloc failure (0x100003204) |
| `0x00000100` | `1167` (0x48F) | `ERROR_DEVICE_NOT_CONNECTED` | generic I/O error; `OpenSession` open/fcntl/fstat/fchmod failure (0x10000300e) |
| `0x00000200` | `1117` (0x45D) | `ERROR_IO_DEVICE` | `EBUSY` |
| `0x000A0000` | `1117` (0x45D) | `ERROR_IO_DEVICE` | poll timeout, `ETIMEDOUT` |
| `0x000F0000` | `1117` (0x45D) | `ERROR_IO_DEVICE` | `CDocScanner::DecodeIOResult` default |
| `0x00100000` | **`0`** | — | `GetResponse()` check-condition |
| anything else | `0` | — | |

The result is stashed in `CCeiFileIOLite::m_error` (`this+0x10`) and returned by
`GetFIOError()` (0x100001a60).

⚠ **`0x100000` (device status non-zero / check condition) maps to Win32 `0`, i.e. "success".**
The `Exec*` wrappers still branch to `ExecRequestSense` on *any* non-zero scanner result
(`test eax,eax; jne` @ 0x1000016f9 → 0x100001707) and print the sense to stderr, but the value
handed back to the application is `0`. A clean-room driver should treat
`GetResponse() != 0` as CHECK CONDITION and act on the sense data.

### 5.4 CCeiSimpleDriver-level codes

`0xFFFFFC16` = −1002, `0xFFFFFC17` = −1001, `0xFFFFFC18` = −1000 (0x100003e94, 0x100003f10,
0x100004031, 0x10000437d).

---

## 6. Fetching the embedded CaptureOnTouch Lite payload (answer to Q6)

### 6.1 The vendor CDB — opcode `0x3B`

Built identically in `ReadFileHeaderFromScanner` (0x100003e31–0x100003e61) and
`ReadDataFromScanner` (0x10000403e–0x100004072):

```
10000404e: c6 06 3b          mov byte ptr [rsi], 0x3b   ; cdb[0] = 0x3B
100004046: mov qword ptr [rsi+1], 0                     ; cdb[1..8] = 0 (then overwritten)
100004042: mov byte ptr [rsi+9], 0                      ; cdb[9] = 0
100004053: shr eax, 0x18 ; mov [rsi+2], al              ; cdb[2] = addr >> 24
10000405b: shr eax, 0x10 ; mov [rsi+3], al              ; cdb[3] = addr >> 16
100004061: mov [rbp-0xe], dh                            ; cdb[4] = addr >> 8
100004064: mov [rsi+5], dl                              ; cdb[5] = addr
100004069: shr eax, 0x10 ; mov [rsi+6], al              ; cdb[6] = len >> 16
10000406f: mov [rbp-0xb], ch                            ; cdb[7] = len >> 8
100004072: mov [rsi+8], cl                              ; cdb[8] = len
10000407f: mov edx, 0x0a                                ; CDB length = 10
100004087: call [vtable+0x18]                           ; CCeiFileIOLite::ExecRead
```

```
byte : 0    1    2    3    4    5    6    7    8    9
value: 3B   00   A31  A16  A8   A0   L16  L8   L0   00
       ^op  ^0   ^--- 32-bit address, big-endian ---^  ^-- 24-bit length, BE --^  ^ctrl
```

```c
/* CDB is 10 bytes; the transport zero-pads it to 12 in the command block */
struct FlashReadCdb {
    uint8_t opcode;      /* 0x3B                                */
    uint8_t reserved;    /* 0x00                                */
    uint8_t addr[4];     /* big-endian byte address in flash    */
    uint8_t length[3];   /* big-endian transfer length in bytes */
    uint8_t control;     /* 0x00                                */
};
```

Note: 0x3B is WRITE BUFFER in standard SCSI — Canon has repurposed the opcode as a
**read** (it is issued through `ExecRead`, data-in). The address field is 4 bytes at
`cdb[2..5]`, i.e. one byte wider than standard READ BUFFER's 3-byte buffer offset.

`ReadDataFromScanner` rejects `length > 0xFFFFFF` up front
(`cmp ecx, 0xffffff; ja` @ 0x100004036) and returns −1001.

### 6.2 The flash directory header (`ReadFileHeaderFromScanner`, 0x100003dac)

```
100003e2c  addr = this->m_StartAddress     ; CCeiSimpleDriver+0x00
           CDB  = 3B 00 <addr BE32> 00 01 00 00     ; length = 0x000100 = 256 bytes
100003e76  ExecRead(cdb, 10, buf /*256 B stack*/, 0x100)
100003e81  FileCount = (buf[0] << 8) | buf[1]       ; BE16
100003e99  if (FileCount > 0x1F) return -1002       ; hard cap of 31 entries
100003ecb  entries = new(nothrow) uint8[12 * FileCount]
100003ee8  for (i = 0; i < FileCount; ++i) {
             size = bswap32(*(u32*)(buf + 2 + 8*i));   ; 0x100003ee8 / 0x100003ef6
             addr = bswap32(*(u32*)(buf + 6 + 8*i));   ; 0x100003eef / 0x100003ef8
             entries[i] = { .index = i,                ; store @0x100003efa (base+0)
                            .a     = addr,             ; store @0x100003eff (base+4)
                            .b     = size };           ; store @0x100003efd (base+8)
           }
```

`ReadToArchiveProcess` (0x100003f3a) then uses `entry+4` as the **byte count** to fetch
(0x100003f7e, decremented by the chunk size at 0x100003ff3) and `entry+8` as the **flash
address** (0x100003fbf, incremented at 0x100003fea). Feeding that back through the byte-swap
sites gives the on-flash layout:

```c
/* 256 bytes read from StartAddress; all fields big-endian */
struct FlashDirectory {
    uint16_t file_count;            /* +0x00, must be <= 31            */
    struct {
        uint32_t address;           /* +0x02 + 8*i : absolute flash byte address */
        uint32_t length;            /* +0x06 + 8*i : byte count                  */
    } file[/* file_count */];
};

/* in-memory form, 12 bytes/entry */
struct FlashDirEntry { uint32_t index; uint32_t length; uint32_t address; };
```

With `FileCount = 31` the last entry ends at byte 250, comfortably inside the 256-byte read.

### 6.3 Bulk transfer (`ReadToArchiveProcess`, 0x100003f3a)

```
100003f7e  remaining = entry[i].length
100003f8d  if (archive->GetBufSize() < remaining)         ; CArchiveCore vtable+0x18
100003f9e      archive->SetBufferSize(remaining)          ; vtable+0x10, bail with -1001 on failure
100003fbf  addr = entry[i].address
100003fc4  while (remaining) {
             chunk = min(remaining, 0x100000);            ; 1 MiB, hard-coded @0x100003fc4/0x100003fcc
             ReadDataFromScanner(ptr, addr, chunk);       ; @0x100003fe1
             addr += chunk; ptr += chunk; remaining -= chunk;
           }
100004004  archive->SetDataReady(true)                    ; vtable+0x40
```

**Chunk size = 1 MiB (0x100000)**, which fits inside the 2 MiB `INDATA.dat` window.
`GetTransferLimit()`'s 4 MiB is not used here.

### 6.4 Configuration and the two archives

`TouchDRL.ini` lives at
`CaptureOnTouch Lite Launcher.app/Contents/Resources/TouchDRL.ini` (string @ 0x10000c778),
section `[Launcher]` (@ 0x10000c7b9), read via `GetPrivateProfileInt` (0x10000439a).

| key | consumer | default |
|-----|----------|---------|
| `FileCount` (0x10000c7c2) | `CLauncherMainC2` @0x1000044bc → number of archives to pull | 1 |
| `StartAddress` (0x10000c7cc) | `CCeiSimpleDriver+0x00` @0x1000044d4, also `GetStartAddress` @0x100004520 | `0x10500000` (ctor 0x100003bf6) |
| `LoadNumber%d` (0x10000c7d9) | `GetLoadFileId` @0x10000463e → index into the flash directory | — |
| `Archive%dFileType` (0x10000c7e6) | `GetFileType` (0x10000467c) → `CArchiveCore::SetType` | — |
| `AppName` (0x10000c800) | app to exec after unpacking | — |

The shipped ini has `StartAddress = 272105472 = 0x10380000` (overriding the 0x10500000
built-in default) and `FileCount = 2`. The header read therefore is:

```
CDB: 3B 00 10 38 00 00 00 01 00 00      ; read 256 B @ 0x10380000
```

`CDecompCtrl::Decompress` (0x1000040d2) branches on `CArchiveCore::GetType()`
(vtable+0x38 @ 0x1000040f7):

* **0 → ZIP** → `TranslateIntoObjC::DecompressMemoryZipFileA` (0x100002557), which shells out
  to `/usr/bin/unzip -u <tmp>/ocr.zip -d <dir>` (CFStrings 0x10000ee18, 0x10000edd8,
  0x10000edb8, 0x10000edf8).
* **1 → TAR** → `TranslateIntoObjC::DecompressMemoryTarFileA` (0x1000027bc), which shells out
  to `/usr/bin/tar xzf <tmp>/TempLite.tar -C <dir>` (CFStrings 0x10000ee58, 0x10000ee78,
  0x10000ee38, 0x10000ee98).
* anything else → `"CDecompCtrl::Decompress() Unknown archive type"` (0x10000c740).

So the two payload files are a gzipped tar (the app bundle, staged as `TempLite.tar`) and a
zip (`ocr.zip`, the OCR resources), each described by one 8-byte flash-directory entry.

---

## 7. Uncertain points and competing hypotheses

### 7.1 Why does `transfer.dat + 0x14` contain an INQUIRY response?

**The facts.** `CreateScannerList` identifies the device *without* using the tunnel at all:

```
100002bca  path = CFURLCopyFileSystemPath(URL_TRANSFER)      ; TRANSFER.dat, not INDATA.dat
100002bfa  f = fopen(path, "r")                              ; buffered stdio, no O_SYNC
100002c1f  fread(buf, 1, 0x200, f)                           ; 512 bytes
100002c4c  strncmp(desc.vendor /*"CANON   "*/, buf + 0x1C, 8)   == 0
100002c75  strncmp(desc.model  /*"P-215II "*/, buf + 0x24, 16)  == 0
```

`buf+0x1C` and `buf+0x24` are exactly INQUIRY offsets 8 (vendor ID) and 16 (product ID) if the
INQUIRY response begins at file offset **0x14** — which is what the live hexdump shows.
Meanwhile the live protocol puts its status doorbell at **0x18**, i.e. overlapping INQUIRY
bytes 4..7. Both cannot be simultaneously true of a single flat byte array.

**Hypothesis A (preferred): asymmetric read/write views of `transfer.dat`.**
The firmware intercepts writes to these LBAs as command submission and synthesises the read
view. In the idle state the read view is `<20-byte command header echo> || <64-byte INQUIRY
response>` — a canned identity record so that enumeration costs no I/O. The 4 bytes at 0x18
behave as a status latch only after the host has written `0xFFFFFFFF` there. Evidence: the
identity record's header bytes (`00 00 00 14 00 01 90 00 00 00 00 00` + `12 00 00 00 40 00`)
are byte-identical to what `WriteData` emits for a type-1 INQUIRY, which is exactly what a
firmware that "replays the last transaction" would produce; `CreateScannerList` deliberately
uses plain `fopen`/`fread` before any session exists; and the driver's own data-in path never
touches `transfer.dat`.

**Hypothesis B: `INDATA.dat[0]` and `transfer.dat[0x14]` are two windows on the same in-buffer.**
Cheap to implement in a fake FAT, and it explains the INQUIRY placement directly. It requires
the firmware to special-case the 4 bytes at 0x18 in the read path, otherwise every poll would
read INQUIRY byte 4 (`0x0000003B`-ish), see "status != 0xFFFFFFFF and != 0", and make
`GetResponse()` return `0x100000` on essentially every command — which the app treats as
CHECK CONDITION and logs to stderr. That failure mode is not impossible (the sense path exists
and is chatty), but it would be a strange design.

**How to settle it empirically:** open a session (mode-0 + `O_SYNC` + `F_GLOBAL_NOCACHE`), write
a TEST UNIT READY command block, write `FF FF FF FF` at 0x18, then dump the first 128 bytes of
*both* files with `pread`. If `INDATA.dat[0..]` holds the response and `transfer.dat[0x18]`
holds a small status byte → Hypothesis A. If `transfer.dat[0x14..]` holds the response →
Hypothesis B.

### 7.2 Header field at `+0x00`: "payload+8" vs "data offset"

Both readings yield `0x14` for the command block. The type-2 block disambiguates: it stores
`BE32(n+8)` while its payload starts at `+0x0C`, which is only consistent with **"payload
length + 8" (= total message length − 4)**. That is the reading adopted above, and it implies
a **12-byte** CDB field. The competing reading ("offset at which data begins", giving an
8-byte CDB field plus 4 pad bytes) cannot explain the type-2 block, but it *does* match where
the firmware's INQUIRY response starts. Since only 6- and 10-byte CDBs are ever issued, the
difference is untested; if you need a 12-byte vendor CDB, place it at `+0x0C..+0x17` and keep
`be_len = 0x14`, but verify.

### 7.3 The reserved dword at `+0x08`

Always written as zero (0x1000034ec, 0x10000363c, 0x1000037c1, 0x100003354) and never read
back. Purpose unknown — plausibly a tag/sequence or a direction/flags word that this firmware
revision ignores.

### 7.4 `0x1B` in the no-doorbell set

`START STOP UNIT` is a non-data command, so under the "doorbell triggers execution" model it
would never actually run. Two readings: (a) the firmware executes on the command-block write
and the doorbell is only a completion latch, in which case `0x1B` is simply "fire and forget,
don't block on the motor"; or (b) the doorbell is the trigger and `0x1B` in this table is a
leftover from the Windows driver. Nothing in `launcher.bin` issues `0x1B`, so it is untested.

### 7.5 The `+0x430` timeout

Loaded into `ecx` at every `WriteData`/`ReadData` call site and then unconditionally discarded
(`xor ecx,ecx` @ 0x1000038f4). It presumably mattered in the USB/SCSI back-end that this file
back-end replaced. Only `+0x434` (90 s) has any effect.

---

## 8. Clean-room implementation summary

```c
/* ---- session ---- */
int fd_in  = open("/Volumes/ONTOUCHLITE/INDATA.dat",   O_RDWR | O_SYNC);
int fd_cmd = open("/Volumes/ONTOUCHLITE/TRANSFER.dat", O_RDWR | O_SYNC);
for (each fd) { fcntl(fd, 55 /*F_GLOBAL_NOCACHE*/, 1); fstat(fd,&st); fchmod(fd, 0); }
{ void *z = calloc(1, 2u<<20); pwrite(fd_in, z, 2u<<20, 0); free(z); }   /* wipe data-in */

/* ---- one transaction ---- */
int cei_exec(const uint8_t *cdb, size_t cdb_len,       /* <= 12 */
             void *din, size_t din_len,                /* data-in, may be NULL  */
             const void *dout, size_t dout_len)        /* data-out, may be NULL */
{
    uint8_t blk[24] = {0};
    blk[0]=0x00; blk[1]=0x00; blk[2]=0x00; blk[3]=0x14;   /* be_len  = 0x14      */
    blk[4]=0x00; blk[5]=0x01;                             /* be_type = 1         */
    blk[6]=0x90; blk[7]=0x00;                             /* be_tag  = 0x9000    */
    /* blk[8..11] = 0 */
    memcpy(blk + 0x0C, cdb, cdb_len);
    pwrite(fd_cmd, blk, 24, 0);

    if (dout) {                                            /* type-2 message @0x1C */
        uint8_t *m = malloc(12 + dout_len);
        uint32_t L = (uint32_t)dout_len + 8;
        m[0]=L>>24; m[1]=L>>16; m[2]=L>>8; m[3]=L;
        m[4]=0x00; m[5]=0x02; m[6]=0xB0; m[7]=0x00;
        memset(m+8, 0, 4);
        memcpy(m+12, dout, dout_len);
        pwrite(fd_cmd, m, 12 + dout_len, 0x1C);
        free(m);
    } else if (is_no_doorbell(cdb[0]))   /* 0x15,0x1B,0x24,0x2A,0xD6,0xE1 */
        return 0;

    uint32_t st = 0xFFFFFFFFu;                             /* arm the doorbell   */
    pwrite(fd_cmd, &st, 4, 0x18);

    double deadline = now() + 90.0;                        /* 90000 ms default   */
    for (;;) {
        pread(fd_cmd, &st, 4, 0x18);
        if (st != 0xFFFFFFFFu) break;
        usleep(100000);                                    /* 100 ms             */
        if (now() > deadline) return 0xA0000;              /* timeout            */
    }
    if (din) pread(fd_in, din, din_len, 0);                /* data-in @ INDATA.dat:0 */
    return st ? 0x100000 : 0;                              /* 0x100000 = check condition */
}

/* ---- known CDBs ---- */
/* TEST UNIT READY : 00 00 00 00 00 00                         (_TestUnitReady_CDB @0x10000fc24, BSS zeros) */
/* REQUEST SENSE   : 03 00 00 00 0E 00        -> 14 bytes in                                                */
/* INQUIRY         : 12 00 00 00 40 00        -> 64 bytes in                                                */
/* FLASH READ      : 3B 00 aa aa aa aa ll ll ll 00                                                          */

/* ---- close ---- */
uint8_t zero512[512] = {0};
pwrite(fd_cmd, zero512, 512, 0);
for (each fd) { fchmod(fd, saved_mode); close(fd); }
```
