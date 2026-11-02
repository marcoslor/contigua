import lldb, re
def rs(proc, a):
    try:
        e = lldb.SBError(); v = proc.ReadCStringFromMemory(a, 120, e)
        return v if e.Success() else None
    except Exception:
        return None
def name_at(t, a):
    sa = t.ResolveLoadAddress(a)
    s = sa.GetSymbol()
    n = s.GetName() if s.IsValid() else None
    return (n or hex(a)), sa.GetModule().GetFileSpec().GetFilename()
def walk(t, start, depth, seen, out):
    if start in seen or depth > 2: return
    seen.add(start)
    sym = t.ResolveLoadAddress(start).GetSymbol()
    insts = t.ReadInstructions(sym.GetStartAddress(), 400) if sym.IsValid() else t.ReadInstructions(t.ResolveLoadAddress(start), 120)
    proc = t.GetProcess(); err = lldb.SBError()
    page = {}
    n0, m0 = name_at(t, start)
    out.append("%s== %s [%s]" % ("  "*depth, n0, m0))
    end = sym.GetEndAddress().GetLoadAddress(t) if sym.IsValid() else None
    for i in insts:
        a = i.GetAddress().GetLoadAddress(t)
        if end and a >= end: break
        mn = i.GetMnemonic(t); op = i.GetOperands(t)
        if mn == "adrp":
            r, imm = op.split(",")[0].strip(), int(op.split(",")[1].strip(), 0)
            page[r] = (a & ~0xfff) + imm * 0x1000
        elif mn in ("ldr", "add") and page:
            m = re.match(r"(\w+), \[?(\w+), #(0x[0-9a-f]+|\d+)\]?", op)
            if m and m.group(2) in page:
                ref = page[m.group(2)] + int(m.group(3), 0)
                if mn == "ldr":
                    ptr = proc.ReadPointerFromMemory(ref, err)
                    s = rs(proc, ptr)
                    nm, mod = name_at(t, ptr)
                    out.append("%s  ref %s -> %s %s" % ("  "*depth, hex(ref), nm, ("'%s'" % s) if s and s.isprintable() and len(s) > 2 else ""))
                else:
                    s = rs(proc, ref)
                    nm, mod = name_at(t, ref)
                    out.append("%s  addr %s %s" % ("  "*depth, nm, ("'%s'" % s) if s and s.isprintable() and len(s) > 2 else ""))
        elif mn in ("bl", "b") and op.startswith("0x"):
            tgt = int(op.split()[0], 0)
            nm, mod = name_at(t, tgt)
            out.append("%s  %s %s [%s]" % ("  "*depth, mn, nm, mod))
            if mod == "WiFiAware" or "unnamed" in nm:
                walk(t, tgt, depth + 1, seen, out)
        if mn in ("ret", "retab") and not end: break
def run(dbg, cmd, res, d):
    t = dbg.GetSelectedTarget()
    syms = t.FindSymbols("$s9WiFiAware14WACapabilitiesV17supportedFeaturesShyAC7FeatureOGvgZ")
    a = syms.GetContextAtIndex(0).GetSymbol().GetStartAddress().GetLoadAddress(t)
    out = []
    walk(t, a, 0, set(), out)
    print("\n".join(out))
def __lldb_init_module(dbg, d):
    dbg.HandleCommand("command script add -f walk.run walk")
