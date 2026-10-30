import lldb
def cstr(frame, reg):
    v = frame.FindRegister(reg).GetValueAsUnsigned()
    err = lldb.SBError()
    s = frame.GetThread().GetProcess().ReadCStringFromMemory(v, 256, err)
    return s if err.Success() else hex(v)
def caller(frame):
    f1 = frame.GetThread().GetFrameAtIndex(1)
    return "%s`%s" % (f1.GetModule().GetFileSpec().GetFilename(), f1.GetFunctionName())
def hit(frame, bp_loc, d):
    name = frame.GetFunctionName()
    if name in ("_os_feature_enabled_impl",):
        a = "%s/%s" % (cstr(frame, "x0"), cstr(frame, "x1"))
    elif name.startswith("MG"):
        a = frame.EvaluateExpression("(id)$x0").GetObjectDescription()
    else:
        a = cstr(frame, "x0")
    print("HIT %s(%s) from %s" % (name, a, caller(frame)))
    return False
def __lldb_init_module(dbg, d):
    t = dbg.GetSelectedTarget()
    for n in ["_os_feature_enabled_impl", "MGGetBoolAnswer", "MGCopyAnswer", "sysctlbyname", "xpc_connection_create_mach_service", "IOServiceMatching", "IOServiceNameMatching", "SecTaskCopyValueForEntitlement"]:
        bp = t.BreakpointCreateByName(n)
        bp.SetScriptCallbackFunction("tr.hit")
