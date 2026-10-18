#!/usr/bin/env python3
"""Post-link fix for arm64e slices built with a clang that lacks -fptrauth-objc-isa.

The iOS 16/17 Objective-C runtime expects the `isa` and `superclass` fields of every class and
metaclass to be pointer-authenticated (key DA, address-diversified, discriminator 0x6AE1 for isa
and 0xB5AB for superclass). Procursus clang 16 emits them as plain chained-fixup rebase/bind
entries, and the runtime faults in readClass() the moment such a dylib is loaded into an arm64e
process. This script rewrites exactly those chained-fixup entries (DYLD_CHAINED_PTR_ARM64E format)
into their authenticated form. Everything else in the binary is left untouched.

Usage: sign-objc-isa.py <mach-o or fat file> [more files...]
Re-sign with `ldid -S` afterwards (the Makefile does).
"""
import struct, sys

FAT_MAGIC = 0xCAFEBABE
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_DYLD_CHAINED_FIXUPS = 0x80000034
ISA_BIND_SYMBOLS = {'___CFConstantStringClassReference', '__NSConcreteGlobalBlock', '__NSConcreteStackBlock', '__NSConcreteMallocBlock'}
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
KEY_DA = 2
DISC_ISA = 0x6AE1
DISC_SUPER = 0xB5AB


def decode(raw):
    auth = raw >> 63 & 1
    bind = raw >> 62 & 1
    nxt = raw >> 51 & 0x7FF
    return auth, bind, nxt


def plain_rebase_target(raw):
    target = raw & ((1 << 43) - 1)
    high8 = raw >> 43 & 0xFF
    return target | (high8 << 56)


def to_auth(raw, diversity):
    auth, bind, nxt = decode(raw)
    if auth:
        return raw, False
    if bind:
        ordinal = raw & 0xFFFF
        addend = raw >> 32 & 0x7FFFF
        if addend:
            raise SystemExit(f"bind entry with addend {addend} cannot be converted")
        new = ordinal | (diversity << 32) | (1 << 48) | (KEY_DA << 49) | (nxt << 51) | (1 << 62) | (1 << 63)
    else:
        target = plain_rebase_target(raw)
        if target >> 32:
            raise SystemExit(f"rebase target 0x{target:x} does not fit 32 bits")
        new = target | (diversity << 32) | (1 << 48) | (KEY_DA << 49) | (nxt << 51) | (1 << 63)
    return new, True


