"""Luau string literal: UTF-8 kept raw, only \\ " and control characters escaped (Luau has no \\uXXXX)."""
def luastr(s):
    out = ['"']
    for ch in str(s):
        o = ord(ch)
        if ch == '\\': out.append('\\\\')
        elif ch == '"': out.append('\\"')
        elif ch == '\n': out.append('\\n')
        elif ch == '\r': out.append('\\r')
        elif ch == '\t': out.append('\\t')
        elif o < 32: out.append('\\%03d' % o)
        else: out.append(ch)
    out.append('"')
    return ''.join(out)
