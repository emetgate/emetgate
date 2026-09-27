import json

MAX_SAFE_INTEGER = 2**53 - 1


class NotCanonical(Exception):
    pass


def _object(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise NotCanonical("duplicate member " + key)
        out[key] = value
    return out


def _no_float(text):
    raise NotCanonical("number with a fraction or an exponent: " + text)


def _no_constant(text):
    raise NotCanonical("not a JSON value: " + text)


def parse(data):
    if isinstance(data, bytes):
        try:
            data = data.decode("utf-8")
        except UnicodeDecodeError as err:
            raise NotCanonical("not UTF-8") from err
    try:
        return json.loads(data, object_pairs_hook=_object, parse_float=_no_float, parse_constant=_no_constant)
    except json.JSONDecodeError as err:
        raise NotCanonical(str(err)) from err


def _utf16_key(text):
    return text.encode("utf-16-be", "surrogatepass")


def _string(text):
    out = ['"']
    for ch in text:
        code = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\b":
            out.append("\\b")
        elif ch == "\f":
            out.append("\\f")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif code < 0x20:
            out.append("\\u%04x" % code)
        elif 0xD800 <= code <= 0xDFFF:
            raise NotCanonical("lone surrogate")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _write(value, out):
    if value is None:
        out.append("null")
    elif value is True:
        out.append("true")
    elif value is False:
        out.append("false")
    elif isinstance(value, int):
        if value > MAX_SAFE_INTEGER or value < -MAX_SAFE_INTEGER:
            raise NotCanonical("integer outside the IEEE 754 safe range")
        out.append(str(value))
    elif isinstance(value, str):
        out.append(_string(value))
    elif isinstance(value, list):
        out.append("[")
        for i, item in enumerate(value):
            if i:
                out.append(",")
            _write(item, out)
        out.append("]")
    elif isinstance(value, dict):
        out.append("{")
        for i, key in enumerate(sorted(value, key=_utf16_key)):
            if i:
                out.append(",")
            out.append(_string(key))
            out.append(":")
            _write(value[key], out)
        out.append("}")
    else:
        raise NotCanonical("unsupported value")


def canonicalize(value):
    out = []
    _write(value, out)
    return "".join(out).encode("utf-8")