def patch_slice(buf, base, size):
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<IiiIIIII', buf, base)
    if magic != MH_MAGIC_64:
        return 0
    if cputype != CPU_TYPE_ARM64 or (cpusubtype & 0xFF) != CPU_SUBTYPE_ARM64E:
        return 0
    segments = []
    classlist = None
    fixups = None
    off = base + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', buf, off)
        if cmd == LC_DYLD_CHAINED_FIXUPS:
            fixups = struct.unpack_from('<II', buf, off + 8)   # dataoff, datasize
        if cmd == LC_SEGMENT_64:
            segname = buf[off + 8:off + 24].split(b'\0')[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', buf, off + 24)
            nsects = struct.unpack_from('<I', buf, off + 64)[0]
            segments.append((vmaddr, vmsize, fileoff))
            soff = off + 72
            for _ in range(nsects):
                sectname = buf[soff:soff + 16].split(b'\0')[0].decode()
                saddr, ssize, soffset = struct.unpack_from('<QQI', buf, soff + 32)
                if sectname == '__objc_classlist':
                    classlist = (saddr, ssize)
                soff += 80
        off += cmdsize
    if not classlist:
        return 0
    # --- names of bound symbols, so we can find CFString / block isa binds by walking the chains
    import_names = []
    if fixups:
        hdr = base + fixups[0]
        fixups_version, starts_offset, imports_offset, symbols_offset, imports_count, imports_format, symbols_format = struct.unpack_from('<7I', buf, hdr)
        if imports_format == 1:      # DYLD_CHAINED_IMPORT
            for i in range(imports_count):
                raw = struct.unpack_from('<I', buf, hdr + imports_offset + i * 4)[0]
                name_off = raw >> 9
                name = buf[hdr + symbols_offset + name_off:].split(b'\0')[0].decode()
                import_names.append(name)

    def fileoff(vmaddr):
        for segaddr, segsize, segfile in segments:
            if segaddr <= vmaddr < segaddr + segsize:
                return base + segfile + (vmaddr - segaddr)
        raise SystemExit(f"vmaddr 0x{vmaddr:x} not in any segment")

    def read_ptr(vmaddr):
        return struct.unpack_from('<Q', buf, fileoff(vmaddr))[0]

    def write_ptr(vmaddr, value):
        struct.pack_into('<Q', buf, fileoff(vmaddr), value)

    patched = 0
    seen = set()

    def fix_class(cls):
        nonlocal patched
        if cls in seen:
            return
        seen.add(cls)
        for field, disc in ((0, DISC_ISA), (8, DISC_SUPER)):
            raw = read_ptr(cls + field)
            if raw == 0:
                continue
            new, changed = to_auth(raw, disc)
            if changed:
                write_ptr(cls + field, new)
                patched += 1

    # --- walk every fixup chain: sign binds to the CFString/block class references (isa of constant objects)
    if fixups and import_names:
        hdr = base + fixups[0]
        starts = hdr + starts_offset
        seg_count = struct.unpack_from('<I', buf, starts)[0]
        for si in range(seg_count):
            seg_info_off = struct.unpack_from('<I', buf, starts + 4 + si * 4)[0]
            if seg_info_off == 0:
                continue
            so = starts + seg_info_off
            size, page_size, pointer_format, segment_offset, max_valid, page_count = struct.unpack_from('<IHHQIH', buf, so)
            if pointer_format not in (1, 12):   # DYLD_CHAINED_PTR_ARM64E, DYLD_CHAINED_PTR_ARM64E_USERLAND24
                raise SystemExit(f"unsupported chained pointer format {pointer_format}")
            ordinal_bits = 24 if pointer_format == 12 else 16
            for pi in range(page_count):
                page_start = struct.unpack_from('<H', buf, so + 24 + pi * 2)[0]
                if page_start == 0xFFFF:
                    continue
                pos = base + segment_offset + pi * page_size + page_start
                while True:
                    raw = struct.unpack_from('<Q', buf, pos)[0]
                    auth, bind, nxt = decode(raw)
                    if bind and not auth:
                        ordinal = raw & ((1 << ordinal_bits) - 1)
                        name = import_names[ordinal] if ordinal < len(import_names) else ''
                        if name in ISA_BIND_SYMBOLS:
                            new = ordinal | (DISC_ISA << 32) | (1 << 48) | (KEY_DA << 49) | (nxt << 51) | (1 << 62) | (1 << 63)
                            struct.pack_into('<Q', buf, pos, new)
                            patched += 1
                    if nxt == 0:
                        break
                    pos += nxt * 8

    saddr, ssize = classlist
    for i in range(ssize // 8):
        raw = read_ptr(saddr + i * 8)
        auth, bind, _ = decode(raw)
        if bind:
            continue
        cls = plain_rebase_target(raw)
        isa_raw = read_ptr(cls)
        fix_class(cls)
        auth, bind, _ = decode(isa_raw)
        if not bind:
            fix_class(plain_rebase_target(isa_raw))   # the metaclass
    return patched


def patch_file(path):
    buf = bytearray(open(path, 'rb').read())
    total = 0
    magic = struct.unpack_from('>I', buf, 0)[0]
    if magic == FAT_MAGIC:
        nfat = struct.unpack_from('>I', buf, 4)[0]
        for i in range(nfat):
            cputype, cpusubtype, offset, size, align = struct.unpack_from('>iiIII', buf, 8 + i * 20)
            total += patch_slice(buf, offset, size)
    else:
        total += patch_slice(buf, 0, len(buf))
    if total:
        open(path, 'wb').write(buf)
    print(f"{path}: {total} isa/superclass entries signed")
    return total


if __name__ == '__main__':
    for p in sys.argv[1:]:
        patch_file(p)
