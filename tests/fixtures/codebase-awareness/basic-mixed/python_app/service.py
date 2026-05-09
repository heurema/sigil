def parse_status(raw):
    value = raw.strip().lower()
    if value not in {"active", "disabled"}:
        raise ValueError("unknown status")
    return value


def format_status(raw):
    return parse_status(raw).upper()
